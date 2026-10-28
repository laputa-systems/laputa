//! Match + apply (P3).
//!
//! Ports `run_scriptelem` / `run_script` / `act_on_event` / `on_event` and
//! `alias_format` from `src/mdevd/mdevd.c`. The transition table for `%`
//! expansion is generated verbatim into `tables.rs`.
//!
//! Behavior mirrors the reference, including observed quirks: only `add`
//! consults `MAJOR`/`MINOR` (so `remove` never unlinks), unknown actions
//! behave as "any" (no filesystem ops in v1), and every processed event
//! publishes — only variable-less records are dropped.
//!
//! Hardening over the reference (registered in `docs/divergence.md`):
//! sysfs fallback reads skip `..` escapes; the real adapter refuses
//! absolute/`..` node paths and only adopts an existing node on matching
//! type and device identity; a missing trailing newline in a sysfs
//! `uevent` file ends the value instead of crashing.

mod tables;
pub mod fake;
pub mod ops;

use crate::config::regex::lossy;
use crate::config::{Config, DevMatch, MoveKind, Rule, scan_decimal};
use crate::uevent::Uevent;
use ops::{MknodOut, NodeKind, Ops};
use tables::{FORMAT_CCLASS, FORMAT_TABLE};

pub const PATH_MAX: usize = 4096;
const NODE_CAP: usize = PATH_MAX - 5;
const SYS_DEV_MAX: usize = 22;
const SYS_UEVENT_MAX: usize = 8191;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Add,
    Remove,
    Any,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    pub devname: Vec<u8>,
    pub kind: NodeKind,
    pub maj: Option<u32>,
    pub min: Option<u32>,
    pub action: Action,
    pub sysdevpath: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Warn {
    pub level: u8,
    pub msg: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Drop,
    Publish,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Step {
    Stop,
    Continue,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EngineError {
    Hook { line: u32 },
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EngineError::Hook { line } => {
                write!(f, "rule at line {line} carries a command (rejected)")
            }
        }
    }
}

impl std::error::Error for EngineError {}

fn errno_msg(e: i32) -> String {
    // SAFETY: strerror returns a static string for any input.
    unsafe {
        let p = libc::strerror(e);
        if p.is_null() {
            return format!("errno {e}");
        }
        std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned()
    }
}

fn fmt_class(b: u8) -> usize {
    if b < 58 {
        (FORMAT_CCLASS[b as usize] - b'0') as usize
    } else {
        3
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AliasError {
    TooLong,
    Invalid,
}

/// Port of `alias_format`: expands `%1`-`%9` from regex captures and `%%`.
/// Returns the bytes INCLUDING the counted NUL terminator, like `w`.
pub fn alias_format(
    out_max: usize,
    fmt: &[u8],
    data: &[u8],
    caps: &[Option<(usize, usize)>; 10],
) -> Result<Vec<u8>, AliasError> {
    let mut w: Vec<u8> = Vec::new();
    let mut state: u8 = 0;
    let mut it = fmt.iter().chain(std::iter::once(&0u8));
    while state < 2 {
        let next = *it.next().unwrap_or(&0);
        let what = FORMAT_TABLE[state as usize][fmt_class(next)];
        state = what & 0x03;
        if what & 0x10 != 0 {
            if w.len() >= out_max {
                return Err(AliasError::TooLong);
            }
            w.push(next);
        }
        if what & 0x20 != 0 {
            let i = (next - b'0') as usize;
            // Only digits reach the substitute action (class 2), so `i < 10`
            // always holds; the bound below keeps even that assumption loud.
            let (so, eo) = caps.get(i).copied().flatten().unwrap_or((0, 0));
            let len = eo.saturating_sub(so);
            if w.len() + len > out_max {
                return Err(AliasError::TooLong);
            }
            w.extend_from_slice(&data[so.min(data.len())..eo.min(data.len())]);
        }
    }
    if state == 3 {
        return Err(AliasError::Invalid);
    }
    Ok(w)
}

pub type Caps = [Option<(usize, usize)>; 10];

/// Pure rule match: environment selectors (unanchored) plus the device
/// selector (anchored full match with captures), like `run_scriptelem`.
pub fn match_rule(cfg: &Config, rule: &Rule, ev: &Uevent, dev: &Device) -> Option<Caps> {
    for e in &rule.env {
        let v = ev.getvar(cfg.at(e.var))?;
        if !e.re.is_match(v) {
            return None;
        }
    }
    match &rule.dev {
        DevMatch::Nothing | DevMatch::Catchall => Some([None; 10]),
        DevMatch::MajMin { maj, minlo, minhi } => match (dev.maj, dev.min) {
            (Some(m), Some(n)) if m == *maj && n >= *minlo && n <= *minhi => Some([None; 10]),
            _ => None,
        },
        DevMatch::DevRe(re) => {
            let caps = re.captures10(&dev.devname)?;
            match caps[0] {
                Some((0, n)) if n == dev.devname.len() => Some(caps),
                _ => None,
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NodeFail {
    Empty,
    TooLong,
    Invalid,
    Internal,
}

/// Compute the device node path (without NUL), like the `MOVEINFO` block.
pub fn node_for(
    cfg: &Config,
    rule: &Rule,
    devname: &[u8],
    caps: &Caps,
) -> Result<Vec<u8>, NodeFail> {
    match rule.move_kind {
        MoveKind::Nothing | MoveKind::NoCreate => Ok(devname.to_vec()),
        MoveKind::Move | MoveKind::MoveAndLink => {
            let off = rule.movepath.ok_or(NodeFail::Internal)?;
            let w = alias_format(NODE_CAP, cfg.at(off), devname, caps).map_err(|e| match e {
                AliasError::TooLong => NodeFail::TooLong,
                AliasError::Invalid => NodeFail::Invalid,
            })?;
            if w.len() <= 1 {
                return Err(NodeFail::Empty);
            }
            let mut node = w[..w.len() - 1].to_vec();
            if node.last() == Some(&b'/') {
                if node.len() + devname.len() >= PATH_MAX - 6 {
                    return Err(NodeFail::TooLong);
                }
                node.extend_from_slice(devname);
            }
            Ok(node)
        }
    }
}

/// Slash-terminated prefixes, mirroring `mdevd_mkdirp` (including the empty
/// prefix of a leading slash).
fn mkdir_prefixes(path: &[u8]) -> Vec<&[u8]> {
    path.iter()
        .enumerate()
        .filter(|(_, &b)| b == b'/')
        .map(|(i, _)| &path[..i])
        .collect()
}

/// The run context: privileged operations plus the dry/real sink.
pub struct Run<'a> {
    pub ops: &'a mut dyn Ops,
    pub out: Out<'a>,
}

pub enum Out<'a> {
    Dry(&'a mut Vec<String>),
    Real(&'a mut Vec<Warn>),
}

impl Run<'_> {
    fn emit(&mut self, line: String) {
        if let Out::Dry(t) = &mut self.out {
            t.push(line);
        }
    }

    fn warn(&mut self, level: u8, msg: String) {
        match &mut self.out {
            Out::Dry(t) => t.push(format!("warn: {msg}")),
            Out::Real(w) => w.push(Warn { level, msg }),
        }
    }
}

fn apply_rule(
    cfg: &Config,
    rule: &Rule,
    dev: &Device,
    ev: &Uevent,
    root_dev: (u32, u32),
    run: &mut Run,
) -> Result<Step, EngineError> {
    let caps = match match_rule(cfg, rule, ev, dev) {
        Some(c) => c,
        None => return Ok(Step::Continue),
    };
    if rule.action_mask != 0 {
        // The daemon validates first; reaching this is a programming error.
        // Never spawn: fail loudly instead.
        return Err(EngineError::Hook { line: rule.line });
    }
    let node = match node_for(cfg, rule, &dev.devname, &caps) {
        Ok(n) => n,
        Err(e) => {
            let p = rule.movepath.map(|o| cfg.at(o)).unwrap_or_default();
            let d = dev.devname.as_slice();
            let errno = match e {
                NodeFail::TooLong => libc::ENAMETOOLONG,
                _ => libc::EINVAL,
            };
            run.warn(
                1,
                format!(
                    "process expression \"{}\" with devname \"{}\": {}",
                    lossy(p),
                    lossy(d),
                    errno_msg(errno)
                ),
            );
            return Ok(Step::Stop);
        }
    };
    let node_s = lossy(&node).into_owned();
    let dev_s = lossy(&dev.devname).into_owned();
    let has_mm = dev.maj.is_some() && dev.min.is_some();
    let is_add = dev.action == Action::Add && has_mm && !matches!(rule.move_kind, MoveKind::NoCreate);
    let is_remove =
        dev.action == Action::Remove && has_mm && !matches!(rule.move_kind, MoveKind::NoCreate);

    if is_add {
        if node.contains(&b'/') {
            if run.is_dry() {
                for p in mkdir_prefixes(&node) {
                    run.emit(format!("dry run: mkdir {}", lossy(p)));
                }
            } else if let Err(e) = run.ops.subdirs(&node) {
                run.warn(1, format!("create subdirectories for {node_s}: {e}"));
                return Ok(Step::Stop);
            }
        }
        let (maj, min) = (dev.maj.unwrap(), dev.min.unwrap());
        let kind_c = match dev.kind {
            NodeKind::Block => "b",
            NodeKind::Char => "c",
        };
        if run.is_dry() {
            run.emit(format!("dry run: mknod {node_s} {kind_c} {maj} {min}"));
            run.emit(format!("dry run: chmod {:o} {node_s}", rule.mode));
            if rule.uid != 0 || rule.gid != 0 {
                run.emit(format!("dry run: chown {}:{} {node_s}", rule.uid, rule.gid));
            }
        } else {
            match run.ops.mknod(&node, rule.mode, dev.kind, maj, min) {
                Ok(MknodOut::Created) => {}
                Ok(MknodOut::Exists) => {
                    if let Err(e) = run.ops.chmod(&node, rule.mode) {
                        run.warn(2, format!("chmod {node_s}: {e}"));
                    }
                }
                Err(e) => {
                    run.warn(1, format!("mknod {node_s}: {e}"));
                    return Ok(Step::Stop);
                }
            }
            if rule.uid != 0 || rule.gid != 0 {
                if let Err(e) = run.ops.chown(&node, rule.uid, rule.gid) {
                    run.warn(2, format!("chown {node_s}: {e}"));
                }
            }
        }
        if (maj, min) == root_dev {
            if run.is_dry() {
                run.emit(format!("dry run: symlink {node_s} to root"));
            } else {
                let _ = run.ops.symlink_replace(&node, b"root");
            }
        }
        if matches!(rule.move_kind, MoveKind::MoveAndLink) {
            if run.is_dry() {
                if dev.devname.contains(&b'/') {
                    for p in mkdir_prefixes(&dev.devname) {
                        run.emit(format!("dry run: mkdir {}", lossy(p)));
                    }
                }
                run.emit(format!("dry run: symlink {node_s} to {dev_s}"));
            } else {
                if dev.devname.contains(&b'/') {
                    if let Err(e) = run.ops.subdirs(&dev.devname) {
                        run.warn(1, format!("create subdirectories for {dev_s}: {e}"));
                        return Ok(Step::Stop);
                    }
                }
                if let Err(e) = run.ops.symlink_replace(&node, &dev.devname) {
                    run.warn(1, format!("symlink {node_s} to {dev_s}: {e}"));
                    return Ok(Step::Stop);
                }
            }
        }
    }

    if is_remove {
        // Unreachable through on_event (remove never carries maj/min), kept
        // for fidelity and covered by direct unit tests.
        if matches!(rule.move_kind, MoveKind::MoveAndLink) {
            if run.is_dry() {
                run.emit(format!("dry run: unlink {dev_s}"));
            } else {
                run.ops.unlink(&dev.devname);
            }
        }
        if run.is_dry() {
            run.emit(format!("dry run: unlink {node_s}"));
        } else {
            run.ops.unlink(&node);
        }
    }

    Ok(if rule.cont { Step::Continue } else { Step::Stop })
}

impl Run<'_> {
    fn is_dry(&mut self) -> bool {
        matches!(self.out, Out::Dry(_))
    }
}

fn scan_run(buf: &[u8]) -> Option<(u32, usize)> {
    let mut v: u32 = 0;
    let mut n = 0usize;
    for &b in buf {
        if !b.is_ascii_digit() {
            break;
        }
        v = v.checked_mul(10)?.checked_add((b - b'0') as u32)?;
        n += 1;
    }
    if n == 0 { None } else { Some((v, n)) }
}

/// Strict `maj:min\n` prefix rule for sysfs `dev` files, like the C code
/// (trailing content after the newline is ignored).
fn parse_dev_file(buf: &[u8]) -> Option<(u32, u32)> {
    let (maj, i) = scan_run(buf)?;
    if buf.get(i) != Some(&b':') {
        return None;
    }
    let (min, j) = scan_run(&buf[i + 1..])?;
    if buf.get(i + 1 + j) != Some(&b'\n') {
        return None;
    }
    Some((maj, min))
}

fn has_dotdot(path: &[u8]) -> bool {
    path.split(|&b| b == b'/').any(|seg| seg == b"..")
}

fn posix_basename(path: &[u8]) -> &[u8] {
    let mut p = path;
    while p.len() > 1 && p.ends_with(b"/") {
        p = &p[..p.len() - 1];
    }
    match p.iter().rposition(|&b| b == b'/') {
        Some(i) => &p[i + 1..],
        None => p,
    }
}

fn find_sub(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

/// Sysfs fallback read, relative to the sys root. `..` escapes are skipped
/// loudly instead of followed.
fn sys_read(
    run: &mut Run,
    slashsys: &[u8],
    sysdevpath: &[u8],
    file: &[u8],
    max: usize,
) -> Option<Vec<u8>> {
    let mut full = sysdevpath.to_vec();
    if !full.ends_with(b"/") {
        full.push(b'/');
    }
    full.extend_from_slice(file);
    if has_dotdot(&full) {
        run.warn(
            1,
            format!("skip sysfs read outside authority: {}", lossy(&full)),
        );
        return None;
    }
    let rel = full.strip_prefix(slashsys).unwrap_or(&full);
    let rel = rel.strip_prefix(b"/").unwrap_or(rel);
    run.ops.read_sys(rel, max).ok()
}

fn gather_device(
    req: &Request,
    sysdevpath: &[u8],
    action: Action,
    run: &mut Run,
) -> Option<Device> {
    let (mut maj, mut min) = (None, None);
    if action == Action::Add {
        if let (Some(maj_s), Some(min_s)) = (req.ev.getvar(b"MAJOR"), req.ev.getvar(b"MINOR")) {
            if let (Some(m), Some(n)) = (scan_decimal(maj_s), scan_decimal(min_s)) {
                maj = Some(m);
                min = Some(n);
            }
        }
        if maj.is_none() {
            if let Some(bytes) = sys_read(run, req.slashsys, sysdevpath, b"dev", SYS_DEV_MAX)
            {
                if let Some((m, n)) = parse_dev_file(&bytes) {
                    maj = Some(m);
                    min = Some(n);
                }
            }
        }
    }
    let devname = match req.ev.getvar(b"DEVNAME") {
        Some(d) => d.to_vec(),
        None => {
            let fallback = sys_read(run, req.slashsys, sysdevpath, b"uevent", SYS_UEVENT_MAX)
                .and_then(|bytes| {
                    let pos = find_sub(&bytes, b"\nDEVNAME=")?;
                    let start = pos + 9;
                    let end = bytes[start..]
                        .iter()
                        .position(|&b| b == b'\n')
                        // Robustness fix: a missing trailing newline ends the
                        // value instead of crashing (see divergence.md).
                        .map(|e| start + e)
                        .unwrap_or(bytes.len());
                    Some(bytes[start..end].to_vec())
                });
            match fallback {
                Some(d) => d,
                None => posix_basename(sysdevpath).to_vec(),
            }
        }
    };
    if devname.len() >= PATH_MAX - 1 {
        run.warn(1, format!("device name too long: {}", lossy(&devname)));
        return None;
    }
    let is_block = sysdevpath.windows(7).any(|w| w == b"/block/")
        || req
            .ev
            .getvar(b"SUBSYSTEM")
            .map(|s| s.starts_with(b"block"))
            .unwrap_or(false);
    Some(Device {
        devname,
        kind: if is_block { NodeKind::Block } else { NodeKind::Char },
        maj,
        min,
        action,
        sysdevpath: sysdevpath.to_vec(),
    })
}

pub struct Request<'a> {
    pub cfg: &'a Config,
    pub ev: &'a Uevent,
    pub slashsys: &'a [u8],
    pub root_dev: (u32, u32),
}

/// Mirror of `on_event`: `Drop` only for variable-less records; everything
/// processed (or skipped for a missing field) publishes.
pub fn on_event(req: &Request, run: &mut Run) -> Result<Outcome, EngineError> {
    if req.ev.vars.len() <= 1 {
        return Ok(Outcome::Drop);
    }
    let action = match req.ev.getvar(b"ACTION") {
        Some(b"add") => Action::Add,
        Some(b"remove") => Action::Remove,
        Some(_) => Action::Any,
        None => return Ok(Outcome::Publish),
    };
    let devpath = match req.ev.getvar(b"DEVPATH") {
        Some(p) => p,
        None => return Ok(Outcome::Publish),
    };
    let mut sysdevpath = Vec::with_capacity(req.slashsys.len() + devpath.len());
    sysdevpath.extend_from_slice(req.slashsys);
    sysdevpath.extend_from_slice(devpath);

    let firmware = req.ev.getvar(b"FIRMWARE");
    if action == Action::Remove && firmware.is_some() {
        return Ok(Outcome::Publish);
    }

    let dev = match gather_device(req, &sysdevpath, action, run) {
        Some(d) => d,
        None => return Ok(Outcome::Publish),
    };

    for rule in &req.cfg.rules {
        match apply_rule(req.cfg, rule, &dev, req.ev, req.root_dev, run)? {
            Step::Stop => break,
            Step::Continue => {}
        }
    }
    if action == Action::Add {
        if let Some(fw) = firmware {
            let msg = format!("firmware request for {} skipped (unsupported)", lossy(fw));
            match &mut run.out {
                Out::Dry(t) => t.push(msg),
                Out::Real(w) => w.push(Warn { level: 1, msg }),
            }
        }
    }
    Ok(Outcome::Publish)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::parse;
    use crate::config::regex::pin_c_locale;
    use fake::NullOps;

    fn dry_apply(conf: &str, dev: &Device) -> Vec<String> {
        pin_c_locale();
        let cfg = parse(conf.as_bytes()).unwrap();
        let ev = Uevent {
            buf: b"add@/x\0ACTION=remove\0".to_vec(),
            vars: vec![0, 9],
        };
        let mut ops = NullOps;
        let mut t = Vec::new();
        let mut run = Run {
            ops: &mut ops,
            out: Out::Dry(&mut t),
        };
        let step = apply_rule(&cfg, &cfg.rules[0], dev, &ev, (u32::MAX, u32::MAX), &mut run).unwrap();
        assert_eq!(step, Step::Stop);
        t
    }

    fn rm_dev(devname: &[u8]) -> Device {
        Device {
            devname: devname.to_vec(),
            kind: NodeKind::Block,
            maj: Some(8),
            min: Some(0),
            action: Action::Remove,
            sysdevpath: b"/sys/devices/x".to_vec(),
        }
    }

    #[test]
    fn engine_remove_branch() {
        // MoveAndLink unlinks the alias first, then the node.
        assert_eq!(
            dry_apply("(sd[a-z]) root:disk 660 >disk/%1\n", &rm_dev(b"sda")),
            vec!["dry run: unlink sda", "dry run: unlink disk/sda"]
        );
        // Plain Move unlinks only the node.
        assert_eq!(
            dry_apply("(sd[a-z]) root:disk 660 =disk/%1\n", &rm_dev(b"sda")),
            vec!["dry run: unlink disk/sda"]
        );
        // NoCreate removes nothing.
        assert!(dry_apply("sda root:disk 660 !\n", &rm_dev(b"sda")).is_empty());
    }

    #[test]
    fn engine_dev_file_edges() {
        assert_eq!(parse_dev_file(b"8:0\n"), Some((8, 0)));
        assert_eq!(parse_dev_file(b"8:0\ntrailing junk"), Some((8, 0)));
        assert_eq!(parse_dev_file(b"8:0"), None);
        assert_eq!(parse_dev_file(b"8"), None);
        assert_eq!(parse_dev_file(b"x:0\n"), None);
        assert_eq!(parse_dev_file(b""), None);
    }

    #[test]
    fn engine_basename_edges() {
        assert_eq!(posix_basename(b"/sys/devices/x"), b"x");
        assert_eq!(posix_basename(b"/sys/"), b"sys");
        assert_eq!(posix_basename(b"plain"), b"plain");
    }
}

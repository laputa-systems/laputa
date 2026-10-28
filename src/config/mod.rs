//! mdev.conf grammar and rule matching (P1).
//!
//! Faithful port of the reference two-pass state machines in
//! `src/mdevd/mdevd.c` (`script_firstpass`, `script_secondpass`). The
//! transition tables are generated verbatim from the C source by
//! `tools/gen-tables.py` into `tables.rs`; only the action application is
//! hand-written, mirroring the C statement order, including its quirks
//! (e.g. an `@`-led rule keeps `env_base` 0; see the differential corpus).
//!
//! Like the reference, tokens live as offsets into the surviving zeroed
//! working copy (`Config.storage`); nothing is re-sliced or re-encoded.
//!
//! Deliberate divergences, all registered in `docs/divergence.md`: input
//! larger than 8191 bytes is an error instead of a silent truncation;
//! command-carrying rules (including the empty-command quirk) are rejected
//! by [`validate_v1`] instead of spawned.

mod tables;
pub mod regex;

use regex::{Regex, lossy};
use std::ffi::CStr;
use std::fmt;
use tables::{FIRSTPASS_CCLASS, FIRSTPASS_TABLE, SECONDPASS_CCLASS, SECONDPASS_TABLE};

/// Reference CONFBUFSIZE; input may hold at most this minus the NUL.
pub const CONF_MAX: usize = 8192;
/// Reference UEVENT bounds, kept for the intake side (P2).
pub const UEVENT_MAX_VARS: usize = 63;
pub const UEVENT_MAX_SIZE: usize = 8192;

fn fp_class(b: u8) -> usize {
    if b < 65 {
        (FIRSTPASS_CCLASS[b as usize] - b'0') as usize
    } else {
        8
    }
}

fn sp_class(b: u8) -> usize {
    if b < 65 {
        (SECONDPASS_CCLASS[b as usize] - b'`') as usize
    } else {
        18
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvMatch {
    /// Offset of the NUL-terminated variable name in `Config.storage`.
    pub var: usize,
    pub re: Regex,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DevMatch {
    Nothing,
    Catchall,
    DevRe(Regex),
    MajMin { maj: u32, minlo: u32, minhi: u32 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MoveKind {
    Nothing,
    NoCreate,
    Move,
    MoveAndLink,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rule {
    /// The rule's own env matches (mirrors `envmatch[base..base+len]`).
    pub env: Vec<EnvMatch>,
    /// Absolute base, mirroring the reference `envmatchs` field (an
    /// `@`-led rule keeps 0 even after earlier rules; quirk preserved).
    pub env_base: usize,
    pub dev: DevMatch,
    pub cont: bool,
    pub uid: u32,
    pub gid: u32,
    pub mode: u32,
    pub move_kind: MoveKind,
    /// Offset of the NUL-terminated move path (`Move`/`MoveAndLink` only).
    pub movepath: Option<usize>,
    /// Add bit 0, remove bit 1 (both set = any action), like `cmdtype`.
    pub action_mask: u8,
    pub execline: bool,
    /// Offset of the NUL-terminated command text. `None` with a nonzero
    /// mask is the reference empty-command quirk (offset 0 there).
    pub cmd: Option<usize>,
    pub line: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub rules: Vec<Rule>,
    /// The zeroed working copy every offset points into.
    pub storage: Vec<u8>,
}

impl Config {
    /// Resolve a stored NUL-terminated offset to its bytes.
    pub fn at(&self, off: usize) -> &[u8] {
        CStr::from_bytes_until_nul(&self.storage[off..])
            .expect("stored offset is NUL-terminated")
            .to_bytes()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigError {
    TooLarge { len: usize },
    FirstPass { line: u32, col: u32 },
    SecondPass { line: u32, col: u32 },
    Regex { line: u32, is_env: bool, err: regex::RegexError },
    Number { line: u32, what: &'static str, text: Vec<u8> },
    User { line: u32, name: Vec<u8> },
    Group { line: u32, name: Vec<u8> },
    HooksUnsupported { line: u32 },
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConfigError::TooLarge { len } => {
                write!(f, "configuration too large: {len} bytes (max {})", CONF_MAX - 1)
            }
            ConfigError::FirstPass { line, col } => {
                write!(f, "syntax error during first pass: line {line} column {col}")
            }
            ConfigError::SecondPass { line, col } => {
                write!(f, "syntax error during second pass: line {line} column {col}")
            }
            ConfigError::Regex { line, is_env, err } => {
                let what = if *is_env { "envmatch" } else { "devmatch" };
                write!(
                    f,
                    "compile regular expression {} for {what} at line {line}: {}",
                    lossy(&err.pattern),
                    err.msg
                )
            }
            ConfigError::Number { line, what, text } => {
                write!(f, "get {what} from string {} at line {line}", lossy(text))
            }
            ConfigError::User { line, name } => {
                write!(f, "get uid from string {} at line {line}", lossy(name))
            }
            ConfigError::Group { line, name } => {
                write!(f, "get gid from string {} at line {line}", lossy(name))
            }
            ConfigError::HooksUnsupported { line } => {
                write!(f, "command hooks are unsupported in this build (line {line})")
            }
        }
    }
}

impl std::error::Error for ConfigError {}

/// Decimal scan mirroring `uint0_scan` (also used for `uid0`/`gid0`): ASCII
/// digits only, checked arithmetic, `None` on empty/non-digit/overflow.
pub fn scan_decimal(text: &[u8]) -> Option<u32> {
    if text.is_empty() {
        return None;
    }
    let mut v: u32 = 0;
    for &b in text {
        if !b.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((b - b'0') as u32)?;
    }
    Some(v)
}

fn scan_octal(text: &[u8]) -> Option<u32> {
    if text.is_empty() {
        return None;
    }
    let mut v: u32 = 0;
    for &b in text {
        if !(b'0'..=b'7').contains(&b) {
            return None;
        }
        v = v.checked_mul(8)?.checked_add((b - b'0') as u32)?;
    }
    Some(v)
}

fn nss_lock() -> std::sync::MutexGuard<'static, ()> {
    static NSS: std::sync::Mutex<()> = std::sync::Mutex::new(());
    NSS.lock().unwrap_or_else(|e| e.into_inner())
}

fn resolve_user(name: &[u8]) -> Option<u32> {
    let mut nt = Vec::with_capacity(name.len() + 1);
    nt.extend_from_slice(name);
    nt.push(0);
    // SAFETY: nt is NUL-terminated; the result is NULL or a static struct.
    // The static storage is process-global, so every access is serialized.
    let uid = {
        let _guard = nss_lock();
        let pw = unsafe { libc::getpwnam(nt.as_ptr() as *const _) };
        if pw.is_null() {
            None
        } else {
            // SAFETY: pw is non-NULL per the check above; copied under lock.
            Some(unsafe { (*pw).pw_uid })
        }
    };
    uid.or_else(|| scan_decimal(name))
}

fn resolve_group(name: &[u8]) -> Option<u32> {
    let mut nt = Vec::with_capacity(name.len() + 1);
    nt.extend_from_slice(name);
    nt.push(0);
    // SAFETY: as above; getgrnam shares the same static-storage caveat.
    let gid = {
        let _guard = nss_lock();
        let gr = unsafe { libc::getgrnam(nt.as_ptr() as *const _) };
        if gr.is_null() {
            None
        } else {
            // SAFETY: gr is non-NULL per the check above; copied under lock.
            Some(unsafe { (*gr).gr_gid })
        }
    };
    gid.or_else(|| scan_decimal(name))
}

// Action bits, named after PARSING.txt.
const A_ENVINIT: u32 = 0x4000_0000;
const A_MAJMIN: u32 = 0x2000_0000;
const A_DEVRE: u32 = 0x1000_0000;
const A_CONT: u32 = 0x0800_0000;
const A_MARK: u32 = 0x0400_0000;
const A_ZERO: u32 = 0x0200_0000;
const A_RE_ENV: u32 = 0x0100_0000;
const A_MJ: u32 = 0x0080_0000;
const A_MINLO: u32 = 0x0040_0000;
const A_MINHI_EQ: u32 = 0x0020_0000;
const A_MINHI: u32 = 0x0010_0000;
const A_RE: u32 = 0x0008_0000;
const A_VAR: u32 = 0x0004_0000;
const A_UID: u32 = 0x0002_0000;
const A_GID: u32 = 0x0001_0000;
const A_MODE: u32 = 0x0000_8000;
const A_FINAL: u32 = 0x0000_4000;
const A_REMOVE: u32 = 0x0000_2000;
const A_ADD: u32 = 0x0000_1000;
const A_MOVE: u32 = 0x0000_0800;
const A_MOVELINK: u32 = 0x0000_0400;
const A_NOCREATE: u32 = 0x0000_0200;
const A_PATH: u32 = 0x0000_0100;
const A_CMD: u32 = 0x0000_0080;
const A_LINE: u32 = 0x0000_0040;
const A_EXECLINE: u32 = 0x0000_0020;

const ST_END: u32 = 0x1e;
const ST_INPATH: u32 = 26;
const ST_INCMD: u32 = 29;

fn first_pass(buf: &[u8]) -> Result<(usize, usize), ConfigError> {
    let mut i = 0usize;
    let mut col0 = 0usize;
    let mut line: u32 = 1;
    let (mut n, mut m) = (0usize, 0usize);
    let mut state: u8 = 0;
    while state < 5 {
        if i >= buf.len() {
            return Err(ConfigError::FirstPass { line, col: 0 });
        }
        let what = FIRSTPASS_TABLE[state as usize][fp_class(buf[i])];
        state = what & 0x07;
        if what & 0x10 != 0 {
            m += 1;
        }
        if what & 0x20 != 0 {
            n += 1;
        }
        if what & 0x40 != 0 {
            line += 1;
            col0 = i;
        }
        i += 1;
    }
    if state == 6 {
        return Err(ConfigError::FirstPass {
            line,
            col: (i - col0) as u32,
        });
    }
    Ok((n, m))
}

#[derive(Debug)]
enum BuildDev {
    Nothing,
    DevRePending,
    DevRe(Regex),
    MajMin { maj: u32, minlo: u32, minhi: u32 },
}

#[derive(Debug)]
struct Builder {
    dev: BuildDev,
    env_base: usize,
    env_len: usize,
    cont: bool,
    uid: u32,
    gid: u32,
    mode: u32,
    move_kind: MoveKind,
    movepath: Option<usize>,
    action_mask: u8,
    execline: bool,
    cmd: Option<usize>,
    line: u32,
}

fn fresh_builder() -> Builder {
    // Mirrors the memset-zeroed slot: env_base 0 until $/d overwrite it.
    Builder {
        dev: BuildDev::Nothing,
        env_base: 0,
        env_len: 0,
        cont: false,
        uid: 0,
        gid: 0,
        mode: 0,
        move_kind: MoveKind::Nothing,
        movepath: None,
        action_mask: 0,
        execline: false,
        cmd: None,
        line: 1,
    }
}

fn second_pass(buf: &mut [u8]) -> Result<(Vec<Rule>, Vec<EnvMatch>), ConfigError> {
    let mut mark = 0usize;
    let mut col0 = 0usize;
    let mut pos = 0usize;
    let mut line: u32 = 1;
    let mut state: u32 = 0;
    let mut rules: Vec<Rule> = Vec::new();
    let mut env: Vec<EnvMatch> = Vec::new();
    let mut cur = fresh_builder();
    let mut path_start: Option<usize> = None;
    let mut cmd_start: Option<usize> = None;
    let mut var_start = 0usize;

    while state < ST_END {
        if pos >= buf.len() {
            return Err(ConfigError::SecondPass { line, col: 0 });
        }
        let what = SECONDPASS_TABLE[state as usize][sp_class(buf[pos])];
        let next = what & 0x1f;
        // Capture a move path / command text when its state is left. Every
        // exit from INPATH/INCMD carries ZERO, and no stay carries it. The
        // stored offset is the token start recorded by p/c, like the C code.
        if state == ST_INPATH && next != ST_INPATH {
            if path_start.is_some() {
                cur.movepath = path_start;
            }
            path_start = None;
        }
        if state == ST_INCMD && next != ST_INCMD {
            if cmd_start.is_some() {
                cur.cmd = cmd_start;
            }
            cmd_start = None;
        }
        // The three initializers touch only their own fields, like the C
        // code; in particular they preserve a leading `-` cont flag.
        if what & A_ENVINIT != 0 {
            cur.dev = BuildDev::Nothing;
            cur.env_base = env.len();
            cur.line = line;
        }
        if what & A_MAJMIN != 0 {
            cur.dev = BuildDev::MajMin {
                maj: 0,
                minlo: 0,
                minhi: 0,
            };
        }
        if what & A_DEVRE != 0 {
            cur.dev = BuildDev::DevRePending;
            cur.env_base = env.len();
            cur.line = line;
        }
        if what & A_CONT != 0 {
            cur.cont = true;
        }
        if what & A_MARK != 0 {
            mark = pos;
        }
        if what & A_ZERO != 0 {
            buf[pos] = 0;
        }
        if what & A_RE_ENV != 0 {
            let re = Regex::compile(&buf[mark..pos]).map_err(|err| ConfigError::Regex {
                line,
                is_env: true,
                err,
            })?;
            env.push(EnvMatch { var: var_start, re });
            cur.env_len += 1;
        }
        match cur.dev {
            BuildDev::MajMin {
                ref mut maj,
                ref mut minlo,
                ref mut minhi,
            } => {
                if what & A_MJ != 0 {
                    *maj = scan_decimal(&buf[mark..pos]).ok_or(ConfigError::Number {
                        line,
                        what: "major",
                        text: buf[mark..pos].to_vec(),
                    })?;
                }
                if what & A_MINLO != 0 {
                    *minlo = scan_decimal(&buf[mark..pos]).ok_or(ConfigError::Number {
                        line,
                        what: "minor",
                        text: buf[mark..pos].to_vec(),
                    })?;
                }
                if what & A_MINHI_EQ != 0 {
                    *minhi = *minlo;
                }
                if what & A_MINHI != 0 {
                    *minhi = scan_decimal(&buf[mark..pos]).ok_or(ConfigError::Number {
                        line,
                        what: "minor",
                        text: buf[mark..pos].to_vec(),
                    })?;
                }
            }
            _ => {
                if what & (A_MJ | A_MINLO | A_MINHI_EQ | A_MINHI) != 0 {
                    return Err(ConfigError::SecondPass { line, col: 0 });
                }
            }
        }
        if what & A_RE != 0 {
            let re = Regex::compile(&buf[mark..pos]).map_err(|err| ConfigError::Regex {
                line,
                is_env: false,
                err,
            })?;
            cur.dev = BuildDev::DevRe(re);
        }
        if what & A_VAR != 0 {
            // The name resolves lazily from storage (like the reference,
            // which reads storage+var after all zeroing is done).
            var_start = mark;
        }
        if what & A_UID != 0 {
            cur.uid = resolve_user(&buf[mark..pos]).ok_or(ConfigError::User {
                line,
                name: buf[mark..pos].to_vec(),
            })?;
        }
        if what & A_GID != 0 {
            cur.gid = resolve_group(&buf[mark..pos]).ok_or(ConfigError::Group {
                line,
                name: buf[mark..pos].to_vec(),
            })?;
        }
        if what & A_MODE != 0 {
            cur.mode = scan_octal(&buf[mark..pos]).ok_or(ConfigError::Number {
                line,
                what: "mode",
                text: buf[mark..pos].to_vec(),
            })?;
        }
        // Reference order: r/a clear the execline flag, E sets it last.
        if what & A_REMOVE != 0 {
            cur.action_mask |= 0x2;
            cur.execline = false;
        }
        if what & A_ADD != 0 {
            cur.action_mask |= 0x1;
            cur.execline = false;
        }
        if what & A_MOVE != 0 {
            cur.move_kind = MoveKind::Move;
        }
        if what & A_MOVELINK != 0 {
            cur.move_kind = MoveKind::MoveAndLink;
        }
        if what & A_NOCREATE != 0 {
            cur.move_kind = MoveKind::NoCreate;
        }
        if what & A_PATH != 0 {
            path_start = Some(pos);
        }
        if what & A_CMD != 0 {
            cmd_start = Some(pos);
        }
        if what & A_EXECLINE != 0 {
            cur.execline = true;
        }
        if what & A_LINE != 0 {
            line += 1;
            col0 = pos;
        }
        if what & A_FINAL != 0 {
            let dev = match std::mem::replace(&mut cur.dev, BuildDev::Nothing) {
                BuildDev::Nothing => DevMatch::Nothing,
                // Believed unreachable: every DEVRE entry compiles or errors
                // before its rule finalizes. Loud, so a corpus case proving
                // otherwise is impossible to miss.
                BuildDev::DevRePending => {
                    return Err(ConfigError::SecondPass {
                        line: cur.line,
                        col: 0,
                    });
                }
                BuildDev::DevRe(re) => DevMatch::DevRe(re),
                BuildDev::MajMin { maj, minlo, minhi } => {
                    DevMatch::MajMin { maj, minlo, minhi }
                }
            };
            let env_base = cur.env_base;
            let env_len = cur.env_len;
            rules.push(Rule {
                env: env[env_base..env_base + env_len].to_vec(),
                env_base,
                dev,
                cont: cur.cont,
                uid: cur.uid,
                gid: cur.gid,
                mode: cur.mode,
                move_kind: cur.move_kind,
                movepath: cur.movepath,
                action_mask: cur.action_mask,
                execline: cur.execline,
                cmd: cur.cmd,
                line: cur.line,
            });
            cur = fresh_builder();
        }
        state = next;
        pos += 1;
        if state == 0x1f {
            return Err(ConfigError::SecondPass {
                line,
                col: (pos - col0) as u32,
            });
        }
    }
    Ok((rules, env))
}

/// Parse `input` exactly like the reference (hooks included). The daemon
/// path follows up with [`validate_v1`].
pub fn parse(input: &[u8]) -> Result<Config, ConfigError> {
    if input.len() > CONF_MAX - 1 {
        return Err(ConfigError::TooLarge { len: input.len() });
    }
    let mut buf = Vec::with_capacity(input.len() + 1);
    buf.extend_from_slice(input);
    buf.push(0);
    let (n, _) = first_pass(&buf)?;
    let (mut rules, _) = second_pass(&mut buf)?;
    debug_assert!(rules.len() <= n + 1);
    // Mirrors main: the catchall sorts last and matches anything unmatched.
    rules.push(Rule {
        env: Vec::new(),
        env_base: 0,
        dev: DevMatch::Catchall,
        cont: false,
        uid: 0,
        gid: 0,
        mode: 0o660,
        move_kind: MoveKind::Nothing,
        movepath: None,
        action_mask: 0,
        execline: false,
        cmd: None,
        line: 0,
    });
    Ok(Config { rules, storage: buf })
}

/// v1 admission: reject every command-carrying rule (owner decision),
/// including the reference empty-command quirk (mask without text).
pub fn validate_v1(cfg: &Config) -> Result<(), ConfigError> {
    for r in &cfg.rules {
        if r.action_mask != 0 {
            return Err(ConfigError::HooksUnsupported { line: r.line });
        }
    }
    Ok(())
}

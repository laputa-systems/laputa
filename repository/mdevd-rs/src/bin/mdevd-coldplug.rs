//! mdevd-coldplug: Rust replacement for the coldplug helper (P5).
//!
//! Mirrors `src/mdevd/mdevd-coldplug.c`: scan sysfs for `uevent` files,
//! trigger them, and with `-O` wait for the last triggered event to come
//! back through the daemon. Registered divergences: the sync wait is
//! bounded (default 60 s, `MDEVD_COLDPLUG_SYNC_TIMEOUT_SECS` overrides)
//! instead of forever, and malformed sync events never match instead of
//! crashing the waiter.

use mdevd::uevent::{Stats, bind_intake, read_event};
use std::os::unix::io::AsRawFd;

const USAGE: &str = "mdevd-coldplug [ -v verbosity ] [ -s slashsys ] [ -O nlgroup ] [ -b kbufsz ]";
const SYNC_TIMEOUT_DEFAULT: u64 = 60;

fn fatal(code: i32, msg: String) -> ! {
    eprintln!("mdevd-coldplug: fatal: {msg}");
    std::process::exit(code);
}

fn usage() -> ! {
    eprintln!("mdevd-coldplug: usage: {USAGE}");
    std::process::exit(100);
}

fn warn(level: u32, verbosity: u32, msg: &str) {
    if verbosity >= level.max(1) {
        eprintln!("mdevd-coldplug: warning: {msg}");
    }
}

fn parse_uint(arg: &str) -> Option<u32> {
    if arg.is_empty() {
        return None;
    }
    let mut v: u32 = 0;
    for b in arg.bytes() {
        if !b.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((b - b'0') as u32)?;
    }
    Some(v)
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Args {
    verbosity: u32,
    slashsys: String,
    nlgroup: u32,
    kbufsz: u32,
}

impl Default for Args {
    fn default() -> Args {
        Args {
            verbosity: 1,
            slashsys: "/sys".into(),
            nlgroup: 0,
            kbufsz: 1048576,
        }
    }
}

fn parse_args(argv: &[String]) -> Result<Args, ()> {
    let mut a = Args::default();
    let mut i = 0;
    let mut opts_done = false;
    while i < argv.len() {
        let arg = &argv[i];
        i += 1;
        if opts_done {
            continue;
        }
        if arg == "--" {
            opts_done = true;
            continue;
        }
        if arg.len() <= 1 || !arg.starts_with('-') {
            continue;
        }
        let chars: Vec<char> = arg[1..].chars().collect();
        let mut j = 0;
        while j < chars.len() {
            let c = chars[j];
            j += 1;
            let take_arg = |j: &mut usize, i: &mut usize| -> Result<String, ()> {
                if *j < chars.len() {
                    let rest: String = chars[*j..].iter().collect();
                    *j = chars.len();
                    Ok(rest)
                } else if *i < argv.len() {
                    let s = argv[*i].clone();
                    *i += 1;
                    Ok(s)
                } else {
                    Err(())
                }
            };
            match c {
                'v' | 's' | 'O' | 'b' => {
                    let val = take_arg(&mut j, &mut i).map_err(|_| ())?;
                    match c {
                        'v' => a.verbosity = parse_uint(&val).ok_or(())?,
                        's' => a.slashsys = val,
                        'O' => a.nlgroup = parse_uint(&val).ok_or(())?,
                        'b' => a.kbufsz = parse_uint(&val).ok_or(())?,
                        _ => unreachable!(),
                    }
                }
                _ => return Err(()),
            }
        }
    }
    Ok(a)
}

fn force_c_locale() {
    // SAFETY: constant string; process start, single-threaded here.
    unsafe {
        libc::setlocale(libc::LC_ALL, c"C".as_ptr());
    }
}

/// Scan one sysfs listing for `uevent` files and trigger them. Returns
/// whether anything was triggered; records the last entry name on success
/// (last entry read, not last triggered).
fn scan_subdir(path: &std::path::Path, list: &str, pathat: &str, mdev: &mut String) -> bool {
    let dir = path.join(list);
    let entries = match std::fs::read_dir(&dir) {
        Ok(e) => e,
        Err(e) => fatal(
            111,
            format!("unable to open {pathat}/{list}: {}", e),
        ),
    };
    let mut r = false;
    let mut last = String::new();
    for entry in entries {
        let entry = match entry {
            Ok(e) => e,
            Err(e) => fatal(111, format!("unable to readdir {pathat}/{list}: {}", e)),
        };
        let name = entry.file_name();
        let name = name.to_string_lossy().into_owned();
        last = name.clone();
        if name.starts_with('.') {
            continue;
        }
        let uevent = dir.join(&name).join("uevent");
        let mut f = match std::fs::OpenOptions::new().write(true).open(&uevent) {
            Ok(f) => f,
            Err(_) => continue,
        };
        use std::io::Write;
        if let Err(e) = f.write_all(b"add\n") {
            warn(1, 1, &format!("unable to write to {pathat}/{list}/{name}/uevent: {e}"));
        }
        r = true;
    }
    if r {
        *mdev = last;
    }
    r
}

fn scan_dir(
    path: &std::path::Path,
    add_devices: bool,
    subsystem: &mut String,
    mdev: &mut String,
) -> Result<(), std::io::Error> {
    let entries = std::fs::read_dir(path)?;
    for entry in entries {
        let entry = match entry {
            Ok(e) => e,
            Err(e) => fatal(111, format!("unable to readdir {}: {}", path.display(), e)),
        };
        let name = entry.file_name();
        let name = name.to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        if add_devices {
            let list = format!("{name}/devices");
            if scan_subdir(path, &list, &path.display().to_string(), mdev) {
                *subsystem = name;
            }
        } else if scan_subdir(path, &name, &path.display().to_string(), mdev) {
            *subsystem = name;
        }
    }
    Ok(())
}

fn main() {
    force_c_locale();
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let a = parse_args(&argv).unwrap_or_else(|_| usage());
    let nlgroup = a.nlgroup & !1;
    let nlfd = if nlgroup != 0 {
        let fd = match bind_intake(nlgroup, a.kbufsz) {
            Ok(fd) => fd,
            Err(e) => fatal(111, format!("unable to init netlink: {e}")),
        };
        // Blocking reads for the sync wait.
        // SAFETY: fd is a valid netlink socket.
        unsafe {
            let flags = libc::fcntl(fd.as_raw_fd(), libc::F_GETFL);
            if flags == -1
                || libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags & !libc::O_NONBLOCK) == -1
            {
                fatal(111, format!("unable to make netlink socket blocking: {}", std::io::Error::last_os_error()));
            }
        }
        Some(fd)
    } else {
        None
    };

    let sys = std::path::Path::new(&a.slashsys);
    let mut subsystem = String::new();
    let mut mdev = String::new();
    {
        let sub = sys.join("subsystem");
        if scan_dir(&sub, true, &mut subsystem, &mut mdev).is_err() {
            let class = sys.join("class");
            if let Err(e) = scan_dir(&class, false, &mut subsystem, &mut mdev) { fatal(111, format!("unable to open {}/class: {e}", a.slashsys)) }
            let bus = sys.join("bus");
            if let Err(e) = scan_dir(&bus, true, &mut subsystem, &mut mdev) { fatal(111, format!("unable to open {}/bus: {e}", a.slashsys)) }
        }
    }
    if let Some(fd) = nlfd {
        wait_sync(&a, &subsystem, &mdev, fd);
    }
}

/// Bounded synchronous wait for the last triggered event to come back
/// through the daemon (default 60 s, `MDEVD_COLDPLUG_SYNC_TIMEOUT_SECS`
/// overrides). Upstream waits forever; a timeout exits 1 loudly instead
/// of hanging boot. Malformed events never match (see divergence.md).
fn wait_sync(
    a: &Args,
    subsystem: &str,
    mdev: &str,
    fd: std::os::unix::io::OwnedFd,
) {
    if subsystem.is_empty() || mdev.is_empty() {
        return;
    }
    let timeout = std::env::var("MDEVD_COLDPLUG_SYNC_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(SYNC_TIMEOUT_DEFAULT);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(timeout);
    let mut stats = Stats::default();
    // SAFETY: fd is a valid blocking netlink socket.
    let raw = unsafe { std::os::unix::io::BorrowedFd::borrow_raw(fd.as_raw_fd()) };
    loop {
        let now = std::time::Instant::now();
        if now >= deadline {
            fatal(1, "timed out waiting for coldplug sync".to_string());
        }
        let ms = (deadline - now).as_millis().min(i32::MAX as u128) as i32;
        let mut pfd = libc::pollfd {
            fd: fd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: pfd is valid.
        let r = unsafe { libc::poll(&mut pfd, 1, ms) };
        if r == -1 {
            let e = std::io::Error::last_os_error();
            if e.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            fatal(111, format!("unable to poll netlink: {e}"));
        }
        if r == 0 {
            continue;
        }
        let ev = match read_event(raw, false, &mut stats) {
            Ok(mdevd::uevent::ReadOutcome::Event(ev)) => ev,
            Ok(mdevd::uevent::ReadOutcome::Invalid(e)) => {
                let text = match e {
                    mdevd::uevent::Invalid::Empty => "empty",
                    mdevd::uevent::Invalid::NotTerminated => "improperly terminated",
                    mdevd::uevent::Invalid::BadHeader => "bad initial summary",
                    mdevd::uevent::Invalid::TooManyVars => "too many variables",
                };
                warn(1, a.verbosity, &format!("received invalid event: {text}"));
                continue;
            }
            Ok(_) => continue,
            Err(e) => fatal(111, format!("unable to {e}")),
        };
        if !sync_match(&ev, subsystem, mdev) {
            continue;
        }
        return;
    }
}

/// Whether a received event is the last triggered one. Missing fields never
/// match (see divergence.md).
fn sync_match(ev: &mdevd::uevent::Uevent, subsystem: &str, mdev: &str) -> bool {
    if ev.getvar(b"ACTION") != Some(b"add".as_slice()) {
        return false;
    }
    if ev.getvar(b"SUBSYSTEM") != Some(subsystem.as_bytes()) {
        return false;
    }
    let devpath = match ev.getvar(b"DEVPATH") {
        Some(p) => p,
        None => return false,
    };
    let base = match devpath.iter().rposition(|&b| b == b'/') {
        Some(i) => &devpath[i + 1..],
        None => devpath,
    };
    base == mdev.as_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(s: &[&str]) -> Result<Args, ()> {
        parse_args(&s.iter().map(|x| x.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn bins_coldplug_cli() {
        let a = args(&[]).unwrap();
        assert_eq!((a.verbosity, a.nlgroup, a.kbufsz), (1, 0, 1048576));
        assert_eq!(a.slashsys, "/sys");
        let a = args(&["-v2", "-s", "/x", "-O4", "-b1"]).unwrap();
        assert_eq!((a.verbosity, a.nlgroup, a.kbufsz), (2, 4, 1));
        assert_eq!(a.slashsys, "/x");
        assert!(args(&["-Z"]).is_err());
        assert!(args(&["-O", "0x4"]).is_err());
    }

    #[test]
    fn bins_coldplug_sync_match() {
        let ev = mdevd::uevent::Uevent {
            buf: b"add@/d\0ACTION=add\0SUBSYSTEM=foo\0DEVPATH=/devices/bar\0".to_vec(),
            vars: vec![0, 7, 18, 32],
        };
        assert!(sync_match(&ev, "foo", "bar"));
        assert!(!sync_match(&ev, "foo", "baz"));
        assert!(!sync_match(&ev, "other", "bar"));
        let ev2 = mdevd::uevent::Uevent {
            buf: b"add@/d\0ACTION=remove\0SUBSYSTEM=foo\0DEVPATH=/devices/bar\0".to_vec(),
            vars: vec![0, 7, 21, 35],
        };
        assert!(!sync_match(&ev2, "foo", "bar"));
    }
}

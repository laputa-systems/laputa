//! mdevd: Rust replacement for the mdevd daemon (P5).
//!
//! Wiring around the library: CLI, startup order, readiness, signals,
//! config reload, and the poll loop. Mirrors `main` in `src/mdevd/mdevd.c`
//! step for step, except for registered divergences: hook/firmware
//! rejection, invalid reloads retaining the last valid config, and a
//! bounded coldplug-sync wait owned by mdevd-coldplug.

use mdevd::config::{Config, parse, validate_v1};
use mdevd::engine::{Out, Outcome, Request, Run, Warn};
use mdevd::publish::{Sinks, apply_loop_guard, publish};
use mdevd::uevent::{Invalid, ReadOutcome, Stats, bind_intake, read_event};
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd};

const USAGE: &str = "mdevd [ -v verbosity ] [ -D notif ] [ -I intake ] [ -o outputfd ] [ -O nlgroups ] [ -b kbufsz ] [ -f conffile ] [ -n | -N ] [ -s slashsys ] [ -d slashdev ] [ -F fwbase ] [ -C ]";

fn fatal(code: i32, msg: String) -> ! {
    eprintln!("mdevd: fatal: {msg}");
    std::process::exit(code);
}

fn usage() -> ! {
    eprintln!("mdevd: usage: {USAGE}");
    std::process::exit(100);
}

fn warn(verbosity: u32, level: u8, msg: &str) {
    if verbosity >= level as u32 {
        eprintln!("mdevd: warning: {msg}");
    }
}

fn info(line: &str) {
    eprintln!("mdevd: info: {line}");
}

fn errno_text(e: std::io::Error) -> String {
    // libc strerror text, matching the reference byte-for-byte.
    // SAFETY: strerror handles any errno value.
    unsafe {
        let p = libc::strerror(e.raw_os_error().unwrap_or(0));
        if p.is_null() {
            return format!("{e}");
        }
        std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned()
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
    dryrun: u8,
    verbosity: u32,
    notif: Option<u32>,
    intake: u32,
    outputfd: Option<u32>,
    rebc: u32,
    kbufsz: u32,
    configfile: String,
    slashsys: String,
    slashdev: String,
    firmware_flag: bool,
    coldplug: bool,
}

impl Default for Args {
    fn default() -> Args {
        Args {
            dryrun: 0,
            verbosity: 1,
            notif: None,
            intake: 1,
            outputfd: None,
            rebc: 0,
            kbufsz: 1048576,
            configfile: "/etc/mdev.conf".into(),
            slashsys: "/sys".into(),
            slashdev: "/dev".into(),
            firmware_flag: false,
            coldplug: false,
        }
    }
}

/// Hand-rolled option parsing with subgetopt semantics: combined shorts,
/// attached or separate arguments, `--` terminator, last-wins `-n`/`-N`,
/// extra positionals ignored.
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
        // Bare "-" and positionals are ignored, like the reference.
        if arg.len() <= 1 || !arg.starts_with('-') {
            continue;
        }
        let chars: Vec<char> = arg[1..].chars().collect();
        let mut j = 0;
        while j < chars.len() {
            let c = chars[j];
            j += 1;
            // Options taking an argument consume the rest of this arg or
            // the next argv element.
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
                'n' => a.dryrun = 1,
                'N' => a.dryrun = 2,
                'C' => a.coldplug = true,
                'v' | 'D' | 'I' | 'o' | 'O' | 'b' | 'f' | 's' | 'd' | 'F' => {
                    let val = take_arg(&mut j, &mut i).map_err(|_| ())?;
                    match c {
                        'v' => a.verbosity = parse_uint(&val).ok_or(())?,
                        'D' => a.notif = Some(parse_uint(&val).ok_or(())?),
                        'I' => a.intake = parse_uint(&val).ok_or(())?,
                        'o' => a.outputfd = Some(parse_uint(&val).ok_or(())?),
                        'O' => a.rebc = parse_uint(&val).ok_or(())?,
                        'b' => a.kbufsz = parse_uint(&val).ok_or(())?,
                        'f' => a.configfile = val,
                        's' => a.slashsys = val,
                        'd' => a.slashdev = val,
                        'F' => a.firmware_flag = true,
                        _ => unreachable!(),
                    }
                }
                _ => return Err(()),
            }
        }
    }
    Ok(a)
}

fn fd_open(fd: u32) -> bool {
    // SAFETY: pure fcntl probe.
    unsafe { libc::fcntl(fd as libc::c_int, libc::F_GETFD) != -1 }
}

fn fd_error(fd: u32) -> std::io::Error {
    // SAFETY: pure fcntl probe; preserves the errno for the message.
    unsafe {
        libc::fcntl(fd as libc::c_int, libc::F_GETFD);
        std::io::Error::last_os_error()
    }
}

fn set_nonblock_coe(fd: u32, what: &str) {
    // SAFETY: fd was validated open.
    unsafe {
        let flags = libc::fcntl(fd as libc::c_int, libc::F_GETFL);
        if flags == -1 || libc::fcntl(fd as libc::c_int, libc::F_SETFL, flags | libc::O_NONBLOCK) == -1
        {
            fatal(111, format!("unable to set {what} non-blocking: {}", errno_text(std::io::Error::last_os_error())));
        }
        if libc::fcntl(fd as libc::c_int, libc::F_SETFD, libc::FD_CLOEXEC) == -1 {
            fatal(111, format!("unable to set {what} close-on-exec: {}", errno_text(std::io::Error::last_os_error())));
        }
    }
}

fn fd_sanitize() {
    for fd in 0..3 {
        if !fd_open(fd) {
            let c = std::ffi::CString::new("/dev/null").unwrap();
            // SAFETY: opening /dev/null yields the lowest free fd, i.e. fd.
            let r = unsafe { libc::open(c.as_ptr(), libc::O_RDWR) };
            if r == -1 {
                fatal(111, format!("unable to sanitize standard fds: {}", errno_text(std::io::Error::last_os_error())));
            }
        }
    }
}

fn read_bounded_config(path: &str) -> std::io::Result<Vec<u8>> {
    let cpath = std::ffi::CString::new(path)
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid path"))?;
    // SAFETY: openat with O_NOFOLLOW, then fstat.
    unsafe {
        let fd = libc::openat(
            libc::AT_FDCWD,
            cpath.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        );
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let mut sb: libc::stat = std::mem::zeroed();
        if libc::fstat(fd, &mut sb) != 0 {
            let e = std::io::Error::last_os_error();
            libc::close(fd);
            return Err(e);
        }
        if (sb.st_mode & libc::S_IFMT) != libc::S_IFREG
            && (sb.st_mode & libc::S_IFMT) != libc::S_IFIFO
        {
            libc::close(fd);
            if (sb.st_mode & libc::S_IFMT) == libc::S_IFDIR {
                return Err(std::io::Error::from_raw_os_error(libc::EISDIR));
            }
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "not a regular file",
            ));
        }
        if sb.st_size < 0 || sb.st_size as u64 > mdevd::config::CONF_MAX as u64 {
            libc::close(fd);
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "configuration too large",
            ));
        }
        let file = std::fs::File::from_raw_fd(fd);
        let mut data = Vec::new();
        use std::io::Read;
        file.take(mdevd::config::CONF_MAX as u64 + 1)
            .read_to_end(&mut data)?;
        if data.len() > mdevd::config::CONF_MAX {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "configuration too large",
            ));
        }
        Ok(data)
    }
}

fn coldplug_helper_path() -> std::path::PathBuf {
    if let Ok(helper) = std::env::var("MDEVD_COLDPLUG_HELPER") {
        if !helper.is_empty() {
            return std::path::PathBuf::from(helper);
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let sibling = dir.join("mdevd-coldplug");
            if std::fs::metadata(&sibling).is_ok() {
                return sibling;
            }
        }
    }
    std::path::PathBuf::from("/usr/libexec/mdevd-coldplug")
}

fn spawn_coldplug(a: &Args) {
    let helper = coldplug_helper_path();
    let mut cmd = std::process::Command::new(&helper);
    cmd.arg("-s").arg(&a.slashsys);
    cmd.arg("-b").arg(a.kbufsz.to_string());
    cmd.arg("-v").arg(a.verbosity.to_string());
    unsafe {
        use std::os::unix::process::CommandExt;
        cmd.pre_exec(|| {
            let mut set: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut set);
            libc::sigaddset(&mut set, libc::SIGTERM);
            libc::sigaddset(&mut set, libc::SIGHUP);
            libc::sigprocmask(libc::SIG_UNBLOCK, &set, std::ptr::null_mut());
            libc::signal(libc::SIGCHLD, libc::SIG_DFL);
            Ok(())
        });
    }
    match cmd.spawn() {
        Ok(_) => {}
        Err(e) => warn(
            a.verbosity,
            1,
            &format!(
                "unable to spawn {}: {}",
                helper.display(),
                errno_text(e)
            ),
        ),
    }
}

fn load_config(path: &str, verbosity: u32, initial: bool, old: Option<Config>) -> Config {
    let bytes = match read_bounded_config(path) {
        Ok(b) => b,
        Err(e) => {
            if e.kind() == std::io::ErrorKind::NotFound {
                warn(verbosity, 1, &format!("unable to read {path}: {}", errno_text(e)));
                // Empty config: just the catchall, like the reference.
                return parse(b"").unwrap_or_else(|err| fatal(2, err.to_string()));
            }
            fatal(111, format!("unable to read {path}: {}", errno_text(e)));
        }
    };
    match parse(&bytes).and_then(|cfg| validate_v1(&cfg).map(|_| cfg)) {
        Ok(cfg) => cfg,
        Err(e) => {
            if initial {
                fatal(2, e.to_string());
            }
            warn(verbosity, 1, &format!("reload keeps last valid config: {e}"));
            old.unwrap_or_else(|| parse(b"").unwrap_or_else(|err| fatal(2, err.to_string())))
        }
    }
}

fn invalid_text(e: Invalid) -> &'static str {
    match e {
        Invalid::Empty => "empty",
        Invalid::NotTerminated => "improperly terminated",
        Invalid::BadHeader => "bad initial summary",
        Invalid::TooManyVars => "too many variables",
    }
}

fn force_c_locale() {
    // SAFETY: constant string; process start, single-threaded here.
    unsafe {
        libc::setlocale(libc::LC_ALL, c"C".as_ptr());
    }
}

#[derive(PartialEq, Eq)]
enum State {
    Reload,
    Exit,
}

fn main() {
    force_c_locale();
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let a = parse_args(&argv).unwrap_or_else(|_| usage());
    if a.firmware_flag {
        fatal(100, "firmware loading is unsupported in this build (-F rejected)".to_string());
    }
    for (path, _name) in [(&a.configfile, "conffile"), (&a.slashsys, "slashsys"), (&a.slashdev, "slashdev")] {
        if !path.starts_with('/') {
            fatal(100, format!("{path} is not an absolute path"));
        }
    }
    if std::env::set_current_dir(&a.slashdev).is_err() {
        fatal(111, format!("unable to chdir to {}: {}", a.slashdev, errno_text(std::io::Error::last_os_error())));
    }
    if a.slashsys.len() >= 4095 {
        fatal(100, "paths too long".to_string());
    }
    fd_sanitize();
    if let Some(n) = a.notif {
        if n < 3 {
            fatal(100, "notification fd must be 3 or more".to_string());
        }
        if !fd_open(n) {
            fatal(100, format!("invalid notification fd: {}", errno_text(fd_error(n))));
        }
    }
    if let Some(o) = a.outputfd {
        if o < 3 {
            fatal(100, "output fd must be 3 or more".to_string());
        }
        if !fd_open(o) {
            fatal(100, format!("invalid output fd: {}", errno_text(fd_error(o))));
        }
        if Some(o) == a.notif {
            fatal(100, "output fd and notification fd must not be the same".to_string());
        }
        set_nonblock_coe(o, "output fd");
    }
    let root_dev = match std::fs::metadata("/") {
        Ok(m) => {
            use std::os::unix::fs::MetadataExt;
            let r = m.rdev();
            // SAFETY: makedev/major/minor are pure.
            (libc::major(r) as u32, libc::minor(r) as u32)
        }
        Err(e) => fatal(111, format!("unable to stat /: {}", errno_text(e))),
    };
    let netlink = match bind_intake(a.intake, a.kbufsz) {
        Ok(fd) => fd,
        Err(e) => fatal(111, format!("unable to init netlink: {}", errno_text(e))),
    };
    let (rebc_masked, dropped) = apply_loop_guard(a.intake, a.rebc);
    if let Some(bits) = dropped {
        warn(a.verbosity, 1, &format!("ignoring rebroadcast request on nlgroups {bits} to avoid loops"));
    }
    let mut sinks = Sinks {
        output: None,
        rebroadcast: None,
    };
    if let Some(o) = a.outputfd {
        // SAFETY: fd was validated open; ownership moves to the sink.
        sinks.output = Some(mdevd::publish::Output::new(unsafe { OwnedFd::from_raw_fd(o as libc::c_int) }));
    }
    if rebc_masked != 0 {
        match mdevd::publish::Rebroadcast::connect(rebc_masked, a.kbufsz) {
            Ok(r) => sinks.rebroadcast = Some(r),
            Err(e) => fatal(111, format!("unable to init netlink rebroadcast socket: {}", errno_text(e))),
        }
    }

    // Signals: block TERM/HUP, read them over signalfd; CHLD is ignored so
    // the one-shot coldplug child never zombies.
    // SAFETY: signal setup before the poll loop, single-threaded.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        libc::signal(libc::SIGCHLD, libc::SIG_IGN);
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGTERM);
        libc::sigaddset(&mut set, libc::SIGHUP);
        if libc::sigprocmask(libc::SIG_BLOCK, &set, std::ptr::null_mut()) == -1 {
            fatal(111, format!("unable to trap signals: {}", errno_text(std::io::Error::last_os_error())));
        }
        let sfd = libc::signalfd(-1, &set, libc::SFD_NONBLOCK | libc::SFD_CLOEXEC);
        if sfd == -1 {
            fatal(111, format!("unable to init signalfd: {}", errno_text(std::io::Error::last_os_error())));
        }
        let sfd = OwnedFd::from_raw_fd(sfd);
        run(a, netlink, sfd, root_dev, sinks);
    }
}

fn run(
    a: Args,
    netlink: OwnedFd,
    sfd: OwnedFd,
    root_dev: (u32, u32),
    mut sinks: Sinks,
) {
    // SAFETY: umask is process-global; single-threaded startup here.
    unsafe {
        libc::umask(0);
    }
    let mut notif = a.notif;
    let mut coldplug_pending = a.coldplug;
    let mut first = true;
    let mut cfg = Config { rules: Vec::new(), storage: Vec::new() };
    let sys = std::path::Path::new(&a.slashsys);
    let dev = std::path::Path::new(&a.slashdev);
    let mut ops = match mdevd::engine::ops::RealOps::open(dev, sys) {
        Ok(ops) => ops,
        Err(e) => fatal(111, format!("unable to open device/sys roots: {}", errno_text(e))),
    };
    let mut stats = Stats::default();
    let mut overruns_seen = 0u64;
    loop {
        let old = if first { None } else { Some(std::mem::replace(&mut cfg, Config { rules: Vec::new(), storage: Vec::new() })) };
        cfg = load_config(&a.configfile, a.verbosity, first, old);
        if a.dryrun == 2 {
            std::process::exit(0);
        }
        if coldplug_pending {
            coldplug_pending = false;
            spawn_coldplug(&a);
        }
        if let Some(n) = notif.take() {
            let one = *b"\n";
            // SAFETY: notif was validated open; result ignored like the C code.
            unsafe {
                libc::write(n as libc::c_int, one.as_ptr() as *const libc::c_void, 1);
                libc::close(n as libc::c_int);
            }
        }
        first = false;
        let mut fds = [
            libc::pollfd {
                fd: sfd.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: netlink.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        let state = loop {
            // SAFETY: fds are valid; EINTR retries.
            let r = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
            if r == -1 {
                let e = std::io::Error::last_os_error();
                if e.raw_os_error() == Some(libc::EINTR) {
                    continue;
                }
                fatal(111, format!("unable to poll: {}", errno_text(e)));
            }
            if fds[0].revents & libc::POLLIN != 0 {
                let mut saw_term = false;
                let mut saw_hup = false;
                loop {
                    let mut ssi: libc::signalfd_siginfo = unsafe { std::mem::zeroed() };
                    // SAFETY: sfd is a valid signalfd.
                    let n = unsafe {
                        libc::read(
                            sfd.as_raw_fd(),
                            &mut ssi as *mut _ as *mut libc::c_void,
                            std::mem::size_of::<libc::signalfd_siginfo>(),
                        )
                    };
                    if n != std::mem::size_of::<libc::signalfd_siginfo>() as isize {
                        break;
                    }
                    if ssi.ssi_signo as libc::c_int == libc::SIGTERM {
                        saw_term = true;
                    } else if ssi.ssi_signo as libc::c_int == libc::SIGHUP {
                        saw_hup = true;
                    }
                }
                if saw_term {
                    break State::Exit;
                }
                if saw_hup {
                    break State::Reload;
                }
            }
            if fds[1].revents & libc::POLLIN != 0 {
                // SAFETY: netlink fd is valid.
                let borrowed = unsafe { std::os::unix::io::BorrowedFd::borrow_raw(netlink.as_raw_fd()) };
                match read_event(borrowed, true, &mut stats) {
                    Err(e) => fatal(111, format!("unable to {e}")),
                    Ok(ReadOutcome::Nothing) => {}
                    Ok(ReadOutcome::DroppedUserspace(pid)) => {
                        warn(a.verbosity, 3, &format!("received netlink message from userspace process {pid}"));
                    }
                    Ok(ReadOutcome::Invalid(e)) => {
                        warn(a.verbosity, 1, &format!("received invalid event: {}", invalid_text(e)));
                    }
                    Ok(ReadOutcome::Event(ev)) => {
                        let req = Request {
                            cfg: &cfg,
                            ev: &ev,
                            slashsys: a.slashsys.as_bytes(),
                            root_dev,
                        };
                        let mut notes: Vec<Warn> = Vec::new();
                        let outcome = if a.dryrun == 1 {
                            let mut t = Vec::new();
                            let mut run = Run {
                                ops: &mut ops,
                                out: Out::Dry(&mut t),
                            };
                            let o = match mdevd::engine::on_event(&req, &mut run) {
                                Ok(o) => o,
                                Err(e) => fatal(111, format!("event handling: {e}")),
                            };
                            for line in t {
                                info(&line);
                            }
                            o
                        } else {
                            let mut run = Run {
                                ops: &mut ops,
                                out: Out::Real(&mut notes),
                            };
                            match mdevd::engine::on_event(&req, &mut run) {
                                Ok(o) => o,
                                Err(e) => fatal(111, format!("event handling: {e}")),
                            }
                        };
                        for w in notes {
                            warn(a.verbosity, w.level, &w.msg);
                        }
                        if stats.overruns != overruns_seen {
                            overruns_seen = stats.overruns;
                            warn(a.verbosity, 0, "missed events! you should increase the -b kbufsz value");
                        }
                        if outcome == Outcome::Publish {
                            let mut pnotes = Vec::new();
                            publish(&ev.buf, &mut sinks, &mut pnotes);
                            for n in pnotes {
                                warn(a.verbosity, n.level, &n.msg);
                            }
                        }
                    }
                }
            }
        };
        if state == State::Exit {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(s: &[&str]) -> Result<Args, ()> {
        parse_args(&s.iter().map(|x| x.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn bins_cli_defaults() {
        let a = args(&[]).unwrap();
        assert_eq!(a.verbosity, 1);
        assert_eq!(a.intake, 1);
        assert_eq!(a.kbufsz, 1048576);
        assert_eq!(a.configfile, "/etc/mdev.conf");
        assert_eq!(a.dryrun, 0);
    }

    #[test]
    fn bins_cli_forms() {
        let a = args(&["-v3", "-O", "4", "-f", "/x.conf", "-n", "-C"]).unwrap();
        assert_eq!(a.verbosity, 3);
        assert_eq!(a.rebc, 4);
        assert_eq!(a.configfile, "/x.conf");
        assert_eq!(a.dryrun, 1);
        assert!(a.coldplug);
        // Last of -n/-N wins.
        assert_eq!(args(&["-n", "-N"]).unwrap().dryrun, 2);
        assert_eq!(args(&["-N", "-n"]).unwrap().dryrun, 1);
        // Combined shorts and -- terminator.
        assert!(args(&["-nC"]).unwrap().coldplug);
        assert!(args(&["--", "-n"]).unwrap().dryrun == 0);
        // Junk numerics and unknown flags fail.
        assert!(args(&["-v", "nan"]).is_err());
        assert!(args(&["-O", "0x4"]).is_err());
        assert!(args(&["-Z"]).is_err());
        // Extra positionals are ignored, like the reference.
        assert!(args(&["extra", "-v2"]).unwrap().verbosity == 2);
    }
}

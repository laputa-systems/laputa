//! P5: binaries + lifecycle tests. `bins` filter.
//!
//! CLI matrix runs against the C oracle byte-for-byte. Daemon lifecycle
//! tests run in the sandbox namespace (intake bind needs no privileges);
//! anything needing multicast userspace send is either unicast (works) or
//! explicitly parked. HUP-retain and sync-timeout are registered
//! divergences proven against the oracle's contrasting behavior.
use std::io::Read;
use std::os::unix::io::FromRawFd;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn bin(name: &str) -> String {
    std::env::var(format!("CARGO_BIN_EXE_{name}")).expect("cargo bin exe")
}

fn oracle() -> (PathBuf, PathBuf) {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    (
        root.join(".work/oracle/src-tree/mdevd"),
        root.join(".work/oracle/src-tree/mdevd-coldplug"),
    )
}

fn ld_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join(".work/vendor/sysdeps-root/lib")
}

struct Done {
    code: Option<i32>,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

fn run_timeout(mut cmd: Command, secs: u64) -> Done {
    let mut child = cmd.stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().expect("spawn");
    let mut out = Vec::new();
    let mut err = Vec::new();
    let start = std::time::Instant::now();
    loop {
        match child.try_wait().expect("wait") {
            Some(status) => {
                if let Some(mut o) = child.stdout.take() {
                    o.read_to_end(&mut out).ok();
                }
                if let Some(mut e) = child.stderr.take() {
                    e.read_to_end(&mut err).ok();
                }
                return Done {
                    code: status.code(),
                    stdout: out,
                    stderr: err,
                };
            }
            None => {
                if start.elapsed() > std::time::Duration::from_secs(secs) {
                    child.kill().ok();
                    let _ = child.wait();
                    if let Some(mut o) = child.stdout.take() {
                        o.read_to_end(&mut out).ok();
                    }
                    if let Some(mut e) = child.stderr.take() {
                        e.read_to_end(&mut err).ok();
                    }
                    return Done {
                        code: None,
                        stdout: out,
                        stderr: err,
                    };
                }
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
        }
    }
}

fn devdir() -> PathBuf {
    let d = Path::new(env!("CARGO_MANIFEST_DIR")).join(".work/tmp/bins-dev");
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Writable fake sysroot. RealOps::open only needs the dirs to exist.
fn sysdir() -> PathBuf {
    let d = Path::new(env!("CARGO_MANIFEST_DIR")).join(".work/tmp/bins-sys");
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Coldplug with an alternate sysfs root must never open the host's real
/// /sys: strace the child and reject any open of a /sys path. The alt
/// tree is still triggered, proving the scan went to the selected root.
#[test]
fn bins_coldplug_never_touches_host_sys() {
    let ours = bin("mdevd-coldplug");
    let tree = Path::new(env!("CARGO_MANIFEST_DIR")).join(".work/tmp/cptree-nosys");
    let _ = std::fs::remove_dir_all(&tree);
    for dev in ["bar", "baz"] {
        let d = tree.join("subsystem/foo/devices").join(dev);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("uevent"), format!("PLACEHOLDER-{dev}\n")).unwrap();
    }
    let trace = Path::new(env!("CARGO_MANIFEST_DIR")).join(".work/tmp/cptree-nosys.trace");
    let _ = std::fs::remove_file(&trace);
    let mut cmd = Command::new("strace");
    cmd.args(["-f", "-e", "trace=openat,open,openat2", "-o"])
        .arg(&trace)
        .arg(&ours)
        .arg("-s")
        .arg(&tree);
    let done = run_timeout(cmd, 30);
    assert_eq!(done.code, Some(0), "coldplug under strace exit");
    for dev in ["bar", "baz"] {
        let content = std::fs::read(tree.join("subsystem/foo/devices").join(dev).join("uevent")).unwrap();
        assert!(content.starts_with(b"add\n"), "{dev}: alt uevent not triggered");
    }
    let log = std::fs::read_to_string(&trace).unwrap();
    for line in log.lines() {
        for pat in ["/sys/", "/sys\""] {
            assert!(
                !line.contains(pat),
                "host /sys touched: {line}"
            );
        }
    }
}

/// CLI matrix: identical exit codes and byte-identical stderr.
#[test]
fn bins_cli_diff() {
    let (o_mdevd, _) = oracle();
    let ours = bin("mdevd");
    let dev = devdir();
    let sys = sysdir();
    let good = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/laputa-mdev.conf");
    let bad = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/bad-mdev.conf");
    let cases: Vec<Vec<&str>> = vec![
        vec!["--badflag"],
        vec!["-v", "nan"],
        vec!["-D", "2"],
        vec!["-o", "2"],
        vec!["-D", "9"],
        vec!["-f", "relative.conf"],
        vec!["-s", "relative-sys"],
        vec!["-d", "relative-dev"],
        vec!["-O", "0x4"],
        vec!["-N", "-f", good.to_str().unwrap()],
        vec!["-N", "-f", bad.to_str().unwrap()],
        vec!["-N", "-f", good.to_str().unwrap(), "extra1", "extra2"],
        vec!["-N", "-f", "/nonexistent-mdev-conf-xyz"],
    ];
    for args in cases {
        let has = |f: &str| args.contains(&f);
        // Fill in deterministic defaults without overriding the case.
        let mut full: Vec<&str> = args.clone();
        if !has("-f") {
            full.push("-f");
            full.push(good.to_str().unwrap());
        }
        if !has("-d") {
            full.push("-d");
            full.push(dev.to_str().unwrap());
        }
        if !has("-s") {
            full.push("-s");
            full.push(sys.to_str().unwrap());
        }
        let mut oc = Command::new(&o_mdevd);
        oc.args(&full).env("LD_LIBRARY_PATH", ld_path());
        let od = run_timeout(oc, 10);
        let mut mc = Command::new(&ours);
        mc.args(&full);
        let md = run_timeout(mc, 10);
        assert_eq!((md.code, od.code), (od.code, od.code), "{args:?}: exit differs");
        assert_eq!(
            String::from_utf8_lossy(&md.stderr),
            String::from_utf8_lossy(&od.stderr),
            "{args:?}: stderr differs"
        );
        assert!(md.stdout.is_empty() && od.stdout.is_empty(), "{args:?}: stdout");
    }
}

/// -F is rejected here (registered divergence); the oracle accepts it.
#[test]
fn bins_firmware_flag_diverges() {
    let (o_mdevd, _) = oracle();
    let ours = bin("mdevd");
    let dev = devdir();
    let sys = sysdir();
    let good = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/laputa-mdev.conf");
    let mut mc = Command::new(&ours);
    mc.args(["-F", "/lib/firmware", "-N", "-f"])
        .arg(&good)
        .arg("-d")
        .arg(&dev)
        .arg("-s")
        .arg(&sys);
    let md = run_timeout(mc, 10);
    assert_eq!(md.code, Some(100));
    assert!(String::from_utf8_lossy(&md.stderr).contains("firmware loading is unsupported"));
    let mut oc = Command::new(&o_mdevd);
    oc.args(["-F", "/lib/firmware", "-N", "-f"])
        .arg(&good)
        .arg("-d")
        .arg(&dev)
        .arg("-s")
        .arg(&sys)
        .env("LD_LIBRARY_PATH", ld_path());
    let od = run_timeout(oc, 10);
    assert_eq!(od.code, Some(0));
}

/// Same-fd -D/-o rejection needs inherited fds; raw pipe() fds inherit.
#[test]
fn bins_same_fd_diff() {
    let (o_mdevd, _) = oracle();
    let ours = bin("mdevd");
    let mut fds = [0; 2];
    // SAFETY: fds is a valid output array; plain pipe() has no CLOEXEC.
    assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
    for (prog, extra_env) in [(o_mdevd.to_str().unwrap().to_string(), true), (ours.clone(), false)] {
        let mut cmd = Command::new(&prog);
        cmd.arg("-D")
            .arg(fds[1].to_string())
            .arg("-o")
            .arg(fds[1].to_string())
            .arg("-d")
            .arg(devdir())
            .arg("-s")
            .arg(sysdir());
        if extra_env {
            cmd.env("LD_LIBRARY_PATH", ld_path());
        }
        let d = run_timeout(cmd, 10);
        assert_eq!(d.code, Some(100), "{prog}");
        assert!(
            String::from_utf8_lossy(&d.stderr).contains("must not be the same"),
            "{prog}: {}",
            String::from_utf8_lossy(&d.stderr)
        );
    }
    unsafe {
        libc::close(fds[0]);
        libc::close(fds[1]);
    }
}

/// Spawn a daemon with a readiness pipe on fd N (inherited, non-CLOEXEC).
/// Returns the child plus the read end to await "\n" on.
fn spawn_daemon(prog: &str, args: &[&str], ld: bool) -> (std::process::Child, std::fs::File, i32) {
    let mut fds = [0; 2];
    assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
    // SAFETY: fds[0] is open and owned.
    let read = unsafe { std::os::unix::io::OwnedFd::from_raw_fd(fds[0]) };
    let read = std::fs::File::from(read);
    let mut cmd = Command::new(prog);
    cmd.args(args).arg("-D").arg(fds[1].to_string());
    if ld {
        cmd.env("LD_LIBRARY_PATH", ld_path());
    }
    let child = cmd.stdout(Stdio::null()).stderr(Stdio::null()).spawn().expect("daemon spawn");
    // SAFETY: write end was inherited; drop our copy so EOF works.
    unsafe {
        libc::close(fds[1]);
    }
    (child, read, fds[1])
}

fn await_ready(read: &mut std::fs::File) -> bool {
    use std::os::unix::io::AsRawFd;
    let mut pfd = libc::pollfd {
        fd: read.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: pfd is valid.
    let r = unsafe { libc::poll(&mut pfd, 1, 5000) };
    if r <= 0 {
        return false;
    }
    let mut b = [0u8; 8];
    use std::io::Read;
    matches!(read.read(&mut b), Ok(n) if n >= 1 && b[..n].contains(&b'\n'))
}

fn alive(pid: u32) -> bool {
    // SAFETY: kill(pid, 0) is a pure existence probe.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

fn term(child: &mut std::process::Child) -> Option<i32> {
    child.kill().ok();
    child.wait().ok().and_then(|s| s.code())
}

/// Readiness fires and SIGTERM exits 0, both binaries identically.
#[test]
fn bins_readiness_term() {
    let (o_mdevd, _) = oracle();
    let ours = bin("mdevd");
    let dev = devdir();
    let sys = sysdir();
    let good = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/laputa-mdev.conf");
    for (prog, ld) in [(o_mdevd.to_str().unwrap().to_string(), true), (ours.clone(), false)] {
        let args = ["-I".to_string(),
            "1".to_string(),
            "-f".to_string(),
            good.to_str().unwrap().to_string(),
            "-d".to_string(),
            dev.to_str().unwrap().to_string(),
            "-s".to_string(),
            sys.to_str().unwrap().to_string()];
        let argrefs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
        let (mut child, mut read, _) = spawn_daemon(&prog, &argrefs, ld);
        assert!(await_ready(&mut read), "{prog}: readiness never fired");
        std::thread::sleep(std::time::Duration::from_millis(100));
        // SIGTERM, not SIGKILL: the daemon must exit 0 by itself.
        // SAFETY: child is our own daemon.
        unsafe {
            libc::kill(child.id() as libc::pid_t, libc::SIGTERM);
        }
        let code = child.wait().expect("wait").code();
        assert_eq!(code, Some(0), "{prog}: TERM exit");
        let _ = term(&mut child);
    }
}

/// Re-exec this test under `unshare -U -n -r` when needed for netlink
/// multicast/cross-process send. Returns true when the caller should skip
/// (inner run delegated and asserted, or unshare unavailable).
fn delegate_unshare(test: &str) -> bool {
    if std::env::var("BINS_UNSHARED").is_ok() {
        return false;
    }
    let exe = match std::env::current_exe() {
        Ok(e) => e,
        Err(_) => {
            println!("note: no current exe; {test} skipped");
            return true;
        }
    };
    match Command::new("unshare")
        .args(["-U", "-n", "-r"])
        .arg(&exe)
        .arg(test)
        .arg("--exact")
        .arg("--nocapture")
        .env("BINS_UNSHARED", "1")
        .output()
    {
        Ok(o) => {
            println!("{}", String::from_utf8_lossy(&o.stdout));
            eprintln!("{}", String::from_utf8_lossy(&o.stderr));
            assert!(o.status.success(), "{test} failed under unshare");
            true
        }
        Err(e) => {
            println!("note: unshare unavailable ({e}); {test} skipped");
            true
        }
    }
}

/// Send one datagram by unicast to a bound netlink pid (works unprivileged).
fn send_unicast(pid: u32, datagram: &[u8]) {
    // SAFETY: minimal socket/sendto/close sequence.
    unsafe {
        let s = libc::socket(libc::AF_NETLINK, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 15);
        assert!(s != -1);
        let mut addr: libc::sockaddr_nl = std::mem::zeroed();
        addr.nl_family = libc::AF_NETLINK as libc::sa_family_t;
        addr.nl_pid = pid;
        let r = libc::sendto(
            s,
            datagram.as_ptr() as *const libc::c_void,
            datagram.len(),
            0,
            &addr as *const _ as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_nl>() as libc::socklen_t,
        );
        libc::close(s);
        assert!(r == datagram.len() as isize, "unicast send failed");
    }
}

fn normalize_pid(s: &str) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(i) = rest.find("process ") {
        out.push_str(&rest[..i + 8]);
        rest = &rest[i + 8..];
        let n = rest.bytes().take_while(|b| b.is_ascii_digit()).count();
        out.push_str("PID");
        rest = &rest[n..];
    }
    out.push_str(rest);
    out
}

/// Userspace events are dropped with a -v3 warning and never published.
#[test]
fn bins_drop_policy_diff() {
    if delegate_unshare("bins_drop_policy_diff") {
        return;
    }
    let (o_mdevd, _) = oracle();
    let ours = bin("mdevd");
    let dev = devdir();
    let sys = sysdir();
    let good = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/laputa-mdev.conf");
    let mut outputs = Vec::new();
    for (prog, ld) in [(o_mdevd.to_str().unwrap().to_string(), true), (ours.clone(), false)] {
        let out_path = Path::new(env!("CARGO_MANIFEST_DIR")).join(".work/tmp/bins-out.bin");
        let _ = std::fs::remove_file(&out_path);
        // SAFETY: plain open() has no CLOEXEC, so the fd is inherited.
        let ofd = unsafe {
            libc::open(
                std::ffi::CString::new(out_path.to_str().unwrap()).unwrap().as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC,
                0o644,
            )
        };
        assert!(ofd >= 0);
        let mut fds = [0; 2];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        // SAFETY: fds[0] is open and owned.
        let mut read = unsafe { std::fs::File::from(std::os::unix::io::OwnedFd::from_raw_fd(fds[0])) };
        let mut cmd = Command::new(&prog);
        cmd.args([
            "-I", "2", "-v3", "-f", good.to_str().unwrap(), "-d", dev.to_str().unwrap(), "-s",
            sys.to_str().unwrap(), "-o", &ofd.to_string(), "-D", &fds[1].to_string(),
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
        if ld {
            cmd.env("LD_LIBRARY_PATH", ld_path());
        }
        let mut child = cmd.spawn().expect("daemon spawn");
        // SAFETY: write end was inherited; drop our copy.
        unsafe {
            libc::close(fds[1]);
            libc::close(ofd);
        }
        assert!(await_ready(&mut read), "{prog}: readiness never fired");
        send_unicast(
            child.id(),
            b"add@/devices/x\0ACTION=add\0DEVPATH=/devices/x\0SUBSYSTEM=test\0DEVNAME=mydev\0MAJOR=1\0MINOR=2\0",
        );
        std::thread::sleep(std::time::Duration::from_millis(300));
        // SAFETY: child is our own daemon.
        unsafe {
            libc::kill(child.id() as libc::pid_t, libc::SIGTERM);
        }
        let status = child.wait().expect("wait");
        assert_eq!(status.code(), Some(0), "{prog}: TERM exit");
        let mut err = String::new();
        child.stderr.take().unwrap().read_to_string(&mut err).unwrap();
        let out_bytes = std::fs::read(&out_path).unwrap();
        assert!(out_bytes.is_empty(), "{prog}: dropped event was published");
        outputs.push(normalize_pid(&err));
    }
    assert_eq!(outputs[0], outputs[1], "drop warning differs:\n{}", outputs.join("\n---\n"));
}

/// Invalid reloads retain the last valid config here (registered
/// divergence); the oracle exits 2 on the same HUP.
#[test]
fn bins_hup_retain_diverges() {
    if delegate_unshare("bins_hup_retain_diverges") {
        return;
    }
    let (o_mdevd, _) = oracle();
    let ours = bin("mdevd");
    let dev = devdir();
    let sys = sysdir();
    let work = Path::new(env!("CARGO_MANIFEST_DIR")).join(".work/tmp/bins-hup.conf");
    std::fs::write(&work, "mydev root:root 600\n").unwrap();
    // Ours: HUP with a broken config keeps the daemon alive; TERM exits 0.
    {
        let args = ["-I".to_string(),
            "1".to_string(),
            "-f".to_string(),
            work.to_str().unwrap().to_string(),
            "-d".to_string(),
            dev.to_str().unwrap().to_string(),
            "-s".to_string(),
            sys.to_str().unwrap().to_string()];
        let argrefs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
        let (mut child, mut read, _) = spawn_daemon(&ours, &argrefs, false);
        assert!(await_ready(&mut read), "ours: readiness never fired");
        std::fs::write(&work, ";broken\n").unwrap();
        // SAFETY: child is our own daemon.
        unsafe {
            libc::kill(child.id() as libc::pid_t, libc::SIGHUP);
        }
        std::thread::sleep(std::time::Duration::from_millis(400));
        assert!(alive(child.id()), "ours: daemon died on invalid reload");
        unsafe {
            libc::kill(child.id() as libc::pid_t, libc::SIGTERM);
        }
        assert_eq!(child.wait().expect("wait").code(), Some(0));
    }
    // Oracle: the same HUP kills it with exit 2.
    {
        let args = ["-I".to_string(),
            "1".to_string(),
            "-f".to_string(),
            work.to_str().unwrap().to_string(),
            "-d".to_string(),
            dev.to_str().unwrap().to_string(),
            "-s".to_string(),
            sys.to_str().unwrap().to_string()];
        let argrefs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
        std::fs::write(&work, "mydev root:root 600\n").unwrap();
        let (mut child, mut read, _) = spawn_daemon(o_mdevd.to_str().unwrap(), &argrefs, true);
        assert!(await_ready(&mut read), "oracle: readiness never fired");
        std::fs::write(&work, ";broken\n").unwrap();
        unsafe {
            libc::kill(child.id() as libc::pid_t, libc::SIGHUP);
        }
        let code = child.wait().expect("wait").code();
        assert_eq!(code, Some(2), "oracle: expected death on invalid reload");
    }
}

/// Coldplug triggers every uevent file under a fake tree, both binaries.
#[test]
fn bins_coldplug_tree_diff() {
    let (_, o_coldplug) = oracle();
    let ours = bin("mdevd-coldplug");
    for (tag, prog, ld) in [("oracle", o_coldplug.to_str().unwrap().to_string(), true), ("ours", ours.clone(), false)] {
        let tree = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(format!(".work/tmp/cptree-{tag}"));
        let _ = std::fs::remove_dir_all(&tree);
        for dev in ["bar", "baz"] {
            let d = tree.join("subsystem/foo/devices").join(dev);
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(d.join("uevent"), format!("PLACEHOLDER-{dev}\n")).unwrap();
        }
        // A stray non-uevent file and a dotfile must not break the scan.
        std::fs::write(tree.join("subsystem/foo/devices/bar/note"), b"x\n").unwrap();
        let mut cmd = Command::new(&prog);
        cmd.arg("-s").arg(&tree);
        if ld {
            cmd.env("LD_LIBRARY_PATH", ld_path());
        }
        let done = run_timeout(cmd, 15);
        assert_eq!(done.code, Some(0), "{tag}: coldplug exit");
        for dev in ["bar", "baz"] {
            let content = std::fs::read(tree.join("subsystem/foo/devices").join(dev).join("uevent")).unwrap();
            assert!(content.starts_with(b"add\n"), "{tag}/{dev}: uevent not triggered");
        }
    }
}

/// Coldplug sync without a daemon: ours times out loudly and fast; the
/// oracle waits forever (shown via timeout-kill, proving the divergence).
#[test]
fn bins_coldplug_sync_timeout() {
    let (_, o_coldplug) = oracle();
    let ours = bin("mdevd-coldplug");
    let tree = Path::new(env!("CARGO_MANIFEST_DIR")).join(".work/tmp/cptree-sync");
    let _ = std::fs::remove_dir_all(&tree);
    let d = tree.join("subsystem/foo/devices/bar");
    std::fs::create_dir_all(&d).unwrap();
    std::fs::write(d.join("uevent"), b"PLACEHOLDER\n").unwrap();
    let mut cmd = Command::new(&ours);
    cmd.arg("-s").arg(&tree).arg("-O").arg("4").env("MDEVD_COLDPLUG_SYNC_TIMEOUT_SECS", "2");
    let start = std::time::Instant::now();
    let done = run_timeout(cmd, 20);
    assert!(start.elapsed() < std::time::Duration::from_secs(15));
    assert_eq!(done.code, Some(1));
    assert!(String::from_utf8_lossy(&done.stderr).contains("timed out waiting for coldplug sync"));
    // Oracle side: still waiting after 3 s (killed by timeout).
    let mut ocmd = Command::new(&o_coldplug);
    ocmd.arg("-s").arg(&tree).arg("-O").arg("4").env("LD_LIBRARY_PATH", ld_path());
    let odone = run_timeout(ocmd, 3);
    assert_eq!(odone.code, None, "oracle: expected to still be waiting");
}

use super::Fixture;
use mdevd::uevent::{bind_intake, read_event, ReadOutcome, Stats};
use std::io::{Read, Write};
use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::os::unix::fs::OpenOptionsExt;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

struct Daemon(Child);

impl Drop for Daemon {
    fn drop(&mut self) {
        if self.0.try_wait().unwrap().is_none() { self.0.kill().expect("kill daemon"); }
        self.0.wait().expect("reap daemon");
    }
}

fn pipe() -> (std::fs::File, OwnedFd) {
    let mut fds = [-1; 2];
    // SAFETY: fds is valid output storage for two descriptors.
    assert_eq!(unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) }, 0);
    // SAFETY: pipe2 returned two distinct open descriptors.
    unsafe { (std::fs::File::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) }
}

fn readable(fd: &impl AsRawFd, deadline: Instant) {
    let mut poll = libc::pollfd { fd: fd.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    let remaining = deadline.saturating_duration_since(Instant::now()).as_millis() as i32;
    // SAFETY: poll contains one valid descriptor and remains live during the call.
    assert!(unsafe { libc::poll(&mut poll, 1, remaining) } > 0, "kernel event or daemon output timed out");
}

fn events(fd: &OwnedFd, interface: &[u8], action: &[u8]) -> Vec<Vec<u8>> {
    readable(fd, Instant::now() + Duration::from_secs(5));
    let mut stats = Stats::default();
    let mut records = Vec::new();
    let mut matched = false;
    loop {
        match read_event(fd.as_fd(), true, &mut stats).unwrap() {
            ReadOutcome::Event(event) => {
                if event.getvar(b"INTERFACE") == Some(interface) && event.getvar(b"ACTION") == Some(action) {
                    assert_eq!(event.getvar(b"SUBSYSTEM"), Some(b"net".as_slice()));
                    matched = true;
                }
                records.push(event.buf);
            }
            ReadOutcome::Nothing => break,
            other => panic!("unexpected kernel input: {other:?}"),
        }
    }
    assert!(matched, "missing interface event");
    assert_eq!((stats.dropped_userspace, stats.invalid, stats.overruns), (0, 0, 0));
    records
}

fn rebroadcast(fd: &OwnedFd, expected: &[u8]) {
    readable(fd, Instant::now() + Duration::from_secs(5));
    let mut stats = Stats::default();
    match read_event(fd.as_fd(), false, &mut stats).unwrap() {
        ReadOutcome::Event(event) => assert_eq!(event.buf, expected),
        other => panic!("expected rebroadcast, got {other:?}"),
    }
}

fn exact(read: &mut std::fs::File, expected: &[u8]) {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut bytes = vec![0; expected.len()];
    let mut offset = 0;
    while offset < bytes.len() {
        readable(read, deadline);
        let size = read.read(&mut bytes[offset..]).unwrap();
        assert!(size > 0, "daemon closed output early");
        offset += size;
    }
    assert_eq!(bytes, expected);
}

fn ip(args: &[&str]) {
    let output = Command::new("/busybox").arg("ip").args(args).output().unwrap();
    assert!(output.status.success(), "ip: {}", String::from_utf8_lossy(&output.stderr));
}

#[test]
#[ignore = "requires tools/check-privileged.sh kernel network namespace"]
fn adversarial_kernel_daemon_publication_matches_intake() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    for (index, program) in [root.join(".work/oracle/src-tree/mdevd"), env!("CARGO_BIN_EXE_mdevd").into()].iter().enumerate() {
        let f = Fixture::new(&format!("kernel-{index}"));
        let config = f.root.join("config");
        std::fs::write(&config, b".* 0:0 600\n").unwrap();
        let kernel = bind_intake(1, 1048576).unwrap();
        let published = bind_intake(4, 1048576).unwrap();
        let (mut ready, notify) = pipe();
        let (mut output, sink) = pipe();
        let inherited = [notify.as_raw_fd(), sink.as_raw_fd()];
        let mut cmd = Command::new(program);
        cmd.arg("-f").arg(&config).arg("-d").arg(f.root.join("dev"))
            .arg("-s").arg(f.root.join("sys")).args(["-O", "4", "-D"])
            .arg(notify.as_raw_fd().to_string()).arg("-o").arg(sink.as_raw_fd().to_string())
            .env("LD_LIBRARY_PATH", root.join(".work/vendor/sysdeps-root/lib"))
            .stdout(Stdio::null()).stderr(Stdio::inherit());
        // SAFETY: only the validated pipe ends have CLOEXEC cleared in the child.
        unsafe { cmd.pre_exec(move || {
            for fd in inherited {
                if libc::fcntl(fd, libc::F_SETFD, 0) == -1 { return Err(std::io::Error::last_os_error()); }
            }
            Ok(())
        }); }
        let mut daemon = Daemon(cmd.spawn().unwrap());
        drop(notify);
        drop(sink);
        exact(&mut ready, b"\n");
        let name = format!("mdevd-proof{index}");
        std::fs::remove_file(&config).unwrap();
        let fifo = std::ffi::CString::new(config.as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: fifo is NUL-terminated and the parent is our private fixture.
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        // SAFETY: daemon is our owned live child.
        assert_eq!(unsafe { libc::kill(daemon.0.id() as i32, libc::SIGHUP) }, 0);
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut reload = loop {
            match std::fs::OpenOptions::new().write(true).custom_flags(libc::O_NONBLOCK).open(&config) {
                Ok(writer) => break writer,
                Err(e) if e.raw_os_error() == Some(libc::ENXIO) => {
                    assert!(Instant::now() < deadline, "daemon never opened reload config");
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(e) => panic!("reload config: {e}"),
            }
        };
        ip(&["link", "add", &name, "type", "dummy"]);
        reload.write_all(b".* 0:0 640\n").unwrap();
        drop(reload);
        for add in events(&kernel, name.as_bytes(), b"add") {
            let mut framed = add.clone();
            framed.push(0);
            exact(&mut output, &framed);
            rebroadcast(&published, &add);
        }
        ip(&["link", "del", &name]);
        for remove in events(&kernel, name.as_bytes(), b"remove") {
            let mut framed = remove.clone();
            framed.push(0);
            exact(&mut output, &framed);
            rebroadcast(&published, &remove);
        }
        // SAFETY: daemon is our owned live child.
        assert_eq!(unsafe { libc::kill(daemon.0.id() as i32, libc::SIGTERM) }, 0);
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = daemon.0.try_wait().unwrap() {
                assert_eq!(status.code(), Some(0));
                break;
            }
            assert!(Instant::now() < deadline, "daemon ignored TERM");
            std::thread::sleep(Duration::from_millis(5));
        }
        let mut remainder = Vec::new();
        output.read_to_end(&mut remainder).unwrap();
        assert!(remainder.is_empty(), "duplicate or out-of-order publication");
        assert!(std::fs::read_dir(f.root.join("dev")).unwrap().next().is_none());
    }
}

use super::support::*;
use std::io::Write;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

fn our_program() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_mdevd"))
}

struct Daemon {
    child: Process,
    ready: std::fs::File,
    err: std::process::ChildStderr,
    out: PathBuf,
}

impl Daemon {
    fn start(program: &Path, work: &Work) -> Self {
        let (mut ready, notify) = pipe();
        let out = work.0.join("output");
        let file = std::fs::File::create(&out).unwrap();
        let mut cmd = command(program);
        cmd.args(["-I", "2", "-v3", "-f"]).arg(work.0.join("config"))
            .arg("-d").arg(work.0.join("dev")).arg("-s").arg(work.0.join("sys"))
            .arg("-o").arg(file.as_raw_fd().to_string())
            .arg("-D").arg(notify.as_raw_fd().to_string())
            .stdout(Stdio::null()).stderr(Stdio::piped());
        let inherited = [file.as_raw_fd(), notify.as_raw_fd()];
        unsafe {
            cmd.pre_exec(move || {
                for fd in inherited {
                    if libc::fcntl(fd, libc::F_SETFD, 0) == -1 {
                        return Err(std::io::Error::last_os_error());
                    }
                }
                Ok(())
            });
        }
        let mut child = Process(cmd.spawn().unwrap());
        drop(notify);
        drop(file);
        assert_eq!(line(&mut ready), b"\n");
        let err = child.0.stderr.take().unwrap();
        Self { child, ready, err, out }
    }

    fn inject(&mut self, record: &[u8]) -> Vec<u8> {
        let fd = unsafe { libc::socket(libc::AF_NETLINK, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 15) };
        assert!(fd >= 0);
        let fd = unsafe { OwnedFd::from_raw_fd(fd) };
        let mut address: libc::sockaddr_nl = unsafe { std::mem::zeroed() };
        address.nl_family = libc::AF_NETLINK as u16;
        address.nl_pid = self.child.0.id();
        assert_eq!(unsafe { libc::sendto(fd.as_raw_fd(), record.as_ptr().cast(), record.len(), 0,
            (&address as *const libc::sockaddr_nl).cast(), std::mem::size_of_val(&address) as u32) }, record.len() as isize);
        let warning = line(&mut self.err);
        let text = std::str::from_utf8(&warning).unwrap();
        let prefix = "mdevd: warning: received netlink message from userspace process ";
        let pid = text.strip_prefix(prefix).unwrap().trim_end().parse::<u32>().unwrap();
        assert!(pid > 0);
        assert!(std::fs::read(&self.out).unwrap().is_empty(), "spoofed event reached -o");
        prefix.as_bytes().to_vec()
    }

    fn stop(&mut self) -> (Vec<u8>, i32) {
        self.child.signal(libc::SIGTERM);
        let status = self.child.wait().code().unwrap();
        use std::io::Read;
        let mut readiness = Vec::new();
        self.ready.read_to_end(&mut readiness).unwrap();
        assert!(readiness.is_empty(), "readiness fired again on reload");
        (std::fs::read(&self.out).unwrap(), status)
    }
}

fn fixture(name: &str) -> Work {
    let work = Work::new(name);
    std::fs::create_dir(work.0.join("dev")).unwrap();
    std::fs::create_dir(work.0.join("sys")).unwrap();
    std::fs::write(work.0.join("config"), b"mydev root:root 600\n").unwrap();
    work
}

fn reload(daemon: &Daemon, work: &Work, text: &[u8]) {
    let path = work.0.join("config");
    std::fs::remove_file(&path).unwrap();
    let cpath = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(cpath.as_ptr(), 0o600) }, 0);
    daemon.child.signal(libc::SIGHUP);
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut writer = loop {
        match std::fs::OpenOptions::new().write(true)
            .custom_flags(libc::O_NONBLOCK).open(&path) {
            Ok(file) => break file,
            Err(e) if e.raw_os_error() == Some(libc::ENXIO) => {
                assert!(Instant::now() < deadline, "daemon never opened reload config");
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(e) => panic!("reload FIFO: {e}"),
        }
    };
    writer.write_all(text).unwrap();
}

use std::os::unix::fs::OpenOptionsExt;

#[test]
fn daemon_userspace_output_drops_spoofed() {
    if unshare("daemon::daemon_userspace_output_drops_spoofed") { return; }
    let events = [
        b"add@/devices/x\0ACTION=add\0DEVPATH=/devices/x\0DEVNAME=mydev\0MAJOR=1\0MINOR=2\0".as_slice(),
        b"change@/devices/x\0ACTION=change\0DEVPATH=/devices/x\0",
        b"remove@/devices/x\0ACTION=remove\0DEVPATH=/devices/x\0",
        b"not-nul-terminated",
    ];
    let work = fixture("output");
    let mut daemon = Daemon::start(&our_program(), &work);
    for e in events {
        let warning = daemon.inject(e);
        assert!(warning.starts_with(b"mdevd: warning: received netlink message from userspace process "));
    }
    let (bytes, code) = daemon.stop();
    assert_eq!(code, 0);
    assert!(bytes.is_empty(), "spoofed event reached -o");
    assert!(std::fs::read_dir(work.0.join("dev")).unwrap().next().is_none());
}

#[test]
fn daemon_reload_matrix() {
    if unshare("daemon::daemon_reload_matrix") { return; }
    let work = fixture("reload");
    let mut daemon = Daemon::start(&our_program(), &work);
    for text in [b"mydev root:root 640\n".as_slice(), b"", b"# comments only\n"] {
        reload(&daemon, &work, text);
        daemon.inject(b"add@/x\0ACTION=add\0DEVPATH=/x\0");
    }
    std::fs::remove_file(work.0.join("config")).unwrap();
    daemon.child.signal(libc::SIGHUP);
    let warning = String::from_utf8(line(&mut daemon.err)).unwrap();
    assert_eq!(warning, format!("mdevd: warning: unable to read {}: No such file or directory\n",
        work.0.join("config").display()));
    daemon.inject(b"remove@/x\0ACTION=remove\0DEVPATH=/x\0");
    std::fs::write(work.0.join("config"), b"mydev root:root 600\n").unwrap();
    reload(&daemon, &work, b";broken\n");
    assert_eq!(line(&mut daemon.err),
        b"mdevd: warning: reload keeps last valid config: syntax error during first pass: line 1 column 1\n");
    daemon.inject(b"change@/x\0ACTION=change\0DEVPATH=/x\0");
    reload(&daemon, &work, b"mydev root:root 660\n");
    daemon.inject(b"add@/x\0ACTION=add\0DEVPATH=/x\0");
    assert_eq!(daemon.stop(), (vec![], 0));
    let error_work = fixture("read-error");
    let mut daemon = Daemon::start(&our_program(), &error_work);
    std::fs::remove_file(error_work.0.join("config")).unwrap();
    std::fs::create_dir(error_work.0.join("config")).unwrap();
    daemon.child.signal(libc::SIGHUP);
    assert_eq!(daemon.child.wait().code(), Some(111));
    assert_eq!(String::from_utf8(line(&mut daemon.err)).unwrap(),
        format!("mdevd: fatal: unable to read {}: Is a directory\n", error_work.0.join("config").display()));
}

#[test]
fn config_acceptance_contract() {
    let work = fixture("config");
    let ours = our_program();
    let cases = [
        ("tests/corpus/c-min.conf", 0, ""),
        ("tests/corpus/c-cmds.conf", 2, "command hooks are unsupported"),
        ("tests/fixtures/bad-mdev.conf", 2, "syntax error"),
    ];
    for (file, code, fragment) in cases {
        let path = root().join(file);
        let mut cmd = command(&ours);
        cmd.args(["-N", "-f"]).arg(&path).arg("-d").arg(work.0.join("dev"))
            .arg("-s").arg(work.0.join("sys"));
        let out = output(cmd);
        assert_eq!(out.status.code(), Some(code), "{file}");
        assert!(out.stdout.is_empty(), "{file}");
        if fragment.is_empty() {
            assert!(out.stderr.is_empty(), "{file}: {}", String::from_utf8_lossy(&out.stderr));
        } else {
            assert!(String::from_utf8_lossy(&out.stderr).contains(fragment), "{file}");
        }
    }
}

#[test]
fn coldplug_tree_triggers_all() {
    let program = PathBuf::from(env!("CARGO_BIN_EXE_mdevd-coldplug"));
    let work = Work::new("coldplug");
    for name in ["block/devices/a", "input/devices/b", "pci/devices/c"] {
        let dir = work.0.join("sys/subsystem").join(name);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("uevent"), b"placeholder\n").unwrap();
    }
    let mut cmd = command(&program);
    cmd.arg("-s").arg(work.0.join("sys"));
    let out = output(cmd);
    assert_eq!(out.status.code(), Some(0));
    for name in ["block/devices/a", "input/devices/b", "pci/devices/c"] {
        let content = std::fs::read(work.0.join("sys/subsystem").join(name).join("uevent")).unwrap();
        assert!(content.starts_with(b"add\n"), "{name}");
    }
    assert!(out.stdout.is_empty());
}

#[test]
fn oversize_config_rejected() {
    let work = fixture("oversize");
    std::fs::write(work.0.join("config"), vec![b'#'; mdevd::config::CONF_MAX]).unwrap();
    let mut cmd = command(&our_program());
    cmd.args(["-N", "-f"]).arg(work.0.join("config"))
        .arg("-d").arg(work.0.join("dev")).arg("-s").arg(work.0.join("sys"));
    let out = output(cmd);
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("configuration too large"));
}

#[test]
fn coldplug_cli_rejects_bad_flags() {
    let program = PathBuf::from(env!("CARGO_BIN_EXE_mdevd-coldplug"));
    for args in [["-z", ""], ["-v", "nan"], ["-O", "0x4"], ["-b", "bad"]] {
        let mut cmd = command(&program);
        cmd.args(args);
        let out = output(cmd);
        assert_eq!(out.status.code(), Some(100), "{args:?}");
        assert!(out.stdout.is_empty());
    }
}

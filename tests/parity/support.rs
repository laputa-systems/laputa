use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

pub fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).to_path_buf()
}

pub fn command(program: &Path) -> Command {
    let mut cmd = Command::new(program);
    cmd.env("LC_ALL", "C");
    cmd
}

pub struct Process(pub Child);

impl Process {
    pub fn wait(&mut self) -> ExitStatus {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = self.0.try_wait().unwrap() {
                return status;
            }
            assert!(Instant::now() < deadline, "child {} did not exit", self.0.id());
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    pub fn signal(&self, signal: i32) {
        assert_eq!(unsafe { libc::kill(self.0.id() as i32, signal) }, 0);
    }
}

impl Drop for Process {
    fn drop(&mut self) {
        if self.0.try_wait().unwrap().is_none() {
            self.0.kill().expect("kill test child");
        }
        self.0.wait().expect("reap test child");
    }
}

pub fn output(mut cmd: Command) -> std::process::Output {
    let mut child = Process(cmd.stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap());
    let status = child.wait();
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    child.0.stdout.take().unwrap().read_to_end(&mut stdout).unwrap();
    child.0.stderr.take().unwrap().read_to_end(&mut stderr).unwrap();
    std::process::Output { status, stdout, stderr }
}

pub struct Work(pub PathBuf);

impl Work {
    pub fn new(name: &str) -> Self {
        let path = root().join(format!(".work/tmp/parity-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Work {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).expect("remove parity fixture");
    }
}

pub fn pipe() -> (std::fs::File, OwnedFd) {
    let mut fds = [-1; 2];
    assert_eq!(unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) }, 0);
    unsafe { (std::fs::File::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) }
}

pub fn readable(fd: &impl AsRawFd, deadline: Instant) {
    let mut poll = libc::pollfd { fd: fd.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    let remaining = deadline.saturating_duration_since(Instant::now());
    assert!(unsafe { libc::poll(&mut poll, 1, remaining.as_millis() as i32) } > 0,
        "timed out waiting for child I/O");
}

pub fn line(fd: &mut (impl AsRawFd + Read)) -> Vec<u8> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut line = Vec::new();
    loop {
        readable(fd, deadline);
        let mut b = [0];
        fd.read_exact(&mut b).expect("child closed before acknowledgement");
        line.push(b[0]);
        if b[0] == b'\n' { return line; }
    }
}

pub fn unshare(test: &str) -> bool {
    if std::env::var_os("PARITY_UNSHARED").is_some() { return false; }
    let out = Command::new("unshare").args(["-U", "-n", "-r"])
        .arg(std::env::current_exe().unwrap()).args([test, "--exact", "--nocapture"])
        .env("PARITY_UNSHARED", "1").output().expect("run unshare");
    assert!(out.status.success(), "namespace test failed:\n{}\n{}",
        String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    true
}

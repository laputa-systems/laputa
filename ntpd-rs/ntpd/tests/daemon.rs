#![allow(missing_docs)]

use std::{
    io::Read,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

const CARGO_TARGET_TMPDIR: &str = env!("CARGO_TARGET_TMPDIR");

struct Daemon {
    child: Child,
}

impl Daemon {
    fn start(config: &Path) -> Daemon {
        let child = Command::new(env!("CARGO_BIN_EXE_ntp-daemon"))
            .arg("-c")
            .arg(config)
            .env_remove("NOTIFY_SOCKET")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        Daemon { child }
    }

    fn wait_for_exit(&mut self, limit: Duration) -> Option<std::process::ExitStatus> {
        let deadline = Instant::now() + limit;
        while Instant::now() < deadline {
            if let Some(status) = self.child.try_wait().unwrap() {
                return Some(status);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        None
    }

    fn output(mut self) -> String {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let mut text = String::new();
        if let Some(mut stdout) = self.child.stdout.take() {
            let _ = stdout.read_to_string(&mut text);
        }
        if let Some(mut stderr) = self.child.stderr.take() {
            let _ = stderr.read_to_string(&mut text);
        }
        text
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn scratch_dir(name: &str) -> PathBuf {
    let dir = Path::new(CARGO_TARGET_TMPDIR).join(format!("daemon-{name}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn daemon_fails_when_the_observation_socket_cannot_be_created() {
    let dir = scratch_dir("unbindable");
    let config = dir.join("ntp.toml");
    std::fs::write(
        &config,
        format!(
            "[observability]\nobservation-path = \"{}\"\n",
            dir.join("missing-directory/observe").display()
        ),
    )
    .unwrap();

    let mut daemon = Daemon::start(&config);

    let Some(status) = daemon.wait_for_exit(Duration::from_secs(10)) else {
        panic!("daemon kept running: {}", daemon.output());
    };
    assert!(!status.success());
    let text = daemon.output();
    assert!(text.contains("Could not create observe socket"), "{text}");
}

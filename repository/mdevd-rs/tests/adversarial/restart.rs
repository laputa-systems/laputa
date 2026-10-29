use std::os::unix::io::FromRawFd;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

fn root(name: &str) -> std::path::PathBuf {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join(format!(".work/tmp/adversarial-restart-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("dev")).unwrap();
    std::fs::create_dir_all(root.join("sys")).unwrap();
    root
}

fn alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

fn wait_exit(child: &mut Child, secs: u64) -> Option<i32> {
    let deadline = Instant::now() + Duration::from_secs(secs);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status.code();
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn await_ready(read: &mut std::fs::File) -> bool {
    use std::os::unix::io::AsRawFd;
    let mut pfd = libc::pollfd {
        fd: read.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    let r = unsafe { libc::poll(&mut pfd, 1, 5000) };
    if r <= 0 {
        return false;
    }
    let mut buf = [0u8; 8];
    use std::io::Read;
    match read.read(&mut buf) {
        Ok(n) => n >= 1 && buf[..n].contains(&b'\n'),
        Err(_) => false,
    }
}

fn spawn_daemon(root: &std::path::Path, path_env: &str) -> (Child, std::fs::File) {
    let mut fds = [0; 2];
    assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
    let read = unsafe {
        std::fs::File::from(std::os::unix::io::OwnedFd::from_raw_fd(fds[0]))
    };
    let helper = root.join("bin").join("mdevd-coldplug");
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_mdevd"));
    cmd.args([
        "-I",
        "1",
        "-f",
        root.join("config").to_str().unwrap(),
        "-d",
        root.join("dev").to_str().unwrap(),
        "-s",
        root.join("sys").to_str().unwrap(),
        "-C",
        "-D",
        &fds[1].to_string(),
    ])
    .env("PATH", path_env)
    .env("MDEVD_COLDPLUG_HELPER", &helper)
    .stdout(Stdio::null())
    .stderr(Stdio::null());
    let child = cmd.spawn().expect("spawn mdevd");
    unsafe {
        libc::close(fds[1]);
    }
    (child, read)
}

#[test]
fn adversarial_restart_during_coldplug() {
    let root = root("coldplug");
    std::fs::write(root.join("config"), b"mydev root:root 600\n").unwrap();
    let bindir = root.join("bin");
    std::fs::create_dir_all(&bindir).unwrap();
    let marker = root.join("coldplug-started");
    let pidfile = root.join("coldplug.pid");
    let shim = bindir.join("mdevd-coldplug");
    std::fs::write(
        &shim,
        format!(
            "#!/bin/sh\necho $$ > {}\ntouch {}\nexec sleep 30\n",
            pidfile.display(),
            marker.display()
        ),
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755)).unwrap();
    let path_env = format!(
        "{}:{}",
        bindir.display(),
        std::env::var("PATH").unwrap_or_default()
    );

    let (mut first, mut ready) = spawn_daemon(&root, &path_env);
    assert!(await_ready(&mut ready), "readiness never fired with -C");
    let deadline = Instant::now() + Duration::from_secs(5);
    while !marker.exists() {
        assert!(Instant::now() < deadline, "coldplug child never spawned");
        std::thread::sleep(Duration::from_millis(5));
    }
    let coldplug_pid: i32 = std::fs::read_to_string(&pidfile)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    assert!(coldplug_pid > 0);
    assert!(alive(first.id()), "daemon died before restart probe");
    assert!(alive(coldplug_pid as u32), "coldplug shim died early");

    unsafe {
        libc::kill(first.id() as libc::pid_t, libc::SIGHUP);
    }
    std::thread::sleep(Duration::from_millis(400));
    assert!(alive(first.id()), "daemon died on HUP during coldplug");
    assert!(
        alive(coldplug_pid as u32),
        "coldplug reaped or died on daemon HUP"
    );

    unsafe {
        libc::kill(first.id() as libc::pid_t, libc::SIGTERM);
    }
    assert_eq!(
        wait_exit(&mut first, 5),
        Some(0),
        "daemon did not exit promptly with coldplug child running"
    );
    assert!(
        alive(coldplug_pid as u32),
        "daemon exit killed or waited on coldplug child"
    );

    let (mut second, mut ready2) = spawn_daemon(&root, &path_env);
    assert!(await_ready(&mut ready2), "restarted daemon never became ready");
    unsafe {
        libc::kill(second.id() as libc::pid_t, libc::SIGTERM);
    }
    assert_eq!(wait_exit(&mut second, 5), Some(0));

    unsafe {
        libc::kill(coldplug_pid, libc::SIGKILL);
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    while alive(coldplug_pid as u32) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    let _ = std::fs::remove_dir_all(&root);
}

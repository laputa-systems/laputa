use super::Fixture;
use mdevd::engine::ops::Ops;
use std::os::unix::fs::{symlink, PermissionsExt};

#[test]
fn adversarial_mkdir_confines_ancestors() {
    let f = Fixture::new("mkdir");
    symlink("../outside", f.root.join("dev/link")).unwrap();
    let mut ops = f.ops();
    let result = ops.subdirs(b"link/escaped/node");
    assert!(!f.root.join("outside/escaped").exists(), "mkdir followed an ancestor symlink");
    assert!(result.is_err());
    assert!(ops.subdirs(b"../outside/escaped/node").is_err());
    assert!(!f.root.join("outside/escaped").exists());
}

#[test]
fn adversarial_chmod_refuses_leaf_symlink() {
    let f = Fixture::new("chmod");
    let victim = f.root.join("outside/file");
    std::fs::write(&victim, b"victim").unwrap();
    std::fs::set_permissions(&victim, std::fs::Permissions::from_mode(0o600)).unwrap();
    symlink("../outside/file", f.root.join("dev/node")).unwrap();
    assert!(f.ops().chmod(b"node", 0o666).is_err());
    assert_eq!(std::fs::metadata(victim).unwrap().permissions().mode() & 0o7777, 0o600);
}

#[test]
fn adversarial_unlink_confines_ancestors() {
    let f = Fixture::new("unlink");
    let victim = f.root.join("outside/file");
    std::fs::write(&victim, b"victim").unwrap();
    symlink("../outside", f.root.join("dev/link")).unwrap();
    f.ops().unlink(b"link/file");
    assert_eq!(std::fs::read(victim).unwrap(), b"victim");
}

#[test]
fn adversarial_fifo_root_fails_without_blocking_daemon() {
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};
    let f = Fixture::new("fifo-root");
    let path = f.root.join("fifo");
    let name = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: name is NUL-terminated and the parent belongs to this fixture.
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    let mut child = Command::new(env!("CARGO_BIN_EXE_mdevd"))
        .args(["-N", "-s"]).arg(path).arg("-d").arg(f.root.join("dev"))
        .stdout(Stdio::null()).stderr(Stdio::piped()).spawn().unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert_eq!(status.code(), Some(111));
            let mut diagnostic = String::new();
            use std::io::Read;
            child.stderr.take().unwrap().read_to_string(&mut diagnostic).unwrap();
            assert!(diagnostic.contains("unable to open device/sys roots: Not a directory"), "{diagnostic}");
            break;
        }
        if Instant::now() >= deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("opening a non-directory root blocked the daemon");
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

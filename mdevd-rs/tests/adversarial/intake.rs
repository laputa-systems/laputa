use mdevd::uevent::{bind_intake, read_event, Fatal, ReadOutcome, Stats};
use std::os::fd::{AsFd, AsRawFd};

fn namespace(test: &str) -> bool {
    if std::env::var_os("ADVERSARIAL_UNSHARED").is_some() { return false; }
    let out = std::process::Command::new("unshare").args(["-U", "-n", "-r"])
        .arg(std::env::current_exe().unwrap()).args([test, "--exact", "--nocapture"])
        .env("ADVERSARIAL_UNSHARED", "1").output().unwrap();
    assert!(out.status.success(), "{}\n{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    true
}

fn send(fd: &std::os::fd::OwnedFd, bytes: &[u8]) {
    let mut address: libc::sockaddr_nl = unsafe { std::mem::zeroed() };
    let mut size = std::mem::size_of_val(&address) as libc::socklen_t;
    // SAFETY: address and size are valid output storage for this socket.
    assert_eq!(unsafe { libc::getsockname(fd.as_raw_fd(), (&mut address as *mut libc::sockaddr_nl).cast(), &mut size) }, 0);
    // SAFETY: the record and destination address remain valid for sendto.
    assert_eq!(unsafe { libc::sendto(fd.as_raw_fd(), bytes.as_ptr().cast(), bytes.len(), 0,
        (&address as *const libc::sockaddr_nl).cast(), size) }, bytes.len() as isize);
}

#[test]
fn adversarial_truncation_precedes_userspace_filter() {
    if namespace("intake::adversarial_truncation_precedes_userspace_filter") { return; }
    let fd = bind_intake(0, 65536).unwrap();
    send(&fd, &vec![b'x'; 8193]);
    let mut stats = Stats::default();
    assert!(matches!(read_event(fd.as_fd(), true, &mut stats), Err(Fatal::Truncated)));
    assert_eq!(stats.truncated, 1);
    assert_eq!(stats.dropped_userspace, 0);
}

#[test]
fn adversarial_spoof_flood_and_variable_limit() {
    if namespace("intake::adversarial_spoof_flood_and_variable_limit") { return; }
    let fd = bind_intake(0, 65536).unwrap();
    let mut stats = Stats::default();
    for _ in 0..10_000 {
        send(&fd, b"add@/x\0ACTION=add\0DEVPATH=/x\0");
        assert!(matches!(read_event(fd.as_fd(), true, &mut stats).unwrap(), ReadOutcome::DroppedUserspace(_)));
    }
    assert_eq!(stats.dropped_userspace, 10_000);
    assert_eq!((stats.invalid, stats.overruns, stats.truncated), (0, 0, 0));
    let mut record = b"add@/x\0".to_vec();
    for _ in 0..63 { record.extend_from_slice(b"A=1\0"); }
    send(&fd, &record);
    assert!(matches!(read_event(fd.as_fd(), false, &mut stats).unwrap(),
        ReadOutcome::Invalid(mdevd::uevent::Invalid::TooManyVars)));
    assert_eq!(stats.invalid, 1);
    assert!(matches!(read_event(fd.as_fd(), true, &mut stats).unwrap(), ReadOutcome::Nothing));
}

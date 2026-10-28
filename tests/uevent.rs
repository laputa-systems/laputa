//! P2: uevent intake tests. `uevent` filter.
use mdevd::config::UEVENT_MAX_VARS;
use mdevd::uevent::{DataOutcome, Invalid, Stats, bind_intake, parse_record, read_datagram, read_event};
use mdevd::uevent::ReadOutcome;
use std::os::unix::io::BorrowedFd;

fn record(parts: &[&[u8]]) -> Vec<u8> {
    let mut b = Vec::new();
    for p in parts {
        b.extend_from_slice(p);
        b.push(0);
    }
    b
}

#[test]
fn uevent_parse_valid() {
    let buf = record(&[b"add@/devices/x", b"ACTION=add", b"DEVPATH=/devices/x", b"DEVNAME=mydev"]);
    let ev = parse_record(&buf).unwrap();
    assert_eq!(ev.vars.len(), 4);
    assert_eq!(ev.getvar(b"ACTION"), Some(b"add".as_slice()));
    assert_eq!(ev.getvar(b"DEVNAME"), Some(b"mydev".as_slice()));
    assert_eq!(ev.getvar(b"MISSING"), None);
    assert!(!ev.is_empty());
}

#[test]
fn uevent_header_never_matches() {
    // Even if the header carries '=', lookup starts at index 1 like the C.
    let buf = record(&[b"add@/x?ACTION=zzz", b"ACTION=add"]);
    let ev = parse_record(&buf).unwrap();
    assert_eq!(ev.getvar(b"ACTION"), Some(b"add".as_slice()));
}

#[test]
fn uevent_duplicates_first_wins() {
    let buf = record(&[b"add@/x", b"A=1", b"A=2"]);
    let ev = parse_record(&buf).unwrap();
    assert_eq!(ev.getvar(b"A"), Some(b"1".as_slice()));
}

#[test]
fn uevent_rejects() {
    assert_eq!(parse_record(&[]), Err(Invalid::Empty));
    assert_eq!(parse_record(b"add@/x"), Err(Invalid::NotTerminated));
    assert_eq!(parse_record(b"no-header-here\0"), Err(Invalid::BadHeader));
    // "@/“ anywhere in the datagram satisfies the check, like strstr.
    assert!(parse_record(b"junk@/tail\0").is_ok());
    // 63 records are fine, the 64th is rejected.
    let mut many = vec![b"add@/x".as_slice()];
    many.extend(std::iter::repeat_n(b"V=1".as_slice(), UEVENT_MAX_VARS - 1));
    assert!(parse_record(&record(&many)).is_ok());
    many.push(b"V=2");
    assert_eq!(parse_record(&record(&many)), Err(Invalid::TooManyVars));
}

#[test]
fn uevent_datagram_policy() {
    let buf = record(&[b"add@/x", b"ACTION=add"]);
    // Kernel sender passes the userspace drop.
    assert!(matches!(read_datagram(&buf, 0, true), DataOutcome::Event(_)));
    // Userspace sender is dropped when configured...
    assert_eq!(read_datagram(&buf, 99, true), DataOutcome::DroppedUserspace);
    // ...and accepted (like coldplug's options=0) otherwise.
    assert!(matches!(read_datagram(&buf, 99, false), DataOutcome::Event(_)));
    // Invalid records are classified, never fatal.
    assert!(matches!(read_datagram(b"junk\0", 0, true), DataOutcome::Invalid(Invalid::BadHeader)));
    assert_eq!(read_datagram(&[], 0, true), DataOutcome::Empty);
}

/// Full fd-level loopback over real netlink sockets (unicast to self, so no
/// multicast privileges are needed). Skipped with a note where the sandbox
/// forbids even that.
#[test]
fn uevent_loopback() {
    let rx = match bind_intake(0, 1024 * 1024) {
        Ok(fd) => fd,
        Err(e) => {
            println!("note: netlink bind unavailable ({e}); loopback skipped");
            return;
        }
    };
    let pid = netlink_pid(&rx);
    // SAFETY: minimal sendto of a valid datagram to our own pid.
    let send = |buf: &[u8]| unsafe {
        let mut addr: libc::sockaddr_nl = std::mem::zeroed();
        addr.nl_family = libc::AF_NETLINK as libc::sa_family_t;
        addr.nl_pid = pid;
        libc::sendto(
            rx.as_raw_fd(),
            buf.as_ptr() as *const _,
            buf.len(),
            0,
            &addr as *const _ as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_nl>() as libc::socklen_t,
        )
    };
    use std::os::unix::io::AsRawFd;
    let buf = record(&[b"add@/x", b"ACTION=add", b"DEVNAME=lo"]);
    let r = send(&buf);
    if r == -1 {
        let e = std::io::Error::last_os_error();
        println!("note: netlink send unavailable ({e}); loopback skipped");
        return;
    }
    let mut stats = Stats::default();
    // SAFETY: rx is a valid owned fd for the duration of the borrow.
    let fd = unsafe { BorrowedFd::borrow_raw(rx.as_raw_fd()) };
    // Sender pid is nonzero (ourselves): dropped when configured...
    match read_event(fd, true, &mut stats).unwrap() {
        ReadOutcome::DroppedUserspace(pid) => assert!(pid != 0),
        other => panic!("expected drop, got {other:?}"),
    }
    assert_eq!(stats.dropped_userspace, 1);
    // ...accepted otherwise, with fields intact.
    let r = send(&buf);
    assert!(r != -1);
    let got = match read_event(fd, false, &mut stats).unwrap() {
        ReadOutcome::Event(ev) => ev,
        other => panic!("expected event, got {other:?}"),
    };
    assert_eq!(got.getvar(b"DEVNAME"), Some(b"lo".as_slice()));
    // Nothing queued: clean Nothing.
    assert!(matches!(read_event(fd, false, &mut stats).unwrap(), ReadOutcome::Nothing));
}

fn netlink_pid(fd: &std::os::unix::io::OwnedFd) -> u32 {
    use std::os::unix::io::AsRawFd;
    // SAFETY: output storage is a correctly sized sockaddr_nl.
    unsafe {
        let mut addr: libc::sockaddr_nl = std::mem::zeroed();
        let mut len = std::mem::size_of::<libc::sockaddr_nl>() as libc::socklen_t;
        let r = libc::getsockname(
            fd.as_raw_fd(),
            &mut addr as *mut _ as *mut libc::sockaddr,
            &mut len,
        );
        assert_eq!(r, 0);
        addr.nl_pid
    }
}

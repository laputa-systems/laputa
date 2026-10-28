//! P4: publication tests. `publish` filter.
//!
//! `publish_live_multicast` runs for real under a capable netns and
//! skip-notes otherwise; `tools/check-udev-consumer.sh` runs it under
//! `unshare` and requires the exchange marker. `publish_live_consumer`
//! needs `CONSUMER_BIN`/`CONSUMER_OUT` (set by that script) and never
//! passes silently.
use mdevd::publish::{Note, Output, Rebroadcast, Sinks, apply_loop_guard, publish};
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd};

fn socketpair() -> (OwnedFd, OwnedFd) {
    let mut fds = [0; 2];
    // SAFETY: fds is a valid 2-int output array.
    let r = unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM, 0, fds.as_mut_ptr()) };
    assert_eq!(r, 0);
    // SAFETY: socketpair succeeded, fds are open and owned.
    unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) }
}

/// Wire-format record: NUL-separated fields with a trailing NUL, exactly
/// as intake guarantees them. `-o` appends one additional NUL on top.
fn record(action: &str, seq: u32) -> Vec<u8> {
    let mut b = Vec::new();
    for part in [
        format!("{action}@/devices/x"),
        format!("ACTION={action}"),
        "DEVPATH=/devices/x".to_string(),
        "SUBSYSTEM=test".to_string(),
        "DEVNAME=mydev".to_string(),
        "MAJOR=1".to_string(),
        "MINOR=2".to_string(),
        format!("SEQNUM={seq}"),
    ] {
        b.extend_from_slice(part.as_bytes());
        b.push(0);
    }
    b
}

#[test]
fn publish_output_exact() {
    let (a, b) = socketpair();
    let mut sinks = Sinks {
        output: Some(Output::new(a)),
        rebroadcast: None,
    };
    let mut notes = Vec::new();
    let rec = record("add", 1);
    publish(&rec, &mut sinks, &mut notes);
    assert!(notes.is_empty());
    assert!(sinks.output.as_ref().unwrap().live());
    // Peer sees the record plus exactly one NUL terminator.
    let mut got = vec![0u8; rec.len() + 16];
    // SAFETY: b is a valid fd; got has capacity.
    let r = unsafe { libc::read(b.as_raw_fd(), got.as_mut_ptr() as *mut _, got.len()) };
    assert!(r > 0);
    got.truncate(r as usize);
    let mut expected = rec.clone();
    expected.push(0);
    assert_eq!(got, expected);
}

#[test]
fn publish_output_failure_closes() {
    let (a, b) = socketpair();
    drop(b);
    // SIGPIPE is ignored by the Rust runtime; the write fails with EPIPE.
    let mut sinks = Sinks {
        output: Some(Output::new(a)),
        rebroadcast: None,
    };
    let mut notes: Vec<Note> = Vec::new();
    publish(&record("add", 1), &mut sinks, &mut notes);
    assert_eq!(notes.len(), 1);
    assert!(notes[0].msg.starts_with("unable to write to descriptor "));
    assert!(notes[0].msg.contains("(closing it): "));
    assert!(!sinks.output.as_ref().unwrap().live());
    // Further publishes are no-ops, like the reference stopping writes.
    let mut notes2 = Vec::new();
    publish(&record("add", 2), &mut sinks, &mut notes2);
    assert!(notes2.is_empty());
}

#[test]
fn publish_loop_guard() {
    assert_eq!(apply_loop_guard(1, 4), (4, None));
    assert_eq!(apply_loop_guard(1, 5), (4, Some(1)));
    assert_eq!(apply_loop_guard(2, 6), (4, Some(2)));
    assert_eq!(apply_loop_guard(1, 0), (0, None));
}

#[test]
fn publish_rebroadcast_socket() {
    let r = match Rebroadcast::connect(4, 1024 * 1024) {
        Ok(r) => r,
        Err(e) => {
            println!("note: rebroadcast connect blocked ({e}); socket test skipped");
            return;
        }
    };
    let mut notes = Vec::new();
    // No listener here; the send may still succeed into the void. Either
    // way the call itself must not misbehave at the API level.
    r.send(b"add@/x\x00ACTION=add\x00", &mut notes);
    let _ = notes;
}

fn bind_group4() -> Result<OwnedFd, std::io::Error> {
    // SAFETY: straightforward netlink bind; errors return errno.
    unsafe {
        let fd = libc::socket(libc::AF_NETLINK, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 15);
        if fd == -1 {
            return Err(std::io::Error::last_os_error());
        }
        let mut nl: libc::sockaddr_nl = std::mem::zeroed();
        nl.nl_family = libc::AF_NETLINK as libc::sa_family_t;
        nl.nl_pid = 0;
        nl.nl_groups = 4;
        if libc::bind(
            fd,
            &nl as *const _ as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_nl>() as libc::socklen_t,
        ) == -1
        {
            let e = std::io::Error::last_os_error();
            libc::close(fd);
            return Err(e);
        }
        Ok(OwnedFd::from_raw_fd(fd))
    }
}

#[test]
fn publish_live_multicast() {
    let rx = match bind_group4() {
        Ok(fd) => fd,
        Err(e) => {
            println!("note: netlink bind unavailable ({e}); live multicast skipped");
            return;
        }
    };
    let tx = match Rebroadcast::connect(4, 1024 * 1024) {
        Ok(tx) => tx,
        Err(e) => {
            println!("note: rebroadcast connect blocked ({e}); live multicast skipped");
            return;
        }
    };
    let rec = record("add", 7);
    let mut notes = Vec::new();
    tx.send(&rec, &mut notes);
    if !notes.is_empty() {
        println!("note: multicast send blocked ({}); live multicast skipped", notes[0].msg);
        return;
    }
    // SAFETY: rx is a bound netlink fd; buf has capacity.
    let mut buf = vec![0u8; 8192];
    let r = unsafe { libc::recv(rx.as_raw_fd(), buf.as_mut_ptr() as *mut _, buf.len(), 0) };
    assert!(r > 0, "expected the rebroadcast datagram");
    buf.truncate(r as usize);
    assert_eq!(buf, rec);
    println!("live-multicast: exchanged {} bytes on group 4", buf.len());
}

#[test]
fn publish_live_consumer() {
    let (bin, out) = match (std::env::var("CONSUMER_BIN"), std::env::var("CONSUMER_OUT")) {
        (Ok(bin), Ok(out)) => (bin, out),
        _ => {
            println!("note: CONSUMER_BIN/OUT unset; live consumer skipped (see check-udev-consumer.sh)");
            return;
        }
    };
    let tx = match Rebroadcast::connect(4, 1024 * 1024) {
        Ok(tx) => tx,
        Err(e) => panic!("rebroadcast connect blocked ({e}); run under unshare -U -n -r"),
    };
    let log = std::fs::File::create(&out).expect("consumer log");
    let mut child = std::process::Command::new(&bin)
        .stdout(log)
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("spawn consumer");
    // Give the consumer a moment to bind before publishing.
    std::thread::sleep(std::time::Duration::from_millis(300));
    let mut notes = Vec::new();
    for (action, seq) in [("add", 1), ("change", 2), ("remove", 3)] {
        tx.send(&record(action, seq), &mut notes);
    }
    assert!(
        notes.is_empty(),
        "multicast blocked ({}); run under unshare -U -n -r",
        notes.first().map(|n| n.msg.as_str()).unwrap_or("")
    );
    let mut lines = Vec::new();
    for _ in 0..100 {
        let text = std::fs::read_to_string(&out).unwrap_or_default();
        lines = text.lines().map(|l| l.to_string()).collect();
        if lines.len() >= 3 {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    let _ = child.kill();
    let _ = child.wait();
    assert_eq!(lines.len(), 3, "consumer saw {lines:?}");
    assert_eq!(lines[0], "ACTION=add SUBSYSTEM=test SYSNAME=x DEVNAME=/dev/mydev");
    assert_eq!(lines[1], "ACTION=change SUBSYSTEM=test SYSNAME=x DEVNAME=/dev/mydev");
    assert_eq!(lines[2], "ACTION=remove SUBSYSTEM=test SYSNAME=x DEVNAME=/dev/mydev");
    println!("live-consumer: verified add/change/remove with device state");
}

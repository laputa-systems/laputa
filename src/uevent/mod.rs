//! NETLINK_KOBJECT_UEVENT intake (P2).
//!
//! Ports `mdevd_netlink_init.c` and `mdevd_uevent_read.c`. Record parsing
//! is pure and rootless-testable; only the small recvmsg seam touches an
//! fd. Semantics mirror the reference, including its quirks: the `@/`
//! check searches the whole datagram, and persistent `ENOBUFS` retries
//! forever while counting overruns.

use crate::config::{UEVENT_MAX_SIZE, UEVENT_MAX_VARS};
use std::mem;
use std::os::unix::io::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Invalid {
    Empty,
    NotTerminated,
    BadHeader,
    TooManyVars,
}

#[derive(Debug, Default)]
pub struct Stats {
    pub overruns: u64,
    pub dropped_userspace: u64,
    pub invalid: u64,
    pub truncated: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Uevent {
    pub buf: Vec<u8>,
    pub vars: Vec<usize>,
}

impl Uevent {
    /// First `name=value` record at index 1+, like `mdevd_uevent_getvar`
    /// (index 0 is the `@/...` header and never matches).
    pub fn getvar(&self, name: &[u8]) -> Option<&[u8]> {
        for &v in self.vars.iter().skip(1) {
            let rec = &self.buf[v..];
            let end = rec.iter().position(|&b| b == 0).unwrap_or(rec.len());
            let rec = &rec[..end];
            if rec.len() > name.len() && &rec[..name.len()] == name && rec[name.len()] == b'=' {
                return Some(&rec[name.len() + 1..]);
            }
        }
        None
    }

    /// Records with no variables are skipped by the caller, like the
    /// reference (`event->varn <= 1`).
    pub fn is_empty(&self) -> bool {
        self.vars.len() <= 1
    }
}

/// Split a raw datagram exactly like `mdevd_uevent_read`.
pub fn parse_record(buf: &[u8]) -> Result<Uevent, Invalid> {
    if buf.is_empty() {
        return Err(Invalid::Empty);
    }
    if buf[buf.len() - 1] != 0 {
        return Err(Invalid::NotTerminated);
    }
    if !buf.windows(2).any(|w| w == b"@/") {
        return Err(Invalid::BadHeader);
    }
    let mut vars = Vec::new();
    let mut off = 0usize;
    while off < buf.len() {
        if vars.len() >= UEVENT_MAX_VARS {
            return Err(Invalid::TooManyVars);
        }
        vars.push(off);
        let rel = buf[off..].iter().position(|&b| b == 0).unwrap_or(buf.len() - off);
        off += rel + 1;
    }
    Ok(Uevent {
        buf: buf.to_vec(),
        vars,
    })
}

#[derive(Debug)]
pub enum Fatal {
    Truncated,
    Read(std::io::Error),
}

impl std::fmt::Display for Fatal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Fatal::Truncated => write!(f, "buffer too small for netlink message"),
            Fatal::Read(e) => write!(f, "read netlink message: {e}"),
        }
    }
}

impl std::error::Error for Fatal {}

enum Recv {
    None,
    Overrun,
    Got { n: usize, pid: u32, flags: i32 },
}

fn recv_once(fd: BorrowedFd, buf: &mut [u8]) -> Result<Recv, Fatal> {
    let mut addr: libc::sockaddr_nl = unsafe { mem::zeroed() };
    let mut iov = libc::iovec {
        iov_base: buf.as_mut_ptr() as *mut libc::c_void,
        iov_len: buf.len(),
    };
    let mut hdr: libc::msghdr = unsafe { mem::zeroed() };
    hdr.msg_name = &mut addr as *mut _ as *mut libc::c_void;
    hdr.msg_namelen = mem::size_of::<libc::sockaddr_nl>() as libc::socklen_t;
    hdr.msg_iov = &mut iov;
    hdr.msg_iovlen = 1;
    // SAFETY: hdr/iov/addr are valid for the call; retried on EINTR.
    let r = loop {
        let r = unsafe { libc::recvmsg(fd.as_raw_fd(), &mut hdr, 0) };
        if r == -1 && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
            continue;
        }
        break r;
    };
    if r == -1 {
        let e = std::io::Error::last_os_error();
        return match e.raw_os_error() {
            // Nonblocking and nothing queued: no event this round.
            Some(libc::EAGAIN) => Ok(Recv::None),
            // Lost events: counted by the caller, which retries.
            Some(libc::ENOBUFS) => Ok(Recv::Overrun),
            _ => Err(Fatal::Read(e)),
        };
    }
    if r == 0 {
        return Ok(Recv::None);
    }
    Ok(Recv::Got {
        n: r as usize,
        pid: addr.nl_pid,
        flags: hdr.msg_flags,
    })
}

/// Read one datagram: `Ok(None)` means no event this round (nothing queued
/// or userspace-dropped; invalid records are counted too). `Err` is fatal
/// (`MSG_TRUNC`, I/O failure), like the reference dying.
pub fn read_event(
    fd: BorrowedFd,
    drop_userspace: bool,
    stats: &mut Stats,
) -> Result<Option<Uevent>, Fatal> {
    let mut buf = vec![0u8; UEVENT_MAX_SIZE];
    loop {
        match recv_once(fd, &mut buf)? {
            Recv::None => return Ok(None),
            Recv::Overrun => {
                stats.overruns += 1;
                continue;
            }
            Recv::Got { n, pid, flags } => {
                if flags & libc::MSG_TRUNC != 0 {
                    stats.truncated += 1;
                    return Err(Fatal::Truncated);
                }
                return Ok(read_datagram(&buf[..n], pid, drop_userspace, stats));
            }
        }
    }
}

/// Pure half of `read_event`, over an already-received datagram.
pub fn read_datagram(
    datagram: &[u8],
    pid: u32,
    drop_userspace: bool,
    stats: &mut Stats,
) -> Option<Uevent> {
    if datagram.is_empty() {
        return None;
    }
    if drop_userspace && pid != 0 {
        stats.dropped_userspace += 1;
        return None;
    }
    match parse_record(datagram) {
        Ok(ev) => Some(ev),
        Err(_) => {
            stats.invalid += 1;
            None
        }
    }
}

/// Bind the intake socket, like `mdevd_netlink_init`: nonblocking,
/// close-on-exec, `SO_RCVBUFFORCE` with an `EPERM` fallback to `SO_RCVBUF`.
pub fn bind_intake(group: u32, kbufsz: u32) -> std::io::Result<OwnedFd> {
    // SAFETY: straightforward socket/bind/setsockopt sequence; every
    // failure closes the fd and returns the errno.
    unsafe {
        let fd = libc::socket(
            libc::AF_NETLINK,
            libc::SOCK_DGRAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
            15,
        );
        if fd == -1 {
            return Err(std::io::Error::last_os_error());
        }
        let guard = FdGuard(fd);
        let mut nl: libc::sockaddr_nl = mem::zeroed();
        nl.nl_family = libc::AF_NETLINK as libc::sa_family_t;
        nl.nl_pid = 0;
        nl.nl_groups = group;
        if libc::bind(
            fd,
            &nl as *const _ as *const libc::sockaddr,
            mem::size_of::<libc::sockaddr_nl>() as libc::socklen_t,
        ) == -1
        {
            return Err(std::io::Error::last_os_error());
        }
        let kbufsz_c = kbufsz as libc::c_int;
        if libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_RCVBUFFORCE,
            &kbufsz_c as *const _ as *const libc::c_void,
            mem::size_of::<libc::c_int>() as libc::socklen_t,
        ) == -1
        {
            let e = std::io::Error::last_os_error();
            if e.raw_os_error() != Some(libc::EPERM) {
                return Err(e);
            }
            if libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_RCVBUF,
                &kbufsz_c as *const _ as *const libc::c_void,
                mem::size_of::<libc::c_int>() as libc::socklen_t,
            ) == -1
            {
                return Err(std::io::Error::last_os_error());
            }
        }
        mem::forget(guard);
        Ok(OwnedFd::from_raw_fd(fd))
    }
}

struct FdGuard(libc::c_int);

impl Drop for FdGuard {
    fn drop(&mut self) {
        // SAFETY: fd is open; best-effort close on the error path.
        unsafe {
            libc::close(self.0);
        }
    }
}

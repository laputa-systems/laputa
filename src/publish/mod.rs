//! Post-processing event publication (P4).
//!
//! Ports `output_event`, `rebc_event`, `rebc_init`, and the startup loop
//! guard from `src/mdevd/mdevd.c`. Both sinks fire only after handling
//! completes — the daemon (P5) enforces the ordering; this module is the
//! byte-exact send side. Output is bounded: a failing `-o` fd is closed
//! and never retried; rebroadcast failures warn without buffering.

use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Note {
    pub level: u8,
    pub msg: String,
}

/// `-o` output fd. A short write closes and disables it, like the C code.
pub struct Output {
    fd: Option<OwnedFd>,
}

/// `-O` rebroadcast socket, connected to the target groups.
pub struct Rebroadcast {
    fd: OwnedFd,
}

pub struct Sinks {
    pub output: Option<Output>,
    pub rebroadcast: Option<Rebroadcast>,
}

fn errno_msg(e: std::io::Error) -> String {
    // SAFETY: strerror handles any errno value.
    unsafe {
        let p = libc::strerror(e.raw_os_error().unwrap_or(0));
        if p.is_null() {
            return format!("{e}");
        }
        std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned()
    }
}

impl Output {
    pub fn new(fd: OwnedFd) -> Output {
        Output { fd: Some(fd) }
    }

    pub fn live(&self) -> bool {
        self.fd.is_some()
    }

    /// Mirror `output_event`: `writev(record, NUL)`; anything short of the
    /// full record plus terminator closes the fd with a warning.
    pub fn send(&mut self, record: &[u8], notes: &mut Vec<Note>) {
        let fd = match self.fd.as_ref() {
            Some(fd) => fd.as_raw_fd(),
            None => return,
        };
        let nul = [0u8; 1];
        let iov = [
            libc::iovec {
                iov_base: record.as_ptr() as *mut libc::c_void,
                iov_len: record.len(),
            },
            libc::iovec {
                iov_base: nul.as_ptr() as *mut libc::c_void,
                iov_len: 1,
            },
        ];
        // SAFETY: iov points at live memory for the call.
        let r = unsafe { libc::writev(fd, iov.as_ptr(), iov.len() as libc::c_int) };
        if r != (record.len() + 1) as libc::ssize_t {
            let e = std::io::Error::last_os_error();
            notes.push(Note {
                level: 1,
                msg: format!("write to descriptor {fd} (closing it): {}", errno_msg(e)),
            });
            self.fd = None;
        }
    }
}

impl Rebroadcast {
    /// Mirror `rebc_init`: `DGRAM` + `CLOEXEC` socket connected to the
    /// groups, `SO_SNDBUFFORCE` with an `EPERM` fallback to `SO_SNDBUF`.
    pub fn connect(groups: u32, kbufsz: u32) -> std::io::Result<Rebroadcast> {
        // SAFETY: straightforward socket/connect/setsockopt sequence; every
        // failure closes the fd and returns the errno.
        unsafe {
            let fd = libc::socket(libc::AF_NETLINK, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 15);
            if fd == -1 {
                return Err(std::io::Error::last_os_error());
            }
            let mut nl: libc::sockaddr_nl = std::mem::zeroed();
            nl.nl_family = libc::AF_NETLINK as libc::sa_family_t;
            nl.nl_pid = 0;
            nl.nl_groups = groups;
            let r = libc::connect(
                fd,
                &nl as *const _ as *const libc::sockaddr,
                std::mem::size_of::<libc::sockaddr_nl>() as libc::socklen_t,
            );
            if r == -1 {
                let e = std::io::Error::last_os_error();
                libc::close(fd);
                return Err(e);
            }
            let kbufsz_c = kbufsz as libc::c_int;
            let sz = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
            if libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_SNDBUFFORCE,
                &kbufsz_c as *const _ as *const libc::c_void,
                sz,
            ) == -1
            {
                let e = std::io::Error::last_os_error();
                if e.raw_os_error() != Some(libc::EPERM) {
                    libc::close(fd);
                    return Err(e);
                }
                if libc::setsockopt(
                    fd,
                    libc::SOL_SOCKET,
                    libc::SO_SNDBUF,
                    &kbufsz_c as *const _ as *const libc::c_void,
                    sz,
                ) == -1
                {
                    let e = std::io::Error::last_os_error();
                    libc::close(fd);
                    return Err(e);
                }
            }
            Ok(Rebroadcast {
                fd: OwnedFd::from_raw_fd(fd),
            })
        }
    }

    /// Mirror `rebc_event`: a single `send`; only `-1` warns. Short sends
    /// are accepted silently, exactly like the reference.
    pub fn send(&self, record: &[u8], notes: &mut Vec<Note>) {
        // SAFETY: record is live for the call.
        let r = unsafe {
            libc::send(
                self.fd.as_raw_fd(),
                record.as_ptr() as *const libc::c_void,
                record.len(),
                0,
            )
        };
        if r == -1 {
            let e = std::io::Error::last_os_error();
            notes.push(Note {
                level: 1,
                msg: format!("rebroadcast uevent: {}", errno_msg(e)),
            });
        }
    }
}

/// Mirror the startup loop guard: `intake|1` bits are dropped from the
/// rebroadcast mask. Returns the masked value plus dropped bits, if any
/// (the daemon warns naming them, like the reference).
pub fn apply_loop_guard(intake: u32, rebc: u32) -> (u32, Option<u32>) {
    let dropped = rebc & (intake | 1);
    (rebc & !dropped, if dropped != 0 { Some(dropped) } else { None })
}

pub fn publish(record: &[u8], sinks: &mut Sinks, notes: &mut Vec<Note>) {
    if let Some(o) = sinks.output.as_mut() {
        o.send(record, notes);
    }
    if let Some(r) = sinks.rebroadcast.as_ref() {
        r.send(record, notes);
    }
}

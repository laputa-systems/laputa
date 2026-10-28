//! Privileged filesystem/device adapter (P3).
//!
//! Every path is relative to a held directory fd (`openat` family); the
//! daemon never re-resolves a pathname. Absolute paths and `..` escapes
//! are refused loudly by every mutating method (the reference resolves
//! them; dry-run transcripts stay identical, real runs fail safe — see
//! `docs/divergence.md`). On `EEXIST`, an existing node is only adopted
//! when its type and device identity match; anything else is refused
//! instead of `chmod`/`chown`-ed blindly.

use std::ffi::CString;
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeKind {
    Char,
    Block,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MknodOut {
    Created,
    Exists,
}

/// Refusal or I/O failure; the message feeds daemon warnings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpErr(pub String);

impl std::fmt::Display for OpErr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for OpErr {}

fn os_err(what: &str, path: &[u8]) -> OpErr {
    let e = std::io::Error::last_os_error();
    OpErr(format!(
        "{what} {}: {e}",
        String::from_utf8_lossy(path)
    ))
}

fn refused(what: &str, path: &[u8]) -> OpErr {
    OpErr(format!(
        "{what} {}: refused (absolute path or .. escape)",
        String::from_utf8_lossy(path)
    ))
}

fn has_escape(path: &[u8]) -> bool {
    path.starts_with(b"/") || path.split(|&b| b == b'/').any(|seg| seg == b"..")
}

fn cstr(path: &[u8]) -> Result<CString, OpErr> {
    CString::new(path).map_err(|_| OpErr(format!("bad path {:?}", String::from_utf8_lossy(path))))
}

pub trait Ops {
    fn read_sys(&mut self, rel: &[u8], max: usize) -> Result<Vec<u8>, OpErr>;
    fn subdirs(&mut self, path: &[u8]) -> Result<(), OpErr>;
    fn mknod(
        &mut self,
        path: &[u8],
        mode: u32,
        kind: NodeKind,
        maj: u32,
        min: u32,
    ) -> Result<MknodOut, OpErr>;
    fn chmod(&mut self, path: &[u8], mode: u32) -> Result<(), OpErr>;
    fn chown(&mut self, path: &[u8], uid: u32, gid: u32) -> Result<(), OpErr>;
    fn symlink_replace(&mut self, target: &[u8], link: &[u8]) -> Result<(), OpErr>;
    /// Like the reference `unlink_void`: errors are ignored.
    fn unlink(&mut self, path: &[u8]);
}

pub struct RealOps {
    dev: OwnedFd,
    sys: OwnedFd,
    tmp_counter: u64,
}

impl RealOps {
    pub fn open(dev_dir: &std::path::Path, sys_dir: &std::path::Path) -> std::io::Result<RealOps> {        fn open_dir(p: &std::path::Path) -> std::io::Result<OwnedFd> {
            let c = CString::new(p.as_os_str().as_encoded_bytes())
                .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidInput, "bad dir"))?;
            // SAFETY: c is NUL-terminated; the fd is owned on success.
            let fd = unsafe {
                libc::open(
                    c.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
                )
            };
            if fd == -1 {
                return Err(std::io::Error::last_os_error());
            }
            // SAFETY: fd is open and owned.
            Ok(unsafe { OwnedFd::from_raw_fd(fd) })
        }
        Ok(RealOps {
            dev: open_dir(dev_dir)?,
            sys: open_dir(sys_dir)?,
            tmp_counter: 0,
        })
    }
}

impl Ops for RealOps {
    fn read_sys(&mut self, rel: &[u8], max: usize) -> Result<Vec<u8>, OpErr> {
        if has_escape(rel) {
            return Err(refused("read", rel));
        }
        let c = cstr(rel)?;
        // SAFETY: sys fd is valid; c is NUL-terminated. Symlinks are
        // followed deliberately: legitimate sysfs traversal needs them
        // (e.g. /sys/class links); `..` above bounds the escape.
        let fd = unsafe { libc::openat(self.sys.as_raw_fd(), c.as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC) };
        if fd == -1 {
            return Err(os_err("open", rel));
        }
        let mut out = Vec::new();
        let mut chunk = [0u8; 1024];
        loop {
            // SAFETY: fd is open; chunk is valid for reads.
            let r = unsafe { libc::read(fd, chunk.as_mut_ptr() as *mut _, chunk.len()) };
            if r == -1 {
                let e = std::io::Error::last_os_error();
                unsafe { libc::close(fd) };
                if e.raw_os_error() == Some(libc::EINTR) {
                    continue;
                }
                return Err(OpErr(format!("read {}: {e}", String::from_utf8_lossy(rel))));
            }
            if r == 0 {
                break;
            }
            let n = (r as usize).min(max.saturating_sub(out.len()));
            out.extend_from_slice(&chunk[..n]);
            if out.len() >= max || n < r as usize {
                break;
            }
        }
        unsafe { libc::close(fd) };
        Ok(out)
    }

    fn subdirs(&mut self, path: &[u8]) -> Result<(), OpErr> {
        // Mirrors mdevd_mkdirp: every slash-terminated prefix, 0755. An
        // empty prefix (absolute path) fails naturally with ENOENT, exactly
        // like the reference; deeper absolute/`..` damage is still refused
        // by the mutating methods below.
        for (i, &b) in path.iter().enumerate() {
            if b != b'/' {
                continue;
            }
            let prefix = &path[..i];
            let c = cstr(prefix)?;
            // SAFETY: dev fd is valid; c is NUL-terminated.
            let r = unsafe { libc::mkdirat(self.dev.as_raw_fd(), c.as_ptr(), 0o755) };
            if r == -1 {
                let e = std::io::Error::last_os_error();
                if e.raw_os_error() != Some(libc::EEXIST) {
                    return Err(OpErr(format!(
                        "mkdir {}: {e}",
                        String::from_utf8_lossy(prefix)
                    )));
                }
            }
        }
        Ok(())
    }

    fn mknod(
        &mut self,
        path: &[u8],
        mode: u32,
        kind: NodeKind,
        maj: u32,
        min: u32,
    ) -> Result<MknodOut, OpErr> {
        if has_escape(path) {
            return Err(refused("mknod", path));
        }
        let c = cstr(path)?;
        let ftype = match kind {
            NodeKind::Char => libc::S_IFCHR,
            NodeKind::Block => libc::S_IFBLK,
        };
        let dev = libc::makedev(maj, min);
        // SAFETY: dev fd is valid; c is NUL-terminated.
        let r = unsafe {
            libc::mknodat(
                self.dev.as_raw_fd(),
                c.as_ptr(),
                (mode & 0o7777) | ftype,
                dev,
            )
        };
        if r == 0 {
            return Ok(MknodOut::Created);
        }
        let e = std::io::Error::last_os_error();
        if e.raw_os_error() != Some(libc::EEXIST) {
            return Err(OpErr(format!("mknod {}: {e}", String::from_utf8_lossy(path))));
        }
        // Adopt only the expected device identity; never chmod/chown an
        // unrelated replacement object.
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: dev fd is valid; st is a valid output struct. No-follow:
        // a swapped-in symlink must not be adopted.
        let sr = unsafe {
            libc::fstatat(
                self.dev.as_raw_fd(),
                c.as_ptr(),
                &mut st,
                libc::AT_SYMLINK_NOFOLLOW,
            )
        };
        if sr == -1 {
            return Err(os_err("stat", path));
        }
        let is_dev = st.st_mode & libc::S_IFMT == ftype;
        if !is_dev || st.st_rdev != dev as libc::dev_t {
            return Err(OpErr(format!(
                "mknod {}: refused (existing object is not the expected device)",
                String::from_utf8_lossy(path)
            )));
        }
        Ok(MknodOut::Exists)
    }

    fn chmod(&mut self, path: &[u8], mode: u32) -> Result<(), OpErr> {
        if has_escape(path) {
            return Err(refused("chmod", path));
        }
        let c = cstr(path)?;
        // SAFETY: dev fd is valid; c is NUL-terminated.
        let r = unsafe { libc::fchmodat(self.dev.as_raw_fd(), c.as_ptr(), mode & 0o7777, 0) };
        if r == -1 {
            return Err(os_err("chmod", path));
        }
        Ok(())
    }

    fn chown(&mut self, path: &[u8], uid: u32, gid: u32) -> Result<(), OpErr> {
        if has_escape(path) {
            return Err(refused("chown", path));
        }
        let c = cstr(path)?;
        // SAFETY: dev fd is valid; c is NUL-terminated.
        let r = unsafe { libc::fchownat(self.dev.as_raw_fd(), c.as_ptr(), uid, gid, 0) };
        if r == -1 {
            return Err(os_err("chown", path));
        }
        Ok(())
    }

    fn symlink_replace(&mut self, target: &[u8], link: &[u8]) -> Result<(), OpErr> {
        if has_escape(target) || has_escape(link) {
            return Err(refused("symlink", link));
        }
        // Atomic replace via a unique temp name + rename, like
        // atomic_symlink4 in the reference.
        self.tmp_counter += 1;
        let tmp = format!(".mdevd-tmp-{}-{}", std::process::id(), self.tmp_counter);
        let t = cstr(target)?;
        let l = cstr(link)?;
        let tc = CString::new(tmp).unwrap();
        // SAFETY: dev fd is valid; all pointers are NUL-terminated.
        unsafe {
            if libc::symlinkat(t.as_ptr(), self.dev.as_raw_fd(), tc.as_ptr()) == -1 {
                return Err(os_err("symlink", link));
            }
            if libc::renameat(
                self.dev.as_raw_fd(),
                tc.as_ptr(),
                self.dev.as_raw_fd(),
                l.as_ptr(),
            ) == -1
            {
                let e = os_err("symlink", link);
                libc::unlinkat(self.dev.as_raw_fd(), tc.as_ptr(), 0);
                return Err(e);
            }
        }
        Ok(())
    }

    fn unlink(&mut self, path: &[u8]) {
        if has_escape(path) {
            return;
        }
        if let Ok(c) = cstr(path) {
            // SAFETY: dev fd is valid; c is NUL-terminated. Errors are
            // ignored like the reference unlink_void.
            unsafe {
                libc::unlinkat(self.dev.as_raw_fd(), c.as_ptr(), 0);
            }
        }
    }
}

//! Privileged filesystem/device adapter.
//!
//! Every path is relative to a held directory fd (`openat` family); the
//! daemon never re-resolves a pathname. Absolute paths and `..` escapes
//! are refused loudly by every mutating method (see
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
    /// Errors are ignored.
    fn unlink(&mut self, path: &[u8]);
}

/// Mutations reject symlink ancestors and retain the last verified device inode
/// for metadata updates. chmod requires a mounted /proc/self/fd.
pub struct RealOps {
    dev: OwnedFd,
    sys: OwnedFd,
    node: Option<(Vec<u8>, OwnedFd)>,
    tmp_counter: u64,
}

fn openat_owned(dir: libc::c_int, name: &std::ffi::CStr, flags: libc::c_int) -> Result<OwnedFd, OpErr> {
    // SAFETY: name is NUL-terminated; the returned descriptor has one owner.
    let fd = unsafe { libc::openat(dir, name.as_ptr(), flags | libc::O_CLOEXEC) };
    if fd == -1 { return Err(os_err("open", name.to_bytes())); }
    // SAFETY: openat returned an open descriptor.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

impl RealOps {
    pub fn open(dev_dir: &std::path::Path, sys_dir: &std::path::Path) -> std::io::Result<RealOps> {
        fn open_dir(path: &std::path::Path) -> std::io::Result<OwnedFd> {
            use std::os::unix::fs::OpenOptionsExt;
            let file = std::fs::OpenOptions::new().read(true)
                .custom_flags(libc::O_DIRECTORY).open(path)?;
            Ok(file.into())
        }
        Ok(RealOps { dev: open_dir(dev_dir)?, sys: open_dir(sys_dir)?, node: None, tmp_counter: 0 })
    }

    fn parent(&self, path: &[u8], create: bool) -> Result<(OwnedFd, CString), OpErr> {
        if has_escape(path) { return Err(refused("resolve", path)); }
        let mut components = path.split(|b| *b == b'/').peekable();
        let mut dir = self.dev.try_clone().map_err(|e| OpErr(e.to_string()))?;
        while let Some(component) = components.next() {
            let name = cstr(component)?;
            if components.peek().is_none() { return Ok((dir, name)); }
            if component.is_empty() { continue; }
            if create {
                // SAFETY: dir is held open and name is NUL-terminated.
                if unsafe { libc::mkdirat(dir.as_raw_fd(), name.as_ptr(), 0o755) } == -1 {
                    let e = std::io::Error::last_os_error();
                    if e.raw_os_error() != Some(libc::EEXIST) { return Err(OpErr(format!("mkdir: {e}"))); }
                }
            }
            dir = openat_owned(dir.as_raw_fd(), &name, libc::O_PATH | libc::O_DIRECTORY | libc::O_NOFOLLOW)?;
        }
        Err(refused("resolve", path))
    }

    fn metadata_fd(&self, path: &[u8]) -> Result<OwnedFd, OpErr> {
        if let Some((name, fd)) = &self.node {
            if name == path { return fd.try_clone().map_err(|e| OpErr(e.to_string())); }
        }
        let (parent, name) = self.parent(path, false)?;
        let fd = openat_owned(parent.as_raw_fd(), &name, libc::O_PATH | libc::O_NOFOLLOW)?;
        let file = std::fs::File::from(fd);
        if file.metadata().map_err(|e| OpErr(e.to_string()))?.file_type().is_symlink() {
            return Err(refused("metadata", path));
        }
        Ok(file.into())
    }
}

impl Ops for RealOps {
    fn read_sys(&mut self, rel: &[u8], max: usize) -> Result<Vec<u8>, OpErr> {
        use std::io::Read;
        if has_escape(rel) { return Err(refused("read", rel)); }
        let name = cstr(rel)?;
        let fd = openat_owned(self.sys.as_raw_fd(), &name, libc::O_RDONLY)?;
        let mut out = Vec::new();
        std::fs::File::from(fd).take(max as u64).read_to_end(&mut out)
            .map_err(|e| OpErr(format!("read {}: {e}", String::from_utf8_lossy(rel))))?;
        Ok(out)
    }

    fn subdirs(&mut self, path: &[u8]) -> Result<(), OpErr> {
        self.parent(path, true).map(|_| ())
    }

    fn mknod(&mut self, path: &[u8], mode: u32, kind: NodeKind, maj: u32, min: u32) -> Result<MknodOut, OpErr> {
        use std::os::unix::fs::MetadataExt;
        self.node = None;
        let (parent, name) = self.parent(path, false)?;
        let ftype = match kind { NodeKind::Char => libc::S_IFCHR, NodeKind::Block => libc::S_IFBLK };
        let dev = libc::makedev(maj, min);
        // SAFETY: parent is held open and name is NUL-terminated.
        let result = unsafe { libc::mknodat(parent.as_raw_fd(), name.as_ptr(), (mode & 0o7777) | ftype, dev) };
        let outcome = if result == 0 { MknodOut::Created } else {
            let e = std::io::Error::last_os_error();
            if e.raw_os_error() != Some(libc::EEXIST) { return Err(OpErr(format!("mknod {}: {e}", String::from_utf8_lossy(path)))); }
            MknodOut::Exists
        };
        let fd = openat_owned(parent.as_raw_fd(), &name, libc::O_PATH | libc::O_NOFOLLOW)?;
        let file = std::fs::File::from(fd);
        let metadata = file.metadata().map_err(|e| OpErr(e.to_string()))?;
        if metadata.mode() & libc::S_IFMT != ftype || metadata.rdev() != dev {
            return Err(OpErr(format!("mknod {}: refused (existing object is not the expected device)", String::from_utf8_lossy(path))));
        }
        self.node = Some((path.to_vec(), file.into()));
        Ok(outcome)
    }

    fn chmod(&mut self, path: &[u8], mode: u32) -> Result<(), OpErr> {
        let fd = self.metadata_fd(path)?;
        let proc_path = CString::new(format!("/proc/self/fd/{}", fd.as_raw_fd())).unwrap();
        // SAFETY: procfs resolves this held O_PATH descriptor without opening the device.
        if unsafe { libc::chmod(proc_path.as_ptr(), mode & 0o7777) } == -1 { return Err(os_err("chmod", path)); }
        Ok(())
    }

    fn chown(&mut self, path: &[u8], uid: u32, gid: u32) -> Result<(), OpErr> {
        let fd = self.metadata_fd(path)?;
        // SAFETY: fd pins the inode; the empty path selects that inode.
        if unsafe { libc::fchownat(fd.as_raw_fd(), c"".as_ptr(), uid, gid, libc::AT_EMPTY_PATH) } == -1 {
            return Err(os_err("chown", path));
        }
        Ok(())
    }

    fn symlink_replace(&mut self, target: &[u8], link: &[u8]) -> Result<(), OpErr> {
        if has_escape(target) { return Err(refused("symlink", target)); }
        let (parent, name) = self.parent(link, false)?;
        self.tmp_counter += 1;
        let temporary = CString::new(format!(".mdevd-tmp-{}-{}", std::process::id(), self.tmp_counter)).unwrap();
        let target = cstr(target)?;
        // SAFETY: parent is held open; all names are NUL-terminated.
        if unsafe { libc::symlinkat(target.as_ptr(), parent.as_raw_fd(), temporary.as_ptr()) } == -1 {
            return Err(os_err("symlink", link));
        }
        // SAFETY: both names are relative to the same held parent.
        if unsafe { libc::renameat(parent.as_raw_fd(), temporary.as_ptr(), parent.as_raw_fd(), name.as_ptr()) } == -1 {
            let e = os_err("symlink", link);
            // SAFETY: remove only the temporary entry created above.
            unsafe { libc::unlinkat(parent.as_raw_fd(), temporary.as_ptr(), 0); }
            return Err(e);
        }
        Ok(())
    }

    fn unlink(&mut self, path: &[u8]) {
        if let Ok((parent, name)) = self.parent(path, false) {
            // SAFETY: unlink acts on the leaf entry in the held parent directory.
            unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), 0); }
        }
    }
}

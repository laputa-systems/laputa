//! In-memory [`Ops`](super::ops::Ops) for tests: records planned operations,
//! serves synthetic sysfs files, and programs `mknod` outcomes.
use super::ops::{MknodOut, NodeKind, OpErr, Ops};
use std::collections::HashMap;

#[derive(Debug, Default)]
pub struct FakeOps {
    pub log: Vec<String>,
    pub sysfiles: HashMap<Vec<u8>, Vec<u8>>,
    pub mknod_out: HashMap<Vec<u8>, MknodOut>,
    pub fail: HashMap<&'static str, String>,
}

impl FakeOps {
    fn fail(&self, op: &'static str) -> Option<OpErr> {
        self.fail.get(op).map(|m| OpErr(m.clone()))
    }
}

/// No sysfs access and no mutations: for dry runs that must resolve every
/// fallback as absent. (Daemon dry runs pass the real adapter instead, so
/// `-n` still reads sysfs.)
#[derive(Debug, Default)]
pub struct NullOps;

impl Ops for NullOps {
    fn read_sys(&mut self, rel: &[u8], _max: usize) -> Result<Vec<u8>, OpErr> {
        Err(OpErr(format!("no sysfs access: {}", String::from_utf8_lossy(rel))))
    }

    fn subdirs(&mut self, path: &[u8]) -> Result<(), OpErr> {
        Err(OpErr(format!("no mutations: {}", String::from_utf8_lossy(path))))
    }

    fn mknod(
        &mut self,
        path: &[u8],
        _mode: u32,
        _kind: NodeKind,
        _maj: u32,
        _min: u32,
    ) -> Result<MknodOut, OpErr> {
        Err(OpErr(format!("no mutations: {}", String::from_utf8_lossy(path))))
    }

    fn chmod(&mut self, path: &[u8], _mode: u32) -> Result<(), OpErr> {
        Err(OpErr(format!("no mutations: {}", String::from_utf8_lossy(path))))
    }

    fn chown(&mut self, path: &[u8], _uid: u32, _gid: u32) -> Result<(), OpErr> {
        Err(OpErr(format!("no mutations: {}", String::from_utf8_lossy(path))))
    }

    fn symlink_replace(&mut self, _target: &[u8], link: &[u8]) -> Result<(), OpErr> {
        Err(OpErr(format!("no mutations: {}", String::from_utf8_lossy(link))))
    }

    fn unlink(&mut self, _path: &[u8]) {}
}

impl Ops for FakeOps {
    fn read_sys(&mut self, rel: &[u8], max: usize) -> Result<Vec<u8>, OpErr> {
        match self.sysfiles.get(rel) {
            Some(content) => {
                self.log.push(format!("read:{}->ok", String::from_utf8_lossy(rel)));
                Ok(content[..content.len().min(max)].to_vec())
            }
            None => {
                self.log.push(format!("read:{}->err", String::from_utf8_lossy(rel)));
                Err(OpErr(format!("open {}: no such file", String::from_utf8_lossy(rel))))
            }
        }
    }

    fn subdirs(&mut self, path: &[u8]) -> Result<(), OpErr> {
        let p = String::from_utf8_lossy(path).into_owned();
        self.log.push(format!("subdirs:{p}"));
        if let Some(e) = self.fail("subdirs") {
            return Err(e);
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
        let p = String::from_utf8_lossy(path).into_owned();
        let out = self.mknod_out.get(path).copied().unwrap_or(MknodOut::Created);
        self.log.push(format!(
            "mknod:{p}:{mode:o}:{}:{maj}:{min}->{out:?}",
            match kind {
                NodeKind::Char => "c",
                NodeKind::Block => "b",
            }
        ));
        if let Some(e) = self.fail("mknod") {
            return Err(e);
        }
        Ok(out)
    }

    fn chmod(&mut self, path: &[u8], mode: u32) -> Result<(), OpErr> {
        let p = String::from_utf8_lossy(path).into_owned();
        self.log.push(format!("chmod:{p}:{mode:o}"));
        if let Some(e) = self.fail("chmod") {
            return Err(e);
        }
        Ok(())
    }

    fn chown(&mut self, path: &[u8], uid: u32, gid: u32) -> Result<(), OpErr> {
        let p = String::from_utf8_lossy(path).into_owned();
        self.log.push(format!("chown:{p}:{uid}:{gid}"));
        if let Some(e) = self.fail("chown") {
            return Err(e);
        }
        Ok(())
    }

    fn symlink_replace(&mut self, target: &[u8], link: &[u8]) -> Result<(), OpErr> {
        let entry = format!(
            "symlink:{}->{}",
            String::from_utf8_lossy(target),
            String::from_utf8_lossy(link)
        );
        self.log.push(entry);
        if let Some(e) = self.fail("symlink") {
            return Err(e);
        }
        Ok(())
    }

    fn unlink(&mut self, path: &[u8]) {
        self.log.push(format!("unlink:{}", String::from_utf8_lossy(path)));
    }
}

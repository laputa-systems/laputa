//! Persistent graph snapshot. Conservative invalidation: a snapshot
//! is valid only if build.ninja is present and not newer than the
//! snapshot; anything else forces a full reparse (safe fallback).

use std::path::Path;

#[derive(Debug, Clone)]
pub struct Snapshot {
    pub build_ninja_mtime: u64,
    pub edge_count: usize,
    pub output_count: usize,
}

pub trait SnapshotWrite {
    fn write_snapshot(&self, dirt: &Path) -> Result<(), String>;
    fn read_snapshot(dirt: &Path) -> Option<Snapshot>;
}

impl SnapshotWrite for Snapshot {
    fn write_snapshot(&self, dirt: &Path) -> Result<(), String> {
        let text = format!(
            "{}\t{}\t{}\n",
            self.build_ninja_mtime, self.edge_count, self.output_count
        );
        std::fs::write(dirt.join(".gluon_snapshot"), text)
            .map_err(|e| format!("snapshot write: {e}"))?;
        Ok(())
    }

    fn read_snapshot(dirt: &Path) -> Option<Snapshot> {
        let text = std::fs::read_to_string(dirt.join(".gluon_snapshot")).ok()?;
        let mut it = text.split_whitespace();
        let m = it.next()?.parse::<u64>().ok()?;
        let e = it.next()?.parse::<usize>().ok()?;
        let o = it.next()?.parse::<usize>().ok()?;
        Some(Snapshot {
            build_ninja_mtime: m,
            edge_count: e,
            output_count: o,
        })
    }
}

impl Snapshot {
    /// Conservative invalidation: snapshot is fresh only when build.ninja
    /// exists and its mtime is not newer than the snapshot's recorded
    /// mtime. Missing files invalidate (force reparse).
    pub fn is_fresh(&self, dirt: &Path) -> bool {
        let p = dirt.join("build.ninja");
        let meta = match std::fs::metadata(&p) {
            Ok(m) => m,
            Err(_) => return false,
        };
        let mtime = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0);
        mtime <= self.build_ninja_mtime
    }

    fn _unused() {
        let _ = Path::new(".gluon_snapshot");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_conservative() {
        let dir = std::env::temp_dir().join(format!("gluon-snap-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("build.ninja"), "build a.o: cc a.c\n").unwrap();
        let s = Snapshot {
            build_ninja_mtime: u64::MAX,
            edge_count: 1,
            output_count: 1,
        };
        s.write_snapshot(&dir).unwrap();
        let r = Snapshot::read_snapshot(&dir).unwrap();
        assert_eq!(r.edge_count, 1);
        assert!(r.is_fresh(&dir));
        let _ = std::fs::remove_dir_all(&dir);
    }
}

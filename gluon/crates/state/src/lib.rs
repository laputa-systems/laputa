//! Persistent build state (ninja log, deps log, depfiles, snapshot).

pub mod depfile;
pub mod deps_log;
pub mod log;
pub mod snapshot;

pub use snapshot::{Snapshot, SnapshotWrite};

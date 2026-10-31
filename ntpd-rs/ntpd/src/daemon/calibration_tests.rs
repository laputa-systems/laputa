use super::calibration::{Calibration, CalibrationStore, restore};
use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf, sync::{Arc, Mutex, atomic::{AtomicU64, Ordering}}};
use statime_base::{Clock, ClockError, Duration, LeapStatus, TAI, Timestamp};

#[derive(Clone, Default)]
struct TestClock(Arc<Mutex<Vec<f64>>>);
impl Clock<TAI> for TestClock {
    fn now(&self) -> Result<Timestamp<TAI>, ClockError> { Ok(Timestamp::UNIX_EPOCH) }
    fn max_frequency(&self) -> Result<f64, ClockError> { Ok(0.0005) }
    fn get_frequency(&self) -> Result<f64, ClockError> { Ok(0.0) }
    fn set_frequency(&self, frequency: f64) -> Result<Timestamp<TAI>, ClockError> { self.0.lock().unwrap().push(frequency); self.now() }
    fn step_clock(&self, _: Duration) -> Result<Timestamp<TAI>, ClockError> { panic!("calibration must not step time") }
    fn error_estimate_update(&self, _: Duration, _: Duration) -> Result<(), ClockError> { Ok(()) }
    fn leap_update(&self, _: LeapStatus) -> Result<(), ClockError> { Ok(()) }
    fn synchronization_update(&self, _: bool) -> Result<(), ClockError> { panic!("calibration must not signal synchronization") }
}

struct TestDirectory(PathBuf);
impl TestDirectory {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!("ntpd-calibration-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
        fs::create_dir(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        Self(path)
    }
    fn path(&self) -> PathBuf { self.0.join("frequency.json") }
}
impl Drop for TestDirectory { fn drop(&mut self) { fs::remove_dir_all(&self.0).unwrap(); } }

#[test]
fn roundtrip_and_exclusive_writer() {
    let dir = TestDirectory::new();
    let store = CalibrationStore::open(&dir.path(), 0.0005).unwrap();
    assert!(store.load().unwrap().is_none());
    let clock = TestClock::default();
    assert!(!restore(&store, &clock).unwrap());
    assert!(CalibrationStore::open(&dir.path(), 0.0005).is_err());
    let value = Calibration { correction: -0.000_02, uncertainty: 0.000_001 };
    store.save(value).unwrap();
    assert_eq!(store.load().unwrap(), Some(value));
    assert!(restore(&store, &clock).unwrap());
    assert_eq!(*clock.0.lock().unwrap(), [value.correction]);
    drop(store);
    assert_eq!(CalibrationStore::open(&dir.path(), 0.0005).unwrap().load().unwrap(), Some(value));
}

#[test]
fn in_flight_writer_holds_the_lock() {
    let dir = TestDirectory::new();
    let store = Arc::new(CalibrationStore::open(&dir.path(), 0.0005).unwrap());
    let (ready, ready_rx) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel();
    let worker = std::thread::spawn({ let store = store.clone(); move || {
        ready.send(()).unwrap();
        release_rx.recv().unwrap();
        store.save(Calibration { correction: 0.000_02, uncertainty: 0.000_001 }).unwrap();
    }});
    ready_rx.recv().unwrap();
    drop(store);
    assert!(CalibrationStore::open(&dir.path(), 0.0005).is_err());
    release.send(()).unwrap();
    worker.join().unwrap();
    assert!(CalibrationStore::open(&dir.path(), 0.0005).unwrap().load().unwrap().is_some());
}

#[test]
fn rejects_corrupt_unknown_and_out_of_bounds_state() {
    let dir = TestDirectory::new();
    let store = CalibrationStore::open(&dir.path(), 0.0005).unwrap();
    let clock = TestClock::default();
    for value in ["not json", r#"{"version":2,"correction":0.0,"uncertainty":0.0}"#, r#"{"version":1,"correction":0.0005,"uncertainty":0.0001}"#, r#"{"version":1,"correction":0.0,"uncertainty":-0.1}"#, r#"{"version":1,"correction":0.0,"uncertainty":0.0,"extra":1}"#] {
        fs::write(dir.path(), value).unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o600)).unwrap();
        assert!(store.load().is_err(), "accepted {value}");
        assert!(restore(&store, &clock).is_err(), "restored {value}");
    }
    assert!(clock.0.lock().unwrap().is_empty());
    assert!(store.save(Calibration { correction: f64::NAN, uncertainty: 0.0 }).is_err());
    assert!(store.save(Calibration { correction: 0.0, uncertainty: f64::INFINITY }).is_err());
}

#[test]
fn failed_replace_keeps_last_complete_calibration() {
    let dir = TestDirectory::new();
    let store = CalibrationStore::open(&dir.path(), 0.0005).unwrap();
    let original = Calibration { correction: 0.000_02, uncertainty: 0.000_001 };
    store.save(original).unwrap();
    fs::set_permissions(&dir.0, fs::Permissions::from_mode(0o500)).unwrap();
    let result = store.save(Calibration { correction: 0.000_03, uncertainty: 0.000_001 });
    fs::set_permissions(&dir.0, fs::Permissions::from_mode(0o700)).unwrap();
    assert!(result.is_err());
    assert_eq!(store.load().unwrap(), Some(original));
}

#[test]
fn rejects_symlinks_and_recovers_an_interrupted_temporary_write() {
    let dir = TestDirectory::new();
    let value = Calibration { correction: 0.000_02, uncertainty: 0.000_001 };
    let store = CalibrationStore::open(&dir.path(), 0.0005).unwrap();
    store.save(value).unwrap();
    fs::write(dir.0.join(".frequency.tmp"), "partial").unwrap();
    drop(store);
    let store = CalibrationStore::open(&dir.path(), 0.0005).unwrap();
    assert_eq!(store.load().unwrap(), Some(value));
    store.save(value).unwrap();
    fs::remove_file(dir.path()).unwrap();
    std::os::unix::fs::symlink(".frequency.lock", dir.path()).unwrap();
    assert!(store.load().is_err());
    drop(store);
    let linked = dir.0.with_extension("linked");
    std::os::unix::fs::symlink(&dir.0, &linked).unwrap();
    assert!(CalibrationStore::open(&linked.join("frequency.json"), 0.0005).is_err());
    fs::remove_file(linked).unwrap();
}

#[test]
fn interrupted_writer_child() {
    let Some(path) = std::env::var_os("NTPD_CALIBRATION_CHILD") else { return; };
    let path = PathBuf::from(path);
    let _store = CalibrationStore::open(&path, 0.0005).unwrap();
    let temporary = path.parent().unwrap().join(".frequency.tmp");
    fs::write(&temporary, "partial").unwrap();
    fs::File::open(&temporary).unwrap().sync_all().unwrap();
    fs::write(path.parent().unwrap().join("child-ready"), "ready").unwrap();
    loop { std::thread::park(); }
}

#[test]
fn killed_writer_preserves_previous_calibration() {
    let dir = TestDirectory::new();
    let value = Calibration { correction: 0.000_02, uncertainty: 0.000_001 };
    let store = CalibrationStore::open(&dir.path(), 0.0005).unwrap();
    store.save(value).unwrap();
    drop(store);
    let mut child = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "daemon::calibration_tests::interrupted_writer_child"])
        .env("NTPD_CALIBRATION_CHILD", dir.path()).spawn().unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while !dir.0.join("child-ready").exists() && std::time::Instant::now() < deadline {
        std::thread::yield_now();
    }
    let ready = dir.0.join("child-ready").exists();
    child.kill().unwrap();
    child.wait().unwrap();
    assert!(ready, "writer child did not reach the incomplete update");
    let store = CalibrationStore::open(&dir.path(), 0.0005).unwrap();
    assert_eq!(store.load().unwrap(), Some(value));
    store.save(value).unwrap();
}

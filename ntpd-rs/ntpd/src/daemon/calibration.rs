use std::{
    ffi::OsStr,
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    os::{fd::AsRawFd, unix::fs::{MetadataExt, OpenOptionsExt}},
    path::{Path, PathBuf},
};
use serde::{Deserialize, Serialize};
use statime_base::{Clock, TAI};

#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct Calibration {
    pub correction: f64,
    pub uncertainty: f64,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredCalibration {
    version: u32,
    correction: f64,
    uncertainty: f64,
}

pub(super) struct CalibrationStore {
    directory: File,
    lock: File,
    filename: PathBuf,
    limit: f64,
    owner: u32,
}

fn invalid(message: &'static str) -> io::Error { io::Error::new(io::ErrorKind::InvalidData, message) }

pub(super) fn restore<C: Clock<TAI>>(store: &CalibrationStore, clock: &C) -> Result<bool, Box<dyn std::error::Error>> {
    if let Some(value) = store.load()? {
        clock.set_frequency(value.correction)?;
        return Ok(true);
    }
    Ok(false)
}

impl CalibrationStore {
    pub fn open(path: &Path, limit: f64) -> io::Result<Self> {
        if !limit.is_finite() || limit <= 0.0 { return Err(invalid("invalid clock frequency limit")); }
        let name = path.file_name().ok_or_else(|| invalid("calibration file needs a name"))?;
        if name == OsStr::new(".frequency.lock") || name == OsStr::new(".frequency.tmp") {
            return Err(invalid("calibration file uses a reserved name"));
        }
        let parent = path.parent().filter(|p| !p.as_os_str().is_empty()).ok_or_else(|| invalid("calibration file needs a parent directory"))?;
        let directory = OpenOptions::new().read(true).custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC).open(parent)?;
        let metadata = directory.metadata()?;
        let status = fs::read_to_string("/proc/self/status")?;
        let owner: u32 = status.lines().find_map(|line| line.strip_prefix("Uid:").and_then(|value| value.split_whitespace().nth(1))).ok_or_else(|| invalid("missing effective uid"))?.parse().map_err(|_| invalid("invalid effective uid"))?;
        if metadata.uid() != owner || metadata.mode() & 0o7777 != 0o700 {
            return Err(invalid("calibration directory must be private and owned by the daemon"));
        }
        let base = PathBuf::from(format!("/proc/self/fd/{}", directory.as_raw_fd()));
        let lock = OpenOptions::new().read(true).write(true).create(true).mode(0o600).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(base.join(".frequency.lock"))?;
        Self::check_file(&lock, owner)?;
        lock.try_lock().map_err(io::Error::other)?;
        Ok(Self { directory, lock, filename: name.into(), limit, owner })
    }

    fn base(&self) -> PathBuf { PathBuf::from(format!("/proc/self/fd/{}", self.directory.as_raw_fd())) }

    fn check_file(file: &File, owner: u32) -> io::Result<()> {
        let metadata = file.metadata()?;
        if !metadata.is_file() || metadata.uid() != owner || metadata.nlink() != 1 || metadata.mode() & 0o7777 != 0o600 {
            return Err(invalid("calibration file must be private, owned, and unlinked elsewhere"));
        }
        Ok(())
    }

    fn validate(&self, value: Calibration) -> io::Result<Calibration> {
        if !value.correction.is_finite() || !value.uncertainty.is_finite() || value.uncertainty < 0.0 || value.correction.abs() + value.uncertainty >= self.limit {
            return Err(invalid("frequency calibration exceeds clock bounds"));
        }
        Ok(value)
    }

    pub fn load(&self) -> io::Result<Option<Calibration>> {
        let path = self.base().join(&self.filename);
        let file = match OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        Self::check_file(&file, self.owner)?;
        let mut bytes = Vec::new();
        file.take(4097).read_to_end(&mut bytes)?;
        if bytes.len() > 4096 { return Err(invalid("frequency calibration is too large")); }
        let stored: StoredCalibration = serde_json::from_slice(&bytes).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        if stored.version != 1 { return Err(invalid("unsupported frequency calibration version")); }
        self.validate(Calibration { correction: stored.correction, uncertainty: stored.uncertainty }).map(Some)
    }

    pub fn save(&self, value: Calibration) -> io::Result<()> {
        let value = self.validate(value)?;
        let data = serde_json::to_vec(&StoredCalibration { version: 1, correction: value.correction, uncertainty: value.uncertainty }).map_err(io::Error::other)?;
        let temp = self.base().join(".frequency.tmp");
        match fs::remove_file(&temp) {
            Ok(()) => {},
            Err(error) if error.kind() == io::ErrorKind::NotFound => {},
            Err(error) => return Err(error),
        }
        let result = (|| {
            let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(&temp)?;
            file.write_all(&data)?;
            file.sync_all()?;
            fs::rename(&temp, self.base().join(&self.filename))?;
            self.directory.sync_all()
        })();
        if result.is_err() {
            if let Err(error) = fs::remove_file(&temp) {
                if error.kind() != io::ErrorKind::NotFound { tracing::warn!(%error, "failed to remove frequency calibration temporary file"); }
            }
        }
        result
    }
}

#![forbid(unsafe_code)]
#![allow(missing_docs)]
// FIXME: the lints below should be reenabled. Please fix them with a per-lint
// PR fixing that one lint and enabling it accross all crates.
#![allow(clippy::bool_to_int_with_if)]

use std::{error::Error, process};

fn main() {
    if let Err(err) = ntpd::daemon_main() {
        let (status, message) = report_error(err.as_ref());
        eprintln!("{message}");
        process::exit(status);
    }
    process::exit(0);
}

fn report_error(error: &(dyn Error + 'static)) -> (i32, String) {
    #[cfg(target_os = "linux")]
    {
        let mut cause = Some(error);
        while let Some(current) = cause {
            if current.downcast_ref::<statime_base::ClockError>()
                == Some(&statime_base::ClockError::PermissionDenied)
            {
                return (77, "clock operation denied; check CAP_SYS_TIME".to_owned());
            }
            cause = current.source();
        }
    }
    (1, error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use statime_base::ClockError;

    #[test]
    #[cfg(target_os = "linux")]
    fn clock_permission_denial_names_capability_and_exits_noperm() {
        let (status, message) = report_error(&ClockError::PermissionDenied);
        assert_eq!(status, 77);
        assert!(message.contains("CAP_SYS_TIME"));
    }

    #[test]
    fn other_permission_errors_keep_their_status_and_message() {
        let error = std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "configuration denied",
        );
        let (status, message) = report_error(&error);
        assert_eq!(status, 1);
        assert_eq!(message, "configuration denied");
    }

    #[test]
    fn other_clock_errors_keep_their_status() {
        let (status, _) = report_error(&ClockError::NoDevice);
        assert_eq!(status, 1);
    }
}

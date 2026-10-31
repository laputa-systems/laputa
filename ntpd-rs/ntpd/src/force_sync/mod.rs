use std::{path::Path, process::ExitCode};

pub(crate) fn force_sync(_config: Option<&Path>) -> ExitCode {
    println!("Disabled for now");
    ExitCode::FAILURE
}

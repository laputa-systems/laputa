// Code for notifying systemd that a daemon is ready. Originally based on the sd-notify crate by lnicola.

use std::{ffi::OsStr, io::Write};

use tokio::net::UnixDatagram;

const NOTIFY_SOCKET: &str = "NOTIFY_SOCKET";
const NOTIFY_FD: &str = "NOTIFY_FD";

/// Tells a supervisor that passed a pipe in `NOTIFY_FD` that the daemon is ready, by writing one
/// byte to it. Does nothing when the variable is unset.
///
/// The descriptor is reopened through procfs because the crate forbids unsafe code, which taking
/// ownership of an inherited raw descriptor would need.
pub(crate) fn notify_fd_ready() -> std::io::Result<()> {
    match std::env::var_os(NOTIFY_FD) {
        Some(descriptor) => write_ready_byte(&descriptor),
        None => Ok(()),
    }
}

fn write_ready_byte(descriptor: &OsStr) -> std::io::Result<()> {
    let descriptor = descriptor
        .to_str()
        .and_then(|text| text.parse::<u32>().ok())
        .ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("{NOTIFY_FD} is not a descriptor number: {descriptor:?}"),
            )
        })?;
    let mut pipe = std::fs::OpenOptions::new()
        .write(true)
        .open(format!("/proc/self/fd/{descriptor}"))?;
    pipe.write_all(&[b'\n'])
}

pub(crate) async fn notify_ready() -> std::io::Result<()> {
    let Some(socket_path) = std::env::var_os(NOTIFY_SOCKET) else {
        return Ok(());
    };
    let sock = UnixDatagram::unbound()?;
    sock.connect(&socket_path)?;
    let msg = b"READY=1";
    let len = sock.send(msg).await?;
    if len != msg.len() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::WriteZero,
            "incomplete write",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{ffi::OsStr, io::Read, os::fd::AsRawFd};

    use super::write_ready_byte;

    #[test]
    fn ready_byte_reaches_the_reader_of_the_pipe() {
        let (mut reader, writer) = std::io::pipe().unwrap();

        write_ready_byte(OsStr::new(&writer.as_raw_fd().to_string())).unwrap();

        let mut byte = [0_u8; 1];
        reader.read_exact(&mut byte).unwrap();
    }

    #[test]
    fn a_descriptor_that_is_not_open_is_an_error() {
        assert!(write_ready_byte(OsStr::new("4000000")).is_err());
    }

    #[test]
    fn a_non_numeric_descriptor_is_an_error() {
        let error = write_ready_byte(OsStr::new("pipe")).unwrap_err();

        assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
    }
}

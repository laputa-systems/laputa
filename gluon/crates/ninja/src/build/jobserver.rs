//! GNU make jobserver client.
//!
//! Implements the Posix FIFO and FD-pair protocols documented at
//! https://www.gnu.org/software/make/manual/html_node/POSIX-Jobserver.html
//! Each running edge holds either the implicit slot (one per ninja
//! process, always available at startup) or one explicit token byte
//! consumed from the shared FIFO/pipe. Tokens are returned to the
//! same descriptor on edge completion so other concurrent ninja /
//! make clients can pick them up.
//!
//! Activation rules match reference ninja:
//!
//!   - parse `MAKEFLAGS` from the process env;
//!   - `--jobserver-auth=fifo:PATH` → open the FIFO;
//!   - `--jobserver-auth=R,W` / `--jobserver-fds=R,W` → pipe mode,
//!     which we don't yet implement; we emit
//!     `ninja: warning: Pipe-based protocol is not supported!` to
//!     stderr and disable the jobserver so the local `-j N` cap
//!     takes over;
//!   - an explicit `-j N` on the command line short-circuits the
//!     whole detection — the user asked for that exact local cap.
//!
//! The server side (running ninja itself as a top-level make-style
//! parent that hands tokens out) is intentionally out of scope.

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;

/// Opaque token returned by `try_acquire`. The implicit slot is the
/// `Implicit` variant (no byte to write back); explicit slots carry
/// the exact byte we read so we can put it back unmodified.
#[derive(Debug)]
pub(super) enum Slot {
    Implicit,
    Explicit(u8),
}

/// Minimal FIFO-based client. The read side is opened with `O_NONBLOCK`
/// so `try_acquire` never blocks the dispatch loop; the write side is
/// blocking but writes a single byte at a time, which is well within
/// the kernel's atomicity guarantee.
#[derive(Debug)]
pub(super) struct Client {
    read_fd: File,
    write_fd: File,
    has_implicit: bool,
}

impl Client {
    fn open_fifo(path: &str) -> std::io::Result<Self> {
        // Open both ends nonblock to avoid hangs even if the server
        // exits before us; reads will return EAGAIN cleanly when no
        // tokens are available.
        let read_fd = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(path)?;
        let write_fd = OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(path)?;
        // Sanity check: must actually be a FIFO. Otherwise the user
        // probably pointed us at a regular file, which would happily
        // read/write but not enforce mutual exclusion.
        use std::os::unix::fs::FileTypeExt;
        if !read_fd.metadata()?.file_type().is_fifo() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "jobserver path is not a FIFO",
            ));
        }
        Ok(Self {
            read_fd,
            write_fd,
            has_implicit: true,
        })
    }

    /// Try to acquire one slot without blocking. Returns `None` if no
    /// token is available right now — the caller should back off and
    /// re-poll once it has reaped a completion.
    pub(super) fn try_acquire(&mut self) -> Option<Slot> {
        if self.has_implicit {
            self.has_implicit = false;
            return Some(Slot::Implicit);
        }
        let mut buf = [0u8; 1];
        match self.read_fd.read(&mut buf) {
            Ok(1) => Some(Slot::Explicit(buf[0])),
            _ => None,
        }
    }

    /// Return a slot to the pool. Implicit slots are tracked locally;
    /// explicit slots are written back to the FIFO/pipe so other
    /// clients (and our own future `try_acquire`) can pick them up.
    pub(super) fn release(&mut self, slot: Slot) {
        match slot {
            Slot::Implicit => {
                self.has_implicit = true;
            }
            Slot::Explicit(b) => {
                let _ = self.write_fd.write_all(&[b]);
            }
        }
    }
}

/// Detect a jobserver from the current `MAKEFLAGS`. Returns:
///   - `Ok(Some(client))` on a usable FIFO setup;
///   - `Ok(None)` if no jobserver is configured;
///   - `Err(message)` if the env requested a mode we can't service —
///     the caller should print the message as a warning and proceed
///     with the local `-j N` cap.
pub(super) fn detect_from_env() -> Result<Option<Client>, String> {
    let makeflags = std::env::var("MAKEFLAGS").unwrap_or_default();
    detect(&makeflags)
}

fn detect(makeflags: &str) -> Result<Option<Client>, String> {
    // Last `--jobserver-auth=` / `--jobserver-fds=` wins, matching GNU
    // make's own behaviour (and reference ninja's `ParseMakeFlagsValue`).
    let mut auth: Option<String> = None;
    for tok in makeflags.split_whitespace() {
        if let Some(v) = tok.strip_prefix("--jobserver-auth=") {
            auth = Some(v.to_string());
        } else if let Some(v) = tok.strip_prefix("--jobserver-fds=") {
            auth = Some(v.to_string());
        }
    }
    let Some(auth) = auth else {
        return Ok(None);
    };
    if let Some(path) = auth.strip_prefix("fifo:") {
        return match Client::open_fifo(path) {
            Ok(c) => Ok(Some(c)),
            Err(e) => Err(format!("opening jobserver fifo '{path}': {e}")),
        };
    }
    // R,W file-descriptor pair. Reference ninja explicitly rejects
    // this with "Pipe-based protocol is not supported!" — match the
    // wording so test_jobserver_client_with_posix_pipe is satisfied.
    if let Some((r, w)) = auth.split_once(',')
        && r.parse::<i32>().is_ok()
        && w.parse::<i32>().is_ok()
    {
        return Err("Pipe-based protocol is not supported!".to_string());
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_fifo_auth() {
        let tmp = std::env::temp_dir().join(format!("ninja-js-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        let path = tmp.join("fifo");
        assert!(std::process::Command::new("mkfifo").arg(&path).status().unwrap().success());
        let makeflags = format!(" -j4 --jobserver-auth=fifo:{}", path.display());
        let mut client = detect(&makeflags).unwrap().expect("expected fifo client");

        // Implicit slot is always handed out first.
        assert!(matches!(client.try_acquire(), Some(Slot::Implicit)));
        // No explicit tokens injected yet → second acquire fails.
        assert!(client.try_acquire().is_none());
        // Inject two explicit tokens via the writer side, then re-acquire.
        client.release(Slot::Explicit(b'x'));
        client.release(Slot::Explicit(b'y'));
        let s1 = client.try_acquire().expect("expected explicit");
        let s2 = client.try_acquire().expect("expected explicit");
        assert!(matches!(s1, Slot::Explicit(_)));
        assert!(matches!(s2, Slot::Explicit(_)));

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn pipe_mode_is_rejected_with_friendly_warning() {
        let err = detect("--jobserver-auth=3,4").unwrap_err();
        assert!(err.contains("Pipe-based protocol is not supported!"));
    }

    #[test]
    fn no_makeflags_means_no_jobserver() {
        assert!(detect("").unwrap().is_none());
    }
}

//! POSIX extended regex via libc, with process-locale caveats documented.
//!
//! Patterns compile with `regcomp(REG_EXTENDED)` under whatever locale the
//! daemon runs in. musl's regex engine is effectively
//! locale-independent, but glibc's is not, so the binaries force the `C`
//! locale at startup and tests pin it with [`pin_c_locale`]. A `Regex`
//! must only be used while that holds.

use std::ffi::CStr;
use std::fmt;
use std::os::unix::ffi::OsStrExt;
use std::sync::Once;

/// Compile `pattern` (raw bytes, no interior NUL) with REG_EXTENDED.
#[derive(Debug)]
pub struct Regex {
    pattern: Vec<u8>,
    raw: libc::regex_t,
}

impl PartialEq for Regex {
    fn eq(&self, other: &Regex) -> bool {
        self.pattern == other.pattern
    }
}

impl Eq for Regex {}

impl Regex {
    pub fn compile(pattern: &[u8]) -> Result<Regex, RegexError> {
        if pattern.contains(&0) {
            return Err(RegexError {
                pattern: pattern.to_vec(),
                msg: "pattern contains NUL".into(),
            });
        }
        let mut with_nul = Vec::with_capacity(pattern.len() + 1);
        with_nul.extend_from_slice(pattern);
        with_nul.push(0);
        // Zeroed first: on regcomp failure the buffer is deterministic, and
        // regerror never sees garbage.
        let mut raw: libc::regex_t = unsafe { std::mem::zeroed() };
        // SAFETY: with_nul is NUL-terminated; regcomp initializes raw on
        // success, in which case Drop regfrees it.
        let r = unsafe {
            libc::regcomp(&mut raw, with_nul.as_ptr() as *const _, libc::REG_EXTENDED)
        };
        if r != 0 {
            let mut errbuf = vec![0 as libc::c_char; 256];
            unsafe {
                libc::regerror(r, &raw, errbuf.as_mut_ptr(), errbuf.len());
            }
            let msg = unsafe { CStr::from_ptr(errbuf.as_ptr()) }
                .to_string_lossy()
                .into_owned();
            return Err(RegexError {
                pattern: pattern.to_vec(),
                msg,
            });
        }
        Ok(Regex {
            pattern: pattern.to_vec(),
            raw,
        })
    }

    pub fn pattern(&self) -> &[u8] {
        &self.pattern
    }

    fn as_c_vec(text: &[u8]) -> Vec<u8> {
        let end = text.iter().position(|&b| b == 0).unwrap_or(text.len());
        let mut v = Vec::with_capacity(end + 1);
        v.extend_from_slice(&text[..end]);
        v.push(0);
        v
    }

    /// Unanchored substring search.
    pub fn is_match(&self, text: &[u8]) -> bool {
        let c = Self::as_c_vec(text);
        // SAFETY: c is NUL-terminated; nmatch=0 takes no pmatch pointer.
        unsafe { libc::regexec(&self.raw, c.as_ptr() as *const _, 0, std::ptr::null_mut(), 0) == 0 }
    }

    /// Up to 10 capture groups; the caller applies the full-match anchor
    /// check (`off[0] == whole input`).
    pub fn captures10(&self, text: &[u8]) -> Option<[Option<(usize, usize)>; 10]> {
        let c = Self::as_c_vec(text);
        let mut pm: [libc::regmatch_t; 10] = unsafe { std::mem::zeroed() };
        // SAFETY: c is NUL-terminated; pmatch has room for 10 entries.
        let r = unsafe {
            libc::regexec(
                &self.raw,
                c.as_ptr() as *const _,
                pm.len(),
                pm.as_mut_ptr(),
                0,
            )
        };
        if r != 0 {
            return None;
        }
        let mut out: [Option<(usize, usize)>; 10] = [None; 10];
        for (i, m) in pm.iter().enumerate() {
            if m.rm_so >= 0 && m.rm_eo >= m.rm_so {
                out[i] = Some((m.rm_so as usize, m.rm_eo as usize));
            }
        }
        Some(out)
    }
}

impl Clone for Regex {
    fn clone(&self) -> Regex {
        Regex::compile(&self.pattern).expect("stored pattern recompiles")
    }
}

impl Drop for Regex {
    fn drop(&mut self) {
        // SAFETY: raw was initialized by a successful regcomp.
        unsafe { libc::regfree(&mut self.raw) };
    }
}

/// Call once per test binary before matching; the daemon binaries do the
/// equivalent at startup. Process-global by nature (POSIX locale).
pub fn pin_c_locale() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        // SAFETY: constant string; the return value is unchecked.
        unsafe {
            libc::setlocale(libc::LC_ALL, c"C".as_ptr());
        }
    });
}

/// Best-effort lossy rendering of byte strings for diagnostics.
pub fn lossy(bytes: &[u8]) -> std::borrow::Cow<'_, str> {
    std::ffi::OsStr::from_bytes(bytes).to_string_lossy()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegexError {
    pub pattern: Vec<u8>,
    pub msg: String,
}

impl fmt::Display for RegexError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "compile regular expression {}: {}", lossy(&self.pattern), self.msg)
    }
}

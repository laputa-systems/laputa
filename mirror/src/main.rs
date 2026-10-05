use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, RwLock};

use tracing_subscriber::EnvFilter;

use laputa_mirror::{Access, AppState, AuthState, packages, s3};

const USAGE: &str = "\
usage:
  laputa-mirror
      Production mode: S3 storage and passkey/token auth, configured by the
      environment (ALLOWED_USERS, RP_ID, RP_ORIGIN, DB_PATH, S3_*).
  laputa-mirror --local DATA_DIR [--listen 127.0.0.1:PORT] [--sources DIR]
      Local mode: objects under DATA_DIR, no auth, loopback only. --sources
      serves DIR/sha256/<hash> read-only at /sources/sha256/<hash>.";

const LOCAL_DEFAULT_LISTEN: &str = "127.0.0.1:3000";

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        return run_production();
    }
    if args.iter().any(|a| a == "-h" || a == "--help") {
        println!("{USAGE}");
        return;
    }
    let local = LocalArgs::parse(&args).unwrap_or_else(|e| {
        eprintln!("laputa-mirror: {e}\n\n{USAGE}");
        std::process::exit(2);
    });
    if let Err(e) = run_local(local) {
        eprintln!("laputa-mirror: {e}");
        std::process::exit(1);
    }
}

struct LocalArgs {
    data_dir: PathBuf,
    listen: SocketAddr,
    source_cache: Option<PathBuf>,
}

impl LocalArgs {
    fn parse(args: &[String]) -> Result<Self, String> {
        let mut data_dir = None;
        let mut listen = None;
        let mut source_cache = None;
        let mut args = args.iter();
        while let Some(flag) = args.next() {
            let slot = match flag.as_str() {
                "--local" => &mut data_dir,
                "--listen" => &mut listen,
                "--sources" => &mut source_cache,
                other => return Err(format!("unknown argument {other:?}")),
            };
            let value = args.next().ok_or_else(|| format!("{flag} needs a value"))?;
            if slot.replace(value.clone()).is_some() {
                return Err(format!("{flag} given more than once"));
            }
        }
        let data_dir = data_dir.ok_or("--listen and --sources require --local DATA_DIR")?;
        let listen_text = listen.as_deref().unwrap_or(LOCAL_DEFAULT_LISTEN);
        let listen: SocketAddr = listen_text
            .parse()
            .map_err(|_| format!("--listen {listen_text:?} is not an IP:PORT address"))?;
        // Local mode accepts unauthenticated writes, so it must not be reachable
        // from other machines. There is deliberately no override.
        if !listen.ip().is_loopback() {
            return Err(format!(
                "--listen {listen} is not a loopback address; local mode has no auth and binds loopback only"
            ));
        }
        Ok(Self {
            data_dir: data_dir.into(),
            listen,
            source_cache: source_cache.map(PathBuf::from),
        })
    }
}

fn run_local(args: LocalArgs) -> Result<(), String> {
    let data_dir = &args.data_dir;
    std::fs::create_dir_all(data_dir)
        .map_err(|e| format!("create {}: {e}", data_dir.display()))?;
    if let Some(dir) = &args.source_cache
        && !dir.is_dir()
    {
        return Err(format!("--sources {} is not a directory", dir.display()));
    }

    // Unlike production, a corrupt index is an error rather than an empty mirror:
    // serving `[]` would make clients treat every package as missing.
    let index_path = data_dir.join("index.json");
    let index = match std::fs::read(&index_path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map_err(|e| format!("parse {}: {e}", index_path.display()))?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(e) => return Err(format!("read {}: {e}", index_path.display())),
    };

    let state = Arc::new(AppState {
        storage: s3::Storage::fs(data_dir),
        access: Access::Open,
        index: RwLock::new(index),
        // Dot-named, so no object key can name it.
        upload_dir: data_dir.join(".uploads"),
        index_lock: Mutex::new(()),
        r2_public_url: None,
        source_cache: args.source_cache.clone(),
    });

    let server = tiny_http::Server::http(args.listen)
        .map_err(|e| format!("bind {}: {e}", args.listen))?;
    let addr = server
        .server_addr()
        .to_ip()
        .ok_or("listener has no IP address")?;
    println!("http://{addr} (local mode, no auth)");
    println!("  data:    {}", data_dir.display());
    if let Some(dir) = &args.source_cache {
        println!("  sources: {}/sha256/<hash>", dir.display());
    }
    laputa_mirror::serve(server, state);
    Ok(())
}

fn run_production() {
    let listen_addr = env_or("LISTEN_ADDR", "127.0.0.1:3000");

    let allowed_users: Vec<String> = env_required("ALLOWED_USERS")
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let rp_id = env_required("RP_ID");
    let rp_origin = env_required("RP_ORIGIN");

    let db = laputa_mirror::db::Db::open(&env_required("DB_PATH"))
        .expect("failed to open auth database");

    let webauthn = webauthn_minimal::RelyingParty::new(&rp_id, &rp_origin, "Laputa Mirror");

    let jwks = if let Ok(jwks_url) = std::env::var("JWT_JWKS_URL") {
        let config = laputa_mirror::jwt::JwtConfig {
            jwks_url,
            issuer: env_required("JWT_ISSUER"),
            audience: env_required("JWT_AUDIENCE"),
            subject_pattern: env_required("JWT_SUBJECT_PATTERN"),
        };
        Some(Mutex::new(laputa_mirror::jwt::JwksCache::new(config)))
    } else {
        tracing::info!("JWT_JWKS_URL not set; JWT/OIDC auth disabled");
        None
    };

    let storage = s3::Storage::s3(
        &env_required("S3_ENDPOINT"),
        &env_required("S3_BUCKET"),
        &env_credential_required("S3_ACCESS_KEY_ID"),
        &env_credential_required("S3_SECRET_ACCESS_KEY"),
        &env_or("S3_REGION", "auto"),
    );
    let index = packages::load_index(&storage)
        .unwrap_or_else(|e| panic!("failed to load R2 index: {e}"));

    let r2_public_url = std::env::var("R2_PUBLIC_URL")
        .ok()
        .map(|u| u.trim_end_matches('/').to_string());
    let upload_dir = std::env::var("UPLOAD_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/var/lib/laputa-mirror/uploads"));

    let state = Arc::new(AppState {
        storage,
        access: Access::Authenticated(AuthState {
            db: Mutex::new(db),
            webauthn,
            jwks,
            allowed_users,
            secure_cookies: rp_origin.starts_with("https://"),
        }),
        index: RwLock::new(index),
        upload_dir,
        index_lock: Mutex::new(()),
        r2_public_url,
        source_cache: None,
    });

    let server = tiny_http::Server::http(&listen_addr).expect("failed to bind");
    println!("http://{listen_addr}");
    println!("  packages: http://{listen_addr}/");
    println!("  auth:     http://{listen_addr}/auth");

    laputa_mirror::serve(server, state);
}

fn env_required(key: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| panic!("{key} must be set"))
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn env_credential_required(key: &str) -> String {
    credential_required(key, std::env::var(key), std::env::var_os(format!("{key}_FILE")))
        .unwrap_or_else(|e| panic!("{e}"))
}

// A direct value wins even when empty. File credentials may have one terminal
// LF from text-file creation; every other character is part of the credential.
fn credential_required(
    key: &str,
    value: Result<String, std::env::VarError>,
    file: Option<std::ffi::OsString>,
) -> Result<String, String> {
    match value {
        Ok(value) => return Ok(value),
        Err(std::env::VarError::NotPresent) => {},
        Err(std::env::VarError::NotUnicode(_)) => {
            return Err(format!("{key} must contain valid UTF-8"));
        }
    }
    let path = file.map(PathBuf::from).ok_or_else(|| format!("{key} must be set"))?;
    let mut value = std::fs::read_to_string(&path)
        .map_err(|e| format!("read {key}_FILE {}: {e}", path.display()))?;
    if value.ends_with('\n') {
        value.pop();
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env::VarError;
    use std::ffi::OsString;

    struct CredentialFile(PathBuf);

    impl CredentialFile {
        fn new(bytes: &[u8]) -> Self {
            let path = std::env::temp_dir().join(format!("laputa-credential-{}", uuid::Uuid::new_v4()));
            std::fs::write(&path, bytes).unwrap();
            Self(path)
        }

        fn setting(&self) -> Option<OsString> {
            Some(self.0.clone().into_os_string())
        }
    }

    impl Drop for CredentialFile {
        fn drop(&mut self) {
            std::fs::remove_file(&self.0).unwrap();
        }
    }

    #[test]
    fn credential_environment_takes_precedence_over_file() {
        let missing = Some(OsString::from("/no-such-laputa-credential"));
        for value in ["direct\n", ""] {
            assert_eq!(
                credential_required("S3_ACCESS_KEY_ID", Ok(value.into()), missing.clone()).unwrap(),
                value
            );
        }
    }

    #[test]
    fn credential_file_removes_only_one_terminal_newline() {
        for (bytes, expected) in [
            ("secret\n", "secret"),
            ("secret", "secret"),
            (" secret \n", " secret "),
            ("secret\n\n", "secret\n"),
            ("secret\r\n", "secret\r"),
            ("sec\nret\t", "sec\nret\t"),
            ("", ""),
        ] {
            let file = CredentialFile::new(bytes.as_bytes());
            assert_eq!(
                credential_required("S3_SECRET_ACCESS_KEY", Err(VarError::NotPresent), file.setting()).unwrap(),
                expected
            );
        }
    }

    #[test]
    fn credential_is_required_without_environment_or_file() {
        assert_eq!(
            credential_required("S3_ACCESS_KEY_ID", Err(VarError::NotPresent), None).unwrap_err(),
            "S3_ACCESS_KEY_ID must be set"
        );
    }

    #[test]
    fn credential_file_read_failures_are_errors() {
        let file = CredentialFile::new(b"secret");
        let missing = file.0.join("missing").into_os_string();
        let error = credential_required("S3_SECRET_ACCESS_KEY", Err(VarError::NotPresent), Some(missing)).unwrap_err();
        assert!(error.starts_with("read S3_SECRET_ACCESS_KEY_FILE "));

        let invalid = CredentialFile::new(&[0xff]);
        assert!(credential_required("S3_SECRET_ACCESS_KEY", Err(VarError::NotPresent), invalid.setting()).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn credential_invalid_environment_does_not_fall_back_to_file() {
        use std::os::unix::ffi::OsStringExt;

        let file = CredentialFile::new(b"fallback");
        let error = credential_required(
            "S3_ACCESS_KEY_ID",
            Err(VarError::NotUnicode(OsString::from_vec(vec![0xff]))),
            file.setting(),
        ).unwrap_err();
        assert_eq!(error, "S3_ACCESS_KEY_ID must contain valid UTF-8");
    }
}

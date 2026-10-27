use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

use laputa_mirror::{jwt, s3};

fn in_child() -> bool {
    std::env::var_os("LAPUTA_MIRROR_TLS_TEST_CHILD").is_some()
}

fn run_child(test_name: &str) {
    let exe = std::env::current_exe().expect("test binary path");
    let status = std::process::Command::new(exe)
        .arg("--exact")
        .arg(test_name)
        .arg("--nocapture")
        .env("LAPUTA_MIRROR_TLS_TEST_CHILD", "1")
        .status()
        .expect("child test process runs");
    assert!(
        status.success(),
        "isolated test {test_name} failed in its own process"
    );
}

fn isolated(test_name: &str) -> bool {
    if in_child() {
        return false;
    }
    run_child(test_name);
    true
}

struct TempDir(std::path::PathBuf);

impl TempDir {
    fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicUsize =
            std::sync::atomic::AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "laputa-mirror-tls-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).expect("temp dir");
        Self(path)
    }

    fn path(&self) -> &std::path::Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn set_bundle(path: &std::path::Path) {
    unsafe {
        std::env::set_var("SSL_CERT_FILE", path.to_str().expect("bundle path"));
        std::env::remove_var("SSL_CERT_DIR");
    }
}

struct TestCa {
    root_pem: String,
    server_der: Vec<u8>,
    server_key_der: Vec<u8>,
}

fn test_ca() -> TestCa {
    use rcgen::{
        BasicConstraints, CertificateParams, CertifiedIssuer, DnType, ExtendedKeyUsagePurpose,
        IsCa, KeyPair, KeyUsagePurpose,
    };

    let mut ca_params = CertificateParams::new(vec![]).expect("CA params");
    ca_params
        .distinguished_name
        .push(DnType::CommonName, "Test Mirror CA");
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    ca_params.key_usages = vec![
        KeyUsagePurpose::DigitalSignature,
        KeyUsagePurpose::KeyCertSign,
        KeyUsagePurpose::CrlSign,
    ];
    let ca_key = KeyPair::generate().expect("CA key");
    let ca = CertifiedIssuer::self_signed(ca_params, ca_key).expect("CA cert");

    let mut server_params =
        CertificateParams::new(vec!["localhost".to_string(), "127.0.0.1".to_string()])
            .expect("server params");
    server_params
        .distinguished_name
        .push(DnType::CommonName, "localhost");
    server_params.is_ca = IsCa::NoCa;
    server_params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
    server_params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    let server_key = KeyPair::generate().expect("server key");
    let server = server_params
        .signed_by(&server_key, &ca)
        .expect("server cert");

    TestCa {
        root_pem: ca.pem(),
        server_der: server.der().to_vec(),
        server_key_der: server_key.serialize_der(),
    }
}

type Store = Arc<Mutex<HashMap<String, Vec<u8>>>>;

fn serve_s3(ca: &TestCa, store: Store, connections: usize) -> std::net::SocketAddr {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer};

    let chain = vec![CertificateDer::from(ca.server_der.clone())];
    let key = PrivateKeyDer::try_from(ca.server_key_der.clone()).expect("server key");
    let provider = Arc::new(rustls_graviola::default_provider());
    let mut config = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("safe defaults")
        .with_no_client_auth()
        .with_single_cert(chain, key)
        .expect("server chain");
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    let config = Arc::new(config);

    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let address = listener.local_addr().expect("address");
    std::thread::spawn(move || {
        for _ in 0..connections {
            let Ok((stream, _)) = listener.accept() else {
                return;
            };
            let store = store.clone();
            let config = config.clone();
            if handle_s3(stream, &store, &config).is_err() {
                continue;
            }
        }
    });
    address
}

fn handle_s3(
    stream: std::net::TcpStream,
    store: &Store,
    config: &Arc<rustls::ServerConfig>,
) -> std::io::Result<()> {
    let session =
        rustls::ServerConnection::new(config.clone()).map_err(std::io::Error::other)?;
    let mut tls = rustls::StreamOwned::new(session, stream);
    let mut head = Vec::new();
    loop {
        let mut input = [0_u8; 1024];
        let read = tls.read(&mut input)?;
        if read == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "request ended",
            ));
        }
        head.extend_from_slice(&input[..read]);
        if head.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
    }
    let split = head
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .expect("head terminator");
    let header = String::from_utf8(head[..split].to_vec()).map_err(std::io::Error::other)?;
    let mut lines = header.lines();
    let request_line = lines.next().unwrap_or("");
    let mut parts = request_line.split(' ');
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("");
    let mut content_length = 0_usize;
    for line in lines {
        if let Some(value) = line.strip_prefix("content-length:") {
            content_length = value.trim().parse().unwrap_or(0);
        } else if let Some(value) = line.strip_prefix("Content-Length:") {
            content_length = value.trim().parse().unwrap_or(0);
        }
    }
    let key = target.strip_prefix("/mirror/").unwrap_or("").to_string();
    // The head read may already hold some or all of the body.
    let mut body = head[split + 4..].to_vec();
    body.truncate(content_length);
    while body.len() < content_length {
        let mut chunk = [0_u8; 8192];
        let want = (content_length - body.len()).min(chunk.len());
        let read = tls.read(&mut chunk[..want])?;
        if read == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "body ended",
            ));
        }
        body.extend_from_slice(&chunk[..read]);
    }

    let (status, response_body) = match (method, key.as_str()) {
        ("PUT", _) => {
            store.lock().unwrap().insert(key.clone(), body);
            ("200 OK", Vec::new())
        }
        ("GET", "boom") => ("500 Internal Server Error", b"boom".to_vec()),
        ("GET", _) => match store.lock().unwrap().get(&key).cloned() {
            Some(found) => ("200 OK", found),
            None => ("404 Not Found", Vec::new()),
        },
        ("HEAD", _) => match store.lock().unwrap().get(&key).cloned() {
            Some(_) => ("200 OK", Vec::new()),
            None => ("404 Not Found", Vec::new()),
        },
        _ => ("400 Bad Request", Vec::new()),
    };
    let length = if method == "HEAD" {
        store
            .lock()
            .unwrap()
            .get(&key)
            .map(|found| found.len())
            .unwrap_or(0)
    } else {
        response_body.len()
    };
    write!(
        tls,
        "HTTP/1.1 {status}\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n"
    )?;
    if method != "HEAD" {
        tls.write_all(&response_body)?;
    }
    tls.flush()
}

fn s3_storage(endpoint: &std::net::SocketAddr) -> s3::Storage {
    s3::Storage::s3(
        &format!("https://{endpoint}"),
        "mirror",
        "AKID",
        "secret",
        "auto",
    )
}

#[test]
fn s3_transfers_over_https() {
    if isolated("s3_transfers_over_https") {
        return;
    }
    let ca = test_ca();
    let dir = TempDir::new();
    let bundle = dir.path().join("bundle.pem");
    std::fs::write(&bundle, &ca.root_pem).unwrap();
    set_bundle(&bundle);

    let store: Store = Arc::new(Mutex::new(HashMap::new()));
    let address = serve_s3(&ca, store, 16);
    let storage = s3_storage(&address);

    storage.put("pkg/a.txt", b"hello".to_vec(), "text/plain").unwrap();
    assert_eq!(storage.get("pkg/a.txt").unwrap(), Some(b"hello".to_vec()));
    assert_eq!(storage.object_size("pkg/a.txt").unwrap(), Some(5));
    assert_eq!(storage.get("pkg/missing.txt").unwrap(), None);
    assert_eq!(storage.object_size("pkg/missing.txt").unwrap(), None);

    let staged = dir.path().join("staged.bin");
    let payload: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
    std::fs::write(&staged, &payload).unwrap();
    storage
        .put_file("pkg/big.bin", &staged, "application/octet-stream")
        .unwrap();
    assert_eq!(storage.get("pkg/big.bin").unwrap(), Some(payload));
}

const JWKS_MODULUS: &str = "r4Z1tMkvXnNCE4c4JkzlQ0hjg7gcMa-LVL402qbkG_xPNeNKRJ7_LVSyytnG40eoxzyK9MFpOLky2BaS2h8rUaREJyxE1UGPhbASdrhA1tyNbmU2wbHYEwPVzgHuchBHG0ZjN_KWFGjYnEFE1IkyQb4fADVowyAbph85QhGg3H_wzSa5gUMZYoNFertCNCDProxB9x_OqakkT1C3mYb0SqqO_eTPexs0eO79QD_ZQGFoQbOu_JYFSbyH3UxUEMA9EvPr4w27VhGxB492nwjKzzxasLrJ4W6vTQsl5cwo8G1hukuBgqP9FhslaIuQsw1sUGGd1qsZLe6M25RufP7oXw";
const JWKS_VALID: &str = "eyJhbGciOiAiUlMyNTYiLCAidHlwIjogIkpXVCIsICJraWQiOiAidGVzdC1rZXkifQ.eyJpc3MiOiAiaHR0cHM6Ly9pc3N1ZXIudGVzdCIsICJzdWIiOiAicmVwbzpqb3NoL21pcnJvciIsICJhdWQiOiAibGFwdXRhLW1pcnJvciIsICJleHAiOiA0MTAyNDQ0ODAwfQ.f7Tokgt9SXBCNBZywFSoCx4DOAGr-RYplZKgzZ9S2w-RdwJSoBRjwOr0XlvYP8Q5tivpaP0hntm9o3j8dmN9ug6MUKDxnA7bgUgGPshKSIvVf3gbxFVoYm3ixahPV-KX8jHVMH7UBsY8fvIaV0LHzvJ0oLj1HZjN93ZGW8dVyAQuDAvG_WDE5nmNhLA2r1RV3KKIr8uAj4VyEMe3pMxbGIBqWe0KrjPF14vOVOcmsm28Htifts6OqiEwG1lScDpqpuyQN_ms1QuUWKmQ0TlB5oqep9_NpB163ZiCvF08cEv-RCGWDiUAazB0VOPci0Vx-RTiYrMZ8GP5rMMDo2z_WQ";

fn serve_jwks(ca: &TestCa, body: String, connections: usize) -> std::net::SocketAddr {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer};

    let chain = vec![CertificateDer::from(ca.server_der.clone())];
    let key = PrivateKeyDer::try_from(ca.server_key_der.clone()).expect("server key");
    let provider = Arc::new(rustls_graviola::default_provider());
    let mut config = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("safe defaults")
        .with_no_client_auth()
        .with_single_cert(chain, key)
        .expect("server chain");
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    let config = Arc::new(config);

    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let address = listener.local_addr().expect("address");
    std::thread::spawn(move || {
        for _ in 0..connections {
            let Ok((stream, _)) = listener.accept() else {
                return;
            };
            let config = config.clone();
            let body = body.clone();
            let _ = handle_jwks(stream, &config, &body);
        }
    });
    address
}

fn handle_jwks(
    stream: std::net::TcpStream,
    config: &Arc<rustls::ServerConfig>,
    body: &str,
) -> std::io::Result<()> {
    let session =
        rustls::ServerConnection::new(config.clone()).map_err(std::io::Error::other)?;
    let mut tls = rustls::StreamOwned::new(session, stream);
    let mut head = Vec::new();
    loop {
        let mut input = [0_u8; 1024];
        let read = tls.read(&mut input)?;
        if read == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "request ended",
            ));
        }
        head.extend_from_slice(&input[..read]);
        if head.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
    }
    write!(
        tls,
        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )?;
    tls.flush()
}

fn jwks_body() -> String {
    format!(
        r#"{{"keys":[{{"kty":"RSA","kid":"test-key","n":"{JWKS_MODULUS}","e":"AQAB"}}]}}"#
    )
}

fn jwks_cache(url: &str) -> jwt::JwksCache {
    jwt::JwksCache::new(jwt::JwtConfig {
        jwks_url: url.to_string(),
        issuer: "https://issuer.test".into(),
        audience: "laputa-mirror".into(),
        subject_pattern: "repo:josh/*".into(),
    })
}

#[test]
fn jwks_retrieval_over_https() {
    if isolated("jwks_retrieval_over_https") {
        return;
    }
    let ca = test_ca();
    let dir = TempDir::new();
    let bundle = dir.path().join("bundle.pem");
    std::fs::write(&bundle, &ca.root_pem).unwrap();
    set_bundle(&bundle);

    let address = serve_jwks(&ca, jwks_body(), 4);
    let url = format!("https://{address}/jwks");
    jwks_cache(&url).verify(JWKS_VALID).unwrap();
}

#[test]
fn invalid_chain_rejected_as_tls_error() {
    if isolated("invalid_chain_rejected_as_tls_error") {
        return;
    }
    let trusted = test_ca();
    let untrusted = test_ca();
    let dir = TempDir::new();
    let bundle = dir.path().join("bundle.pem");
    std::fs::write(&bundle, &trusted.root_pem).unwrap();
    set_bundle(&bundle);

    let store: Store = Arc::new(Mutex::new(HashMap::new()));
    let address = serve_s3(&untrusted, store, 4);
    let storage = s3_storage(&address);

    let error = storage.get("pkg/a.txt").unwrap_err();
    assert!(
        error.starts_with("S3 GET failed:"),
        "TLS failure must surface as a transfer error, got {error:?}"
    );
    assert!(
        !error.contains("returned 404") && !error.contains("returned 500"),
        "TLS failure must not look like an HTTP status, got {error:?}"
    );

    let reply = laputa_mirror::http::send(
        "GET",
        &format!("https://{address}/mirror/pkg/a.txt"),
        &[],
        &[],
    );
    assert!(reply.is_err(), "invalid chain must fail the transfer");
}

#[test]
fn http_statuses_preserved_over_https() {
    if isolated("http_statuses_preserved_over_https") {
        return;
    }
    let ca = test_ca();
    let dir = TempDir::new();
    let bundle = dir.path().join("bundle.pem");
    std::fs::write(&bundle, &ca.root_pem).unwrap();
    set_bundle(&bundle);

    let store: Store = Arc::new(Mutex::new(HashMap::new()));
    let address = serve_s3(&ca, store, 8);
    let storage = s3_storage(&address);

    assert_eq!(storage.get("pkg/missing.txt").unwrap(), None);
    let reply = laputa_mirror::http::send(
        "GET",
        &format!("https://{address}/mirror/pkg/missing.txt"),
        &[],
        &[],
    )
    .unwrap();
    assert_eq!(reply.status, 404);

    storage
        .put("boom", b"boom".to_vec(), "text/plain")
        .unwrap();
    let reply = laputa_mirror::http::send(
        "GET",
        &format!("https://{address}/mirror/boom"),
        &[],
        &[],
    )
    .unwrap();
    assert_eq!(reply.status, 500);
    let error = storage.get("boom").unwrap_err();
    assert_eq!(error, "S3 GET returned 500");
}

#[test]
fn updated_trust_observed_while_alive() {
    if isolated("updated_trust_observed_while_alive") {
        return;
    }
    let first = test_ca();
    let second = test_ca();
    let dir = TempDir::new();
    let bundle = dir.path().join("bundle.pem");
    std::fs::write(&bundle, &first.root_pem).unwrap();
    set_bundle(&bundle);

    let store: Store = Arc::new(Mutex::new(HashMap::from([(
        "pkg/a.txt".to_string(),
        b"hello".to_vec(),
    )])));
    let first_address = serve_s3(&first, store.clone(), 4);
    let second_address = serve_s3(&second, store.clone(), 4);
    let first_storage = s3_storage(&first_address);
    let second_storage = s3_storage(&second_address);

    assert_eq!(
        first_storage.get("pkg/a.txt").unwrap(),
        Some(b"hello".to_vec())
    );
    let error = second_storage.get("pkg/a.txt").unwrap_err();
    assert!(
        error.starts_with("S3 GET failed:"),
        "unknown root must fail the transfer, got {error:?}"
    );

    let mut combined = first.root_pem.clone();
    combined.push_str(&second.root_pem);
    std::fs::write(&bundle, combined).unwrap();
    assert_eq!(
        second_storage.get("pkg/a.txt").unwrap(),
        Some(b"hello".to_vec()),
        "the live client must observe added trust"
    );

    std::fs::write(&bundle, &second.root_pem).unwrap();
    let error = first_storage.get("pkg/a.txt").unwrap_err();
    assert!(
        error.starts_with("S3 GET failed:"),
        "removed trust must fail later handshakes, got {error:?}"
    );
}

#[test]
fn tls_dependency_closure() {
    let output = std::process::Command::new("cargo")
        .args(["tree", "-e", "normal", "--prefix", "none", "--offline"])
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .expect("cargo tree runs");
    assert!(
        output.status.success(),
        "cargo tree failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let tree = String::from_utf8(output.stdout).expect("tree is UTF-8");
    let mut webpki = None;
    let mut saw_native_certs = false;
    let mut saw_tls_system = false;
    for line in tree.lines() {
        let name = line.split_whitespace().next().unwrap_or("");
        if name == "webpki-roots" {
            panic!("ordinary mirror TLS graph must not contain webpki-roots");
        }
        if name == "rustls-webpki" {
            let version = line.split_whitespace().nth(1).unwrap_or("");
            webpki = Some(version.trim_start_matches('v').to_string());
        }
        if name == "rustls-native-certs" {
            saw_native_certs = true;
        }
        if name == "h12tiny-tls-system" {
            saw_tls_system = true;
        }
    }
    let version = webpki.expect("mirror uses rustls-webpki");
    let mut parts = version.split('.');
    let major: u64 = parts.next().unwrap_or("0").parse().unwrap_or(0);
    let minor: u64 = parts.next().unwrap_or("0").parse().unwrap_or(0);
    let patch: u64 = parts
        .next()
        .unwrap_or("0")
        .split('-')
        .next()
        .unwrap_or("0")
        .parse()
        .unwrap_or(0);
    assert!(
        (major, minor, patch) >= (0, 103, 16),
        "mirror needs rustls-webpki >= 0.103.16, found {version}"
    );
    assert!(saw_native_certs, "mirror uses system roots");
    assert!(saw_tls_system, "mirror uses the system trust crate");
}

#[test]
fn jwks_tls_failure_not_confused() {
    if isolated("jwks_tls_failure_not_confused") {
        return;
    }
    let trusted = test_ca();
    let untrusted = test_ca();
    let dir = TempDir::new();
    let bundle = dir.path().join("bundle.pem");
    std::fs::write(&bundle, &trusted.root_pem).unwrap();
    set_bundle(&bundle);

    let address = serve_jwks(&untrusted, jwks_body(), 2);
    let url = format!("https://{address}/jwks");
    let error = jwks_cache(&url).verify(JWKS_VALID).unwrap_err();
    assert!(
        error.starts_with("jwks fetch:"),
        "JWKS transport failure must surface as a fetch error, got {error:?}"
    );
    assert!(
        !error.contains("signature")
            && !error.contains("audience")
            && !error.contains("expired"),
        "transport failure must not look like token validation, got {error:?}"
    );
}

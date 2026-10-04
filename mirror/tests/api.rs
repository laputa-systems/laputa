use std::collections::HashMap;
use std::io::{Read, Write};
use std::ops::{Deref, DerefMut};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};

use laputa_mirror::{Access, AppState, AuthState, db, packages, s3};

const TEST_USER: &str = "testuser";
const TEST_TOKEN: &str = "aaaaaabbbbbbccccccddddddeeeeeeffffffffaaaaaaabbbbbbccccccddddddee";

/// A fresh directory under the system temp dir, removed when dropped.
struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "laputa-mirror-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).expect("create temp dir");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// An `AppState` together with the temp dir its uploads (and, in local mode, its
/// objects and source cache) live in; the dir outlives the state.
struct TestMirror {
    state: AppState,
    tmp: TempDir,
}

impl Deref for TestMirror {
    type Target = AppState;
    fn deref(&self) -> &AppState {
        &self.state
    }
}

impl DerefMut for TestMirror {
    fn deref_mut(&mut self) -> &mut AppState {
        &mut self.state
    }
}

/// Production configuration: in-memory storage and token auth.
fn make_state() -> TestMirror {
    let db = laputa_mirror::db::Db::open(":memory:").expect("db");
    db.create_user("test-user-id", TEST_USER)
        .expect("create user");
    db.seed_token("test-user-id", "test", TEST_TOKEN)
        .expect("seed token");

    let tmp = TempDir::new();
    let state = AppState {
        storage: s3::Storage::memory(),
        access: Access::Authenticated(AuthState {
            db: Mutex::new(db),
            webauthn: webauthn_minimal::RelyingParty::new(
                "test.example.com",
                "https://test.example.com",
                "Test",
            ),
            jwks: None,
            allowed_users: vec![TEST_USER.to_string()],
            secure_cookies: false,
        }),
        index: RwLock::new(Vec::new()),
        upload_dir: tmp.path().join("uploads"),
        index_lock: Mutex::new(()),
        r2_public_url: None,
        source_cache: None,
    };
    TestMirror { state, tmp }
}

/// Local-mode configuration, as `laputa-mirror --local DATA --sources SOURCES` builds it.
fn make_local_state() -> TestMirror {
    let tmp = TempDir::new();
    let data = tmp.path().join("data");
    let sources = tmp.path().join("sources");
    std::fs::create_dir_all(sources.join("sha256")).unwrap();
    let state = AppState {
        storage: s3::Storage::fs(&data),
        access: Access::Open,
        index: RwLock::new(Vec::new()),
        upload_dir: data.join(".uploads"),
        index_lock: Mutex::new(()),
        r2_public_url: None,
        source_cache: Some(sources),
    };
    TestMirror { state, tmp }
}

fn auth_state(state: &AppState) -> &AuthState {
    match &state.access {
        Access::Authenticated(auth) => auth,
        Access::Open => panic!("test needs a production-mode state"),
    }
}

fn make_browser_session(state: &AppState) -> String {
    let session = auth_state(state)
        .db
        .lock()
        .unwrap()
        .create_browser_session("test-user-id")
        .expect("browser session");
    format!("laputa_mirror_session={session}")
}

fn headers(pairs: &[(&str, &str)]) -> HashMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

fn auth_headers() -> HashMap<String, String> {
    headers(&[("authorization", &format!("Bearer {TEST_TOKEN}"))])
}

fn body_json(resp: &packages::Response) -> serde_json::Value {
    match &resp.body {
        packages::Body::Bytes(bytes) => serde_json::from_slice(bytes).unwrap(),
        packages::Body::File { .. } => panic!("expected an in-memory JSON body"),
    }
}

/// The full response body; for a streamed file, also checks its declared length.
fn body_bytes(resp: packages::Response) -> Vec<u8> {
    match resp.body {
        packages::Body::Bytes(bytes) => bytes,
        packages::Body::File { mut file, length } => {
            let mut bytes = Vec::new();
            file.read_to_end(&mut bytes).unwrap();
            assert_eq!(bytes.len() as u64, length, "declared length");
            bytes
        }
    }
}

fn get(state: &AppState, path: &str) -> packages::Response {
    packages::route("GET", path, &headers(&[]), b"", state)
}

fn sample_index() -> Vec<packages::RemotePackage> {
    vec![packages::RemotePackage {
        arch: "aarch64".to_string(),
        name: "zlib".to_string(),
        ver: "1.3.2".to_string(),
        rel: "5".to_string(),
        deps: vec!["musl".to_string()],
        mkdeps_host: vec!["cmake".to_string()],
        mkdeps_target: vec!["llvm-toolchain".to_string()],
        sha256: db::sha256_hex(b"package"),
        size: 7,
        tarball: PACKAGE.to_string(),
        metadata: METADATA.to_string(),
        source_sha256: db::sha256_hex(b"source"),
        metapackage: false,
        artifact_key: ARTIFACT_KEY.to_string(),
        proof_key: PROOF_KEY.to_string(),
        proof: PROOF.to_string(),
        extra: Default::default(),
    }]
}

fn put_index(state: &AppState, index: &[packages::RemotePackage]) -> packages::Response {
    let body = serde_json::to_vec(index).unwrap();
    packages::route("PUT", "/index.json", &auth_headers(), &body, state)
}

#[test]
fn health_returns_ok() {
    let state = make_state();
    let resp = packages::route("GET", "/health", &headers(&[]), b"", &state);
    assert_eq!(resp.status, 200);
    assert_eq!(body_json(&resp)["status"], "ok");
}

#[test]
fn public_reads_return_index_and_objects() {
    let state = make_state();
    state
        .storage
        .put(
            "packages/aarch64/zlib/zlib-1.3.2-5-0123456789ab.tar.gz",
            b"package".to_vec(),
            "application/octet-stream",
        )
        .unwrap();
    state
        .storage
        .put(
            "sources/zlib/zlib-1.3.2-5-aarch64-src.tar.bz2",
            b"source".to_vec(),
            "application/octet-stream",
        )
        .unwrap();
    state
        .storage
        .put(
            "metadata/aarch64/zlib/zlib-1.3.2-5-0123456789ab-fedcba987654.json",
            br#"{"metadata_sha256":"abc"}"#.to_vec(),
            "application/json",
        )
        .unwrap();
    assert_eq!(put_index(&state, &sample_index()).status, 201);

    let resp = packages::route("GET", "/index.json", &headers(&[]), b"", &state);
    assert_eq!(resp.status, 200);
    assert_eq!(
        resp.extra_headers,
        vec![("Cache-Control", "no-store".to_string())]
    );
    let idx = body_json(&resp);
    assert_eq!(idx[0]["name"], "zlib");
    assert_eq!(idx[0]["mkdeps_target"], serde_json::json!(["llvm-toolchain"]));

    let resp = packages::route(
        "GET",
        "/packages/aarch64/zlib/zlib-1.3.2-5-0123456789ab.tar.gz",
        &headers(&[]),
        b"",
        &state,
    );
    assert_eq!(resp.status, 200);
    assert_eq!(body_bytes(resp), b"package");

    let resp = packages::route(
        "GET",
        "/sources/zlib/zlib-1.3.2-5-aarch64-src.tar.bz2",
        &headers(&[]),
        b"",
        &state,
    );
    assert_eq!(resp.status, 200);
    assert_eq!(body_bytes(resp), b"source");

    let resp = packages::route(
        "GET",
        "/metadata/aarch64/zlib/zlib-1.3.2-5-0123456789ab-fedcba987654.json",
        &headers(&[]),
        b"",
        &state,
    );
    assert_eq!(resp.status, 200);
    assert_eq!(resp.content_type, "application/json");
    assert_eq!(body_bytes(resp), br#"{"metadata_sha256":"abc"}"#);
}

#[test]
fn authenticated_puts_store_objects_and_index() {
    let state = make_state();
    let resp = packages::route(
        "PUT",
        "/packages/aarch64/zlib/zlib-1.3.2-5-0123456789ab.tar.gz",
        &auth_headers(),
        b"package",
        &state,
    );
    assert_eq!(resp.status, 201);
    assert_eq!(
        state
            .storage
            .get("packages/aarch64/zlib/zlib-1.3.2-5-0123456789ab.tar.gz")
            .unwrap(),
        b"package"
    );

    let resp = packages::route(
        "PUT",
        "/sources/zlib/zlib-1.3.2-5-aarch64-src.tar.bz2",
        &auth_headers(),
        b"source",
        &state,
    );
    assert_eq!(resp.status, 201);

    let resp = packages::route(
        "PUT",
        "/metadata/aarch64/zlib/zlib-1.3.2-5-0123456789ab-fedcba987654.json",
        &auth_headers(),
        br#"{"metadata_sha256":"abc"}"#,
        &state,
    );
    assert_eq!(resp.status, 201);
    assert_eq!(
        state
            .storage
            .get("metadata/aarch64/zlib/zlib-1.3.2-5-0123456789ab-fedcba987654.json")
            .unwrap(),
        br#"{"metadata_sha256":"abc"}"#
    );

    let resp = put_index(&state, &sample_index());
    assert_eq!(resp.status, 201);
    assert_eq!(
        state.index.read().unwrap()[0].source_sha256,
        db::sha256_hex(b"source")
    );
}

#[test]
fn chunked_uploads_are_assembled_by_the_mirror() {
    let state = make_state();
    let upload_id = "test-upload";

    let resp = packages::route(
        "PUT",
        "/_uploads/test-upload/0",
        &auth_headers(),
        b"hello ",
        &state,
    );
    assert_eq!(resp.status, 201);

    let resp = packages::route(
        "PUT",
        "/_uploads/test-upload/1",
        &auth_headers(),
        b"world",
        &state,
    );
    assert_eq!(resp.status, 201);

    let body = br#"{"rel":"sources/zlib/zlib-1.3.2-5-aarch64-src.tar.bz2","chunks":2}"#;
    let resp = packages::route(
        "POST",
        "/_uploads/test-upload/complete",
        &auth_headers(),
        body,
        &state,
    );
    assert_eq!(resp.status, 201);
    assert_eq!(
        state.storage.get("sources/zlib/zlib-1.3.2-5-aarch64-src.tar.bz2"),
        Some(b"hello world".to_vec())
    );
    assert!(!state.upload_dir.join(upload_id).exists());
}

#[test]
fn writes_require_bearer_auth() {
    let state = make_state();
    let resp = packages::route(
        "PUT",
        "/packages/aarch64/zlib/zlib-1.3.2-5-0123456789ab.tar.gz",
        &headers(&[]),
        b"package",
        &state,
    );
    assert_eq!(resp.status, 401);

    let resp = packages::route("PUT", "/index.json", &headers(&[]), b"[]", &state);
    assert_eq!(resp.status, 401);

    let resp = packages::route(
        "PUT",
        "/index.json",
        &headers(&[("authorization", "Bearer wrong")]),
        b"[]",
        &state,
    );
    assert_eq!(resp.status, 401);

    let resp = packages::route("PUT", "/_uploads/u/0", &headers(&[]), b"chunk", &state);
    assert_eq!(resp.status, 401);
    assert!(!state.upload_dir.join("u").exists());

    let body = br#"{"rel":"sources/zlib/zlib-1.3.2-5-aarch64-src.tar.bz2","chunks":1}"#;
    let resp = packages::route("POST", "/_uploads/u/complete", &headers(&[]), body, &state);
    assert_eq!(resp.status, 401);
}

#[test]
fn path_traversal_is_rejected() {
    let state = make_state();
    for path in [
        "/packages/zlib/../../../etc/passwd",
        "/packages/../zlib/zlib-1.3.2-5.tar.gz",
        "/sources/zlib/zlib-1.3.2-5.tar.bz2",
    ] {
        let resp = packages::route("GET", path, &headers(&[]), b"", &state);
        assert_eq!(resp.status, 404, "GET {path}");
        let resp = packages::route("PUT", path, &auth_headers(), b"data", &state);
        assert_eq!(resp.status, 404, "PUT {path}");
    }
}

#[test]
fn r2_redirects_use_flat_object_paths() {
    let mut state = make_state();
    state.r2_public_url = Some("https://pub.example".to_string());

    let resp = packages::route(
        "GET",
        "/packages/aarch64/zlib/zlib-1.3.2-5-0123456789ab.tar.gz",
        &headers(&[]),
        b"",
        &state,
    );
    assert_eq!(resp.status, 302);
    let loc = resp
        .extra_headers
        .iter()
        .find(|(k, _)| *k == "Location")
        .map(|(_, v)| v.as_str());
    assert_eq!(
        loc,
        Some("https://pub.example/packages/aarch64/zlib/zlib-1.3.2-5-0123456789ab.tar.gz")
    );
}

#[test]
fn index_persists_to_storage_and_reloads() {
    let state = make_state();
    assert_eq!(put_index(&state, &sample_index()).status, 201);

    let loaded = packages::load_index(&state.storage).unwrap();
    assert_eq!(loaded[0].name, "zlib");
    assert_eq!(
        loaded[0].tarball,
        "packages/aarch64/zlib/zlib-1.3.2-5-0123456789ab.tar.gz"
    );
}

#[test]
fn invalid_index_is_rejected() {
    let state = make_state();
    let mut index = sample_index();
    index[0].tarball = "../zlib.tar.gz".to_string();
    let resp = put_index(&state, &index);
    assert_eq!(resp.status, 400);
}

#[test]
fn settings_page_requires_browser_session() {
    let state = make_state();
    let resp = packages::route("GET", "/auth/settings", &headers(&[]), b"", &state);
    assert_eq!(resp.status, 302);

    let cookie = make_browser_session(&state);
    let resp = packages::route(
        "GET",
        "/auth/settings",
        &headers(&[("cookie", &cookie)]),
        b"",
        &state,
    );
    assert_eq!(resp.status, 200);
    assert!(String::from_utf8_lossy(&body_bytes(resp)).contains(TEST_USER));
}

#[test]
fn create_token_returns_usable_api_token() {
    let state = make_state();
    let cookie = make_browser_session(&state);
    let resp = packages::route(
        "POST",
        "/auth/tokens",
        &headers(&[("cookie", &cookie)]),
        br#"{"name":"ci","expires_days":7}"#,
        &state,
    );
    assert_eq!(resp.status, 200);
    let token = body_json(&resp)["token"].as_str().unwrap().to_string();
    let resp = packages::route(
        "PUT",
        "/index.json",
        &headers(&[("authorization", &format!("Bearer {token}"))]),
        serde_json::to_vec(&sample_index()).unwrap().as_slice(),
        &state,
    );
    assert_eq!(resp.status, 201);
}

#[test]
fn static_serves_assets_with_content_type() {
    let state = make_state();
    let resp = packages::route("GET", "/static/css/index.css", &headers(&[]), b"", &state);
    assert_eq!(resp.status, 200);
    assert_eq!(resp.content_type, "text/css");
}

#[test]
fn static_rejects_path_traversal() {
    let state = make_state();
    for path in ["/static/../Cargo.toml", "/static/css/../../Cargo.toml"] {
        let resp = packages::route("GET", path, &headers(&[]), b"", &state);
        assert_eq!(resp.status, 404, "{path}");
    }
}

// Published package objects are named by artifact key (payload) and by
// artifact and proof key (metadata, proof).
const ARTIFACT_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const PROOF_KEY: &str = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
const PACKAGE: &str = "packages/aarch64/zlib/zlib-1.3.2-5-0123456789ab.tar.gz";
const METADATA: &str = "metadata/aarch64/zlib/zlib-1.3.2-5-0123456789ab-fedcba987654.json";
const PROOF: &str = "proofs/aarch64/zlib/zlib-1.3.2-5-0123456789ab-fedcba987654.json";
const SOURCE: &str = "sources/zlib/zlib-1.3.2-5-aarch64-src.tar.bz2";

/// Names in `dir`, so tests can assert no temp file was left behind.
fn dir_entries(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

#[test]
fn fs_storage_round_trips_objects() {
    let tmp = TempDir::new();
    let storage = s3::Storage::fs(tmp.path());

    assert_eq!(storage.get(PACKAGE), None);
    assert_eq!(storage.object_size(PACKAGE), None);

    storage
        .put(PACKAGE, b"first".to_vec(), "application/octet-stream")
        .unwrap();
    assert_eq!(storage.get(PACKAGE), Some(b"first".to_vec()));
    assert_eq!(storage.object_size(PACKAGE), Some(5));
    assert_eq!(std::fs::read(tmp.path().join(PACKAGE)).unwrap(), b"first");

    storage
        .put(PACKAGE, b"replaced".to_vec(), "application/octet-stream")
        .unwrap();
    assert_eq!(storage.get(PACKAGE), Some(b"replaced".to_vec()));

    let staged = tmp.path().join("staged");
    std::fs::write(&staged, b"from a file").unwrap();
    storage.put_file(SOURCE, &staged, "application/octet-stream").unwrap();
    assert_eq!(storage.get(SOURCE), Some(b"from a file".to_vec()));
    assert!(staged.exists(), "put_file copies, leaving the staged file");

    // Only the final names remain next to each object: temp files were renamed away.
    assert_eq!(
        dir_entries(&tmp.path().join("packages/aarch64/zlib")),
        ["zlib-1.3.2-5-0123456789ab.tar.gz"]
    );
    assert_eq!(
        dir_entries(&tmp.path().join("sources/zlib")),
        ["zlib-1.3.2-5-aarch64-src.tar.bz2"]
    );
}

#[test]
fn fs_storage_rejects_keys_outside_its_root() {
    let tmp = TempDir::new();
    let root = tmp.path().join("root");
    let storage = s3::Storage::fs(&root);
    for key in ["../escape", "/abs/path", "a/../../escape", "a//b", ".uploads/x", ""] {
        assert!(
            storage.put(key, b"x".to_vec(), "").is_err(),
            "put {key:?} must fail"
        );
        assert_eq!(storage.get(key), None, "get {key:?}");
    }
    assert!(!tmp.path().join("escape").exists());
    assert!(!Path::new("/abs/path").exists());
}

#[test]
fn fs_failed_write_leaves_no_partial_object() {
    let tmp = TempDir::new();
    let storage = s3::Storage::fs(tmp.path());
    let missing = tmp.path().join("no-such-staged-file");

    assert!(storage.put_file(PACKAGE, &missing, "").is_err());
    assert_eq!(storage.get(PACKAGE), None);
    assert!(dir_entries(&tmp.path().join("packages/aarch64/zlib")).is_empty());

    // A failed replacement keeps the previous object intact.
    storage.put(PACKAGE, b"old".to_vec(), "").unwrap();
    assert!(storage.put_file(PACKAGE, &missing, "").is_err());
    assert_eq!(storage.get(PACKAGE), Some(b"old".to_vec()));
    assert_eq!(
        dir_entries(&tmp.path().join("packages/aarch64/zlib")),
        ["zlib-1.3.2-5-0123456789ab.tar.gz"]
    );
}

#[test]
fn local_mode_accepts_unauthenticated_writes_and_streams_reads() {
    let state = make_local_state();
    let no_auth = headers(&[]);

    for (path, body) in [
        (PACKAGE, &b"package"[..]),
        (SOURCE, &b"source"[..]),
        (METADATA, &br#"{"metadata_sha256":"abc"}"#[..]),
    ] {
        let resp = packages::route("PUT", &format!("/{path}"), &no_auth, body, &state);
        assert_eq!(resp.status, 201, "PUT {path}");
        assert_eq!(std::fs::read(state.tmp.path().join("data").join(path)).unwrap(), body);
    }
    let index = serde_json::to_vec(&sample_index()).unwrap();
    let resp = packages::route("PUT", "/index.json", &no_auth, &index, &state);
    assert_eq!(resp.status, 201);

    let resp = get(&state, &format!("/{PACKAGE}"));
    assert_eq!(resp.status, 200);
    assert_eq!(resp.content_type, "application/octet-stream");
    assert!(matches!(resp.body, packages::Body::File { length: 7, .. }));
    assert_eq!(body_bytes(resp), b"package");

    let resp = get(&state, &format!("/{METADATA}"));
    assert_eq!(resp.content_type, "application/json");
    assert_eq!(body_bytes(resp), br#"{"metadata_sha256":"abc"}"#);

    assert_eq!(body_bytes(get(&state, &format!("/{SOURCE}"))), b"source");
    assert_eq!(get(&state, "/packages/aarch64/zlib/zlib-9-9.tar.gz").status, 404);

    let resp = get(&state, "/index.json");
    assert_eq!(
        resp.extra_headers,
        vec![("Cache-Control", "no-store".to_string())]
    );
    assert_eq!(body_json(&resp)[0]["name"], "zlib");

    // The index is persisted to the data dir, where the next start reloads it.
    let reloaded = packages::load_index(&s3::Storage::fs(state.tmp.path().join("data"))).unwrap();
    assert_eq!(reloaded, sample_index());
}

#[test]
fn local_mode_assembles_unauthenticated_chunked_uploads() {
    let state = make_local_state();
    let no_auth = headers(&[]);
    for (n, chunk) in [&b"hello "[..], &b"world"[..]].into_iter().enumerate() {
        let resp = packages::route("PUT", &format!("/_uploads/up/{n}"), &no_auth, chunk, &state);
        assert_eq!(resp.status, 201);
    }
    let body = format!(r#"{{"rel":"{SOURCE}","chunks":2}}"#);
    let resp = packages::route("POST", "/_uploads/up/complete", &no_auth, body.as_bytes(), &state);
    assert_eq!(resp.status, 201);
    assert_eq!(body_bytes(get(&state, &format!("/{SOURCE}"))), b"hello world");
    assert!(!state.upload_dir.join("up").exists());
}

#[test]
fn local_mode_incomplete_chunked_upload_publishes_nothing() {
    let state = make_local_state();
    let no_auth = headers(&[]);
    let resp = packages::route("PUT", "/_uploads/up/0", &no_auth, b"half", &state);
    assert_eq!(resp.status, 201);

    let body = format!(r#"{{"rel":"{PACKAGE}","chunks":2}}"#);
    let resp = packages::route("POST", "/_uploads/up/complete", &no_auth, body.as_bytes(), &state);
    assert_eq!(resp.status, 400);
    assert_eq!(get(&state, &format!("/{PACKAGE}")).status, 404);
    assert!(!state.tmp.path().join("data/packages").exists());
}

#[test]
fn local_mode_has_no_auth_routes_but_keeps_the_index_page() {
    let state = make_local_state();
    for path in ["/auth", "/auth?session=x", "/auth/settings", "/auth/poll?id=x", "/auth/logout"] {
        assert_eq!(get(&state, path).status, 404, "GET {path}");
    }
    for path in ["/auth/register/options", "/auth/authenticate/options", "/auth/tokens"] {
        let resp = packages::route("POST", path, &headers(&[]), b"{}", &state);
        assert_eq!(resp.status, 404, "POST {path}");
    }

    let resp = get(&state, "/");
    assert_eq!(resp.status, 200);
    let html = String::from_utf8(body_bytes(resp)).unwrap();
    assert!(html.contains("Laputa Packages"));
    assert!(!html.contains("/auth"), "no sign-in link without auth routes");
}

#[test]
fn production_mode_keeps_auth_routes() {
    let state = make_state();
    assert_eq!(get(&state, "/auth").status, 200);
    assert_eq!(get(&state, "/auth/settings").status, 302);
    let html = String::from_utf8(body_bytes(get(&state, "/"))).unwrap();
    assert!(html.contains("sign in"));
}

#[test]
fn sources_are_served_by_sha256_from_the_source_cache() {
    let state = make_local_state();
    let cache = state.tmp.path().join("sources/sha256");
    let hash = db::sha256_hex(b"upstream tarball");
    std::fs::write(cache.join(&hash), b"upstream tarball").unwrap();

    let resp = get(&state, &format!("/sources/sha256/{hash}"));
    assert_eq!(resp.status, 200);
    assert_eq!(resp.content_type, "application/octet-stream");
    assert_eq!(body_bytes(resp), b"upstream tarball");

    let missing = db::sha256_hex(b"never fetched");
    assert_eq!(get(&state, &format!("/sources/sha256/{missing}")).status, 404);

    // A directory where a file should be is not an object.
    std::fs::create_dir(cache.join(&missing)).unwrap();
    assert_eq!(get(&state, &format!("/sources/sha256/{missing}")).status, 404);

    // A sibling file outside sha256/ must stay unreachable.
    std::fs::write(state.tmp.path().join("secret"), b"secret").unwrap();
    for path in [
        format!("/sources/sha256/{}", hash.to_uppercase()),
        format!("/sources/sha256/{}", &hash[..63]),
        format!("/sources/sha256/{hash}0"),
        format!("/sources/sha256/{hash}.tar.gz"),
        format!("/sources/sha256/{hash}/"),
        "/sources/sha256/".to_string(),
        "/sources/sha256/../../secret".to_string(),
        "/sources/sha256/%2e%2e/%2e%2e/secret".to_string(),
        "/sources/sha256/../sha256/../../secret".to_string(),
    ] {
        assert_eq!(get(&state, &path).status, 404, "GET {path}");
    }
}

#[test]
fn source_cache_is_never_written_over_http() {
    let state = make_local_state();
    let hash = db::sha256_hex(b"forged");
    for method in ["PUT", "POST"] {
        let resp = packages::route(
            method,
            &format!("/sources/sha256/{hash}"),
            &headers(&[]),
            b"forged",
            &state,
        );
        assert_eq!(resp.status, 404, "{method}");
    }
    assert!(dir_entries(&state.tmp.path().join("sources/sha256")).is_empty());
    assert!(!state.tmp.path().join("data/sources").exists());
}

#[test]
fn production_mode_has_no_source_cache_route() {
    let state = make_state();
    let hash = db::sha256_hex(b"x");
    assert_eq!(get(&state, &format!("/sources/sha256/{hash}")).status, 404);
}

/// Sends one raw HTTP/1.1 GET and returns the response head and body.
fn http_get(addr: std::net::SocketAddr, path: &str) -> (String, Vec<u8>) {
    let mut stream = std::net::TcpStream::connect(addr).unwrap();
    write!(stream, "GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").unwrap();
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).unwrap();
    let split = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
    let head = String::from_utf8(raw[..split].to_vec()).unwrap().to_ascii_lowercase();
    (head, raw[split + 4..].to_vec())
}

#[test]
fn local_mode_streams_large_files_with_content_length() {
    let mirror = make_local_state();
    // Above tiny_http's 32 KiB default chunking threshold.
    let package: Vec<u8> = (0..100_000u32).map(|i| i as u8).collect();
    mirror.storage.put(PACKAGE, package.clone(), "").unwrap();
    let hash = db::sha256_hex(&package);
    std::fs::write(mirror.tmp.path().join("sources/sha256").join(&hash), &package).unwrap();

    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let addr = server.server_addr().to_ip().unwrap();
    let TestMirror { state, tmp: _tmp } = mirror;
    // The serving thread runs until the test process exits.
    std::thread::spawn(move || laputa_mirror::serve(server, Arc::new(state)));

    for path in [format!("/{PACKAGE}"), format!("/sources/sha256/{hash}")] {
        let (head, body) = http_get(addr, &path);
        assert!(head.starts_with("http/1.1 200"), "{path}: {head}");
        assert!(head.contains("content-length: 100000"), "{path}: {head}");
        assert!(!head.contains("transfer-encoding"), "{path}: {head}");
        assert!(head.contains("content-type: application/octet-stream"), "{path}: {head}");
        assert_eq!(body, package, "{path}");
    }
}

#[test]
fn local_mode_publishes_proof_receipts_as_json() {
    let state = make_local_state();
    let proof = "proofs/aarch64/zlib/zlib-1.3.2-5-0123456789ab-fedcba987654.json";
    let resp = packages::route("PUT", &format!("/{proof}"), &headers(&[]), br#"{"proof":1}"#, &state);
    assert_eq!(resp.status, 201);
    let resp = get(&state, &format!("/{proof}"));
    assert_eq!(resp.content_type, "application/json");
    assert_eq!(body_bytes(resp), br#"{"proof":1}"#);
    for bad in ["/proofs/aarch64/zlib/../../x.json", "/proofs/arm/zlib/zlib-1.json", "/proofs/aarch64/zlib/zlib-1.tar.gz"] {
        assert_eq!(packages::route("PUT", bad, &headers(&[]), b"{}", &state).status, 404, "{bad}");
    }
}

#[test]
fn if_none_match_star_refuses_to_replace_an_existing_object() {
    let state = make_local_state();
    let immutable = headers(&[("if-none-match", "*")]);
    let path = format!("/{PACKAGE}");
    assert_eq!(packages::route("PUT", &path, &immutable, b"first", &state).status, 201);
    assert_eq!(packages::route("PUT", &path, &immutable, b"second", &state).status, 412);
    assert_eq!(body_bytes(get(&state, &path)), b"first");
    // Without the precondition a write replaces the object.
    assert_eq!(packages::route("PUT", &path, &headers(&[]), b"third", &state).status, 201);
    assert_eq!(body_bytes(get(&state, &path)), b"third");
}

#[test]
fn index_rewrite_keeps_fields_the_mirror_does_not_interpret() {
    let state = make_local_state();
    let mut index = serde_json::to_value(sample_index()).unwrap();
    index[0]["recipe_sha256"] = serde_json::json!("abc123");
    let body = serde_json::to_vec(&index).unwrap();
    assert_eq!(packages::route("PUT", "/index.json", &headers(&[]), &body, &state).status, 201);
    let stored = body_json(&get(&state, "/index.json"));
    assert_eq!(stored[0]["recipe_sha256"], "abc123");
    assert_eq!(stored[0]["artifact_key"], ARTIFACT_KEY);
    assert_eq!(stored[0]["proof"], PROOF);
}

#[test]
fn writes_need_content_addressed_object_names() {
    let state = make_local_state();
    let no_auth = headers(&[]);
    for path in [
        // Legacy names, without the artifact (and proof) key prefixes.
        "/packages/aarch64/zlib/zlib-1.3.2-5.tar.gz",
        "/packages/zlib/zlib-1.3.2-5-0123456789ab.tar.gz",
        "/metadata/aarch64/zlib/zlib-1.3.2-5.json",
        "/proofs/aarch64/zlib/zlib-1.3.2-5-0123456789ab.json",
        // Malformed key prefixes or no ver-rel.
        "/packages/aarch64/zlib/zlib-1.3.2-5-0123456789AB.tar.gz",
        "/packages/aarch64/zlib/zlib-1.3.2-5-0123456789a.tar.gz",
        "/packages/aarch64/zlib/zlib-5-0123456789ab.tar.gz",
        "/metadata/aarch64/zlib/zlib-1.3.2-5-0123456789ab-fedcba98765.json",
    ] {
        assert_eq!(packages::route("PUT", path, &no_auth, b"x", &state).status, 404, "PUT {path}");
    }

    let body = r#"{"rel":"packages/aarch64/zlib/zlib-1.3.2-5.tar.gz","chunks":1}"#;
    assert_eq!(packages::route("PUT", "/_uploads/up/0", &no_auth, b"x", &state).status, 201);
    let resp = packages::route("POST", "/_uploads/up/complete", &no_auth, body.as_bytes(), &state);
    assert_eq!(resp.status, 400);
}

#[test]
fn legacy_object_names_stay_readable() {
    let state = make_local_state();
    let legacy = "packages/aarch64/zlib/zlib-1.3.2-5.tar.gz";
    state.storage.put(legacy, b"legacy".to_vec(), "").unwrap();
    assert_eq!(body_bytes(get(&state, &format!("/{legacy}"))), b"legacy");
}

#[test]
fn index_rows_must_name_their_artifact_key_objects() {
    let state = make_state();
    let other_key = "a".repeat(64);
    let cases: [(&str, Box<dyn Fn(&mut packages::RemotePackage)>); 6] = [
        ("tarball", Box::new(|row| row.tarball = "packages/aarch64/zlib/zlib-1.3.2-5.tar.gz".into())),
        ("metadata", Box::new(|row| row.metadata = "metadata/aarch64/zlib/zlib-1.3.2-5.json".into())),
        ("proof", Box::new(|row| row.proof = String::new())),
        ("artifact key", Box::new(move |row| row.artifact_key = other_key.clone())),
        ("short key", Box::new(|row| row.artifact_key = "0123456789ab".into())),
        ("proof key", Box::new(|row| row.proof_key = String::new())),
    ];
    for (label, mutate) in cases {
        let mut index = sample_index();
        mutate(&mut index[0]);
        assert_eq!(put_index(&state, &index).status, 400, "{label}");
    }

    // A legacy row without an artifact key keeps its legacy object names.
    let mut legacy = sample_index();
    legacy[0].artifact_key = String::new();
    legacy[0].proof_key = String::new();
    legacy[0].proof = String::new();
    legacy[0].tarball = "packages/aarch64/zlib/zlib-1.3.2-5.tar.gz".into();
    legacy[0].metadata = "metadata/aarch64/zlib/zlib-1.3.2-5.json".into();
    assert_eq!(put_index(&state, &legacy).status, 201);
}

#[test]
fn a_rebuild_under_the_same_release_replaces_the_row_not_the_objects() {
    let state = make_local_state();
    let immutable = headers(&[("if-none-match", "*")]);
    for path in [PACKAGE, METADATA, PROOF] {
        assert_eq!(packages::route("PUT", &format!("/{path}"), &immutable, b"first", &state).status, 201);
    }
    assert_eq!(put_index(&state, &sample_index()).status, 201);

    let rebuilt_key = "b".repeat(64);
    let rebuilt_package = "packages/aarch64/zlib/zlib-1.3.2-5-bbbbbbbbbbbb.tar.gz";
    let rebuilt_metadata = "metadata/aarch64/zlib/zlib-1.3.2-5-bbbbbbbbbbbb-fedcba987654.json";
    let rebuilt_proof = "proofs/aarch64/zlib/zlib-1.3.2-5-bbbbbbbbbbbb-fedcba987654.json";
    for path in [rebuilt_package, rebuilt_metadata, rebuilt_proof] {
        assert_eq!(packages::route("PUT", &format!("/{path}"), &immutable, b"second", &state).status, 201);
    }
    let mut rebuilt = sample_index();
    rebuilt[0].artifact_key = rebuilt_key.clone();
    rebuilt[0].tarball = rebuilt_package.into();
    rebuilt[0].metadata = rebuilt_metadata.into();
    rebuilt[0].proof = rebuilt_proof.into();
    assert_eq!(put_index(&state, &rebuilt).status, 201);

    let stored = body_json(&get(&state, "/index.json"));
    assert_eq!(stored[0]["artifact_key"], rebuilt_key);
    assert_eq!(stored[0]["tarball"], rebuilt_package);
    assert_eq!(body_bytes(get(&state, &format!("/{PACKAGE}"))), b"first");
    assert_eq!(body_bytes(get(&state, &format!("/{rebuilt_package}"))), b"second");
}

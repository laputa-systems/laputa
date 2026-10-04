use std::collections::HashMap;
use std::fs::File;
use std::io::{BufReader, BufWriter, Write};

use serde::{Deserialize, Serialize};

use crate::auth;
use crate::s3;
use crate::{Access, AppState, AuthState};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct RemotePackage {
    #[serde(default = "default_arch")]
    pub arch: String,
    pub name: String,
    pub ver: String,
    pub rel: String,
    pub deps: Vec<String>,
    pub mkdeps_host: Vec<String>,
    pub mkdeps_target: Vec<String>,
    pub sha256: String,
    pub size: u64,
    pub tarball: String,
    #[serde(default)]
    pub metadata: String,
    pub source_sha256: String,
    pub metapackage: bool,
    /// The artifact key that names this row's payload object. Empty only in
    /// legacy rows published before content-addressed object names.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub artifact_key: String,
    /// The proof key that, with the artifact key, names the metadata and
    /// proof objects.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub proof_key: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub proof: String,
    /// Fields the mirror does not interpret (recipe, executor and proof
    /// digests) survive the validate-and-rewrite of `index.json` unchanged.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

fn default_arch() -> String {
    "aarch64".to_string()
}

pub struct Response {
    pub status: u16,
    pub content_type: &'static str,
    pub body: Body,
    pub extra_headers: Vec<(&'static str, String)>,
}

pub enum Body {
    Bytes(Vec<u8>),
    /// Streamed from disk with its length known up front.
    File { file: File, length: u64 },
}

impl Response {
    pub fn json(status: u16, body: &str) -> Self {
        Self {
            status,
            content_type: "application/json",
            body: Body::Bytes(body.as_bytes().to_vec()),
            extra_headers: vec![],
        }
    }

    pub fn json_bytes(status: u16, body: Vec<u8>) -> Self {
        Self {
            status,
            content_type: "application/json",
            body: Body::Bytes(body),
            extra_headers: vec![],
        }
    }

    pub fn html(body: Vec<u8>) -> Self {
        Self {
            status: 200,
            content_type: "text/html; charset=utf-8",
            body: Body::Bytes(body),
            extra_headers: vec![],
        }
    }

    pub fn octet(body: Vec<u8>) -> Self {
        Self {
            status: 200,
            content_type: "application/octet-stream",
            body: Body::Bytes(body),
            extra_headers: vec![],
        }
    }

    pub fn redirect(location: &str) -> Self {
        Self {
            status: 302,
            content_type: "text/plain",
            body: Body::Bytes(vec![]),
            extra_headers: vec![("Location", location.to_string())],
        }
    }

    pub fn not_found() -> Self {
        Self {
            status: 404,
            content_type: "text/plain",
            body: Body::Bytes(b"Not Found".to_vec()),
            extra_headers: vec![],
        }
    }

    pub fn unauthorized() -> Self {
        Self::json(401, r#"{"error":"unauthorized"}"#)
    }

    pub fn bad_request(msg: &str) -> Self {
        Self::json(400, &format!(r#"{{"error":"{}"}}"#, json_escape(msg)))
    }

    pub fn error(msg: &str) -> Self {
        Self::json(500, &format!(r#"{{"error":"{}"}}"#, json_escape(msg)))
    }

    pub fn with_set_cookie(mut self, value: String) -> Self {
        self.extra_headers.push(("Set-Cookie", value));
        self
    }
}

pub fn load_index(storage: &s3::Storage) -> Option<Vec<RemotePackage>> {
    let bytes = storage.get("index.json")?;
    serde_json::from_slice(&bytes).ok()
}

pub fn route(
    method: &str,
    path: &str,
    headers: &HashMap<String, String>,
    body: &[u8],
    state: &AppState,
) -> Response {
    if method == "GET"
        && let Some(asset) = path.strip_prefix("/static/")
    {
        return static_asset(asset);
    }

    if path == "/auth" || path.starts_with("/auth?") || path.starts_with("/auth/") {
        return match &state.access {
            Access::Authenticated(auth) => auth_route(method, path, headers, body, auth),
            Access::Open => Response::not_found(),
        };
    }

    match method {
        "GET" => get(path, headers, state),
        "PUT" => put(path, headers, body, state),
        "POST" if path.starts_with("/_uploads/") && path.ends_with("/complete") => {
            complete_chunked_upload(path, headers, body, state)
        }
        _ => Response::not_found(),
    }
}

/// The passkey, browser-session and token routes, which exist only in production.
fn auth_route(
    method: &str,
    path: &str,
    headers: &HashMap<String, String>,
    body: &[u8],
    auth: &AuthState,
) -> Response {
    use crate::webauthn_handlers as wh;
    match method {
        "GET" if path == "/auth" || path.starts_with("/auth?") => wh::auth_page(),
        "GET" if path.starts_with("/auth/poll") => {
            let query = path.find('?').map(|i| &path[i + 1..]).unwrap_or("");
            wh::poll_session(query, auth)
        }
        "GET" if path == "/auth/logout" => wh::logout(headers, auth),
        "GET" if path == "/auth/settings" => wh::settings_page(headers, auth),
        "POST" => match path {
            "/auth/register/options" => wh::register_options(body, auth),
            "/auth/register/verify" => wh::register_verify(body, auth),
            "/auth/authenticate/options" => wh::authenticate_options(auth),
            "/auth/authenticate/verify" => wh::authenticate_verify(body, auth),
            "/auth/tokens" => wh::create_token_api(body, headers, auth),
            "/auth/tokens/delete" => wh::delete_token_api(body, headers, auth),
            _ => Response::not_found(),
        },
        _ => Response::not_found(),
    }
}

/// Whether this request may write objects, the index, or upload chunks.
fn may_write(headers: &HashMap<String, String>, state: &AppState) -> bool {
    match &state.access {
        Access::Authenticated(auth) => auth::authenticated(headers, auth),
        Access::Open => true,
    }
}

/// Serves a file from `static/`, which is read from disk relative to the working directory.
fn static_asset(asset: &str) -> Response {
    // Only plain nested names: no `..`, no absolute or empty segments.
    let plain = asset
        .split('/')
        .all(|seg| !seg.is_empty() && seg != "." && seg != ".." && !seg.contains('\\'));
    let content_type = match asset.rsplit_once('.') {
        Some((_, "js")) => "application/javascript",
        Some((_, "css")) => "text/css",
        _ => return Response::not_found(),
    };
    match plain.then(|| std::fs::read(format!("static/{asset}"))) {
        Some(Ok(body)) => Response {
            status: 200,
            content_type,
            body: Body::Bytes(body),
            extra_headers: vec![],
        },
        _ => Response::not_found(),
    }
}

pub(crate) fn session_cookie(headers: &HashMap<String, String>) -> Option<String> {
    headers.get("cookie").and_then(|h| {
        h.split(';').find_map(|kv| {
            let (k, v) = kv.trim().split_once('=')?;
            if k.trim() == "laputa_mirror_session" {
                Some(v.trim().to_string())
            } else {
                None
            }
        })
    })
}

fn get(path: &str, headers: &HashMap<String, String>, state: &AppState) -> Response {
    if path == "/" {
        return root_index(headers, state);
    }
    if path == "/health" {
        return Response::json(200, r#"{"status":"ok"}"#);
    }
    if path == "/index.json" {
        return get_index(state);
    }
    if let Some(hash) = cached_source_hash(path) {
        return get_cached_source(hash, state);
    }
    if let Some(key) = object_key(path) {
        return get_object(&key, state);
    }
    Response::not_found()
}

fn put(path: &str, headers: &HashMap<String, String>, body: &[u8], state: &AppState) -> Response {
    if !may_write(headers, state) {
        return Response::unauthorized();
    }

    if path == "/index.json" {
        return put_index(body, state);
    }

    if path.starts_with("/_uploads/") {
        return put_upload_chunk(path, body, state);
    }

    let Some(key) = publishable_object_key(path) else {
        return Response::not_found();
    };
    // `If-None-Match: *` publishes an immutable object only if it is absent.
    if headers.get("if-none-match").is_some_and(|value| value.trim() == "*")
        && state.storage.object_size(&key).is_some()
    {
        return Response::json(412, r#"{"error":"object already exists"}"#);
    }

    match state.storage.put(&key, body.to_vec(), content_type_for(&key)) {
        Ok(()) => Response::json(201, r#"{"ok":true}"#),
        Err(e) => {
            tracing::error!("object upload failed for {key}: {e}");
            Response::error("upload failed")
        }
    }
}

fn put_upload_chunk(path: &str, body: &[u8], state: &AppState) -> Response {
    let Some((upload_id, chunk_index)) = parse_chunk_path(path) else {
        return Response::not_found();
    };
    let dir = state.upload_dir.join(upload_id);
    if let Err(e) = std::fs::create_dir_all(&dir) {
        tracing::error!("chunk upload mkdir failed: {e}");
        return Response::error("chunk upload failed");
    }
    let chunk = dir.join(format!("{chunk_index:08}"));
    match std::fs::write(&chunk, body) {
        Ok(()) => Response::json(201, r#"{"ok":true}"#),
        Err(e) => {
            tracing::error!("chunk upload write failed: {e}");
            Response::error("chunk upload failed")
        }
    }
}

fn complete_chunked_upload(
    path: &str,
    headers: &HashMap<String, String>,
    body: &[u8],
    state: &AppState,
) -> Response {
    if !may_write(headers, state) {
        return Response::unauthorized();
    }

    let Some(upload_id) = path
        .strip_prefix("/_uploads/")
        .and_then(|p| p.strip_suffix("/complete"))
        .filter(|id| valid_upload_id(id))
    else {
        return Response::not_found();
    };

    #[derive(Deserialize)]
    struct CompleteRequest {
        rel: String,
        chunks: usize,
    }

    let req: CompleteRequest = match serde_json::from_slice(body) {
        Ok(req) => req,
        Err(_) => return Response::bad_request("invalid upload completion json"),
    };
    if req.chunks == 0 {
        return Response::bad_request("chunk count must be positive");
    }

    let rel_path = format!("/{}", req.rel);
    let Some(key) = publishable_object_key(&rel_path) else {
        return Response::bad_request("invalid upload path");
    };

    let dir = state.upload_dir.join(upload_id);
    let assembled = dir.join("assembled-object");
    let out = match File::create(&assembled) {
        Ok(file) => file,
        Err(e) => {
            tracing::error!("chunk assembly create failed: {e}");
            return Response::error("chunk assembly failed");
        }
    };
    let mut out = BufWriter::new(out);
    for index in 0..req.chunks {
        let chunk = dir.join(format!("{index:08}"));
        let chunk_file = match File::open(&chunk) {
            Ok(file) => file,
            Err(_) => return Response::bad_request("missing upload chunk"),
        };
        let mut chunk_file = BufReader::new(chunk_file);
        if let Err(e) = std::io::copy(&mut chunk_file, &mut out) {
            tracing::error!("chunk assembly copy failed: {e}");
            return Response::error("chunk assembly failed");
        }
    }
    if let Err(e) = out.flush() {
        tracing::error!("chunk assembly flush failed: {e}");
        return Response::error("chunk assembly failed");
    }
    drop(out);

    match state.storage.put_file(&key, &assembled, content_type_for(&key)) {
        Ok(()) => {
            let _ = std::fs::remove_dir_all(&dir);
            Response::json(201, r#"{"ok":true}"#)
        }
        Err(e) => {
            tracing::error!("chunked object upload failed for {key}: {e}");
            Response::error("chunked upload failed")
        }
    }
}

fn parse_chunk_path(path: &str) -> Option<(&str, usize)> {
    let rest = path.strip_prefix("/_uploads/")?;
    let (upload_id, chunk_text) = rest.split_once('/')?;
    if !valid_upload_id(upload_id) || chunk_text.contains('/') {
        return None;
    }
    let chunk_index = chunk_text.parse().ok()?;
    Some((upload_id, chunk_index))
}

fn valid_upload_id(upload_id: &str) -> bool {
    !upload_id.is_empty()
        && upload_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn get_index(state: &AppState) -> Response {
    let index = state.index.read().unwrap();
    let json = serde_json::to_vec_pretty(&*index).unwrap_or_else(|_| b"[]".to_vec());
    let mut response = Response::json_bytes(200, json);
    response
        .extra_headers
        .push(("Cache-Control", "no-store".to_string()));
    response
}

fn put_index(body: &[u8], state: &AppState) -> Response {
    let mut index: Vec<RemotePackage> = match serde_json::from_slice(body) {
        Ok(index) => index,
        Err(_) => return Response::bad_request("invalid index json"),
    };

    if let Err(msg) = validate_index(&index) {
        return Response::bad_request(&msg);
    }

    index.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.arch.cmp(&b.arch)));
    let bytes = match serde_json::to_vec_pretty(&index) {
        Ok(bytes) => bytes,
        Err(e) => {
            tracing::error!("index encode failed: {e}");
            return Response::error("index encode failed");
        }
    };

    let _index_guard = state.index_lock.lock().unwrap();
    if let Err(e) = state.storage.put("index.json", bytes, "application/json") {
        tracing::error!("index upload failed: {e}");
        return Response::error("index upload failed");
    }
    *state.index.write().unwrap() = index;
    Response::json(201, r#"{"ok":true}"#)
}

fn get_object(key: &str, state: &AppState) -> Response {
    if let Some(base) = &state.r2_public_url {
        return Response::redirect(&format!("{base}/{key}"));
    }
    if let Some(url) = state.storage.presign_get(key, 300) {
        return Response::redirect(&url);
    }
    if let s3::Storage::Fs(store) = &state.storage {
        return file_response(store.open(key), content_type_for(key));
    }
    match state.storage.get(key) {
        Some(bytes) => Response {
            status: 200,
            content_type: content_type_for(key),
            body: Body::Bytes(bytes),
            extra_headers: vec![],
        },
        None => Response::not_found(),
    }
}

/// `/sources/sha256/<64 lowercase hex>`, the content-addressed source route. Other
/// names under `/sources/sha256/` fall through to the per-package source route, so
/// a malformed hash is a 404 like any other unknown path.
fn cached_source_hash(path: &str) -> Option<&str> {
    let hash = path.strip_prefix("/sources/sha256/")?;
    let lowercase_hex = hash.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
    (hash.len() == 64 && lowercase_hex).then_some(hash)
}

/// Serves `<source_cache>/sha256/<hash>`, the layout PM's source cache uses.
fn get_cached_source(hash: &str, state: &AppState) -> Response {
    let Some(dir) = &state.source_cache else {
        return Response::not_found();
    };
    let path = dir.join("sha256").join(hash);
    file_response(s3::open_file(&path), "application/octet-stream")
}

fn file_response(
    opened: Result<Option<(File, u64)>, String>,
    content_type: &'static str,
) -> Response {
    match opened {
        Ok(Some((file, length))) => Response {
            status: 200,
            content_type,
            body: Body::File { file, length },
            extra_headers: vec![],
        },
        Ok(None) => Response::not_found(),
        Err(e) => {
            tracing::error!("{e}");
            Response::error("read failed")
        }
    }
}

fn root_index(headers: &HashMap<String, String>, state: &AppState) -> Response {
    let userbar = match &state.access {
        Access::Authenticated(auth) => {
            let username = session_cookie(headers).and_then(|t| {
                auth.db
                    .lock()
                    .unwrap()
                    .verify_browser_session(&t)
                    .ok()
                    .flatten()
            });
            match &username {
                Some(name) => format!(
                    "<span class=userbar>{} <a href=\"/auth/settings\">(settings)</a> &middot; <a href=\"/auth/logout\">sign out</a></span>",
                    html_escape(name),
                ),
                None => "<a href=\"/auth\" class=signin>sign in</a>".to_string(),
            }
        }
        Access::Open => String::new(),
    };

    let mut packages = state.index.read().unwrap().clone();
    packages.sort_by(|a, b| a.name.cmp(&b.name));

    let mut html = format!(
        "<!doctype html>\
        <html><head><meta charset=utf-8><meta name=viewport content=\"width=device-width\">\
        <title>Laputa Packages</title><link rel=\"stylesheet\" href=\"/static/css/index.css\">\
        </head><body>\
        <header><h1>Laputa Packages</h1>{userbar}</header>",
    );

    if packages.is_empty() {
        html.push_str("<p class=empty>No packages indexed yet.</p>");
    } else {
        html.push_str(&format!(
            "<p class=count>{} packages</p>\
            <table><tr><th>Package</th><th>Arch</th><th>Binary</th><th>Source</th><th>Dependencies</th><th>Host build deps</th><th>Target build deps</th></tr>",
            packages.len()
        ));

        for pkg in &packages {
            let binary = if pkg.metapackage || pkg.tarball.is_empty() {
                "<span class=dep>metapackage</span>".to_string()
            } else {
                format!(
                    "<a href=\"/{}\">{}-{}</a> <span class=dep>{}</span>",
                    html_attr(&pkg.tarball),
                    html_escape(&pkg.ver),
                    html_escape(&pkg.rel),
                    fmt_size(pkg.size),
                )
            };
            let source = if pkg.source_sha256.is_empty() {
                "<span class=dep>-</span>".to_string()
            } else {
                format!(
                    "<a href=\"/{}\">download</a>",
                    html_attr(&source_rel(pkg))
                )
            };
            html.push_str(&format!(
                "<tr><td><strong>{}</strong></td><td><span class=dep>{}</span></td><td>{binary}</td><td>{source}</td><td>{}</td><td>{}</td><td>{}</td></tr>",
                html_escape(&pkg.name),
                html_escape(&pkg.arch),
                deps_html(&pkg.deps),
                deps_html(&pkg.mkdeps_host),
                deps_html(&pkg.mkdeps_target),
            ));
        }

        html.push_str("</table>");
    }

    html.push_str("</body></html>");
    Response::html(html.into_bytes())
}

fn deps_html(deps: &[String]) -> String {
    if deps.is_empty() {
        return "<span class=dep>-</span>".to_string();
    }
    format!(
        "<span class=dep>{}</span>",
        deps.iter()
            .map(|d| html_escape(d))
            .collect::<Vec<_>>()
            .join(", ")
    )
}

fn source_rel(pkg: &RemotePackage) -> String {
    format!(
        "sources/{}/{}-{}-{}-{}-src.tar.bz2",
        pkg.name, pkg.name, pkg.ver, pkg.rel, pkg.arch
    )
}

fn package_key(path: &str) -> Option<String> {
    let parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    if parts.len() == 4 && parts[0] == "packages" {
        return validate_package_object_path(parts[1], parts[2], parts[3]);
    }
    if parts.len() == 3 && parts[0] == "packages" {
        return validate_object_path(parts[0], parts[1], parts[2], false);
    }
    None
}

fn source_key(path: &str) -> Option<String> {
    let parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    if parts.len() != 3 || parts[0] != "sources" {
        return None;
    }
    validate_object_path(parts[0], parts[1], parts[2], true)
}

fn metadata_key(path: &str) -> Option<String> {
    json_object_key("metadata", path)
}

fn proof_key(path: &str) -> Option<String> {
    json_object_key("proofs", path)
}

/// Every object path the mirror serves: packages, sources, metadata sidecars,
/// and proof receipts, including the legacy names of objects published before
/// content-addressed naming.
fn object_key(path: &str) -> Option<String> {
    package_key(path)
        .or_else(|| source_key(path))
        .or_else(|| metadata_key(path))
        .or_else(|| proof_key(path))
}

/// The object paths a write may create. Package payloads, metadata and
/// proofs are content-addressed (`<name>-<ver>-<rel>-<artifact12>.tar.gz`,
/// `<name>-<ver>-<rel>-<artifact12>-<proof12>.json`), so a rebuild under the
/// same ver-rel never overwrites a published object; only the index row moves.
fn publishable_object_key(path: &str) -> Option<String> {
    let key = object_key(path)?;
    let parts: Vec<&str> = key.split('/').collect();
    let content_addressed = match parts.as_slice() {
        ["packages", _, name, file] => file
            .strip_suffix(".tar.gz")
            .is_some_and(|stem| is_content_addressed(name, stem, 1)),
        ["metadata" | "proofs", _, name, file] => file
            .strip_suffix(".json")
            .is_some_and(|stem| is_content_addressed(name, stem, 2)),
        ["sources", ..] => true,
        _ => false,
    };
    content_addressed.then_some(key)
}

/// Whether `stem` is `<name>-<ver>-<rel>` followed by `keys` dash-separated
/// twelve-digit lowercase hex key prefixes.
fn is_content_addressed(name: &str, stem: &str, keys: usize) -> bool {
    let Some(mut rest) = stem.strip_prefix(name).and_then(|rest| rest.strip_prefix('-')) else {
        return false;
    };
    for _ in 0..keys {
        match rest.rsplit_once('-') {
            Some((head, prefix)) if valid_key_prefix(prefix) => rest = head,
            _ => return false,
        }
    }
    // At least `<ver>-<rel>` remains.
    rest.split_once('-')
        .is_some_and(|(ver, rel)| !ver.is_empty() && !rel.is_empty())
}

fn valid_key_prefix(value: &str) -> bool {
    value.len() == 12 && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn json_object_key(prefix: &str, path: &str) -> Option<String> {
    let parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    if parts.len() != 4 || parts[0] != prefix {
        return None;
    }
    validate_json_object_path(prefix, parts[1], parts[2], parts[3])
}

fn validate_object_path(prefix: &str, name: &str, file: &str, source: bool) -> Option<String> {
    if !valid_pkg_name(name) || !file.ends_with(if source { ".tar.bz2" } else { ".tar.gz" }) {
        return None;
    }
    if name.contains("..") || file.contains("..") || file.contains('/') || file.is_empty() {
        return None;
    }
    if !file.starts_with(&format!("{name}-")) {
        return None;
    }
    if source && !file.ends_with("-src.tar.bz2") {
        return None;
    }
    if source && !file.ends_with("-aarch64-src.tar.bz2") && !file.ends_with("-x86_64-src.tar.bz2") {
        return None;
    }
    Some(format!("{prefix}/{name}/{file}"))
}

fn validate_package_object_path(arch: &str, name: &str, file: &str) -> Option<String> {
    if !valid_arch(arch) || !valid_pkg_name(name) || !file.ends_with(".tar.gz") {
        return None;
    }
    if name.contains("..") || file.contains("..") || file.contains('/') || file.is_empty() {
        return None;
    }
    if !file.starts_with(&format!("{name}-")) {
        return None;
    }
    Some(format!("packages/{arch}/{name}/{file}"))
}

fn validate_json_object_path(prefix: &str, arch: &str, name: &str, file: &str) -> Option<String> {
    if !valid_arch(arch) || !valid_pkg_name(name) || !file.ends_with(".json") {
        return None;
    }
    if name.contains("..") || file.contains("..") || file.contains('/') || file.is_empty() {
        return None;
    }
    if !file.starts_with(&format!("{name}-")) {
        return None;
    }
    Some(format!("{prefix}/{arch}/{name}/{file}"))
}

fn valid_arch(arch: &str) -> bool {
    matches!(arch, "aarch64" | "x86_64")
}

fn validate_index(index: &[RemotePackage]) -> Result<(), String> {
    let mut seen = std::collections::HashSet::new();
    for pkg in index {
        if !valid_arch(&pkg.arch) {
            return Err(format!("invalid arch for {}: {}", pkg.name, pkg.arch));
        }
        if !valid_pkg_name(&pkg.name) {
            return Err(format!("invalid package name: {}", pkg.name));
        }
        if !seen.insert(format!("{}/{}", pkg.arch, pkg.name)) {
            return Err(format!("duplicate package: {}/{}", pkg.arch, pkg.name));
        }
        if !pkg.sha256.is_empty() && !valid_sha256(&pkg.sha256) {
            return Err(format!("invalid sha256 for {}", pkg.name));
        }
        if !pkg.source_sha256.is_empty() && !valid_sha256(&pkg.source_sha256) {
            return Err(format!("invalid source sha256 for {}", pkg.name));
        }
        if pkg.metapackage {
            if !pkg.tarball.is_empty() || pkg.size != 0 || !pkg.sha256.is_empty() {
                return Err(format!("invalid metapackage fields for {}", pkg.name));
            }
        }
        if !pkg.artifact_key.is_empty() {
            validate_content_addressed_row(pkg)?;
            continue;
        }
        // Legacy rows, published before artifact keys named objects.
        if !pkg.metapackage {
            if package_key(&format!("/{}", pkg.tarball)).is_none() {
                return Err(format!("invalid tarball path for {}", pkg.name));
            }
            if !tarball_matches_entry(pkg) {
                return Err(format!(
                    "tarball path does not match package arch/name for {}",
                    pkg.name
                ));
            }
        }
        if !pkg.metadata.is_empty() {
            if metadata_key(&format!("/{}", pkg.metadata)).is_none() {
                return Err(format!("invalid metadata path for {}", pkg.name));
            }
            if !metadata_matches_entry(pkg) {
                return Err(format!(
                    "metadata path does not match package arch/name for {}",
                    pkg.name
                ));
            }
        }
    }
    Ok(())
}

/// A row that carries an artifact key names exactly the content-addressed
/// objects of that key and its proof key.
fn validate_content_addressed_row(pkg: &RemotePackage) -> Result<(), String> {
    if !valid_lower_sha256(&pkg.artifact_key) || !valid_lower_sha256(&pkg.proof_key) {
        return Err(format!("invalid artifact or proof key for {}", pkg.name));
    }
    let stem = format!("{}-{}-{}-{}", pkg.name, pkg.ver, pkg.rel, &pkg.artifact_key[..12]);
    let json = format!("{}/{}/{stem}-{}.json", pkg.arch, pkg.name, &pkg.proof_key[..12]);
    if !pkg.metapackage && pkg.tarball != format!("packages/{}/{}/{stem}.tar.gz", pkg.arch, pkg.name) {
        return Err(format!("tarball path does not match the artifact key for {}", pkg.name));
    }
    if pkg.metadata != format!("metadata/{json}") {
        return Err(format!("metadata path does not match the artifact key for {}", pkg.name));
    }
    if pkg.proof != format!("proofs/{json}") {
        return Err(format!("proof path does not match the artifact key for {}", pkg.name));
    }
    // The names must also be writable objects (a ver or rel with `/` is not).
    let mut objects = vec![&pkg.metadata, &pkg.proof];
    if !pkg.metapackage {
        objects.push(&pkg.tarball);
    }
    for object in objects {
        if publishable_object_key(&format!("/{object}")).is_none() {
            return Err(format!("invalid object path {object} for {}", pkg.name));
        }
    }
    Ok(())
}

fn valid_lower_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn tarball_matches_entry(pkg: &RemotePackage) -> bool {
    let parts: Vec<&str> = pkg.tarball.split('/').collect();
    if parts.len() == 4 {
        return parts[0] == "packages" && parts[1] == pkg.arch && parts[2] == pkg.name;
    }
    parts.len() == 3 && parts[0] == "packages" && pkg.arch == "aarch64" && parts[1] == pkg.name
}

fn metadata_matches_entry(pkg: &RemotePackage) -> bool {
    let parts: Vec<&str> = pkg.metadata.split('/').collect();
    parts.len() == 4 && parts[0] == "metadata" && parts[1] == pkg.arch && parts[2] == pkg.name
}

fn valid_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit())
}

fn valid_pkg_name(name: &str) -> bool {
    !name.is_empty()
        && name.bytes().all(|b| {
            b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'.' || b == b'-' || b == b'_'
        })
        && name.as_bytes()[0].is_ascii_alphanumeric()
}

fn content_type_for(key: &str) -> &'static str {
    if key == "index.json" || key.starts_with("metadata/") || key.starts_with("proofs/") {
        "application/json"
    } else {
        "application/octet-stream"
    }
}

fn fmt_size(bytes: u64) -> String {
    if bytes >= 1_048_576 {
        format!("{:.1} MB", bytes as f64 / 1_048_576.0)
    } else {
        format!("{} KB", bytes / 1024)
    }
}

fn html_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn html_attr(value: &str) -> String {
    html_escape(value)
}

fn json_escape(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn object_paths_are_flat_pm_paths() {
        assert_eq!(
            package_key("/packages/aarch64/zlib/zlib-1.3.2-5.tar.gz").as_deref(),
            Some("packages/aarch64/zlib/zlib-1.3.2-5.tar.gz")
        );
        assert_eq!(
            package_key("/packages/zlib/zlib-1.3.2-5.tar.gz").as_deref(),
            Some("packages/zlib/zlib-1.3.2-5.tar.gz")
        );
        assert_eq!(
            source_key("/sources/zlib/zlib-1.3.2-5-aarch64-src.tar.bz2").as_deref(),
            Some("sources/zlib/zlib-1.3.2-5-aarch64-src.tar.bz2")
        );
        assert_eq!(
            metadata_key("/metadata/aarch64/zlib/zlib-1.3.2-5.json").as_deref(),
            Some("metadata/aarch64/zlib/zlib-1.3.2-5.json")
        );
    }

    #[test]
    fn object_paths_reject_traversal() {
        assert!(package_key("/packages/zlib/../../../etc/passwd").is_none());
        assert!(package_key("/packages/../zlib/zlib-1.tar.gz").is_none());
        assert!(source_key("/sources/zlib/zlib-1.tar.bz2").is_none());
        assert!(metadata_key("/metadata/aarch64/zlib/../../../etc/passwd").is_none());
        assert!(metadata_key("/metadata/../zlib/zlib-1.json").is_none());
        assert!(metadata_key("/metadata/aarch64/zlib/zlib-1.tar.gz").is_none());
    }

    #[test]
    fn index_validation_checks_paths() {
        let index = vec![RemotePackage {
            arch: "aarch64".to_string(),
            name: "zlib".to_string(),
            ver: "1.3.2".to_string(),
            rel: "5".to_string(),
            deps: vec!["musl".to_string()],
            mkdeps_host: vec![],
            mkdeps_target: vec![],
            sha256: "a".repeat(64),
            size: 10,
            tarball: "packages/aarch64/zlib/zlib-1.3.2-5-cccccccccccc.tar.gz".to_string(),
            metadata: "metadata/aarch64/zlib/zlib-1.3.2-5-cccccccccccc-dddddddddddd.json".to_string(),
            source_sha256: "b".repeat(64),
            metapackage: false,
            artifact_key: "c".repeat(64),
            proof_key: "d".repeat(64),
            proof: "proofs/aarch64/zlib/zlib-1.3.2-5-cccccccccccc-dddddddddddd.json".to_string(),
            extra: Default::default(),
        }];
        assert!(validate_index(&index).is_ok());
    }

    #[test]
    fn publishable_objects_are_content_addressed() {
        for path in [
            "/packages/aarch64/zlib/zlib-1.3.2-5-0123456789ab.tar.gz",
            "/packages/x86_64/xsh-git/xsh-git-0.1-r2-1-0123456789ab.tar.gz",
            "/metadata/aarch64/zlib/zlib-1.3.2-5-0123456789ab-fedcba987654.json",
            "/proofs/x86_64/zlib/zlib-1.3.2-5-0123456789ab-fedcba987654.json",
            "/sources/zlib/zlib-1.3.2-5-aarch64-src.tar.bz2",
        ] {
            assert_eq!(publishable_object_key(path).as_deref(), Some(&path[1..]), "{path}");
        }
        for path in [
            "/packages/aarch64/zlib/zlib-1.3.2-5.tar.gz",
            "/packages/zlib/zlib-1.3.2-5-0123456789ab.tar.gz",
            "/packages/aarch64/zlib/zlib-0123456789ab.tar.gz",
            "/packages/aarch64/zlib/zlib--5-0123456789ab.tar.gz",
            "/metadata/aarch64/zlib/zlib-1.3.2-5-0123456789ab.json",
            "/proofs/aarch64/zlib/zlib-1.3.2-5-0123456789ab-FEDCBA987654.json",
        ] {
            assert!(publishable_object_key(path).is_none(), "{path}");
        }
    }
}

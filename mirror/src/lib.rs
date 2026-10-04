pub mod auth;
pub mod db;
pub mod http;
pub mod jwt;
pub mod packages;
pub mod publish;
pub mod s3;
pub mod webauthn_handlers;

use std::collections::HashMap;
use std::io::{Cursor, Read};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, RwLock};

pub struct AppState {
    pub storage: s3::Storage,
    pub access: Access,
    pub index: RwLock<Vec<packages::RemotePackage>>,
    pub upload_dir: PathBuf,
    /// Serializes index publication and the corresponding in-memory index update.
    pub index_lock: Mutex<()>,
    /// If set, tarball GETs redirect here instead of proxying through the server.
    pub r2_public_url: Option<String>,
    /// Content-addressed source cache served read-only at `/sources/sha256/<hash>`
    /// from `<dir>/sha256/<hash>`. Never written through HTTP.
    pub source_cache: Option<PathBuf>,
}

/// Who may write, and whether the WebAuthn/token routes exist at all.
pub enum Access {
    /// Production: writes need a bearer token (DB token or OIDC JWT), and the
    /// `/auth` routes manage passkeys, browser sessions and tokens.
    Authenticated(AuthState),
    /// Local mode: anyone who can reach the socket may read and write, and the
    /// `/auth` routes do not exist. Only safe because local mode binds loopback.
    Open,
}

pub struct AuthState {
    pub db: Mutex<db::Db>,
    pub webauthn: webauthn_minimal::RelyingParty,
    pub jwks: Option<Mutex<jwt::JwksCache>>,
    pub allowed_users: Vec<String>,
    /// Set when RP_ORIGIN is https:// so Set-Cookie includes the Secure flag.
    pub secure_cookies: bool,
}

/// Serves requests forever, one thread per request.
pub fn serve(server: tiny_http::Server, state: Arc<AppState>) {
    for mut request in server.incoming_requests() {
        let state = state.clone();
        std::thread::spawn(move || {
            let method = request.method().as_str().to_string();
            let url = request.url().to_string();
            let headers: HashMap<String, String> = request
                .headers()
                .iter()
                .map(|h| {
                    (
                        h.field.as_str().as_str().to_lowercase(),
                        h.value.as_str().to_string(),
                    )
                })
                .collect();

            let mut body = Vec::new();
            let _ = request.as_reader().read_to_end(&mut body);

            let resp = packages::route(&method, &url, &headers, &body, &state);

            let mut response_headers = vec![
                tiny_http::Header::from_bytes(&b"Content-Type"[..], resp.content_type.as_bytes())
                    .unwrap(),
            ];
            for (name, value) in &resp.extra_headers {
                if let Ok(h) = tiny_http::Header::from_bytes(name.as_bytes(), value.as_bytes()) {
                    response_headers.push(h);
                }
            }

            let status = tiny_http::StatusCode(resp.status);
            let response = match resp.body {
                packages::Body::Bytes(bytes) => {
                    let length = bytes.len();
                    tiny_http::Response::new(
                        status,
                        response_headers,
                        Box::new(Cursor::new(bytes)) as Box<dyn Read + Send>,
                        Some(length),
                        None,
                    )
                }
                // Files are streamed, never buffered. tiny_http switches to chunked
                // encoding (dropping Content-Length) above 32 KiB unless told otherwise;
                // clients use the length to size and check downloads, so always send it.
                packages::Body::File { file, length } => tiny_http::Response::new(
                    status,
                    response_headers,
                    Box::new(file) as Box<dyn Read + Send>,
                    Some(length as usize),
                    None,
                )
                .with_chunked_threshold(usize::MAX),
            };

            let _ = request.respond(response);
        });
    }
}

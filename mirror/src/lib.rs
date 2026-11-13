pub mod auth;
pub mod db;
pub mod http;
pub mod jwt;
pub mod packages;
pub mod s3;
pub mod webauthn_handlers;

use std::collections::HashMap;
use std::io::Write;
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

const WORKERS: usize = 8;
const QUEUE: usize = 8;
const BODY_LIMIT: usize = 64 * 1024;
const INDEX_LIMIT: usize = 10 * 1024 * 1024;
const UPLOAD_LIMIT: usize = 128 * 1024 * 1024;
const HEADER_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
const BODY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

pub fn serve(listener: std::net::TcpListener, state: Arc<AppState>) -> std::io::Result<()> {
    let worker_name = format!("mirror-{}", listener.local_addr()?.port());
    let (sender, receiver) = std::sync::mpsc::sync_channel::<std::net::TcpStream>(QUEUE);
    let receiver = Arc::new(Mutex::new(receiver));
    let mut workers = Vec::new();
    for _ in 0..WORKERS {
        let receiver = receiver.clone();
        let state = state.clone();
        workers.push(std::thread::Builder::new().name(worker_name.clone()).spawn(move || loop {
            let stream = match receiver.lock().unwrap().recv() {
                Ok(stream) => stream,
                Err(_) => break,
            };
            if let Err(error) = serve_connection(stream, state.clone()) {
                tracing::warn!("connection: {error}");
            }
        }).expect("spawn mirror worker"));
    }
    let result = loop {
        match listener.accept() {
            Ok((mut stream, _)) => match sender.try_send(stream) {
                Ok(()) => {},
                Err(std::sync::mpsc::TrySendError::Full(returned)) => {
                    stream = returned;
                    let _ = stream.set_write_timeout(Some(std::time::Duration::from_millis(100)));
                    let _ = stream.write_all(b"HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
                }
                Err(std::sync::mpsc::TrySendError::Disconnected(_)) => break Err(std::io::Error::other("mirror workers stopped")),
            },
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => break Err(error),
        }
    };
    drop(sender);
    for worker in workers {
        if worker.join().is_err() {
            tracing::error!("mirror worker panicked");
        }
    }
    result
}

fn serve_connection(stream: std::net::TcpStream, state: Arc<AppState>) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let stream = async_io::Async::new(stream)?;
    let router = h12tiny::web::Router::<()>::new().fallback(move |request: h12tiny::web::Request| {
        let state = state.clone();
        async move { handle(request, state).await }
    });
    let mut builder = h12tiny::server::conn::auto::Builder::new(()).http1_only();
    builder.http1().timer(h12tiny::runtime::AsyncIoTimer).header_read_timeout(HEADER_TIMEOUT).keep_alive(false);
    futures_lite::future::block_on(builder.serve_connection(h12tiny::io::FuturesIo::new(stream), router))?;
    Ok(())
}

async fn handle(request: h12tiny::web::Request, state: Arc<AppState>) -> ::http::Response<h12tiny::util::BoxBody> {
    use h12tiny::util::BodyExt;
    use http_body::Body as _;
    let method = request.method().as_str().to_string();
    let path = request.uri().path_and_query().map(|p| p.as_str()).unwrap_or("/").to_string();
    let headers: HashMap<String, String> = request.headers().iter().filter_map(|(name, value)| {
        value.to_str().ok().map(|value| (name.as_str().to_string(), value.to_string()))
    }).collect();
    let auth_route = path == "/auth" || path.starts_with("/auth?") || path.starts_with("/auth/");
    if !auth_route && (method == "PUT" || (method == "POST" && path.starts_with("/_uploads/") && path.ends_with("/complete"))) && !packages::may_write(&headers, &state) {
        return response(packages::Response::unauthorized());
    }
    let limit = if method == "PUT" && (path.starts_with("/packages/") || path.starts_with("/sources/") || path.starts_with("/_uploads/")) {
        UPLOAD_LIMIT
    } else if method == "PUT" && (path == "/index.json" || path.starts_with("/indexes/")) {
        INDEX_LIMIT
    } else { BODY_LIMIT };
    if request.body().size_hint().upper().is_some_and(|n| n > limit as u64) {
        return response(packages::Response::json(413, r#"{"error":"body too large"}"#));
    }
    let read = async {
        let mut body = request.into_body();
        let mut bytes = Vec::new();
        while let Some(frame) = body.frame().await {
            let frame = frame.map_err(|error| error.to_string())?;
            if let Ok(data) = frame.into_data() {
                if data.len() > limit - bytes.len() {
                    return Ok(None);
                }
                bytes.extend_from_slice(&data);
            }
        }
        Ok::<_, String>(Some(bytes))
    };
    let result = futures_lite::future::race(async { Some(read.await) }, async {
        async_io::Timer::after(BODY_TIMEOUT).await;
        None
    }).await;
    match result {
        None => response(packages::Response::json(408, r#"{"error":"body read timeout"}"#)),
        Some(Ok(None)) => response(packages::Response::json(413, r#"{"error":"body too large"}"#)),
        Some(Ok(Some(body))) => response(packages::route(&method, &path, &headers, &body, &state)),
        Some(Err(error)) => {
            tracing::warn!("body read: {error}");
            response(packages::Response::bad_request("body read failed"))
        }
    }
}

fn response(result: packages::Response) -> ::http::Response<h12tiny::util::BoxBody> {
    use h12tiny::util::{boxed_body, bytes_body, reader_body};
    let mut builder = ::http::Response::builder().status(result.status).header(::http::header::CONTENT_TYPE, result.content_type);
    for (name, value) in result.extra_headers {
        if let Ok(value) = ::http::HeaderValue::from_str(&value) {
            builder = builder.header(name, value);
        }
    }
    let body = match result.body {
        packages::Body::Bytes(bytes) => boxed_body(bytes_body(bytes)),
        packages::Body::File { file, length } => {
            builder = builder.header(::http::header::CONTENT_LENGTH, length);
            boxed_body(reader_body(FileReader(file)))
        }
    };
    builder.body(body).unwrap()
}

struct FileReader(std::fs::File);

impl futures_lite::io::AsyncRead for FileReader {
    fn poll_read(mut self: std::pin::Pin<&mut Self>, _: &mut std::task::Context<'_>, buf: &mut [u8]) -> std::task::Poll<std::io::Result<usize>> {
        std::task::Poll::Ready(std::io::Read::read(&mut self.0, buf))
    }
}

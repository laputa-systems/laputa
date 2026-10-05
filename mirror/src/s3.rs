use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::RwLock;

use graviola::hashing::hmac::Hmac;
use graviola::hashing::{Hash, HashContext, Sha256};

use crate::db::{hex_encode, sha256_hex};
use crate::http::Reply;

fn sha256_file_hex(path: &Path) -> Result<String, String> {
    let mut file = File::open(path).map_err(|e| format!("open {}: {e}", path.display()))?;
    let mut h = Sha256::new();
    let mut buf = [0u8; 1024 * 1024];
    loop {
        let n = file
            .read(&mut buf)
            .map_err(|e| format!("read {}: {e}", path.display()))?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(hex_encode(h.finish().as_ref()))
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = Hmac::<Sha256>::new(key);
    mac.update(data);
    mac.finish().as_ref().to_vec()
}

/// The instant a request is signed, in the two forms SigV4 needs.
struct Timestamp {
    /// `YYYYMMDD`
    date: String,
    /// `YYYYMMDDTHHmmSSZ`
    datetime: String,
}

impl Timestamp {
    fn now() -> Self {
        let secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        Self::from_unix_secs(secs)
    }

    fn from_unix_secs(secs: u64) -> Self {
        let time_of_day = secs % 86400;
        let h = time_of_day / 3600;
        let m = (time_of_day % 3600) / 60;
        let s = time_of_day % 60;

        // Howard Hinnant's civil_from_days.
        let z = (secs / 86400) as i64 + 719468;
        let era = (if z >= 0 { z } else { z - 146096 }) / 146097;
        let doe = (z - era * 146097) as u64;
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        let y = yoe as i64 + era * 400;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = doy - (153 * mp + 2) / 5 + 1;
        let mo = if mp < 10 { mp + 3 } else { mp - 9 };
        let yr = if mo <= 2 { y + 1 } else { y };

        Self {
            date: format!("{yr:04}{mo:02}{d:02}"),
            datetime: format!("{yr:04}{mo:02}{d:02}T{h:02}{m:02}{s:02}Z"),
        }
    }
}

/// The parts of a request that SigV4 signs.
struct CanonicalRequest<'a> {
    method: &'a str,
    path: &'a str,
    query: &'a str,
    /// Lowercase names, sorted.
    headers: &'a [(&'a str, &'a str)],
    payload_hash: &'a str,
}

impl CanonicalRequest<'_> {
    fn signed_headers(&self) -> String {
        let names: Vec<&str> = self.headers.iter().map(|(k, _)| *k).collect();
        names.join(";")
    }
}

/// What a signed request sends as its body. A file is streamed, so its SHA-256
/// and length are supplied up front instead of being derived from bytes in memory.
enum Payload<'a> {
    Bytes(&'a [u8]),
    File {
        file: File,
        length: u64,
        sha256: String,
    },
}

/// Endpoint, credentials and signing for one S3-compatible bucket.
pub struct S3Bucket {
    endpoint: String,
    bucket: String,
    access_key: String,
    secret_key: String,
    region: String,
}

impl S3Bucket {
    /// The endpoint's authority, which SigV4 signs as the `host` header.
    fn host(&self) -> &str {
        self.endpoint
            .strip_prefix("https://")
            .or_else(|| self.endpoint.strip_prefix("http://"))
            .and_then(|r| r.split('/').next())
            .unwrap_or("")
    }

    fn path(&self, key: &str) -> String {
        format!("/{}/{key}", self.bucket)
    }

    fn url(&self, key: &str) -> String {
        format!("{}{}", self.endpoint, self.path(key))
    }

    fn scope(&self, ts: &Timestamp) -> String {
        format!("{}/{}/s3/aws4_request", ts.date, self.region)
    }

    fn signature(&self, request: &CanonicalRequest, ts: &Timestamp) -> String {
        let canonical_headers: String = request
            .headers
            .iter()
            .map(|(k, v)| format!("{k}:{v}\n"))
            .collect();
        let canonical = format!(
            "{}\n{}\n{}\n{canonical_headers}\n{}\n{}",
            request.method,
            request.path,
            request.query,
            request.signed_headers(),
            request.payload_hash,
        );
        let to_sign = format!(
            "AWS4-HMAC-SHA256\n{}\n{}\n{}",
            ts.datetime,
            self.scope(ts),
            sha256_hex(canonical.as_bytes()),
        );

        let dk = hmac_sha256(format!("AWS4{}", self.secret_key).as_bytes(), ts.date.as_bytes());
        let rk = hmac_sha256(&dk, self.region.as_bytes());
        let sk = hmac_sha256(&rk, b"s3");
        let signing_key = hmac_sha256(&sk, b"aws4_request");
        hex_encode(&hmac_sha256(&signing_key, to_sign.as_bytes()))
    }

    fn authorization(&self, request: &CanonicalRequest, ts: &Timestamp) -> String {
        format!(
            "AWS4-HMAC-SHA256 Credential={}/{}, SignedHeaders={}, Signature={}",
            self.access_key,
            self.scope(ts),
            request.signed_headers(),
            self.signature(request, ts),
        )
    }

    /// Send a signed request. `content_type` is `Some` only for requests with a
    /// body, where it and the content length are signed along with the host and
    /// payload hash.
    fn request(
        &self,
        method: &str,
        key: &str,
        content_type: Option<&str>,
        payload: Payload,
    ) -> Result<Reply, String> {
        let (payload_hash, length) = match &payload {
            Payload::Bytes(bytes) => (sha256_hex(bytes), bytes.len() as u64),
            Payload::File { sha256, length, .. } => (sha256.clone(), *length),
        };
        let ts = Timestamp::now();
        let length_text = length.to_string();

        let mut signed = vec![
            ("host", self.host()),
            ("x-amz-content-sha256", payload_hash.as_str()),
            ("x-amz-date", ts.datetime.as_str()),
        ];
        if let Some(content_type) = content_type {
            signed.push(("content-length", length_text.as_str()));
            signed.push(("content-type", content_type));
        }
        signed.sort_by_key(|(name, _)| *name);
        let authorization = self.authorization(
            &CanonicalRequest {
                method,
                path: &self.path(key),
                query: "",
                headers: &signed,
                payload_hash: &payload_hash,
            },
            &ts,
        );

        // Content-Length and Host are added by the HTTP client from the body and URL.
        let mut headers = vec![
            ("Authorization", authorization.as_str()),
            ("X-Amz-Content-Sha256", payload_hash.as_str()),
            ("X-Amz-Date", ts.datetime.as_str()),
        ];
        if let Some(content_type) = content_type {
            headers.push(("Content-Type", content_type));
        }

        let url = self.url(key);
        match payload {
            Payload::Bytes(bytes) => crate::http::send(method, &url, &headers, bytes),
            Payload::File { file, length, .. } => {
                crate::http::send_file(method, &url, &headers, file, length)
            }
        }
        .map_err(|e| format!("S3 {method} failed: {e}"))
    }

    /// A URL granting `method` on `key` for `expires_secs`, signed with an
    /// unsigned payload so the body need not be known in advance.
    fn presign(&self, method: &str, key: &str, expires_secs: u64, ts: &Timestamp) -> String {
        // Percent-encode '/' in credential for the query string.
        let credential = format!("{}/{}", self.access_key, self.scope(ts)).replace('/', "%2F");
        // Query parameters must be sorted alphabetically.
        let query = format!(
            "X-Amz-Algorithm=AWS4-HMAC-SHA256\
            &X-Amz-Credential={credential}\
            &X-Amz-Date={}\
            &X-Amz-Expires={expires_secs}\
            &X-Amz-SignedHeaders=host",
            ts.datetime
        );
        let signature = self.signature(
            &CanonicalRequest {
                method,
                path: &self.path(key),
                query: &query,
                headers: &[("host", self.host())],
                payload_hash: "UNSIGNED-PAYLOAD",
            },
            ts,
        );
        format!("{}?{query}&X-Amz-Signature={signature}", self.url(key))
    }
}

fn stored(reply: Reply) -> Result<(), String> {
    if reply.is_success() {
        Ok(())
    } else {
        Err(format!("S3 PUT returned {}", reply.status))
    }
}

fn content_type_or_default(content_type: &str) -> &str {
    if content_type.is_empty() {
        "application/octet-stream"
    } else {
        content_type
    }
}

/// A directory holding objects at `<root>/<key>`, for the local mirror.
///
/// Writes go to a dot-named temp file in the destination directory and are renamed
/// into place, so readers see either the previous object or the complete new one.
/// Keys arrive validated by the router; `path` re-checks them anyway because a bad
/// key here would read or write outside `root`.
pub struct FsStore {
    root: PathBuf,
}

impl FsStore {
    /// The file for `key`. Rejects absolute keys, empty, `.` and `..` segments, and
    /// dot-named segments, which are reserved for temp files and the upload dir.
    fn path(&self, key: &str) -> Result<PathBuf, String> {
        let mut path = self.root.clone();
        for segment in key.split('/') {
            if segment.is_empty()
                || segment.starts_with('.')
                || segment.contains('\\')
                || segment.contains('\0')
            {
                return Err(format!("unsafe storage key {key:?}"));
            }
            path.push(segment);
        }
        Ok(path)
    }

    /// Open `key` for streaming, with its length; `None` if it does not exist.
    pub fn open(&self, key: &str) -> Result<Option<(File, u64)>, String> {
        open_file(&self.path(key)?)
    }

    fn write_atomic(
        &self,
        key: &str,
        write: impl FnOnce(&mut File) -> io::Result<()>,
    ) -> Result<(), String> {
        let path = self.path(key)?;
        let (Some(dir), Some(name)) = (path.parent(), path.file_name()) else {
            return Err(format!("unsafe storage key {key:?}"));
        };
        fs::create_dir_all(dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
        let temp = dir.join(format!(
            ".{}.{}.tmp",
            name.to_string_lossy(),
            uuid::Uuid::new_v4().simple()
        ));
        let result = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .and_then(|mut file| {
                write(&mut file)?;
                file.sync_all()
            })
            .and_then(|()| fs::rename(&temp, &path));
        result.map_err(|e| {
            let _ = fs::remove_file(&temp);
            format!("write {}: {e}", path.display())
        })
    }
}

/// Open a regular file for streaming, with its length; `None` if nothing is there.
pub fn open_file(path: &Path) -> Result<Option<(File, u64)>, String> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("open {}: {e}", path.display())),
    };
    let metadata = file
        .metadata()
        .map_err(|e| format!("metadata {}: {e}", path.display()))?;
    Ok(metadata.is_file().then(|| (file, metadata.len())))
}

/// Storage backend: S3 in production, a directory in local mode, or in-memory for tests.
pub enum Storage {
    S3(S3Bucket),
    Fs(FsStore),
    Memory(RwLock<HashMap<String, Vec<u8>>>),
}

impl Storage {
    pub fn s3(
        endpoint: &str,
        bucket: &str,
        access_key: &str,
        secret_key: &str,
        region: &str,
    ) -> Self {
        Self::S3(S3Bucket {
            endpoint: endpoint.into(),
            bucket: bucket.into(),
            access_key: access_key.into(),
            secret_key: secret_key.into(),
            region: region.into(),
        })
    }

    pub fn fs(root: impl Into<PathBuf>) -> Self {
        Self::Fs(FsStore { root: root.into() })
    }

    pub fn memory() -> Self {
        Self::Memory(RwLock::new(HashMap::new()))
    }

    /// Return the stored size of an object via HEAD, without downloading it.
    pub fn object_size(&self, key: &str) -> Result<Option<u64>, String> {
        match self {
            Self::Memory(map) => Ok(map.read().unwrap().get(key).map(|b| b.len() as u64)),
            Self::Fs(store) => Ok(store.open(key)?.map(|(_, length)| length)),
            Self::S3(bucket) => {
                let reply = bucket.request("HEAD", key, None, Payload::Bytes(&[]))?;
                match reply.status {
                    404 => Ok(None),
                    status if (200..300).contains(&status) => reply
                        .content_length
                        .map(Some)
                        .ok_or_else(|| "S3 HEAD response had no Content-Length".to_string()),
                    status => Err(format!("S3 HEAD returned {status}")),
                }
            }
        }
    }

    pub fn get(&self, key: &str) -> Result<Option<Vec<u8>>, String> {
        match self {
            Self::S3(bucket) => {
                let reply = bucket.request("GET", key, None, Payload::Bytes(&[]))?;
                match reply.status {
                    200 => Ok(Some(reply.body)),
                    404 => Ok(None),
                    status => Err(format!("S3 GET returned {status}")),
                }
            }
            Self::Fs(store) => {
                let Some((mut file, _)) = store.open(key)? else {
                    return Ok(None);
                };
                let mut body = Vec::new();
                file.read_to_end(&mut body)
                    .map_err(|e| format!("read {key}: {e}"))?;
                Ok(Some(body))
            }
            Self::Memory(map) => Ok(map.read().unwrap().get(key).cloned()),
        }
    }

    pub fn put(&self, key: &str, body: Vec<u8>, content_type: &str) -> Result<(), String> {
        match self {
            Self::S3(bucket) => stored(bucket.request(
                "PUT",
                key,
                Some(content_type_or_default(content_type)),
                Payload::Bytes(&body),
            )?),
            Self::Fs(store) => store.write_atomic(key, |file| io::Write::write_all(file, &body)),
            Self::Memory(map) => {
                map.write().unwrap().insert(key.to_string(), body);
                Ok(())
            }
        }
    }

    pub fn put_file(&self, key: &str, path: &Path, content_type: &str) -> Result<(), String> {
        match self {
            Self::S3(bucket) => {
                let file =
                    File::open(path).map_err(|e| format!("open {}: {e}", path.display()))?;
                let length = file
                    .metadata()
                    .map_err(|e| format!("metadata {}: {e}", path.display()))?
                    .len();
                stored(bucket.request(
                    "PUT",
                    key,
                    Some(content_type_or_default(content_type)),
                    Payload::File {
                        file,
                        length,
                        sha256: sha256_file_hex(path)?,
                    },
                )?)
            }
            Self::Fs(store) => store.write_atomic(key, |file| {
                io::copy(&mut File::open(path)?, file).map(|_| ())
            }),
            Self::Memory(_) => {
                let body =
                    std::fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?;
                self.put(key, body, content_type)
            }
        }
    }

    /// Generate a presigned GET URL valid for `expires_secs` seconds.
    pub fn presign_get(&self, key: &str, expires_secs: u64) -> Option<String> {
        self.presign_url("GET", key, expires_secs)
    }

    /// Generate a presigned PUT URL valid for `expires_secs` seconds.
    /// The caller may PUT any body to this URL without auth headers.
    /// Body hash is UNSIGNED-PAYLOAD so the size need not be known in advance.
    pub fn presign_put(&self, key: &str, expires_secs: u64) -> Option<String> {
        self.presign_url("PUT", key, expires_secs)
    }

    fn presign_url(&self, method: &str, key: &str, expires_secs: u64) -> Option<String> {
        match self {
            Self::S3(bucket) => Some(bucket.presign(method, key, expires_secs, &Timestamp::now())),
            Self::Fs(_) | Self::Memory(_) => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::TcpListener;

    use super::*;

    fn aws_example_bucket() -> S3Bucket {
        S3Bucket {
            endpoint: "https://examplebucket.s3.amazonaws.com".into(),
            bucket: String::new(),
            access_key: "AKIAIOSFODNN7EXAMPLE".into(),
            secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY".into(),
            region: "us-east-1".into(),
        }
    }

    fn storage_returning_status(status: u16) -> (Storage, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                let mut piece = [0_u8; 1024];
                let read = stream.read(&mut piece).unwrap();
                assert!(read > 0, "client closed before sending the request");
                request.extend_from_slice(&piece[..read]);
            }
            write!(
                stream,
                "HTTP/1.1 {status} Test\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )
            .unwrap();
        });
        (
            Storage::s3(&endpoint, "mirror", "AKID", "secret", "auto"),
            server,
        )
    }

    #[test]
    fn timestamp_formats_unix_seconds() {
        let ts = Timestamp::from_unix_secs(1369353600);
        assert_eq!(ts.date, "20130524");
        assert_eq!(ts.datetime, "20130524T000000Z");
    }

    /// The presigned-URL example from the AWS SigV4 query-string documentation.
    #[test]
    fn signature_matches_aws_documented_presigned_get() {
        let query = "X-Amz-Algorithm=AWS4-HMAC-SHA256\
            &X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request\
            &X-Amz-Date=20130524T000000Z\
            &X-Amz-Expires=86400\
            &X-Amz-SignedHeaders=host";
        let signature = aws_example_bucket().signature(
            &CanonicalRequest {
                method: "GET",
                path: "/test.txt",
                query,
                headers: &[("host", "examplebucket.s3.amazonaws.com")],
                payload_hash: "UNSIGNED-PAYLOAD",
            },
            &Timestamp::from_unix_secs(1369353600),
        );
        assert_eq!(
            signature,
            "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
        );
    }

    #[test]
    fn presigned_url_carries_credential_expiry_and_signature() {
        let bucket = S3Bucket {
            endpoint: "https://s3.test".into(),
            bucket: "mirror".into(),
            ..aws_example_bucket()
        };
        let url = bucket.presign("GET", "pkg/a.tar", 300, &Timestamp::from_unix_secs(1369353600));
        assert!(url.starts_with("https://s3.test/mirror/pkg/a.tar?X-Amz-Algorithm=AWS4-HMAC-SHA256&"));
        assert!(url.contains("X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"));
        assert!(url.contains("&X-Amz-Expires=300&X-Amz-SignedHeaders=host&X-Amz-Signature="));
    }

    #[test]
    fn put_sends_signed_headers_and_body() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = Vec::new();
            // Read until the 5-byte body has arrived after the head.
            while !request.ends_with(b"hello") {
                let mut piece = [0_u8; 1024];
                let read = stream.read(&mut piece).unwrap();
                assert!(read > 0, "client closed before sending the body");
                request.extend_from_slice(&piece[..read]);
            }
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                .unwrap();
            String::from_utf8(request).unwrap()
        });

        let storage = Storage::s3(&endpoint, "mirror", "AKID", "secret", "auto");
        storage.put("pkg/a.txt", b"hello".to_vec(), "text/plain").unwrap();

        let request = server.join().unwrap();
        assert!(request.starts_with("PUT /mirror/pkg/a.txt HTTP/1.1\r\n"));
        let lower = request.to_ascii_lowercase();
        assert!(lower.contains("content-type: text/plain\r\n"));
        assert!(lower.contains("content-length: 5\r\n"));
        assert!(lower.contains(&format!("x-amz-content-sha256: {}\r\n", sha256_hex(b"hello"))));
        assert!(lower.contains(
            "signedheaders=content-length;content-type;host;x-amz-content-sha256;x-amz-date,"
        ));
    }

    #[test]
    fn get_reports_unexpected_server_status() {
        let (storage, server) = storage_returning_status(403);
        assert_eq!(storage.get("index.json").unwrap_err(), "S3 GET returned 403");
        server.join().unwrap();
    }

    #[test]
    fn head_reports_unexpected_server_status() {
        let (storage, server) = storage_returning_status(403);
        assert_eq!(storage.object_size("index.json").unwrap_err(), "S3 HEAD returned 403");
        server.join().unwrap();
    }

    #[test]
    fn get_treats_a_missing_object_as_absent() {
        let (storage, server) = storage_returning_status(404);
        assert_eq!(storage.get("index.json").unwrap(), None);
        server.join().unwrap();
    }
}

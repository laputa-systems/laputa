use rusqlite::{Connection, Result, params};
use graviola::hashing::{Hash, Sha256};

pub struct Db {
    conn: Connection,
}

pub struct Session {
    pub user_id: Option<String>,
    pub challenge: Option<String>,
    pub token: Option<String>,
    pub status: String,
}

pub struct TokenRecord {
    pub id: String,
    pub name: String,
    pub created_at: String,
    pub last_used: Option<String>,
    pub expires_at: Option<String>,
}

impl Db {
    pub fn open(path: &str) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA foreign_keys=ON;
             CREATE TABLE IF NOT EXISTS users (
               id         TEXT PRIMARY KEY,
               name       TEXT NOT NULL UNIQUE,
               created_at TEXT NOT NULL DEFAULT (datetime('now'))
             );
             CREATE TABLE IF NOT EXISTS credentials (
               id         TEXT PRIMARY KEY,
               user_id    TEXT NOT NULL REFERENCES users(id),
               passkey    TEXT NOT NULL,
               created_at TEXT NOT NULL DEFAULT (datetime('now'))
             );
             CREATE TABLE IF NOT EXISTS tokens (
               id         TEXT PRIMARY KEY,
               user_id    TEXT NOT NULL REFERENCES users(id),
               token_hash TEXT NOT NULL UNIQUE,
               name       TEXT NOT NULL DEFAULT 'cli',
               created_at TEXT NOT NULL DEFAULT (datetime('now')),
               last_used  TEXT,
               expires_at TEXT
             );
             CREATE TABLE IF NOT EXISTS sessions (
               id         TEXT PRIMARY KEY,
               token      TEXT,
               challenge  TEXT,
               user_id    TEXT,
               status     TEXT NOT NULL DEFAULT 'pending',
               created_at TEXT NOT NULL DEFAULT (datetime('now'))
             );
             CREATE TABLE IF NOT EXISTS browser_sessions (
               id           TEXT PRIMARY KEY,
               user_id      TEXT NOT NULL REFERENCES users(id),
               session_hash TEXT NOT NULL UNIQUE,
               created_at   TEXT NOT NULL DEFAULT (datetime('now')),
               expires_at   TEXT NOT NULL DEFAULT (datetime('now', '+30 days'))
             );
             CREATE TABLE IF NOT EXISTS enrollment_authorizations (
               user_id TEXT PRIMARY KEY REFERENCES users(id),
               verifier TEXT NOT NULL UNIQUE,
               expires_at TEXT NOT NULL
             );
             CREATE TABLE IF NOT EXISTS registration_authority (
               session_id TEXT PRIMARY KEY REFERENCES sessions(id),
               kind TEXT NOT NULL,
               verifier TEXT NOT NULL
             );",
        )?;
        // Migrate existing tokens table; no-op if column already exists.
        let _ = conn.execute("ALTER TABLE tokens ADD COLUMN expires_at TEXT", []);
        let _ = conn.execute("ALTER TABLE browser_sessions ADD COLUMN authenticated_at TEXT", []);
        Ok(Self { conn })
    }

    pub fn issue_enrollment(&self, username: &str) -> Result<String> {
        let user_id = match self.get_user_by_name(username)? {
            Some(id) => id,
            None => {
                let id = uuid::Uuid::new_v4().to_string();
                self.create_user(&id, username)?;
                id
            }
        };
        let secret = random_hex(32);
        self.conn.execute(
            "INSERT OR REPLACE INTO enrollment_authorizations (user_id, verifier, expires_at) VALUES (?1, ?2, datetime('now', '+10 minutes'))",
            params![user_id, sha256_hex(secret.as_bytes())],
        )?;
        Ok(secret)
    }

    pub fn revoke_enrollment(&self, username: &str) -> Result<()> {
        self.conn.execute("DELETE FROM enrollment_authorizations WHERE user_id = (SELECT id FROM users WHERE name = ?1)", params![username])?;
        Ok(())
    }

    pub fn inventory(&self) -> Result<Vec<(String, String, String, String)>> {
        let mut stmt = self.conn.prepare("SELECT u.name, 'credential', c.id, c.created_at FROM credentials c JOIN users u ON u.id = c.user_id UNION ALL SELECT u.name, 'token', t.id, t.created_at FROM tokens t JOIN users u ON u.id = t.user_id ORDER BY 1, 2, 3")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?;
        rows.collect()
    }

    pub fn recent_user(&self, cookie: &str) -> Result<Option<String>> {
        use rusqlite::OptionalExtension;
        self.conn.query_row("SELECT user_id FROM browser_sessions WHERE session_hash = ?1 AND datetime('now') < expires_at AND authenticated_at IS NOT NULL AND datetime('now') < datetime(authenticated_at, '+10 minutes')", params![sha256_hex(cookie.as_bytes())], |r| r.get(0)).optional()
    }

    pub fn create_authenticated_session(&self, user_id: &str) -> Result<String> {
        let cookie = self.create_browser_session(user_id)?;
        self.conn.execute("UPDATE browser_sessions SET authenticated_at = datetime('now') WHERE session_hash = ?1", params![sha256_hex(cookie.as_bytes())])?;
        Ok(cookie)
    }

    pub fn create_registration(&self, user_id: &str, challenge: &str, authorization: Option<&str>, cookie: Option<&str>) -> Result<Option<String>> {
        let has_keys = !self.load_passkeys(user_id)?.is_empty();
        let (kind, verifier) = if has_keys {
            let Some(cookie) = cookie else { return Ok(None) };
            if self.recent_user(cookie)?.as_deref() != Some(user_id) { return Ok(None) }
            ("session", sha256_hex(cookie.as_bytes()))
        } else {
            let Some(secret) = authorization else { return Ok(None) };
            let verifier = sha256_hex(secret.as_bytes());
            let valid: bool = self.conn.query_row("SELECT EXISTS(SELECT 1 FROM enrollment_authorizations WHERE user_id = ?1 AND verifier = ?2 AND datetime('now') < expires_at)", params![user_id, verifier], |r| r.get(0))?;
            if !valid { return Ok(None) }
            ("bootstrap", verifier)
        };
        let tx = self.conn.unchecked_transaction()?;
        let id = random_hex(32);
        tx.execute("INSERT INTO sessions (id, user_id, challenge) VALUES (?1, ?2, ?3)", params![id, user_id, challenge])?;
        tx.execute("INSERT INTO registration_authority (session_id, kind, verifier) VALUES (?1, ?2, ?3)", params![id, kind, verifier])?;
        tx.commit()?;
        Ok(Some(id))
    }

    pub fn finish_registration(&self, session_id: &str, user_id: &str, cred_id: &str, passkey: &str) -> Result<Option<(Option<String>, String)>> {
        let tx = self.conn.unchecked_transaction()?;
        let valid: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM sessions s JOIN registration_authority a ON a.session_id = s.id WHERE s.id = ?1 AND s.user_id = ?2 AND s.status = 'pending' AND datetime('now') < datetime(s.created_at, '+10 minutes') AND ((a.kind = 'bootstrap' AND NOT EXISTS(SELECT 1 FROM credentials WHERE user_id = s.user_id) AND EXISTS(SELECT 1 FROM enrollment_authorizations e WHERE e.user_id = s.user_id AND e.verifier = a.verifier AND datetime('now') < e.expires_at)) OR (a.kind = 'session' AND EXISTS(SELECT 1 FROM browser_sessions b WHERE b.user_id = s.user_id AND b.session_hash = a.verifier AND datetime('now') < b.expires_at AND b.authenticated_at IS NOT NULL AND datetime('now') < datetime(b.authenticated_at, '+10 minutes')))))", params![session_id, user_id], |r| r.get(0))?;
        if !valid { return Ok(None) }
        tx.execute("DELETE FROM enrollment_authorizations WHERE user_id = ?1 AND verifier = (SELECT verifier FROM registration_authority WHERE session_id = ?2 AND kind = 'bootstrap')", params![user_id, session_id])?;
        tx.execute("INSERT INTO credentials (id, user_id, passkey) VALUES (?1, ?2, ?3)", params![cred_id, user_id, passkey])?;
        let has_token: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM tokens WHERE user_id = ?1)", params![user_id], |r| r.get(0))?;
        let token = if has_token { None } else {
            let token = random_hex(32);
            tx.execute("INSERT INTO tokens (id, user_id, token_hash, name) VALUES (?1, ?2, ?3, 'cli')", params![random_hex(16), user_id, sha256_hex(token.as_bytes())])?;
            Some(token)
        };
        let cookie = random_hex(32);
        tx.execute("INSERT INTO browser_sessions (id, user_id, session_hash) VALUES (?1, ?2, ?3)", params![random_hex(16), user_id, sha256_hex(cookie.as_bytes())])?;
        tx.execute("UPDATE sessions SET status = 'completed', challenge = NULL, token = ?1 WHERE id = ?2", params![token, session_id])?;
        tx.execute("DELETE FROM registration_authority WHERE session_id = ?1", params![session_id])?;
        tx.commit()?;
        Ok(Some((token, cookie)))
    }

    pub fn get_user_by_name(&self, name: &str) -> Result<Option<String>> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT id FROM users WHERE name = ?1")?;
        let mut rows = stmt.query(params![name])?;
        match rows.next()? {
            Some(row) => Ok(Some(row.get(0)?)),
            None => Ok(None),
        }
    }

    pub fn create_user(&self, id: &str, name: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO users (id, name) VALUES (?1, ?2)",
            params![id, name],
        )?;
        Ok(())
    }

    pub fn save_credential(&self, cred_id: &str, user_id: &str, passkey_json: &str) -> Result<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO credentials (id, user_id, passkey) VALUES (?1, ?2, ?3)",
            params![cred_id, user_id, passkey_json],
        )?;
        Ok(())
    }

    /// Returns (cred_id_hex, passkey_json) pairs for a user.
    pub fn load_passkeys(&self, user_id: &str) -> Result<Vec<(String, String)>> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT id, passkey FROM credentials WHERE user_id = ?1")?;
        let rows = stmt.query_map(params![user_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        rows.collect()
    }

    pub fn update_passkey(&self, cred_id: &str, passkey_json: &str) -> Result<()> {
        self.conn.execute(
            "UPDATE credentials SET passkey = ?1 WHERE id = ?2",
            params![passkey_json, cred_id],
        )?;
        Ok(())
    }

    /// Generates a 64-char hex token, stores only its SHA-256 hash. Returns plaintext.
    pub fn create_token(
        &self,
        user_id: &str,
        name: &str,
        expires_days: Option<u64>,
    ) -> Result<String> {
        let plaintext = random_hex(32);
        let id = random_hex(16);
        let hash = sha256_hex(plaintext.as_bytes());
        if let Some(days) = expires_days {
            self.conn.execute(
                &format!(
                    "INSERT INTO tokens (id, user_id, token_hash, name, expires_at) \
                     VALUES (?1, ?2, ?3, ?4, datetime('now', '+{days} days'))"
                ),
                params![id, user_id, hash, name],
            )?;
        } else {
            self.conn.execute(
                "INSERT INTO tokens (id, user_id, token_hash, name) VALUES (?1, ?2, ?3, ?4)",
                params![id, user_id, hash, name],
            )?;
        }
        Ok(plaintext)
    }

    pub fn has_any_token(&self, user_id: &str) -> Result<bool> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT COUNT(*) FROM tokens WHERE user_id = ?1")?;
        let mut rows = stmt.query(params![user_id])?;
        match rows.next()? {
            Some(row) => Ok(row.get::<_, i64>(0)? > 0),
            None => Ok(false),
        }
    }

    pub fn list_tokens(&self, user_id: &str) -> Result<Vec<TokenRecord>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT id, name, created_at, last_used, expires_at \
             FROM tokens WHERE user_id = ?1 ORDER BY created_at",
        )?;
        let rows = stmt.query_map(params![user_id], |row| {
            Ok(TokenRecord {
                id: row.get(0)?,
                name: row.get(1)?,
                created_at: row.get(2)?,
                last_used: row.get(3)?,
                expires_at: row.get(4)?,
            })
        })?;
        rows.collect()
    }

    pub fn delete_token(&self, token_id: &str, user_id: &str) -> Result<()> {
        self.conn.execute(
            "DELETE FROM tokens WHERE id = ?1 AND user_id = ?2",
            params![token_id, user_id],
        )?;
        Ok(())
    }

    /// Returns user_id if the token is valid and not expired; updates last_used.
    pub fn verify_token(&self, token: &str) -> Result<Option<String>> {
        let hash = sha256_hex(token.as_bytes());
        let mut stmt = self.conn.prepare_cached(
            "SELECT user_id FROM tokens WHERE token_hash = ?1
             AND (expires_at IS NULL OR datetime('now') < expires_at)",
        )?;
        let mut rows = stmt.query(params![hash])?;
        match rows.next()? {
            Some(row) => {
                let user_id: String = row.get(0)?;
                self.conn.execute(
                    "UPDATE tokens SET last_used = datetime('now') WHERE token_hash = ?1",
                    params![hash],
                )?;
                Ok(Some(user_id))
            }
            None => Ok(None),
        }
    }

    /// Creates a browser session (30-day TTL). Returns plaintext cookie value.
    pub fn create_browser_session(&self, user_id: &str) -> Result<String> {
        let plaintext = random_hex(32);
        let id = random_hex(16);
        let hash = sha256_hex(plaintext.as_bytes());
        self.conn.execute(
            "INSERT INTO browser_sessions (id, user_id, session_hash) VALUES (?1, ?2, ?3)",
            params![id, user_id, hash],
        )?;
        Ok(plaintext)
    }

    /// Returns username if the browser session is valid and not expired.
    pub fn verify_browser_session(&self, cookie: &str) -> Result<Option<String>> {
        let hash = sha256_hex(cookie.as_bytes());
        let mut stmt = self.conn.prepare_cached(
            "SELECT u.name FROM browser_sessions bs JOIN users u ON bs.user_id = u.id
             WHERE bs.session_hash = ?1 AND datetime('now') < bs.expires_at",
        )?;
        let mut rows = stmt.query(params![hash])?;
        match rows.next()? {
            Some(row) => Ok(Some(row.get(0)?)),
            None => Ok(None),
        }
    }

    pub fn invalidate_browser_session(&self, cookie: &str) -> Result<()> {
        let hash = sha256_hex(cookie.as_bytes());
        self.conn.execute(
            "DELETE FROM browser_sessions WHERE session_hash = ?1",
            params![hash],
        )?;
        Ok(())
    }

    /// Creates a session pre-loaded with challenge JSON. Returns session ID.
    pub fn create_session(&self, user_id: Option<&str>, challenge: &str) -> Result<String> {
        let id = random_hex(32);
        self.conn.execute(
            "INSERT INTO sessions (id, user_id, challenge) VALUES (?1, ?2, ?3)",
            params![id, user_id, challenge],
        )?;
        Ok(id)
    }

    /// Returns session if it exists and has not expired (10-minute window).
    pub fn get_session(&self, id: &str) -> Result<Option<Session>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT user_id, challenge, token, status FROM sessions
             WHERE id = ?1 AND datetime('now') < datetime(created_at, '+10 minutes')",
        )?;
        let mut rows = stmt.query(params![id])?;
        match rows.next()? {
            Some(row) => Ok(Some(Session {
                user_id: row.get(0)?,
                challenge: row.get(1)?,
                token: row.get(2)?,
                status: row.get(3)?,
            })),
            None => Ok(None),
        }
    }

    pub fn claim_authentication(&self, id: &str, user_id: &str) -> Result<bool> {
        Ok(self.conn.execute("UPDATE sessions SET status = 'consumed', challenge = NULL WHERE id = ?1 AND user_id = ?2 AND status = 'pending' AND datetime('now') < datetime(created_at, '+10 minutes') AND NOT EXISTS(SELECT 1 FROM registration_authority WHERE session_id = ?1)", params![id, user_id])? == 1)
    }

    pub fn complete_session(&self, id: &str, token: &str) -> Result<()> {
        self.conn.execute(
            "UPDATE sessions SET token = ?1, status = 'completed' WHERE id = ?2",
            params![token, id],
        )?;
        Ok(())
    }

    /// Returns the token exactly once (for CLI polling), then clears it.
    pub fn consume_session_token(&self, id: &str) -> Result<Option<String>> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT token FROM sessions WHERE id = ?1 AND status = 'completed'")?;
        let mut rows = stmt.query(params![id])?;
        match rows.next()? {
            Some(row) => {
                let token: Option<String> = row.get(0)?;
                if token.is_some() {
                    self.conn.execute(
                        "UPDATE sessions SET token = NULL, status = 'consumed' WHERE id = ?1",
                        params![id],
                    )?;
                }
                Ok(token)
            }
            None => Ok(None),
        }
    }

    pub fn seed_token(&self, user_id: &str, name: &str, plaintext: &str) -> Result<()> {
        let id = format!("test-{name}");
        let hash = sha256_hex(plaintext.as_bytes());
        self.conn.execute(
            "INSERT OR REPLACE INTO tokens (id, user_id, token_hash, name) VALUES (?1, ?2, ?3, ?4)",
            params![id, user_id, hash, name],
        )?;
        Ok(())
    }
}

pub fn sha256_hex(data: &[u8]) -> String {
    hex_encode(Sha256::hash(data).as_ref())
}

pub(crate) fn hex_encode(bytes: &[u8]) -> String {
    bytes
        .iter()
        .fold(String::with_capacity(bytes.len() * 2), |mut s, b| {
            use std::fmt::Write;
            let _ = write!(s, "{b:02x}");
            s
        })
}

fn random_hex(n: usize) -> String {
    let mut buf = vec![0u8; n];
    graviola::random::fill(&mut buf).expect("system random source");
    hex_encode(&buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open() -> Db {
        Db::open(":memory:").expect("open")
    }

    fn with_user() -> (Db, String) {
        let db = open();
        db.create_user("uid", "testuser").expect("create_user");
        (db, "uid".to_string())
    }

    #[test]
    fn enrollment_authority_and_replay() {
        let (db, uid) = with_user();
        db.create_user("other", "other").unwrap();
        let secret = db.issue_enrollment("testuser").unwrap();
        assert!(db.create_registration("other", "challenge", Some(&secret), None).unwrap().is_none());
        assert!(db.create_registration(&uid, "challenge", None, None).unwrap().is_none());
        let first = db.create_registration(&uid, "challenge", Some(&secret), None).unwrap().unwrap();
        let second = db.create_registration(&uid, "challenge", Some(&secret), None).unwrap().unwrap();
        assert!(db.finish_registration(&first, &uid, "key1", "passkey").unwrap().is_some());
        assert!(db.finish_registration(&first, &uid, "key2", "passkey").unwrap().is_none());
        assert!(db.finish_registration(&second, &uid, "key2", "passkey").unwrap().is_none());
        assert!(db.create_registration(&uid, "challenge", Some(&secret), None).unwrap().is_none());
        assert!(db.create_registration(&uid, "challenge", None, None).unwrap().is_none());
        let other_cookie = db.create_authenticated_session("other").unwrap();
        assert!(db.create_registration(&uid, "challenge", None, Some(&other_cookie)).unwrap().is_none());
        let cookie = db.create_authenticated_session(&uid).unwrap();
        let additional = db.create_registration(&uid, "challenge", None, Some(&cookie)).unwrap().unwrap();
        assert!(db.finish_registration(&additional, &uid, "key2", "passkey").unwrap().is_some());
        assert!(db.finish_registration(&additional, &uid, "key3", "passkey").unwrap().is_none());
        db.conn.execute("UPDATE browser_sessions SET authenticated_at = '2020-01-01'", []).unwrap();
        assert!(db.create_registration(&uid, "challenge", None, Some(&cookie)).unwrap().is_none());
    }

    #[test]
    fn enrollment_expiry_revocation_and_failed_insert() {
        let (db, uid) = with_user();
        let secret = db.issue_enrollment("testuser").unwrap();
        let pending = db.create_registration(&uid, "challenge", Some(&secret), None).unwrap().unwrap();
        db.conn.execute("UPDATE enrollment_authorizations SET expires_at = '2020-01-01'", []).unwrap();
        assert!(db.finish_registration(&pending, &uid, "key", "passkey").unwrap().is_none());
        let secret = db.issue_enrollment("testuser").unwrap();
        let pending = db.create_registration(&uid, "challenge", Some(&secret), None).unwrap().unwrap();
        db.revoke_enrollment("testuser").unwrap();
        assert!(db.finish_registration(&pending, &uid, "key", "passkey").unwrap().is_none());
        let secret = db.issue_enrollment("testuser").unwrap();
        let pending = db.create_registration(&uid, "challenge", Some(&secret), None).unwrap().unwrap();
        db.create_user("other", "other").unwrap();
        db.save_credential("key", "other", "passkey").unwrap();
        assert!(db.finish_registration(&pending, &uid, "key", "passkey").is_err());
        assert!(db.finish_registration(&pending, &uid, "new-key", "passkey").unwrap().is_some());
    }

    #[test]
    fn concurrent_enrollment_has_one_winner() {
        use std::sync::{Arc, Mutex, Barrier};
        let (db, uid) = with_user();
        let secret = db.issue_enrollment("testuser").unwrap();
        let a = db.create_registration(&uid, "challenge", Some(&secret), None).unwrap().unwrap();
        let b = db.create_registration(&uid, "challenge", Some(&secret), None).unwrap().unwrap();
        let db = Arc::new(Mutex::new(db));
        let barrier = Arc::new(Barrier::new(2));
        let handles: Vec<_> = [a, b].into_iter().enumerate().map(|(i, id)| {
            let db = Arc::clone(&db);
            let barrier = Arc::clone(&barrier);
            let uid = uid.clone();
            std::thread::spawn(move || {
                barrier.wait();
                db.lock().unwrap().finish_registration(&id, &uid, &format!("key{i}"), "passkey").unwrap().is_some()
            })
        }).collect();
        assert_eq!(handles.into_iter().map(|h| h.join().unwrap()).filter(|won| *won).count(), 1);
        assert_eq!(db.lock().unwrap().load_passkeys(&uid).unwrap().len(), 1);
    }

    #[test]
    fn expired_token_is_rejected() {
        let (db, uid) = with_user();
        let token = db.create_token(&uid, "cli", None).expect("create_token");
        assert!(
            db.verify_token(&token).unwrap().is_some(),
            "should be valid before expiry"
        );

        // Backdate the expiry via raw SQL (only accessible in same-module tests).
        db.conn
            .execute("UPDATE tokens SET expires_at = '2020-01-01 00:00:00'", [])
            .unwrap();

        assert!(
            db.verify_token(&token).unwrap().is_none(),
            "should be rejected after expiry"
        );
    }

    #[test]
    fn token_with_future_expiry_is_accepted() {
        let (db, uid) = with_user();
        let token = db
            .create_token(&uid, "cli", Some(30))
            .expect("create_token");
        assert!(db.verify_token(&token).unwrap().is_some());
    }

    #[test]
    fn browser_session_valid_then_invalidated() {
        let (db, uid) = with_user();
        let session = db
            .create_browser_session(&uid)
            .expect("create_browser_session");

        assert_eq!(
            db.verify_browser_session(&session).unwrap(),
            Some("testuser".to_string())
        );

        db.invalidate_browser_session(&session).expect("invalidate");

        assert_eq!(db.verify_browser_session(&session).unwrap(), None);
    }

    #[test]
    fn has_any_token_reflects_create_and_delete() {
        let (db, uid) = with_user();
        assert!(!db.has_any_token(&uid).unwrap(), "no tokens initially");

        db.create_token(&uid, "cli", None).unwrap();
        assert!(db.has_any_token(&uid).unwrap(), "true after create");

        let id = db.list_tokens(&uid).unwrap()[0].id.clone();
        db.delete_token(&id, &uid).unwrap();
        assert!(!db.has_any_token(&uid).unwrap(), "false after delete");
    }

    #[test]
    fn list_tokens_shows_expiry() {
        let (db, uid) = with_user();
        db.create_token(&uid, "no-expiry", None).unwrap();
        db.create_token(&uid, "expiring", Some(7)).unwrap();

        let tokens = db.list_tokens(&uid).unwrap();
        assert_eq!(tokens.len(), 2);
        let no_exp = tokens.iter().find(|t| t.name == "no-expiry").unwrap();
        let exp = tokens.iter().find(|t| t.name == "expiring").unwrap();
        assert!(no_exp.expires_at.is_none());
        assert!(exp.expires_at.is_some());
    }

    #[test]
    fn delete_token_respects_user_id() {
        let (db, uid) = with_user();
        db.create_user("other", "other").expect("create other user");
        db.create_token(&uid, "mine", None).unwrap();
        let id = db.list_tokens(&uid).unwrap()[0].id.clone();

        // Deleting with a different user_id must be a no-op.
        db.delete_token(&id, "other").unwrap();
        assert_eq!(
            db.list_tokens(&uid).unwrap().len(),
            1,
            "token must survive wrong-user delete"
        );

        // Deleting with the correct user_id must work.
        db.delete_token(&id, &uid).unwrap();
        assert_eq!(db.list_tokens(&uid).unwrap().len(), 0);
    }
}

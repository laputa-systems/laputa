//! P1: mdev.conf grammar tests. `config_*` filter.
//!
//! Hermetic tests always run. `config_oracle_diff` additionally diffs the
//! rule dump against the C oracle harness (`tools/build-oracle.sh`); it
//! passes with a note when the harness is absent (fresh clones, CI).
use mdevd::config::regex::{Regex, lossy, pin_c_locale};
use mdevd::config::{Config, DevMatch, MoveKind, parse, validate_v1};
use std::path::Path;

fn parse_ok(name: &str) -> Config {
    pin_c_locale();
    let input = std::fs::read(name).unwrap();
    parse(&input).unwrap()
}

/// Canonical rule dump, byte-identical in shape to dump-run output.
fn dump(cfg: &Config) -> Vec<u8> {
    let mut o = Vec::new();
    for r in &cfg.rules {
        for e in &r.env {
            o.extend_from_slice(format!("PAT {}\n", lossy(e.re.pattern())).as_bytes());
        }
        if let DevMatch::DevRe(re) = &r.dev {
            o.extend_from_slice(format!("PAT {}\n", lossy(re.pattern())).as_bytes());
        }
    }
    for (i, r) in cfg.rules.iter().enumerate() {
        let dev = match &r.dev {
            DevMatch::Nothing => 0,
            DevMatch::Catchall => 1,
            DevMatch::DevRe(_) => 2,
            DevMatch::MajMin { .. } => 3,
        };
        let mv = match r.move_kind {
            MoveKind::Nothing => 0,
            MoveKind::NoCreate => 1,
            MoveKind::Move => 2,
            MoveKind::MoveAndLink => 3,
        };
        o.extend_from_slice(
            format!(
                "rule {i} dev={dev} envbase={} envlen={} cont={} uid={} gid={} mode={:o} move={mv} cmd={}",
                r.env_base,
                r.env.len(),
                r.cont as u8,
                r.uid,
                r.gid,
                r.mode,
                r.action_mask
            )
            .as_bytes(),
        );
        if let DevMatch::MajMin { maj, minlo, minhi } = &r.dev {
            o.extend_from_slice(format!(" maj={maj} lo={minlo} hi={minhi}").as_bytes());
        }
        o.extend_from_slice(b"\n");
        for e in &r.env {
            o.extend_from_slice(format!("  env {}\n", lossy(cfg.at(e.var))).as_bytes());
        }
        if matches!(r.move_kind, MoveKind::Move | MoveKind::MoveAndLink) {
            let p = r.movepath.map(|off| cfg.at(off)).unwrap_or_default();
            o.extend_from_slice(format!("  path {}\n", lossy(p)).as_bytes());
        }
        if r.action_mask != 0 {
            // Mirrors the reference empty-command quirk: offset 0 reads the
            // whole buffer up to its first NUL.
            let t = r.cmd.map(|off| cfg.at(off)).unwrap_or_else(|| {
                let end = cfg.storage.iter().position(|&b| b == 0).unwrap_or(cfg.storage.len());
                &cfg.storage[..end]
            });
            o.extend_from_slice(
                format!("  cmd mask={} excl={} {}\n", r.action_mask, r.execline as u8, lossy(t))
                    .as_bytes(),
            );
        }
    }
    o
}

#[test]
fn config_laputa_golden() {
    let cfg = parse_ok("tests/fixtures/laputa-mdev.conf");
    // 20 parsed rules plus the appended catchall.
    assert_eq!(cfg.rules.len(), 21);
    assert!(matches!(cfg.rules[20].dev, DevMatch::Catchall));
    assert_eq!(cfg.rules[20].mode, 0o660);
    let r0 = &cfg.rules[0];
    assert!(matches!(&r0.dev, DevMatch::DevRe(re) if re.pattern() == b"(null|zero|full|random|urandom)"));
    assert_eq!((r0.uid, r0.gid, r0.mode), (0, 0, 0o666));
    assert!(r0.env.is_empty() && r0.action_mask == 0);
    // Block rules: one SUBSYSTEM=block env each, disk group, MoveAndLink.
    for r in &cfg.rules[1..7] {
        assert_eq!(r.env.len(), 1);
        assert_eq!(cfg.at(r.env[0].var), b"SUBSYSTEM");
        assert_eq!(r.env[0].re.pattern(), b"block");
        assert_eq!((r.uid, r.mode), (0, 0o660));
        assert_eq!(r.gid, unsafe { (*libc::getgrnam(c"disk".as_ptr())).gr_gid });
        assert!(matches!(r.move_kind, MoveKind::MoveAndLink));
        assert_eq!(cfg.at(r.movepath.unwrap()), b"disk/%1");
    }
    assert!(matches!(cfg.rules[7].move_kind, MoveKind::Nothing));
    assert_eq!(cfg.rules[9].gid, unsafe {
        (*libc::getgrnam(c"input".as_ptr())).gr_gid
    });
    assert_eq!(cfg.rules[12].gid, unsafe {
        (*libc::getgrnam(c"audio".as_ptr())).gr_gid
    });
    assert_eq!(cfg.rules[13].gid, unsafe {
        (*libc::getgrnam(c"video".as_ptr())).gr_gid
    });
    // Devname-only tail: no env, kept bases.
    for r in &cfg.rules[14..20] {
        assert!(r.env.is_empty());
    }
    assert_eq!(cfg.rules[16].mode, 0o620);
    assert!(validate_v1(&cfg).is_ok());
}

#[test]
fn config_hook_fixture_rejected() {
    let cfg = parse_ok("tests/fixtures/hook-mdev.conf");
    // The reference accepts hooks; v1 rejects each command line (1-6).
    assert_eq!(cfg.rules.len(), 8);
    assert!(matches!(cfg.rules[7].dev, DevMatch::Catchall));
    for r in &cfg.rules[..6] {
        assert_ne!(r.action_mask, 0, "line {} must carry a command", r.line);
    }
    let err = validate_v1(&cfg).unwrap_err();
    // eth0 is file line 4 (three comment lines precede it).
    assert_eq!(err.to_string(), "command hooks are unsupported in this build (line 4)");
}

#[test]
fn config_bad_fixture_errors() {
    pin_c_locale();
    let input = std::fs::read("tests/fixtures/bad-mdev.conf").unwrap();
    let err = parse(&input).unwrap_err();
    assert_eq!(err.to_string(), "syntax error during first pass: line 3 column 2");
}

#[test]
fn config_too_large() {
    pin_c_locale();
    let big = vec![b'#'; 8192];
    let err = parse(&big).unwrap_err();
    assert!(err.to_string().starts_with("configuration too large"));
    // Exactly 8191 bytes is accepted by size (content may still error).
    let edge = vec![b'\n'; 8191];
    let cfg = parse(&edge).unwrap();
    assert_eq!(cfg.rules.len(), 1);
    assert!(matches!(cfg.rules[0].dev, DevMatch::Catchall));
}

#[test]
fn config_regex_semantics() {
    pin_c_locale();
    let re = Regex::compile(b"(sd[a-z])").unwrap();
    assert!(re.is_match(b"sda"));
    assert!(!re.is_match(b"hd"));
    // Unanchored env search, like the reference.
    let env = Regex::compile(b"block").unwrap();
    assert!(env.is_match(b"block"));
    assert!(!env.is_match(b"blk"));
    // Invalid pattern surfaces libc's message.
    assert!(Regex::compile(b"*foo").is_err());
    // Full-match anchor check used by devmatch.
    let caps = re.captures10(b"sda").unwrap();
    assert_eq!(caps[0], Some((0, 3)));
    assert_eq!(caps[1], Some((0, 3)));
    assert!(re.captures10(b"xsda").unwrap()[0] != Some((0, 4)));
}

#[test]
fn config_minor_forms() {
    let cfg = parse_ok("tests/corpus/c-majmin.conf");
    assert!(matches!(
        cfg.rules[0].dev,
        DevMatch::MajMin { maj: 10, minlo: 20, minhi: 20 }
    ));
    let cfg = parse_ok("tests/corpus/c-majmin-range.conf");
    assert!(matches!(
        cfg.rules[0].dev,
        DevMatch::MajMin { maj: 10, minlo: 20, minhi: 30 }
    ));
    let cfg = parse_ok("tests/corpus/c-cont.conf");
    assert!(cfg.rules[0].cont && !cfg.rules[1].cont);
    let cfg = parse_ok("tests/corpus/c-numids.conf");
    assert_eq!((cfg.rules[0].uid, cfg.rules[0].gid, cfg.rules[0].mode), (1000, 100, 0o640));
}

#[test]
fn config_oracle_diff() {
    pin_c_locale();
    let oracle = Path::new(".work/oracle/dump-run");
    if !oracle.exists() {
        println!("note: oracle harness absent (run tools/build-oracle.sh); differential skipped");
        return;
    }
    let mut files: Vec<String> = std::fs::read_dir("tests/corpus")
        .unwrap()
        .map(|e| e.unwrap().path().to_str().unwrap().to_string())
        .collect();
    files.push("tests/fixtures/laputa-mdev.conf".into());
    files.push("tests/fixtures/hook-mdev.conf".into());
    files.push("tests/fixtures/bad-mdev.conf".into());
    files.sort();
    assert!(!files.is_empty());
    for f in files {
        let input = std::fs::read(&f).unwrap();
        let out = std::process::Command::new(oracle)
            .arg(&f)
            .arg("/dev/null")
            .output()
            .expect("run dump-run");
        let mut expected = Vec::new();
        expected.extend_from_slice(&out.stderr);
        expected.extend_from_slice(&out.stdout);
        // Strip the harness log prefix; keep reference fatal text.
        let expected = strip_prefix(&expected, b"dump-run: ");
        match parse(&input) {
            Ok(cfg) => {
                assert_eq!(out.status.code(), Some(0), "{f}: oracle failed");
                let actual = dump(&cfg);
                assert_eq!(
                    String::from_utf8_lossy(&actual),
                    String::from_utf8_lossy(&expected),
                    "{f}: rule dump differs"
                );
            }
            Err(e) => {
                assert_ne!(out.status.code(), Some(0), "{f}: we failed but oracle passed");
                if e.to_string().starts_with("configuration too large") {
                    // Registered divergence: the reference truncates; skip.
                    println!("note: {f} oversize, oracle comparison skipped (divergence)");
                    continue;
                }
                let exp = String::from_utf8_lossy(&expected);
                // Drop pre-failure PAT lines: success-path coverage already
                // pins every compiled pattern; here only the fatal line
                // and the exit code must agree.
                let exp: String = exp.lines().filter(|l| !l.starts_with("PAT ")).collect::<Vec<_>>().join("\n");
                assert_eq!(exp.trim_end(), e.to_string().as_str(), "{f}: error differs");
            }
        }
    }
}

fn strip_prefix(buf: &[u8], prefix: &[u8]) -> Vec<u8> {
    let mut o = Vec::new();
    for line in buf.split_inclusive(|&b| b == b'\n') {
        if let Some(rest) = line.strip_prefix(prefix) {
            // Drop "dump-run: fatal: " style prefixes, keep the message.
            if let Some(msg) = rest.strip_prefix(b"fatal: ").or_else(|| rest.strip_prefix(b"info: "))
            {
                o.extend_from_slice(msg);
                continue;
            }
        }
        o.extend_from_slice(line);
    }
    o
}

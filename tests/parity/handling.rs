use super::support::*;
use mdevd::config::{parse, validate_v1};
use mdevd::engine::fake::FakeOps;
use mdevd::engine::{on_event, Out, Outcome, Request, Run};
use mdevd::uevent::Uevent;
use std::path::Path;

fn compare_case(config: &Path, event: &Path) {
    compare_case_masked(config, event, false);
}

fn compare_case_masked(config: &Path, event: &Path, mask_ids: bool) {
    let sys = root().join("tests/sysroot");
    let golden = std::fs::read(event.with_extension("golden")).unwrap();
    let cfg = parse(&std::fs::read(config).unwrap()).unwrap();
    validate_v1(&cfg).unwrap();
    let mut buf = b"add@/dump\0".to_vec();
    let mut vars = vec![0];
    for line in std::fs::read_to_string(event).unwrap().lines() {
        vars.push(buf.len());
        buf.extend_from_slice(line.as_bytes());
        buf.push(0);
    }
    let ev = Uevent { buf, vars };
    let req = Request { cfg: &cfg, ev: &ev, slashsys: sys.as_os_str().as_encoded_bytes(),
        root_dev: (u32::MAX, u32::MAX) };
    let mut ops = FakeOps::default();
    for path in ["devices/x/dev", "devices/x/uevent", "devices/y/dev", "devices/z/uevent"] {
        ops.sysfiles.insert(path.as_bytes().to_vec(), std::fs::read(sys.join(path)).unwrap());
    }
    let mut transcript = Vec::new();
    let result = on_event(&req, &mut Run { ops: &mut ops, out: Out::Dry(&mut transcript) }).unwrap();
    assert_eq!(result, Outcome::Publish, "{}", event.display());
    let actual: Vec<u8> = transcript.iter().flat_map(|line| line.bytes().chain(*b"\n")).collect();
    if mask_ids {
        assert_eq!(mask_chown_ids(&actual), mask_chown_ids(&golden), "{}: handling differs", event.display());
    } else {
        assert_eq!(actual, golden, "{}: handling differs", event.display());
    }
    let ops_path = event.with_extension("ops");
    if ops_path.is_file() {
        ops.log.clear();
        let mut warnings = Vec::new();
        assert_eq!(on_event(&req, &mut Run { ops: &mut ops, out: Out::Real(&mut warnings) }).unwrap(),
            Outcome::Publish);
        assert!(warnings.is_empty(), "{warnings:?}");
        let actual = ops.log.join("\n") + "\n";
        assert_eq!(actual, std::fs::read_to_string(ops_path).unwrap(), "{}: applied operations differ", event.display());
    }
}

fn mask_chown_ids(buf: &[u8]) -> Vec<u8> {
    // Laputa goldens pin real group names; numeric ids vary by host.
    // Resolution itself is pinned by config_laputa_golden, so only
    // the surrounding handling stays byte-pinned here.
    let mut out = Vec::with_capacity(buf.len());
    let mut rest = buf;
    while let Some(i) = rest.windows(6).position(|w| w == b"chown ") {
        out.extend_from_slice(&rest[..i + 6]);
        rest = &rest[i + 6..];
        let mut j = 0;
        while j < rest.len() && rest[j].is_ascii_digit() {
            j += 1;
        }
        let mut k = j;
        if k < rest.len() && rest[k] == b':' {
            k += 1;
            while k < rest.len() && rest[k].is_ascii_digit() {
                k += 1;
            }
        }
        if j > 0 && k > j + 1 {
            out.extend_from_slice(b"UID:GID");
            rest = &rest[k..];
        }
    }
    out.extend_from_slice(rest);
    out
}

#[test]
fn parity_handling() {
    mdevd::config::regex::pin_c_locale();
    let dir = root().join("tests/parity/corpus/handling");
    let mut paths: Vec<_> = std::fs::read_dir(dir).unwrap().map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "evt")).collect();
    paths.sort();
    for event in paths { compare_case(&event.with_extension("conf"), &event); }
}

#[test]
fn parity_laputa() {
    mdevd::config::regex::pin_c_locale();
    let config = root().join("tests/fixtures/laputa-mdev.conf");
    let dir = root().join("tests/parity/corpus/laputa");
    let mut paths: Vec<_> = std::fs::read_dir(dir).unwrap().map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "evt")).collect();
    paths.sort();
    for event in paths { compare_case_masked(&config, &event, true); }
}

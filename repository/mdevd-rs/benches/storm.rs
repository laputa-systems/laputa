#![allow(clippy::all)]
use mdevd::config::parse;
use mdevd::engine::fake::FakeOps;
use mdevd::engine::{on_event, Out, Outcome, Request, Run};
use mdevd::uevent::Uevent;

fn rss_kb() -> u64 {
    let status = std::fs::read_to_string("/proc/self/status").unwrap();
    for line in status.lines() {
        if line.starts_with("VmRSS:") {
            return line.split_whitespace().nth(1).unwrap().parse().unwrap();
        }
    }
    panic!("VmRSS missing");
}

fn fd_count() -> usize {
    std::fs::read_dir("/proc/self/fd").unwrap().count()
}

fn main() {
    mdevd::config::regex::pin_c_locale();
    let raw = std::fs::read("tests/fixtures/laputa-mdev.conf").unwrap();
    let cfg = parse(&raw).unwrap();
    let mut buf = Vec::new();
    let mut vars = Vec::new();
    for part in [
        "add@/devices/x",
        "ACTION=add",
        "DEVPATH=/devices/x",
        "SUBSYSTEM=test",
        "DEVNAME=mydev",
        "MAJOR=1",
        "MINOR=2",
    ] {
        vars.push(buf.len());
        buf.extend_from_slice(part.as_bytes());
        buf.push(0);
    }
    let ev = Uevent { buf, vars };
    let mut ops = FakeOps::default();
    for _ in 0..10_000 {
        ops.log.clear();
        let req = Request {
            cfg: &cfg,
            ev: &ev,
            slashsys: b"/sys",
            root_dev: (u32::MAX, u32::MAX),
        };
        let mut t = Vec::new();
        assert_eq!(
            on_event(&req, &mut Run { ops: &mut ops, out: Out::Dry(&mut t) }).unwrap(),
            Outcome::Publish
        );
    }
    let rss_before = rss_kb();
    let fd_before = fd_count();
    for _ in 0..10_000 {
        ops.log.clear();
        let req = Request {
            cfg: &cfg,
            ev: &ev,
            slashsys: b"/sys",
            root_dev: (u32::MAX, u32::MAX),
        };
        let mut t = Vec::new();
        assert_eq!(
            on_event(&req, &mut Run { ops: &mut ops, out: Out::Dry(&mut t) }).unwrap(),
            Outcome::Publish
        );
    }
    let rss_after = rss_kb();
    let fd_after = fd_count();
    let growth = if rss_before == 0 {
        0.0
    } else {
        (rss_after as f64 - rss_before as f64) / rss_before as f64 * 100.0
    };
    println!("storm: rss_before={rss_before}kB rss_after={rss_after}kB growth={growth:.2}%");
    println!("storm: fds_before={fd_before} fds_after={fd_after}");
    if growth > 5.0 {
        eprintln!("storm: RSS growth {growth:.2}% exceeds 5% gate");
        std::process::exit(1);
    }
    if fd_after != fd_before {
        eprintln!("storm: FD delta {} != 0", fd_after as isize - fd_before as isize);
        std::process::exit(1);
    }
    println!("storm: OK");
}

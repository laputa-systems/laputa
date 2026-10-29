#![feature(test)]
extern crate test;
use test::Bencher;
use mdevd::config::parse;
use mdevd::engine::fake::FakeOps;
use mdevd::engine::{on_event, Out, Outcome, Request, Run};
use mdevd::uevent::Uevent;

fn fixture() -> (mdevd::config::Config, Uevent) {
    mdevd::config::regex::pin_c_locale();
    let raw = std::fs::read("tests/fixtures/laputa-mdev.conf").unwrap();
    let cfg = parse(&raw).unwrap();
    let mut buf = Vec::new();
    let mut vars = Vec::new();
    for part in [
        "add@/devices/pci0000:00/block/sda",
        "ACTION=add",
        "DEVPATH=/devices/pci0000:00/block/sda",
        "SUBSYSTEM=block",
        "DEVNAME=sda",
        "MAJOR=8",
        "MINOR=0",
    ] {
        vars.push(buf.len());
        buf.extend_from_slice(part.as_bytes());
        buf.push(0);
    }
    (cfg, Uevent { buf, vars })
}

#[bench]
fn bench_handle_sda(b: &mut Bencher) {
    let (cfg, ev) = fixture();
    b.iter(|| {
        let mut ops = FakeOps::default();
        let req = Request { cfg: &cfg, ev: &ev, slashsys: b"/sys", root_dev: (u32::MAX, u32::MAX) };
        let mut t = Vec::new();
        let r = on_event(&req, &mut Run { ops: &mut ops, out: Out::Dry(&mut t) }).unwrap();
        test::black_box(r == Outcome::Publish);
    });
}

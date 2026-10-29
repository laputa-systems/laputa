#![feature(test)]
extern crate test;
use test::Bencher;

#[bench]
fn bench_parse_laputa(b: &mut Bencher) {
    mdevd::config::regex::pin_c_locale();
    let input = std::fs::read("tests/fixtures/laputa-mdev.conf").unwrap();
    b.iter(|| {
        let cfg = mdevd::config::parse(&input).unwrap();
        test::black_box(cfg.rules.len())
    });
}

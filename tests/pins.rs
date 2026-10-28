//! R0: reference pins and fixture shape.
use std::path::Path;

#[test]
fn pins_recorded() {
    let pins = std::fs::read_to_string("tests/fixtures/pins.txt").expect("pins.txt");
    for needle in [
        "eac18f5",
        "8f1d3d06",
        "0.1.8.3",
        "0.1.8.2",
        "2.15.1.0",
        "laputa-mdev.conf",
    ] {
        assert!(pins.contains(needle), "pins.txt missing {needle}");
    }
}

#[test]
fn pins_laputa_fixture_shape() {
    let conf = std::fs::read_to_string("tests/fixtures/laputa-mdev.conf").expect("fixture");
    assert!(conf.contains("(null|zero|full|random|urandom) root:root 666"));
    assert!(conf.contains("SUBSYSTEM=block;"));
    assert!(conf.contains("ttyUSB"));
}

#[test]
fn pins_hook_and_bad_fixtures_present() {
    assert!(Path::new("tests/fixtures/hook-mdev.conf").exists());
    assert!(Path::new("tests/fixtures/bad-mdev.conf").exists());
    assert!(Path::new("tests/fixtures/laputa-invocation.txt").exists());
}

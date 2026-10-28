use super::Fixture;
use mdevd::config::parse;
use mdevd::engine::ops::{MknodOut, NodeKind, Ops};
use mdevd::engine::{on_event, Out, Outcome, Request, Run};
use mdevd::uevent::parse_record;
use std::os::unix::fs::{symlink, FileTypeExt, MetadataExt, PermissionsExt};

fn handled(f: &Fixture, ops: &mut impl Ops, action: &str, block: bool) {
    let config = parse(b"(node) 1000:100 640 >nested/%1\n").unwrap();
    let subsystem = if block { "block" } else { "test" };
    let record = format!("{action}@/devices/x\0ACTION={action}\0DEVPATH=/devices/x\0SUBSYSTEM={subsystem}\0DEVNAME=node\0MAJOR=1\0MINOR=3\0");
    let event = parse_record(record.as_bytes()).unwrap();
    let sys = f.root.join("sys");
    let request = Request { cfg: &config, ev: &event, slashsys: sys.as_os_str().as_encoded_bytes(), root_dev: (u32::MAX, u32::MAX) };
    let mut warnings = Vec::new();
    assert_eq!(on_event(&request, &mut Run { ops, out: Out::Real(&mut warnings) }).unwrap(), Outcome::Publish);
    assert!(warnings.is_empty(), "{warnings:?}");
}

#[test]
#[ignore = "requires tools/check-privileged.sh"]
fn adversarial_device_modes_aliases_and_repeated_add_remove() {
    for block in [false, true] {
        let f = Fixture::new(if block { "block" } else { "char" });
        let mut ops = f.ops();
        handled(&f, &mut ops, "add", block);
        let path = f.root.join("dev/nested/node");
        let first = std::fs::metadata(&path).unwrap();
        assert_eq!(first.file_type().is_block_device(), block);
        assert_eq!(first.file_type().is_char_device(), !block);
        assert_eq!(first.rdev(), libc::makedev(1, 3));
        assert_eq!((first.mode() & 0o7777, first.uid(), first.gid()), (0o640, 1000, 100));
        assert_eq!(std::fs::read_link(f.root.join("dev/node")).unwrap(), std::path::Path::new("nested/node"));
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        handled(&f, &mut ops, "remove", block);
        assert_eq!(std::fs::metadata(&path).unwrap().ino(), first.ino());
        handled(&f, &mut ops, "add", block);
        let second = std::fs::metadata(&path).unwrap();
        assert_eq!(second.ino(), first.ino());
        assert_eq!((second.mode() & 0o7777, second.uid(), second.gid()), (0o640, 1000, 100));
    }
}

#[test]
#[ignore = "requires tools/check-privileged.sh"]
fn adversarial_device_replacement_cannot_redirect_metadata() {
    let f = Fixture::new("metadata-swap");
    let mut ops = f.ops();
    assert_eq!(ops.mknod(b"node", 0o600, NodeKind::Char, 1, 3).unwrap(), MknodOut::Created);
    std::fs::rename(f.root.join("dev/node"), f.root.join("dev/held")).unwrap();
    let victim = f.root.join("outside/file");
    std::fs::write(&victim, b"victim").unwrap();
    std::fs::set_permissions(&victim, std::fs::Permissions::from_mode(0o600)).unwrap();
    symlink("../outside/file", f.root.join("dev/node")).unwrap();
    ops.chmod(b"node", 0o640).unwrap();
    ops.chown(b"node", 1000, 100).unwrap();
    let original = std::fs::metadata(f.root.join("dev/held")).unwrap();
    assert_eq!((original.mode() & 0o7777, original.uid(), original.gid()), (0o640, 1000, 100));
    let untouched = std::fs::metadata(victim).unwrap();
    assert_eq!((untouched.mode() & 0o7777, untouched.uid(), untouched.gid()), (0o600, 0, 0));
    assert!(ops.mknod(b"node", 0o666, NodeKind::Char, 1, 3).is_err());
    assert!(ops.chmod(b"node", 0o666).is_err());
}

#[test]
#[ignore = "requires tools/check-privileged.sh"]
fn adversarial_device_adopts_only_matching_identity() {
    let f = Fixture::new("identity");
    let mut ops = f.ops();
    assert_eq!(ops.mknod(b"node", 0o600, NodeKind::Char, 1, 3).unwrap(), MknodOut::Created);
    assert_eq!(ops.mknod(b"node", 0o640, NodeKind::Char, 1, 3).unwrap(), MknodOut::Exists);
    for (kind, major, minor) in [(NodeKind::Char, 1, 5), (NodeKind::Block, 1, 3)] {
        assert!(ops.mknod(b"node", 0o666, kind, major, minor).is_err());
        let node = std::fs::metadata(f.root.join("dev/node")).unwrap();
        assert!(node.file_type().is_char_device());
        assert_eq!(node.rdev(), libc::makedev(1, 3));
        assert_eq!(node.mode() & 0o7777, 0o600);
    }
}

#[test]
#[ignore = "requires tools/check-privileged.sh"]
fn adversarial_device_root_replacement_preserves_directory_identity() {
    let f = Fixture::new("root-swap");
    let mut ops = f.ops();
    std::fs::rename(f.root.join("dev"), f.root.join("original-dev")).unwrap();
    symlink("outside", f.root.join("dev")).unwrap();
    ops.mknod(b"node", 0o600, NodeKind::Char, 1, 3).unwrap();
    assert!(std::fs::symlink_metadata(f.root.join("original-dev/node")).unwrap().file_type().is_char_device());
    assert!(!f.root.join("outside/node").exists());
}

#[test]
#[ignore = "requires tools/check-privileged.sh"]
fn adversarial_device_ancestor_symlink_and_permissions() {
    let f = Fixture::new("device-ancestor");
    let mut ops = f.ops();
    symlink("../outside", f.root.join("dev/link")).unwrap();
    assert!(ops.mknod(b"link/node", 0o600, NodeKind::Char, 1, 3).is_err());
    assert!(ops.symlink_replace(b"node", b"link/alias").is_err());
    assert!(!f.root.join("outside/node").exists());
    assert!(!f.root.join("outside/alias").exists());
    let locked = f.root.join("dev/locked");
    std::fs::create_dir(&locked).unwrap();
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).unwrap();
    let denied = ops.mknod(b"locked/node", 0o600, NodeKind::Char, 1, 3);
    std::fs::set_permissions(locked, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert!(denied.is_err(), "container must drop DAC_OVERRIDE");
}

#[test]
#[ignore = "requires tools/check-privileged.sh"]
fn adversarial_device_repeats_release_fds_and_temporary_links() {
    let f = Fixture::new("fd-stability");
    let mut ops = f.ops();
    ops.mknod(b"node", 0o600, NodeKind::Char, 1, 3).unwrap();
    let before = std::fs::read_dir("/proc/self/fd").unwrap().count();
    for _ in 0..10_000 {
        assert_eq!(ops.mknod(b"node", 0o640, NodeKind::Char, 1, 3).unwrap(), MknodOut::Exists);
        ops.chmod(b"node", 0o640).unwrap();
        ops.chown(b"node", 1000, 100).unwrap();
        ops.symlink_replace(b"node", b"alias").unwrap();
    }
    assert_eq!(std::fs::read_dir("/proc/self/fd").unwrap().count(), before);
    let mut names: Vec<_> = std::fs::read_dir(f.root.join("dev")).unwrap()
        .map(|entry| entry.unwrap().file_name()).collect();
    names.sort();
    assert_eq!(names, ["alias", "node"]);
}

#[test]
#[ignore = "requires tools/check-privileged.sh"]
fn adversarial_device_execute_only_ancestor() {
    let f = Fixture::new("execute-only");
    let path = f.root.join("dev/private");
    std::fs::create_dir(&path).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o300)).unwrap();
    let result = f.ops().mknod(b"private/node", 0o600, NodeKind::Char, 1, 3);
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(result.unwrap(), MknodOut::Created);
    assert!(std::fs::symlink_metadata(path.join("node")).unwrap().file_type().is_char_device());
}

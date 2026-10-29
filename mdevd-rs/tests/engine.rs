//! Match-and-apply tests. `engine` filter.
//!
//! Hermetic unit tests always run. `engine_transcript_matches_goldens`
//! pins every dry-run transcript against a committed golden file.
use mdevd::config::regex::pin_c_locale;
use mdevd::config::parse;
use mdevd::engine::fake::{FakeOps, NullOps};
use mdevd::engine::ops::{MknodOut, Ops};
use mdevd::engine::{
    Action, Caps, Device, Out, Outcome, Request, Run, alias_format, match_rule, node_for, on_event,
};
use mdevd::uevent::Uevent;

fn uevent_of(lines: &[&str]) -> Uevent {
    let mut buf = b"add@/devices/x\0".to_vec();
    let mut vars = vec![0usize];
    for l in lines {
        vars.push(buf.len());
        buf.extend_from_slice(l.as_bytes());
        buf.push(0);
    }
    Uevent { buf, vars }
}

fn cfg_of(text: &str) -> mdevd::config::Config {
    pin_c_locale();
    parse(text.as_bytes()).unwrap()
}

fn dev(devname: &[u8]) -> Device {
    Device {
        devname: devname.to_vec(),
        kind: mdevd::engine::ops::NodeKind::Char,
        maj: Some(1),
        min: Some(2),
        action: Action::Add,
        sysdevpath: b"/sys/devices/x".to_vec(),
    }
}

#[test]
fn engine_alias_units() {
    let caps: Caps = [None; 10];
    let w = alias_format(4091, b"disk/%1", b"sda", &caps).unwrap();
    assert_eq!(&w[..w.len() - 1], b"disk/");
    let mut caps: Caps = [None; 10];
    caps[1] = Some((0, 3));
    let w = alias_format(4091, b"disk/%1", b"sda", &caps).unwrap();
    assert_eq!(&w[..w.len() - 1], b"disk/sda");
    let w = alias_format(4091, b"a%%b", b"sda", &caps).unwrap();
    assert_eq!(&w[..w.len() - 1], b"a%b");
    // Trailing % and stray %x are invalid.
    assert!(alias_format(4091, b"a%", b"sda", &caps).is_err());
    assert!(alias_format(4091, b"a%x", b"sda", &caps).is_err());
    // Unmatched groups substitute empty.
    let w = alias_format(4091, b"a%9b", b"sda", &[None; 10]).unwrap();
    assert_eq!(&w[..w.len() - 1], b"ab");
    // Bounds mirror the C outmax accounting (NUL counted).
    assert!(alias_format(4, b"abc", b"sda", &caps).is_ok());
    assert!(alias_format(3, b"abc", b"sda", &caps).is_err());
}

#[test]
fn engine_match_units() {
    let cfg = cfg_of("B=2;C=3;(my|your)dev root:root 600\n");
    let rule = &cfg.rules[0];
    let ev = uevent_of(&["ACTION=add", "B=2", "C=3"]);
    let d = dev(b"mydev");
    let caps = match_rule(&cfg, rule, &ev, &d).expect("match");
    assert_eq!(caps[0], Some((0, 5)));
    assert_eq!(caps[1], Some((0, 2)));
    // Wrong env fails; wrong dev fails; missing var fails.
    assert!(match_rule(&cfg, rule, &uevent_of(&["ACTION=add", "B=9", "C=3"]), &d).is_none());
    assert!(match_rule(&cfg, rule, &ev, &dev(b"other")).is_none());
    assert!(match_rule(&cfg, rule, &uevent_of(&["ACTION=add", "B=2"]), &d).is_none());
    // Unanchored env search (substring), anchored dev match.
    let cfg2 = cfg_of("B=2;mydev root:root 600\n");
    assert!(match_rule(&cfg2, &cfg2.rules[0], &uevent_of(&["B=xx2xx"]), &dev(b"mydev")).is_some());
    assert!(match_rule(&cfg2, &cfg2.rules[0], &uevent_of(&["B=2"]), &dev(b"mydevX")).is_none());
    // node_for with %1 substitution.
    let cfg3 = cfg_of("(sd[a-z]) root:disk 660 >disk/%1\n");
    let caps = match_rule(&cfg3, &cfg3.rules[0], &uevent_of(&[]), &dev(b"sda")).unwrap();
    assert_eq!(node_for(&cfg3, &cfg3.rules[0], b"sda", &caps).unwrap(), b"disk/sda");
    // MajMin matching.
    let cfg4 = cfg_of("@10,20-30 root:root 660\n");
    let mut dmm = dev(b"x");
    dmm.maj = Some(10);
    dmm.min = Some(25);
    assert!(match_rule(&cfg4, &cfg4.rules[0], &uevent_of(&[]), &dmm).is_some());
    dmm.min = Some(31);
    assert!(match_rule(&cfg4, &cfg4.rules[0], &uevent_of(&[]), &dmm).is_none());
}

fn dry_run(conf: &str, evt: &Uevent, sysfiles: Vec<(&[u8], &[u8])>) -> (Outcome, Vec<String>) {
    let cfg = cfg_of(conf);
    let abs = std::env::current_dir().unwrap();
    let sys = abs.join("tests/sysroot");
    let req = Request {
        cfg: &cfg,
        ev: evt,
        slashsys: sys.to_str().unwrap().as_bytes(),
        root_dev: (u32::MAX, u32::MAX),
    };
    let mut ops = FakeOps::default();
    for (k, v) in sysfiles {
        ops.sysfiles.insert(k.to_vec(), v.to_vec());
    }
    let mut t = Vec::new();
    let mut run = Run {
        ops: &mut ops,
        out: Out::Dry(&mut t),
    };
    let outcome = on_event(&req, &mut run).unwrap();
    (outcome, t)
}

fn read_evt(name: &str) -> Uevent {
    let text = std::fs::read_to_string(format!("tests/events/{name}")).unwrap();
    let lines: Vec<String> = text.lines().map(|l| l.to_string()).collect();
    uevent_of(&lines.iter().map(|s| s.as_str()).collect::<Vec<_>>())
}

#[test]
fn engine_dry_basic() {
    let (o, t) = dry_run("mydev root:root 600\n", &read_evt("add-basic.evt"), vec![]);
    assert_eq!(o, Outcome::Publish);
    assert_eq!(
        t,
        vec![
            "dry run: mknod mydev c 1 2",
            "dry run: chmod 600 mydev",
        ]
    );
}

#[test]
fn engine_dry_move_link() {
    let (o, t) = dry_run(
        "SUBSYSTEM=block;(sd[a-z]) root:disk 660 >disk/%1\n",
        &read_evt("add-block.evt"),
        vec![],
    );
    assert_eq!(o, Outcome::Publish);
    assert_eq!(
        t,
        vec![
            "dry run: mkdir disk",
            "dry run: mknod disk/sda b 8 0",
            "dry run: chmod 660 disk/sda",
            "dry run: chown 0:6 disk/sda",
            "dry run: symlink disk/sda to sda",
        ]
    );
}

#[test]
fn engine_quiet_events() {
    // remove/change/fieldless events publish with no transcript lines.
    for evt in ["remove.evt", "change.evt", "no-action.evt", "no-devpath.evt"] {
        let (o, t) = dry_run("mydev root:root 600\n", &read_evt(evt), vec![]);
        assert_eq!(o, Outcome::Publish, "{evt}");
        assert!(t.is_empty(), "{evt}: {t:?}");
    }
    let empty = Uevent {
        buf: b"add@/x\0".to_vec(),
        vars: vec![0],
    };
    let (o, t) = dry_run("mydev root:root 600\n", &empty, vec![]);
    assert_eq!(o, Outcome::Drop);
    assert!(t.is_empty());
}

#[test]
fn engine_stop_continue() {
    // First rule continues: both print. Stopping: only the first.
    let (o, t) = dry_run(
        "-nomatch root:root 600\nmydev root:root 601\n",
        &read_evt("add-basic.evt"),
        vec![],
    );
    assert_eq!(o, Outcome::Publish);
    assert_eq!(t, vec!["dry run: mknod mydev c 1 2", "dry run: chmod 601 mydev"]);
    let (o, t) = dry_run(
        "other root:root 600\nmydev root:root 601\n",
        &read_evt("add-basic.evt"),
        vec![],
    );
    assert_eq!(o, Outcome::Publish);
    assert_eq!(t, vec!["dry run: mknod mydev c 1 2", "dry run: chmod 601 mydev"]);
    let (o, t) = dry_run(
        "mydev root:root 600\n.* root:root 601\n",
        &read_evt("add-basic.evt"),
        vec![],
    );
    assert_eq!(o, Outcome::Publish);
    assert_eq!(t, vec!["dry run: mknod mydev c 1 2", "dry run: chmod 600 mydev"]);
}

#[test]
fn engine_sysfs_fallbacks() {
    // No MAJOR/MINOR in the event: sys dev file supplies them.
    let (o, t) = dry_run(
        "mydev root:root 600\n",
        &read_evt("no-mm.evt"),
        vec![(b"devices/x/dev".as_slice(), b"1:5\n".as_slice())],
    );
    assert_eq!(o, Outcome::Publish);
    assert_eq!(t, vec!["dry run: mknod mydev c 1 5", "dry run: chmod 600 mydev",]);
    // No DEVNAME: sys uevent file supplies it.
    let (o, t) = dry_run(
        "fromfile root:root 600\n",
        &read_evt("no-major.evt"),
        vec![
            (b"devices/x/dev".as_slice(), b"1:5\n".as_slice()),
            (b"devices/x/uevent".as_slice(), b"ACTION=add\nDEVNAME=fromfile\n".as_slice()),
        ],
    );
    assert_eq!(o, Outcome::Publish);
    assert_eq!(t, vec!["dry run: mknod fromfile c 1 5", "dry run: chmod 600 fromfile",]);
    // A sys uevent file without trailing newline ends the value instead of
    // crashing (see divergence.md).
    let (o, t) = dry_run(
        "fromuevent root:root 600\n",
        &read_evt("no-devname-z.evt"),
        vec![(b"devices/z/uevent".as_slice(), b"ACTION=add\nDEVNAME=fromuevent".as_slice())],
    );
    assert_eq!(o, Outcome::Publish);
    assert!(t.is_empty(), "{t:?}");
}

#[test]
fn engine_firmware_note() {
    let (o, t) = dry_run("mydev root:root 600\n", &read_evt("add-fw.evt"), vec![]);
    assert_eq!(o, Outcome::Publish);
    assert_eq!(
        t,
        vec![
            "dry run: mknod mydev c 1 2",
            "dry run: chmod 600 mydev",
            "firmware request for fw.bin skipped (unsupported)",
        ]
    );
}

#[test]
fn engine_real_sequences() {
    let cfg = cfg_of("(sd[a-z]) 1000:100 640 >disk/%1\n");
    let abs = std::env::current_dir().unwrap();
    let sys = abs.join("tests/sysroot");
    let req = Request {
        cfg: &cfg,
        ev: &read_evt("add-block.evt"),
        slashsys: sys.to_str().unwrap().as_bytes(),
        root_dev: (u32::MAX, u32::MAX),
    };
    let mut ops = FakeOps::default();
    let mut warns = Vec::new();
    let mut run = Run {
        ops: &mut ops,
        out: Out::Real(&mut warns),
    };
    assert_eq!(on_event(&req, &mut run).unwrap(), Outcome::Publish);
    assert!(warns.is_empty());
    assert_eq!(
        ops.log,
        vec![
            "subdirs:disk/sda",
            "mknod:disk/sda:640:b:8:0->Created",
            "chown:disk/sda:1000:100",
            "symlink:disk/sda->sda",
        ]
    );
    // Second run: node exists, chmod path instead.
    ops.mknod_out.insert(b"disk/sda".to_vec(), MknodOut::Exists);
    ops.log.clear();
    let mut warns = Vec::new();
    let mut run = Run {
        ops: &mut ops,
        out: Out::Real(&mut warns),
    };
    assert_eq!(on_event(&req, &mut run).unwrap(), Outcome::Publish);
    assert!(warns.is_empty());
    assert_eq!(
        ops.log,
        vec![
            "subdirs:disk/sda",
            "mknod:disk/sda:640:b:8:0->Exists",
            "chmod:disk/sda:640",
            "chown:disk/sda:1000:100",
            "symlink:disk/sda->sda",
        ]
    );
    // Failing mknod stops the rule loudly but still publishes.
    ops.fail.insert("mknod", "nope".into());
    ops.log.clear();
    let mut warns = Vec::new();
    let mut run = Run {
        ops: &mut ops,
        out: Out::Real(&mut warns),
    };
    assert_eq!(on_event(&req, &mut run).unwrap(), Outcome::Publish);
    assert_eq!(warns.len(), 1);
    assert_eq!(warns[0].level, 1);
    assert!(warns[0].msg.starts_with("unable to mknod disk/sda: "));
}

#[test]
fn engine_real_guards() {
    // RealOps refuses absolute and .. node paths without syscalls.
    let devdir = std::env::current_dir().unwrap().join(".work/tmp/devreal");
    let sysdir = std::env::current_dir().unwrap().join(".work/tmp/sysreal");
    std::fs::create_dir_all(&devdir).unwrap();
    std::fs::create_dir_all(&sysdir).unwrap();
    // Idempotent: clear artifacts from previous runs.
    let _ = std::fs::remove_file(devdir.join("planted"));
    let _ = std::fs::remove_file(devdir.join("link"));
    let mut ops =
        mdevd::engine::ops::RealOps::open(&devdir, &sysdir).expect("open real ops");
    assert!(ops.mknod(b"/abs/x", 0o660, mdevd::engine::ops::NodeKind::Char, 1, 5).is_err());
    assert!(ops.mknod(b"../x", 0o660, mdevd::engine::ops::NodeKind::Char, 1, 5).is_err());
    // A planted regular file is not adopted as a device node.
    std::fs::write(devdir.join("planted"), b"victim").unwrap();
    let e = ops
        .mknod(b"planted", 0o660, mdevd::engine::ops::NodeKind::Char, 1, 5)
        .unwrap_err();
    assert!(e.0.contains("not the expected device"), "{e}");
    // ...nor is a swapped-in symlink.
    #[cfg(unix)]
    std::os::unix::fs::symlink("planted", devdir.join("link")).unwrap();
    let e = ops
        .mknod(b"link", 0o660, mdevd::engine::ops::NodeKind::Char, 1, 5)
        .unwrap_err();
    assert!(e.0.contains("not the expected device"), "{e}");
    // NullOps resolves every fallback as absent.
    let mut null = NullOps;
    assert!(null.read_sys(b"devices/x/dev", 22).is_err());
}

/// Dry transcripts pinned as committed goldens (one per case).
#[test]
fn engine_transcript_matches_goldens() {
    pin_c_locale();
    let abs = std::env::current_dir().unwrap();
    let sysroot = abs.join("tests/sysroot");
    // (conf text, event file, golden stem).
    let cases: &[(&str, &str, &str)] = &[
        ("mydev root:root 600\n", "add-basic.evt", "add-basic"),
        ("SUBSYSTEM=block;(sd[a-z]) root:disk 660 >disk/%1\n", "add-block.evt", "add-block"),
        ("B=2;C=3;mydev root:root 600\n", "add-env.evt", "add-env"),
        ("mydev root:root 600\n", "remove.evt", "remove"),
        ("mydev root:root 600\n", "change.evt", "change"),
        ("mydev root:root 600\n", "no-action.evt", "no-action"),
        ("mydev root:root 600\n", "no-devpath.evt", "no-devpath"),
        ("-nomatch root:root 600\nmydev root:root 601\n", "add-basic.evt", "add-basic-nomatch"),
        ("mydev root:root 600\n.* root:root 601\n", "add-basic.evt", "add-basic-catchall"),
        ("mydev root:root 600\n", "no-mm.evt", "no-mm"),
        ("fromfile root:root 600\n", "no-major.evt", "no-major"),
        ("(sd[a-z]) root:disk 660 =disk/%1\n", "add-block.evt", "add-block-alias"),
        ("mydev root:root 660 !\n.* root:root 601\n", "add-basic.evt", "add-basic-cmd"),
    ];
    for (conf, evt, stem) in cases {
        let cfg = cfg_of(conf);
        let evtext = std::fs::read_to_string(abs.join("tests/events").join(evt)).unwrap();
        let ev = uevent_of(&evtext.lines().collect::<Vec<_>>());
        let mut ops = FakeOps::default();
        for name in ["devices/x/dev", "devices/x/uevent", "devices/y/dev", "devices/z/uevent"] {
            let bytes = std::fs::read(abs.join("tests/sysroot").join(name)).unwrap();
            ops.sysfiles.insert(name.as_bytes().to_vec(), bytes);
        }
        let req = Request {
            cfg: &cfg,
            ev: &ev,
            slashsys: sysroot.to_str().unwrap().as_bytes(),
            root_dev: (u32::MAX, u32::MAX),
        };
        let mut t = Vec::new();
        let mut run = Run {
            ops: &mut ops,
            out: Out::Dry(&mut t),
        };
        assert_eq!(on_event(&req, &mut run).unwrap(), Outcome::Publish, "{conf}/{evt}");
        let actual: Vec<u8> = t.iter().flat_map(|line| line.bytes().chain(*b"\n")).collect();
        let golden = abs.join("tests/events/transcript").join(format!("{stem}.golden"));
        if std::env::var_os("UPDATE_EXPECT").is_some() {
            std::fs::create_dir_all(golden.parent().unwrap()).unwrap();
            std::fs::write(&golden, &actual).unwrap();
            continue;
        }
        let expected = std::fs::read(&golden)
            .unwrap_or_else(|_| panic!("missing golden {}", golden.display()));
        assert_eq!(actual, expected, "{conf}/{evt}: transcript differs");
    }
}

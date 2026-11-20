use std::fs::{self, File, FileTimes};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

fn run(dir: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_ninja"))
        .arg("-j1")
        .args(args)
        .env_remove("NINJA_STATUS")
        .current_dir(dir)
        .output()
        .unwrap()
}

fn build(dir: &Path, args: &[&str]) {
    let output = run(dir, args);
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn scratch(name: &str) -> PathBuf {
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir =
        std::env::temp_dir().join(format!("gluon-{name}-{}-{nonce}", std::process::id()));
    fs::create_dir(&dir).unwrap();
    dir
}

fn write_source(path: &Path, contents: &str, seconds: u64) {
    fs::write(path, contents).unwrap();
    File::open(path)
        .unwrap()
        .set_times(FileTimes::new().set_modified(UNIX_EPOCH + Duration::from_secs(seconds)))
        .unwrap();
}

#[test]
fn keep_going_blocks_failed_edge_dependents() {
    for limit in ["0", "2"] {
        let dir = scratch("failed-dependency");
        fs::write(
            dir.join("build.ninja"),
            "rule fail\n  command = printf partial > bad; exit 1\nrule copy\n  command = cp $in $out\nrule good\n  command = printf good > $out\nbuild bad: fail\nbuild consumed: copy bad\nbuild alias: phony bad\nbuild transitive: copy alias\nbuild good: good\ndefault consumed transitive good\n",
        )
        .unwrap();
        let result = run(&dir, &["-j2", "-k", limit]);
        assert_eq!(result.status.code(), Some(1), "{result:?}");
        assert_eq!(fs::read_to_string(dir.join("bad")).unwrap(), "partial");
        assert_eq!(fs::read_to_string(dir.join("good")).unwrap(), "good");
        assert!(!dir.join("consumed").exists(), "{result:?}");
        assert!(!dir.join("transitive").exists(), "{result:?}");
        fs::remove_dir_all(dir).unwrap();
    }
}

#[test]
fn failed_dyndep_producer_does_not_block_independent_dyndep() {
    let dir = scratch("failed-dyndep");
    fs::write(
        dir.join("build.ninja"),
        "rule fail\n  command = printf partial > $out; exit 1\nrule copy\n  command = cp $in $out\nrule touch\n  command = touch $out\nbuild bad.dd: fail\nbuild blocked: touch || bad.dd\n  dyndep = bad.dd\nbuild good.dd: copy template.dd\nbuild good: touch || good.dd\n  dyndep = good.dd\ndefault blocked good\n",
    )
    .unwrap();
    fs::write(dir.join("template.dd"), "ninja_dyndep_version = 1\nbuild good: dyndep\n").unwrap();
    let result = run(&dir, &["-j2", "-k", "0"]);
    assert_eq!(result.status.code(), Some(1), "{result:?}");
    assert!(!dir.join("blocked").exists(), "{result:?}");
    assert!(dir.join("good").is_file(), "{result:?}");
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn clean_edge_does_not_hold_the_only_jobserver_token() {
    let dir = scratch("jobserver");
    let fifo = dir.join("fifo");
    assert!(Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    fs::write(
        dir.join("build.ninja"),
        "rule copy\n  command = cp $in $out\nbuild clean.o: copy clean.c\nbuild dirty.o: copy dirty.c\n",
    )
    .unwrap();
    fs::write(dir.join("clean.c"), "already built").unwrap();
    fs::write(dir.join("dirty.c"), "needs building").unwrap();
    build(&dir, &["clean.o"]);

    let output = Command::new(env!("CARGO_BIN_EXE_ninja"))
        .args(["clean.o", "dirty.o"])
        .current_dir(&dir)
        .env("MAKEFLAGS", format!("--jobserver-auth=fifo:{}", fifo.display()))
        .env_remove("NINJA_STATUS")
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    assert!(output.stderr.is_empty(), "{output:?}");
    assert!(!String::from_utf8_lossy(&output.stdout).contains("cp clean.c clean.o"));
    assert_eq!(fs::read_to_string(dir.join("dirty.o")).unwrap(), "needs building");
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn recorded_header_changes_rebuild_the_output() {
    let dir = scratch("depfile-header");
    fs::write(
        dir.join("build.ninja"),
        "rule copy\n  command = cp -p header out && printf 'out: header\\n' > out.d\n  depfile = out.d\n  deps = gcc\nbuild out: copy\n",
    )
    .unwrap();
    write_source(&dir.join("header"), "first", 1_700_000_000);
    build(&dir, &[]);
    assert_eq!(fs::read_to_string(dir.join("out")).unwrap(), "first");
    let idle = run(&dir, &[]);
    assert!(idle.status.success(), "{idle:?}");
    assert_eq!(idle.stdout, b"ninja: no work to do.\n");

    write_source(&dir.join("header"), "second", 1_700_000_001);
    build(&dir, &[]);
    assert_eq!(fs::read_to_string(dir.join("out")).unwrap(), "second");
    let idle = run(&dir, &[]);
    assert!(idle.status.success(), "{idle:?}");
    assert_eq!(idle.stdout, b"ninja: no work to do.\n");
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn missing_dependency_record_rebuilds_the_output() {
    for missing in ["absent", "truncated", "other-output"] {
        let dir = scratch("missing-dependency-record");
        fs::write(
            dir.join("build.ninja"),
            "rule compile\n  command = cc -MMD -MF app.d app.c -o app\n  depfile = app.d\n  deps = gcc\nrule other\n  command = touch other; printf 'other: app.c\\n' > other.d\n  depfile = other.d\n  deps = gcc\nbuild other: other\nbuild app: compile app.c\ndefault app\n",
        )
        .unwrap();
        fs::write(dir.join("app.c"), "#include \"value.h\"\nint main(void) { return VALUE; }\n").unwrap();
        fs::write(dir.join("value.h"), "#define VALUE 0\n").unwrap();
        build(&dir, &["other"]);
        let other_log = fs::read(dir.join(".ninja_deps")).unwrap();
        build(&dir, &[]);
        assert_eq!(Command::new(dir.join("app")).status().unwrap().code(), Some(0));
        let idle = run(&dir, &[]);
        assert!(idle.status.success(), "{idle:?}");
        assert_eq!(idle.stdout, b"ninja: no work to do.\n");
        let complete_log = fs::read(dir.join(".ninja_deps")).unwrap();
        match missing {
            "absent" => fs::remove_file(dir.join(".ninja_deps")).unwrap(),
            "truncated" => fs::write(dir.join(".ninja_deps"), &complete_log[..complete_log.len() - 1]).unwrap(),
            "other-output" => fs::write(dir.join(".ninja_deps"), &other_log).unwrap(),
            _ => unreachable!(),
        }
        fs::write(dir.join("value.h"), "#define VALUE 7\n").unwrap();
        let rebuilt = run(&dir, &[]);
        assert!(rebuilt.status.success(), "{rebuilt:?}");
        assert_ne!(rebuilt.stdout, b"ninja: no work to do.\n");
        assert_eq!(Command::new(dir.join("app")).status().unwrap().code(), Some(7));
        fs::remove_dir_all(dir).unwrap();
    }
}

#[test]
fn secondary_outputs_without_dependency_records_stay_idle() {
    for outputs in ["primary | secondary", "primary secondary"] {
        let dir = scratch("secondary-output-deps");
        fs::write(
            dir.join("build.ninja"),
            format!("rule generate\n  command = touch primary secondary; printf 'primary: input\\n' > primary.d\n  depfile = primary.d\n  deps = gcc\nbuild {outputs}: generate input\n"),
        )
        .unwrap();
        fs::write(dir.join("input"), "input").unwrap();
        build(&dir, &[]);
        let idle = run(&dir, &[]);
        assert!(idle.status.success(), "{idle:?}");
        assert_eq!(idle.stdout, b"ninja: no work to do.\n", "{outputs}");
        fs::remove_dir_all(dir).unwrap();
    }
}

#[test]
fn msvc_without_depfile_stays_idle() {
    let dir = scratch("msvc-no-depfile");
    fs::write(
        dir.join("build.ninja"),
        "rule generate\n  command = touch output\n  deps = msvc\nbuild output: generate input\n",
    )
    .unwrap();
    fs::write(dir.join("input"), "input").unwrap();
    build(&dir, &[]);
    let idle = run(&dir, &[]);
    assert!(idle.status.success(), "{idle:?}");
    assert_eq!(idle.stdout, b"ninja: no work to do.\n");
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn ordinary_inputs_rebuild_and_restat_stays_idle_after_observing_them() {
    let dir = scratch("incremental");
    fs::write(
        dir.join("build.ninja"),
        r"rule copy
  command = cp -p input $out
rule stable
  command = test -f $out || cp -p baseline $out; printf 'run\n' >> stable-runs
  restat = 1
rule downstream
  command = cp -p $in $out && printf 'run\n' >> downstream-runs
build direct: copy input
build implicit: copy | input
build ordered: copy || input
build alias: phony input
build through-alias: copy alias
build stamp: stable restat-input
build result: downstream stamp
default direct implicit ordered through-alias result
",
    )
    .unwrap();
    write_source(&dir.join("input"), "first", 1_700_000_000);
    write_source(&dir.join("baseline"), "unchanged", 1_700_000_000);
    write_source(&dir.join("restat-input"), "first", 1_700_000_000);

    build(&dir, &[]);
    write_source(&dir.join("input"), "second", 1_700_000_001);
    std::thread::sleep(Duration::from_millis(25));
    fs::write(dir.join("restat-input"), "second").unwrap();
    build(&dir, &[]);
    build(&dir, &[]);

    for output in ["direct", "implicit", "through-alias"] {
        assert_eq!(fs::read_to_string(dir.join(output)).unwrap(), "second", "{output}");
    }
    assert_eq!(fs::read_to_string(dir.join("ordered")).unwrap(), "first");
    assert_eq!(fs::read_to_string(dir.join("stable-runs")).unwrap(), "run\nrun\n");
    assert_eq!(fs::read_to_string(dir.join("downstream-runs")).unwrap(), "run\n");
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn stale_generated_dyndep_cannot_supply_a_missing_manifest_input() {
    let dir = scratch("stale-dyndep");
    let manifest = r"rule write_dd
  command = cp first.dd deps.dd
rule generate
  command = touch primary additional
rule consume
  command = test -f additional && touch $out
build deps.dd: write_dd first.dd new.dd
build primary: generate || deps.dd
  dyndep = deps.dd
build output: consume | additional || deps.dd
  dyndep = deps.dd
default output
";
    let old = "ninja_dyndep_version = 1\nbuild primary | additional: dyndep\nbuild output: dyndep\n";
    let new = "ninja_dyndep_version = 1\nbuild primary: dyndep\nbuild output: dyndep\n";
    fs::write(dir.join("build.ninja"), manifest).unwrap();
    fs::write(dir.join("first.dd"), old).unwrap();
    fs::write(dir.join("new.dd"), new).unwrap();
    build(&dir, &["deps.dd"]);
    build(&dir, &[]);
    fs::remove_file(dir.join("additional")).unwrap();
    fs::remove_file(dir.join("output")).unwrap();

    fs::write(
        dir.join("build.ninja"),
        manifest.replace("cp first.dd", "cp new.dd"),
    )
    .unwrap();
    for flags in [&["-n"][..], &[]] {
        let result = run(&dir, flags);
        assert_eq!(result.status.code(), Some(1), "{result:?}");
        assert_eq!(fs::read_to_string(dir.join("deps.dd")).unwrap(), old);
        assert!(!dir.join("additional").exists());
        assert!(!dir.join("output").exists());
    }
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn dirty_prerequisite_makes_generated_dyndep_unavailable() {
    let dir = scratch("stale-dyndep-prerequisite");
    fs::write(
        dir.join("build.ninja"),
        r"rule copy
  command = cp $in $out
rule generate
  command = touch primary additional
rule consume
  command = test -f additional && touch $out
build input.dd: copy template.dd
build deps.dd: copy input.dd
build primary: generate || deps.dd
  dyndep = deps.dd
build output: consume | additional || deps.dd
  dyndep = deps.dd
default output
",
    )
    .unwrap();
    let old = "ninja_dyndep_version = 1\nbuild primary | additional: dyndep\nbuild output: dyndep\n";
    fs::write(dir.join("template.dd"), old).unwrap();
    build(&dir, &["deps.dd"]);
    build(&dir, &[]);
    fs::remove_file(dir.join("additional")).unwrap();
    fs::remove_file(dir.join("output")).unwrap();
    std::thread::sleep(Duration::from_millis(25));
    fs::write(
        dir.join("template.dd"),
        "ninja_dyndep_version = 1\nbuild primary: dyndep\nbuild output: dyndep\n",
    )
    .unwrap();

    for flags in [&["-n"][..], &[]] {
        let result = run(&dir, flags);
        assert_eq!(result.status.code(), Some(1), "{result:?}");
        assert_eq!(fs::read_to_string(dir.join("input.dd")).unwrap(), old);
        assert_eq!(fs::read_to_string(dir.join("deps.dd")).unwrap(), old);
        assert!(!dir.join("output").exists());
    }
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn nested_dyndep_inputs_participate_in_metadata_readiness() {
    let dir = scratch("nested-dyndep");
    fs::write(
        dir.join("build.ninja"),
        r#"rule copy
  command = cp $in $out
rule select
  command = cp "$$(cat trigger)" $out
rule generate
  command = touch primary additional
rule consume
  command = test -f additional && touch $out
build scan.dd: copy scanner.dd
build trigger: copy trigger-source
build deps.dd: select first.dd new.dd || scan.dd
  dyndep = scan.dd
build primary: generate || deps.dd
  dyndep = deps.dd
build output: consume | additional || deps.dd
  dyndep = deps.dd
default output
"#,
    )
    .unwrap();
    let old = "ninja_dyndep_version = 1\nbuild primary | additional: dyndep\nbuild output: dyndep\n";
    fs::write(dir.join("first.dd"), old).unwrap();
    fs::write(
        dir.join("new.dd"),
        "ninja_dyndep_version = 1\nbuild primary: dyndep\nbuild output: dyndep\n",
    )
    .unwrap();
    fs::write(
        dir.join("scanner.dd"),
        "ninja_dyndep_version = 1\nbuild deps.dd: dyndep | trigger\n",
    )
    .unwrap();
    fs::write(dir.join("trigger-source"), "first.dd").unwrap();
    build(&dir, &["trigger", "deps.dd"]);
    build(&dir, &[]);
    fs::remove_file(dir.join("additional")).unwrap();
    fs::remove_file(dir.join("output")).unwrap();
    std::thread::sleep(Duration::from_millis(25));
    fs::write(dir.join("trigger-source"), "new.dd").unwrap();

    for flags in [&["-n"][..], &[]] {
        let result = run(&dir, flags);
        assert_eq!(result.status.code(), Some(1), "{result:?}");
        assert_eq!(fs::read_to_string(dir.join("trigger")).unwrap(), "first.dd");
        assert_eq!(fs::read_to_string(dir.join("deps.dd")).unwrap(), old);
        assert!(!dir.join("output").exists());
    }
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn current_dyndep_from_generator_is_usable_without_a_build_log() {
    let dir = scratch("ready-dyndep-no-log");
    fs::write(
        dir.join("build.ninja"),
        r"rule meta
  command = cp template.dd deps.dd && touch metadata-ran
  generator = 0
rule generate
  command = touch primary additional
rule consume
  command = test -f additional && touch $out
build deps.dd: meta template.dd
build primary: generate || deps.dd
  dyndep = deps.dd
build output: consume | additional || deps.dd
  dyndep = deps.dd
default output
",
    )
    .unwrap();
    let metadata =
        "ninja_dyndep_version = 1\nbuild primary | additional: dyndep\nbuild output: dyndep\n";
    fs::write(dir.join("template.dd"), metadata).unwrap();
    fs::write(dir.join("deps.dd"), metadata).unwrap();

    build(&dir, &["-n"]);
    assert!(!dir.join("output").exists());
    build(&dir, &[]);
    assert!(dir.join("output").is_file());
    assert!(!dir.join("metadata-ran").exists());
    build(&dir, &["-t", "clean"]);
    assert!(dir.join("deps.dd").is_file());
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn dry_run_reports_work_without_changing_files() {
    let dir = scratch("dry-run");
    fs::write(
        dir.join("build.ninja"),
        r"rule copy
  command = cp -p $in $out
  description = Copy $out
  rspfile = $out.rsp
  rspfile_content = $in
build output: copy input
",
    )
    .unwrap();
    write_source(&dir.join("input"), "first", 1_700_000_000);
    let cold = run(&dir, &["-n"]);
    assert!(cold.status.success(), "{cold:?}");
    assert_eq!(cold.stdout, b"[1/1] Copy output\n");
    let verbose = run(&dir, &["-n", "-v"]);
    assert!(verbose.status.success(), "{verbose:?}");
    assert_eq!(verbose.stdout, b"[1/1] cp -p input output\n");
    let quiet = run(&dir, &["-n", "--quiet"]);
    assert!(quiet.status.success(), "{quiet:?}");
    assert!(quiet.stdout.is_empty(), "{quiet:?}");
    for path in ["output", "output.rsp", ".ninja_log", ".ninja_deps"] {
        assert!(!dir.join(path).exists(), "{path}");
    }

    build(&dir, &[]);
    let build_log = fs::read(dir.join(".ninja_log")).unwrap();
    let clean = run(&dir, &["-n"]);
    assert!(clean.status.success(), "{clean:?}");
    assert_eq!(clean.stdout, b"ninja: no work to do.\n");

    write_source(&dir.join("input"), "second", 1_700_000_001);
    let changed = run(&dir, &["-n"]);
    assert!(changed.status.success(), "{changed:?}");
    assert_eq!(changed.stdout, b"[1/1] Copy output\n");
    assert_eq!(fs::read_to_string(dir.join("output")).unwrap(), "first");
    assert_eq!(fs::read(dir.join(".ninja_log")).unwrap(), build_log);
    assert!(!dir.join("output.rsp").exists());
    assert!(!dir.join(".ninja_deps").exists());
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn dry_run_cannot_load_newly_generated_dyndep_metadata() {
    let dir = scratch("dry-run-generated-dyndep");
    fs::write(
        dir.join("build.ninja"),
        r"rule prepare
  command = cp meta.src deps.dd
rule produce
  command = touch $out
build deps.dd: prepare meta.src
build output: produce || deps.dd
  dyndep = deps.dd
default output
",
    )
    .unwrap();
    fs::write(
        dir.join("meta.src"),
        "ninja_dyndep_version = 1\nbuild output: dyndep\n",
    )
    .unwrap();

    let result = run(&dir, &["-n"]);
    assert_eq!(result.status.code(), Some(1), "{result:?}");
    let stdout = String::from_utf8_lossy(&result.stdout);
    assert!(stdout.starts_with("[1/2] cp meta.src deps.dd\n"), "{result:?}");
    assert!(
        stdout.contains("loading 'deps.dd'"),
        "{result:?}"
    );
    for path in ["output", "deps.dd", ".ninja_log", ".ninja_deps"] {
        assert!(!dir.join(path).exists(), "{path}");
    }
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn dry_run_stops_after_previewing_manifest_regeneration() {
    let dir = scratch("dry-run-manifest");
    let manifest = r"rule regenerate
  command = cp template build.ninja
  generator = 1
rule produce
  command = touch $out
build build.ninja: regenerate template
build output: produce
default output
";
    write_source(&dir.join("build.ninja"), manifest, 1_700_000_000);
    write_source(&dir.join("template"), manifest, 1_700_000_001);
    let result = run(&dir, &["-n"]);
    assert!(result.status.success(), "{result:?}");
    assert_eq!(result.stdout, b"[1/1] cp template build.ninja\n");
    assert_eq!(
        fs::metadata(dir.join("build.ninja")).unwrap().modified().unwrap(),
        UNIX_EPOCH + Duration::from_secs(1_700_000_000)
    );
    assert!(!dir.join("output").exists());
    assert!(!dir.join(".ninja_log").exists());
    fs::remove_dir_all(dir).unwrap();
}

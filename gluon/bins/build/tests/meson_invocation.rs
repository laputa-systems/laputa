use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT: AtomicUsize = AtomicUsize::new(0);

fn run(command: &mut Command) -> std::process::Output {
    let output = command.output().unwrap();
    assert!(output.status.success(), "{command:?}: {}\n{}\n{}", output.status, String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
    output
}

fn fixture() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("gluon-meson-invocation-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("meson.build"), "project('test', 'c')\nstatic_library('value', 'value.c', install: true)\nconfigure_file(input: 'config.in', output: 'configured', command: ['cat', '@INPUT@'], capture: true)\nfs = import('fs')\nfs.copyfile('data.txt', 'copied.txt')\ncustom_target('captured', output: 'captured.txt', command: ['sh', '-c', 'printf captured'], capture: true, build_by_default: true)\n").unwrap();
    std::fs::write(dir.join("value.c"), "int value(void) { return 42; }\n").unwrap();
    std::fs::write(dir.join("data.txt"), "copied").unwrap();
    std::fs::write(dir.join("config.in"), "first").unwrap();
    dir
}

fn exercise(program: &Path, prefix: &[&str], integrated: bool) {
    let dir = fixture();
    let executable = dir.join("tool $'binary");
    std::fs::copy(program, &executable).unwrap();
    let program = executable.as_path();
    let build = dir.join("build");
    let dest = dir.join("dest");
    run(Command::new(program).args(prefix).arg("setup").arg(&build).arg(&dir).arg("--prefix=/usr/local"));
    let manifest = std::fs::read_to_string(build.join("build.ninja")).unwrap();
    if integrated {
        for suffix in ["meson --internal static-link", "meson install --no-rebuild", "meson setup --reconfigure", "meson --internal copy", "meson --internal exe"] {
            assert!(manifest.contains(suffix), "missing {suffix} in {manifest}");
        }
    }
    let ninja = ["/usr/bin/ninja", "/opt/homebrew/bin/ninja"].into_iter().find(|path| Path::new(path).is_file()).unwrap_or("ninja");
    run(Command::new(ninja).arg("-C").arg(&build));
    std::thread::sleep(std::time::Duration::from_millis(1100));
    std::fs::write(dir.join("config.in"), "second").unwrap();
    let regenerated = run(Command::new(ninja).arg("-C").arg(&build));
    assert!(String::from_utf8_lossy(&regenerated.stdout).contains("Regenerating build files"));
    assert_eq!(std::fs::read(build.join("configured")).unwrap(), b"second");
    run(Command::new(ninja).arg("-C").arg(&build).arg("install").env("DESTDIR", &dest));
    assert!(dest.join("usr/local/lib/libvalue.a").is_file());
    assert_eq!(std::fs::read(build.join("copied.txt")).unwrap(), b"copied");
    assert_eq!(std::fs::read(build.join("captured.txt")).unwrap(), b"captured");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn integrated_and_standalone_meson_build_and_install() {
    // Cargo releases its build lock before executing integration tests.
    run(Command::new("cargo").args(["build", "--profile", "dist", "--locked", "-p", "gluon-meson"]));
    let integrated = Path::new(env!("CARGO_BIN_EXE_gluon-build"));
    let standalone = integrated.parent().unwrap().parent().unwrap().join("dist/meson");
    exercise(&standalone, &[], false);
    exercise(integrated, &["meson"], true);
}

#[test]
fn setup_options_survive_configure_and_install() {
    let dir = fixture();
    let build = dir.join("build");
    let dest = dir.join("dest");
    let program = Path::new(env!("CARGO_BIN_EXE_gluon-build"));
    run(Command::new(program).args(["meson", "setup"]).arg(&build).arg(&dir).args(["--prefix=/usr", "--libdir=lib64"]));
    run(Command::new(program).args(["meson", "setup", "--reconfigure"]).arg(&build).arg(&dir));
    run(Command::new(program).args(["meson", "configure", "-Dbuildtype=release"]).arg(&build));
    let saved = std::fs::read_to_string(build.join("meson-private/cmd_line.txt")).unwrap();
    assert!(saved.contains("prefix=/usr"), "{saved}");
    assert!(saved.contains("libdir=lib64"), "{saved}");
    let ninja = ["/usr/bin/ninja", "/opt/homebrew/bin/ninja"].into_iter().find(|path| Path::new(path).is_file()).unwrap_or("ninja");
    run(Command::new(ninja).arg("-C").arg(&build).arg("install").env("DESTDIR", &dest));
    assert!(dest.join("usr/lib64/libvalue.a").is_file());
    std::fs::remove_dir_all(dir).unwrap();
}

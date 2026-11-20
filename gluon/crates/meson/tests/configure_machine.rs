use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT: AtomicUsize = AtomicUsize::new(0);

#[test]
fn cli_child() {
    if let Some(args) = std::env::var_os("GLUON_TEST_ARGS") {
        let args = args.to_str().unwrap().split('\n').map(str::to_owned).collect();
        std::process::exit(meson::Cli::parse_args_from(args).run());
    }
}

fn meson(dir: &std::path::Path, args: &[&str]) {
    let output = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "cli_child", "--nocapture"])
        .current_dir(dir)
        .env("GLUON_TEST_ARGS", [vec!["meson"], args.to_vec()].concat().join("\n"))
        .output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
}

fn machine_options_survive_configure(kind: &str) {
    let dir = std::env::temp_dir().join(format!("gluon-configure-machine-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("meson.build"), "project('test', 'c')\nexecutable('result', 'main.c')\n").unwrap();
    std::fs::write(dir.join("main.c"), "int main(void) { return MACHINE_VALUE; }\n").unwrap();
    std::fs::write(dir.join("machine.ini"), "[built-in options]\nc_args = ['-DMACHINE_VALUE=7']\n").unwrap();
    meson(&dir, &["setup", kind, "machine.ini", "-Dbuildtype=release", "build", "."]);
    meson(dir.parent().unwrap(), &["configure", "-Dbuildtype=debug", dir.join("build").to_str().unwrap()]);
    assert!(std::fs::read_to_string(dir.join("build/build.ninja")).unwrap().contains("-O0"));
    let output = Command::new("ninja").arg("-C").arg(dir.join("build")).output().unwrap();
    assert!(output.status.success(), "{}\n{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
    assert_eq!(Command::new(dir.join("build/result")).status().unwrap().code(), Some(7));
    meson(&dir, &["configure", "-Dc_args=['-DMACHINE_VALUE=9']", "build"]);
    let output = Command::new("ninja").arg("-C").arg(dir.join("build")).output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stdout));
    assert_eq!(Command::new(dir.join("build/result")).status().unwrap().code(), Some(9));
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn cross_file_options_survive_configure() {
    machine_options_survive_configure("--cross-file");
}

#[test]
fn native_file_options_survive_configure() {
    machine_options_survive_configure("--native-file");
}

#[test]
fn old_command_line_remains_readable() {
    let dir = std::env::temp_dir().join(format!("gluon-configure-old-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
    std::fs::create_dir_all(dir.join("build/meson-private")).unwrap();
    std::fs::write(dir.join("meson.build"), "project('test', 'c')\nexecutable('result', 'main.c')\n").unwrap();
    std::fs::write(dir.join("main.c"), "int main(void) { return MACHINE_VALUE; }\n").unwrap();
    std::fs::write(dir.join("build/meson-private/cmd_line.txt"), format!(
        "{{\"source_dir\":\"{}\",\"build_dir\":\"{}\",\"options\":[\"c_args=['-DMACHINE_VALUE=7']\"]}}",
        dir.display(), dir.join("build").display()
    )).unwrap();
    meson(&dir, &["configure", "-Dbuildtype=debug", "build"]);
    let output = Command::new("ninja").arg("-C").arg(dir.join("build")).output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stdout));
    assert_eq!(Command::new(dir.join("build/result")).status().unwrap().code(), Some(7));
    std::fs::remove_dir_all(dir).unwrap();
}

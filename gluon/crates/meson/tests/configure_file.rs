use std::path::PathBuf;
use std::process::Command;

static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

fn setup(source: &str) -> (std::process::Output, PathBuf) {
    let dir = std::env::temp_dir().join(format!(
        "gluon-configure-file-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("input.in"), "value=@VALUE@\n").unwrap();
    std::fs::write(dir.join("data.in"), "first").unwrap();
    std::fs::write(dir.join("meson.build"), format!("project('test')\n{source}\n")).unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "setup_child", "--nocapture"])
        .env("GLUON_TEST_SOURCE", &dir)
        .output().unwrap();
    (output, dir)
}

#[test]
fn setup_child() {
    if let Some(dir) = std::env::var_os("GLUON_TEST_SOURCE") {
        let dir = PathBuf::from(dir);
        let code = meson::Cli::parse_args_from(vec![
            "meson".into(), "setup".into(), dir.join("build").to_string_lossy().into_owned(),
            dir.to_string_lossy().into_owned(),
        ]).run();
        if code == 0 && let Some(wrapper) = std::env::var_os("GLUON_TEST_REGEN") {
            use_regeneration_wrapper(&dir, &PathBuf::from(wrapper));
        }
        std::process::exit(code);
    }
}

fn use_regeneration_wrapper(dir: &std::path::Path, wrapper: &std::path::Path) {
    let build_file = dir.join("build/build.ninja");
    let manifest = std::fs::read_to_string(&build_file).unwrap();
    let (before, rule) = manifest.split_once("rule REGENERATE_BUILD\n").unwrap();
    let (_, after) = rule.split_once('\n').unwrap();
    assert!(rule.starts_with("  command = "));
    let command = wrapper.to_string_lossy().replace('\'', "'\\''").replace('$', "$$");
    std::fs::write(build_file, format!("{before}rule REGENERATE_BUILD\n  command = sh '{command}'\n{after}")).unwrap();
}

fn reject(source: &str, expected: &[&str]) {
    let (output, dir) = setup(source);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success(), "setup succeeded: {stderr}");
    for part in expected {
        assert!(stderr.contains(part), "missing {part:?} in {stderr}");
    }
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn missing_configuration_input_fails_setup() {
    reject("configure_file(input: 'missing.in', output: 'out', configuration: configuration_data())", &["missing.in"]);
}

#[test]
fn failed_command_fails_setup() {
    reject("configure_file(output: 'out', command: ['sh', '-c', 'exit 7'])", &["exit 7", "7"]);
}

#[test]
fn successful_configuration_preserves_output() {
    let (output, dir) = setup("configure_file(output: 'out', configuration: {'VALUE': 'hello'})");
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(std::fs::read_to_string(dir.join("build/out")).unwrap().contains("#define VALUE hello"));
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn successful_input_and_capture_preserve_bytes() {
    let (output, dir) = setup("configure_file(input: 'input.in', output: 'configured', configuration: {'VALUE': 'hello'})\nconfigure_file(output: 'captured', command: ['sh', '-c', 'printf captured'], capture: true)");
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(std::fs::read(dir.join("build/configured")).unwrap(), b"value=hello\n");
    assert_eq!(std::fs::read(dir.join("build/captured")).unwrap(), b"captured");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn missing_command_fails_setup() {
    reject("configure_file(output: 'out', command: ['/no/such/gluon-command'])", &["/no/such/gluon-command"]);
}

#[test]
fn captured_command_input_regenerates_before_default_target() {
    let (output, dir) = setup("configured = configure_file(input: 'data.in', output: 'configured', command: ['sh', '-c', 'tr a-z A-Z < \"$1\"', 'sh', '@INPUT@'], capture: true)\ncustom_target('copy', input: configured, output: 'copied', command: ['cp', '@INPUT@', '@OUTPUT@'], build_by_default: true)");
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    // The test executable hosts the candidate CLI. A wrapper lets Ninja invoke it
    // for regeneration in the same way it invokes the standalone Meson binary.
    let wrapper = dir.join("candidate-meson");
    let exe = std::env::current_exe().unwrap().to_string_lossy().replace('\'', "'\\''");
    std::fs::write(&wrapper, format!("#!/bin/sh\nexec '{exe}' --exact setup_child --nocapture\n")).unwrap();
    use_regeneration_wrapper(&dir, &wrapper);

    // Prefer the system Ninja over an older gluon release on PATH.
    let ninja = ["/usr/bin/ninja", "/opt/homebrew/bin/ninja"].into_iter()
        .find(|path| std::path::Path::new(path).is_file()).unwrap_or("ninja");

    // Expected bytes are Meson 1.12.1's observed output (DSLP-20).
    let builds = [dir.join("build")];
    for build in &builds {
        assert_eq!(std::fs::read(build.join("configured")).unwrap(), b"FIRST");
    }
    for (input, expected) in [("first", b"FIRST".as_slice()), ("second", b"SECOND".as_slice())] {
        if input == "second" {
            std::thread::sleep(std::time::Duration::from_millis(1100));
            std::fs::write(dir.join("data.in"), input).unwrap();
        }
        for build in &builds {
            let output = Command::new(ninja).arg("-C").arg(build).env("GLUON_TEST_SOURCE", &dir).env("GLUON_TEST_REGEN", &wrapper).output().unwrap();
            assert!(output.status.success(), "{}\n{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
            assert_eq!(std::fs::read(build.join("configured")).unwrap(), expected, "{} configured", build.display());
            assert_eq!(std::fs::read(build.join("copied")).unwrap(), expected, "{} copied", build.display());
        }
    }
    std::fs::remove_dir_all(dir).unwrap();
}

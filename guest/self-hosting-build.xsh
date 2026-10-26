proc main(mode: Str = "verification") [fs, process, env, error] -> Result[Unit, Error] {
  let toolchain = "/seed/rust/lib/rustlib/x86_64-unknown-linux-musl/bin"
  var build_environment = {
    PATH: f"/bin:/usr/lib/xsh/core:/usr/bin:/seed/rust/bin:{toolchain}",
    HOME: "/scratch/home",
    TMPDIR: "/scratch",
    LANG: "C",
    LC_ALL: "C",
    TZ: "UTC",
    CARGO_HOME: "/scratch/cargo",
    CARGO_NET_OFFLINE: "true",
    CARGO_TARGET_DIR: "/output/target",
    CARGO_BUILD_TARGET: "x86_64-unknown-linux-musl",
    CARGO_BUILD_JOBS: "2",
    RUSTC: "/seed/rust/bin/rustc",
    RUSTC_WRAPPER: "/bin/kache",
    KACHE_CACHE_DIR: "/output/kache",
    KACHE_RUNTIME_DIR: "/scratch/kache-runtime",
    KACHE_SOCKET_PATH: "/scratch/kache-runtime/daemon.sock",
    KACHE_LOCAL_ONLY: "1",
    CC: "/usr/bin/clang",
    AR: f"{toolchain}/llvm-ar",
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER: "/inputs/laputa/guest/self-hosting-linker.xsh",
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS: "-C target-feature=+crt-static -C link-arg=-Wl,--defsym=__isoc23_sscanf=sscanf -C link-arg=-Wl,--defsym=__isoc23_strtol=strtol",
  }
  let cargo = /seed/rust/bin/cargo
  var argv = [cargo.display(), "build", "--locked", "--offline", "--profile", "verification", "-j", "2", "--target", "x86_64-unknown-linux-musl", "-p", "xsh", "-p", "xsht", "--no-default-features", "--features", "xsh/net xsh/tools xsht/native-tests", "--bin", "xsh", "--bin", "xsht", "--config", "source.crates-io.replace-with=\"vendored-sources\"", "--config", "source.vendored-sources.directory=\"/inputs/vendor\""]
  if mode == "debug" {
    process.set_rlimit("stack", soft: 8 * 1024 * 1024, hard: 8 * 1024 * 1024)?
    let limit = process.rlimit("stack")?
    assert limit.soft == 8 * 1024 * 1024 and limit.hard == 8 * 1024 * 1024
    let text = json.encode(limit)?
    print "LAP19_STACK_LIMIT" $text
    build_environment.CARGO_TARGET_DIR = "/output/target-debug"
    argv = [cargo.display(), "--config", "source.crates-io.replace-with=\"vendored-sources\"", "--config", "source.vendored-sources.directory=\"/inputs/vendor\"", "dev", "--help"]
  } else {
    assert mode == "verification"
  }
  let command_timeout = if mode == "debug" { 1200s } else { 3600s }
  let status = process.run(process.command_argv(cargo, argv, /inputs/xsh, build_environment, timeout: command_timeout))?
  if mode == "debug" {
    let code = status.shell_code()?
    print "LAP19_CARGO_EXIT" $code
    fail "in-guest debug driver failed" unless status.ok
    print "LAP19_DEBUG_DRIVER_OK"
    return
  }
  fail "in-guest XSH build failed" unless status.ok
  print "LAPUTA_SELF_HOSTING_COMPILED"
}

main(@args)?

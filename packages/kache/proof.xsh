use pm.proof
use pm.util as pm_util

type Stats = {local_hits: Int}

proc main(root = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "kache")
  proof.target_elf(root, p"usr/bin/kache", "kache")
  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "kache ok: cross-built"
    return
  }
  let tmp = fp"{root}/var/tmp/proof-kache"
  tmp.remove()
  tmp.mkdir(true)
  defer tmp.remove()
  fp"{tmp}/src".mkdir()
  fp"{tmp}/src/lib.rs".write("pub fn value() -> u32 { 42 }\n")
  fp"{tmp}/Cargo.toml".write("[package]\nname = \"kache-proof\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
  let dynlinker = fp"{root}/usr/lib/ld-musl-{pm_util.target_arch()?}.so.1"
  let rustc = fp"{tmp}/rustc"
  rustc.write(f"""#!/bin/xsh
proc main(...args: List[Str]) [process, error] {{
  run fp"{dynlinker}" fp"{root}/usr/bin/rustc" @args ?
}}
main(@args)?
""", mode: 0o755)
  let kache = fp"{root}/usr/bin/kache"
  env ({
    LD_LIBRARY_PATH: fp"{root}/usr/lib".display(),
    KACHE_HOST_CONFIG: "",
    KACHE_CACHE_DIR: fp"{tmp}/cache".display(),
    KACHE_RUNTIME_DIR: fp"{tmp}/runtime".display(),
    RUSTC: rustc.display(),
    RUSTC_WRAPPER: kache.display(),
    CARGO_INCREMENTAL: "0",
    CARGO_HOME: fp"{tmp}/cargo-home".display(),
  }) {
    run $dynlinker fp"{root}/usr/bin/cargo" "build" "--offline" "--manifest-path" fp"{tmp}/Cargo.toml"
    run $dynlinker fp"{root}/usr/bin/cargo" "clean" "--manifest-path" fp"{tmp}/Cargo.toml"
    run $dynlinker fp"{root}/usr/bin/cargo" "build" "--offline" "--manifest-path" fp"{tmp}/Cargo.toml"
    let stats = (run.text $kache "stats" "--json")
    let report = json.decode(stats)?.require(Stats)?
    run $kache "daemon" "stop"
    proof.ensure(report.local_hits > 0, "proof-kache", "second build did not restore a cached compilation")
  }
  print "kache ok: cached Rust compilation restored"
}

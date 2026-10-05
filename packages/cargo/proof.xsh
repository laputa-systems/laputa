##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

proc main(rootfs: Path = /rootfs) [fs, process, env, error] {
  proof.target_elf(rootfs, p"usr/bin/cargo", "cargo")
  proof.target_elf(rootfs, p"usr/bin/rustc", "rustc")
  let target_arch = pm_util.target_arch()?
  let rust_triple = if target_arch == "aarch64" { "aarch64-unknown-linux-musl" } else { "x86_64-unknown-linux-musl" }

  if ! fp"{rootfs}/usr/lib/rustlib/{rust_triple}/lib".exists() {
    return Err(proof.ProofError.Failed(kind: "proof-cargo", message: f"missing rust std for {rust_triple}"))
  }

  if pm_util.build_arch()? != target_arch {
    print "cargo ok: cross-built "${target_arch}
    return
  }

  let dynlinker = fp"{rootfs}/usr/lib/ld-musl-{target_arch}.so.1"
  let gcc_s = fp"{rootfs}/usr/lib/libgcc_s.so.1"

  if ! gcc_s.exists() {
    print "cargo ok: (runtime test skipped — libgcc_s.so.1 not in root)"
    return
  }

  var cargo = ""
  var rustc = ""
  let tmp = fp"{rootfs}/var/tmp/proof-cargo"
  tmp.remove(missing_ok: true)
  tmp.mkdir()
  defer tmp.remove(missing_ok: true)

  fp"{tmp}/src".mkdir()
  fp"{tmp}/cargo-home".mkdir()
  fp"{tmp}/Cargo.toml".write(
    """[package]
name = "cargo-proof-hello"
version = "0.1.0"
edition = "2024"
""",
  )
  fp"{tmp}/src/main.rs".write(
    """fn main() {
    println!("hello cargo");
}
""",
  )

  let rustc_wrapper = fp"{tmp}/rustc-wrapper"
  rustc_wrapper.write(
    f"""#!/bin/xsh
proc main(...args: List[Str]) [process, error] {{
  run fp"{dynlinker}" fp"{rootfs}/usr/bin/rustc" @args ?
}}
main(@args)?
""", mode: 0o755,
  )

  let linker_wrapper = fp"{tmp}/linker-wrapper"
  let linker = fp"{rootfs}/usr/lib/llvm23/bin/ld.lld"
  linker_wrapper.write(
    f"""#!/bin/xsh
proc main(...args: List[Str]) [process, error] {{
  var linker_args: List[Str] = []
  # rustc emits -m64 for a compiler driver, but direct ld.lld rejects it.
  for arg in args {{
    if arg.starts_with("-Wl,") {{
      let options = arg.split(",")
      var index = 1
      while index < options.len() {{
        linker_args = linker_args.push(options[index])
        index += 1
      }}
    }} else if arg != "-nostartfiles" and arg != "-nodefaultlibs" and arg != "-m64" {{
      linker_args = linker_args.push(arg)
    }}
  }}
  run fp"{dynlinker}" fp"{linker}" @linker_args ?
}}
main(@args)?
""", mode: 0o755,
  )

  env ({
    LD_LIBRARY_PATH: fp"{rootfs}/usr/lib".display(),
    PATH: f"{rootfs}/usr/bin:{e"PATH" ?? ""}",
    CARGO_HOME: fp"{tmp}/cargo-home".display(),
    RUSTC: rustc_wrapper.display(),
    RUSTFLAGS: f"-L native={rootfs}/usr/lib -C linker={linker_wrapper}",
  }) {
    cargo = run.text $dynlinker fp"{rootfs}/usr/bin/cargo" "--version"
    rustc = run.text $dynlinker fp"{rootfs}/usr/bin/rustc" "--version"
    run $dynlinker fp"{rootfs}/usr/bin/cargo" "build" "--release" "--offline" "--target" $rust_triple "--manifest-path" fp"{tmp}/Cargo.toml"
  }

  if ! cargo.starts_with("cargo ") {
    return Err(proof.ProofError.Failed(kind: "proof-cargo", message: f"unexpected cargo version: {cargo.trim()}"))
  }

  # The package is versioned by the Rust release, which rustc reports; cargo
  # has its own version number.
  let ver = proof.package_version(rootfs, "cargo")?

  if ! rustc.starts_with(f"rustc {ver} ") {
    return Err(proof.ProofError.Failed(kind: "proof-cargo", message: f"rustc --version reported {rustc.trim()}, expected {ver}"))
  }

  let hello = fp"{tmp}/target/{rust_triple}/release/cargo-proof-hello"
  let out = run.text $hello
  let trimmed = out.trim()

  if trimmed != "hello cargo" {
    return Err(proof.ProofError.Failed(kind: "proof-cargo", message: f"unexpected hello output: {trimmed}"))
  }

  print "cargo ok: "${trimmed}
}

main(@args)

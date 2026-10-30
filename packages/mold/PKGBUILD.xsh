##! Package recipe.
use pm.env as pm_env
use pm.make

error MoldBuildError = Invalid(message: Str)

## Package recipe export.
export const name = "mold"
## Package recipe export.
export const package_kind = "payload"
## Package recipe export.
export const ver = "2.42.1"
## Package recipe export.
export const rel = "1"
## Package recipe export.
export const deps = ["musl", "llvm-toolchain"]
## Package recipe export.
export const mkdeps_host = ["cmake", "samurai", "llvm-toolchain", "linux-headers"]
## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://github.com/rui314/mold/archive/refs/tags/vVERSION.tar.gz",
    kind: "auto",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "0580221bfdad7148ceeafd0ad3c1c7b3ca9e66b45950405230cc3f81a205c816"}],
  },
  {
    source: p"ninja_actions.xsh",
    kind: "file",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "SKIP"}],
  },
  {
    source: p"ninja_parser.xsh",
    kind: "file",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "SKIP"}],
  },
]
## Package recipe export.
export const filetree = [
  {path: p"usr/bin/mold", kind: "binary"},
  {path: p"usr/bin/ld.mold", kind: "symlink"},
  {path: p"usr/libexec/mold/ld", kind: "symlink"},
  {path: p"usr/share/licenses/mold", kind: "tree"},
]
## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cmake = process.which("cmake")?
  let actions = fp"{fs.cwd()?}/ninja_actions.xsh"
  actions.chmod(0o755)
  let failure = fp"{fs.cwd()?}/.mold-ninja-failure"
  env ({MOLD_NINJA_FAILURE: failure.display()}) {
  run $cmake "-G" "Ninja" "-B" "build" "-DCMAKE_BUILD_TYPE=Release" "-DBUILD_TESTING=OFF" \
    "-DMOLD_USE_MIMALLOC=OFF" f"-DCMAKE_MAKE_PROGRAM={actions}" pm_env.cmake_install_prefix_arg() pm_env.cmake_install_libdir_arg()
  if failure.exists() {
    return Err(MoldBuildError.Invalid(failure.read_text()?))
  }
  cd build {
    run $actions "mold"
  }
  }
  fs.install(p"build/mold", fp"{dest}/usr/bin/mold", 0o755, parents: true, overwrite: true)
  fs.install(p"LICENSE", fp"{dest}/usr/share/licenses/mold/LICENSE", 0o644, parents: true, overwrite: true)
  for license in [
    "blake3/LICENSE_A2", "blake3/LICENSE_CC0", "rust-demangle/LICENSE-APACHE", "rust-demangle/LICENSE-MIT",
    "tbb/LICENSE.txt", "zlib/LICENSE", "zstd/LICENSE",
  ] {
    fs.install(fp"third-party/{license}", fp"{dest}/usr/share/licenses/mold/{license}", 0o644, parents: true, overwrite: true)
  }
  fp"{dest}/usr/bin/ld.mold".symlink(to: p"mold")
  fp"{dest}/usr/libexec/mold".mkdir(parents: true)
  fp"{dest}/usr/libexec/mold/ld".symlink(to: p"../../bin/mold")
}

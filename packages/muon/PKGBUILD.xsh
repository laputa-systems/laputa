##! Package recipe metadata and build operations.
use pm.util as pm_util

## Package recipe export.
export const name = "muon"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "0.7.0"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl"]

## Package recipe export.
export const mkdeps_host = ["llvm-toolchain", "samurai"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://github.com/muon-build/muon/archive/refs/tags/VERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "e7095741dc11338f5ed8e0aa02e993fc34df4295dad4296127bbb212bcf56e07",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [{path: p"usr/bin/muon", kind: "binary"}]

error MuonError = Patch(message: Str)

# Musl provides realtime interfaces in libc, and its librt.so is a symlink to
# libc.so, which has no SONAME. muon resolves find_library() to that file's
# path, so linking it would record the build root's librt.so path as a
# DT_NEEDED entry that no runtime root can satisfy.
proc patch_realtime_dependency() [fs, error] {
  let meson = p"src/platform/meson.build"
  let text = fs.read_text(meson)?
  let lookup = "    librt = cc.find_library('rt', required: false)\n"

  if lookup not in text {
    return Err(MuonError.Patch(f"{meson} no longer looks up librt"))?
  }

  fs.write(meson, text.replace(lookup, "    librt = declare_dependency()\n"))?
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let cross_build = pm_util.build_arch()? != pm_util.target_arch()?
  var bootstrap_cc = cc
  var host_ld_library_path = ""

  if cross_build {
    let build_root = fp"{env.get("XSH_PM_BUILD_ROOT") ?? ""}"
    bootstrap_cc = fp"{build_root}/usr/bin/cc"
    host_ld_library_path = f"{build_root}/usr/lib:{build_root}/usr/lib/llvm23/lib"
  }

  patch_realtime_dependency()?
  fs.mkdir(p"build")?

  if cross_build {
    env ({
      LD_LIBRARY_PATH: host_ld_library_path,
    }) {
      run $bootstrap_cc "-std=c99" "-O2" "-Iinclude" "src/amalgam.c" "-o" "build/muon-bootstrap" ?
    }?
  } else {
    run $bootstrap_cc "-std=c99" "-O2" "-Iinclude" "src/amalgam.c" "-o" "build/muon-bootstrap" ?
  }

  let setup_args = [
    "setup",
    "-Dbuildtype=debug",
    "-Dlibcurl=disabled",
    "-Dlibarchive=disabled",
    "-Dlibpkgconf=disabled",
    "-Dsamurai=enabled",
    "-Dtracy=disabled",
    "-Dnative_backtrace=disabled",
    "-Ddocs=disabled",
    "-Dman-pages=disabled",
    "-Dmeson-docs=disabled",
    "-Dmeson-tests=disabled",
    "-Dwebsite=disabled",
    "build",
  ]

  if cross_build {
    env ({
      LD_LIBRARY_PATH: host_ld_library_path,
    }) {
      run "build/muon-bootstrap" ${setup_args} ?
      let build_ninja = p"build/build.ninja"
      var patched_ninja = build_ninja.read_text()?

      patched_ninja = patched_ninja.replace(
        """rule muon_build_c_linker
 command = cc""",
        f"""rule muon_build_c_linker
 command = {bootstrap_cc}""",
      )

      patched_ninja = patched_ninja.replace(
        """rule muon_build_c_compiler
 command = cc""",
        f"""rule muon_build_c_compiler
 command = {bootstrap_cc}""",
      )

      fs.write(build_ninja, patched_ninja)?
      run "build/muon-bootstrap" "-C" "build" "samu" ?
    }?
  } else {
    run "build/muon-bootstrap" ${setup_args} ?
    run "build/muon-bootstrap" "-C" "build" "samu" ?
  }

  fs.install(p"build/muon", fp"{dest}/usr/bin/muon", 0o755, parents: true, overwrite: true)?
}

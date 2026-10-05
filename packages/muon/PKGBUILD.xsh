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

# muon links a library that find_library() finds in the compiler's own search
# directories by its path, where Meson passes `-l<name>`. Musl's libm, librt,
# libdl, and libpthread are symlinks to libc.so, which has no SONAME, so a
# path link records the build root's path as DT_NEEDED and the result loads
# nowhere else. Like Meson, link such a library by name unless a static one
# was asked for.
proc patch_system_library_links() [fs, error] {
  let compiler = p"src/functions/compiler.c"
  let text = fs.read_text(compiler)?
  let lookup = """		if ((found = find_library_check_dirs(wk, libname, comp->libdirs, ext_order, ext_order_len))) {
			return (struct find_library_result){ found, find_library_found_location_system_dirs };
		}
"""

  if lookup not in text {
    return Err(MuonError.Patch(f"{compiler} no longer resolves libraries in the system directories"))?
  }

  fs.write(
    compiler,
    text.replace(
      lookup,
      """		if ((found = find_library_check_dirs(wk, libname, comp->libdirs, ext_order, ext_order_len))) {
			if (!(flags & (find_library_flag_only_static | find_library_flag_prefer_static))) {
				return (struct find_library_result){ make_str(wk, libname), find_library_found_location_link_arg };
			}
			return (struct find_library_result){ found, find_library_found_location_system_dirs };
		}
""",
    ),
  )?
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let cross_build = pm_util.build_arch()? != pm_util.target_arch()?
  var bootstrap_cc = cc
  var host_ld_library_path = ""

  if cross_build {
    let build_root = fp"{e"XSH_PM_BUILD_ROOT" ?? ""}"
    bootstrap_cc = fp"{build_root}/usr/bin/cc"
    host_ld_library_path = f"{build_root}/usr/lib:{build_root}/usr/lib/llvm23/lib"
  }

  patch_system_library_links()?
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

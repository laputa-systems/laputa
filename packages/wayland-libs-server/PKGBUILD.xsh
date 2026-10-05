##! Package recipe metadata and build operations.
use pm.env as pm_env
use pm.util as pm_util

## Package recipe export.
export const name = "wayland-libs-server"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "1.26.0"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl", "libffi", "expat"]

## Package recipe export.
export const mkdeps_host = ["llvm-toolchain", "muon", "samurai", "pkgconf", "expat", "libffi"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://gitlab.freedesktop.org/wayland/wayland/-/releases/VERSION/downloads/wayland-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "64176eaa46e4969903e286f8e5ef8331affc17fdf03ac9b58381d2b23162b7a3",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"usr/lib/libwayland-server.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libwayland-server.so.0",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libwayland-server.so.0.26.0",
    kind: "binary",
  },
]

proc write_embedded_dtd() {
  let dump = p"protocol/wayland.dtd".read_bytes()?.dump("hex-u8")
  let values = collect {
    for line in dump.split("\n") {
      let words = line.words()
      var index = 1

      while index < words.len() {
        yield f"0x{words[index]},"
        index += 1
      }
    }
  }

  p"src/wayland.dtd.h".write(
    f"""static const char wayland_dtd[] = {{{{
	{values.join(" ")}
}}}};
""",
  )
}

proc patch_python_generator(native_scanner: Str) {
  write_embedded_dtd()
  let meson_path = p"src/meson.build"
  let text = meson_path.read_text()?

  let patched = text.replace(
    """	prog_embed = find_program('embed.py', native: true)

	embed_dtd = custom_target(
		'wayland.dtd.h',
		input: '../protocol/wayland.dtd',
		output: 'wayland.dtd.h',
		command: [ prog_embed, '@INPUT@', 'wayland_dtd' ],
		capture: true
	)

	wayland_scanner_sources = [ 'scanner.c', embed_dtd ]
""",
    with: """	wayland_scanner_sources = [ 'scanner.c' ]
""",
  )

  meson_path.write(patched)
  let root_meson = p"meson.build"

  root_meson.write(
    root_meson.read_text()?.replace(
  """	rt_dep = []
	if not cc.has_function('clock_gettime', prefix: '#include <time.h>')
		rt_dep = cc.find_library('rt')
		if not cc.has_function('clock_gettime', prefix: '#include <time.h>', dependencies: rt_dep, args: cc_args)
			error('clock_gettime not found')
		endif
	endif
""",
  with: """	# musl provides realtime interfaces in libc.
	rt_dep = declare_dependency()
""",
),
  )

  meson_path.write(
    meson_path.read_text()?.replace(
      "\tmathlib_dep = cc.find_library('m', required: false)",
      with: "\tmathlib_dep = declare_dependency(link_args: ['-lm'])",
    ),
  )

  if native_scanner != "" {
    meson_path.write(
      meson_path.read_text()?.replace(
  """if meson.is_cross_build() or not get_option('scanner')
scanner_dep = dependency('wayland-scanner', native: true, version: meson.project_version())
wayland_scanner_for_build = find_program(scanner_dep.get_variable(pkgconfig: 'wayland_scanner'))
else
wayland_scanner_for_build = wayland_scanner
endif
""",
  with: f"""wayland_scanner_for_build = find_program('{native_scanner}')
""",
),
    )
  }
}

proc build_wayland(dest: Path) {
  let muon = process.which("muon")?
  let jobs_flag = f"-j{cpu.count()}"
  let pc = pm_env.pkg_config_context()?
  let build_root = e"XSH_PM_BUILD_ROOT" ?? ""

  let native_scanner = if pm_util.build_arch()? != pm_util.target_arch()? and build_root != "" {
    f"{build_root}/usr/bin/wayland-scanner"
  } else {
    ""
  }

  patch_python_generator(native_scanner)

  env ({
    LD_LIBRARY_PATH: pc.ld_library_path,
    PKG_CONFIG: pc.pkg_config,
    PKG_CONFIG_LIBDIR: pc.pkg_config_libdir,
    PKG_CONFIG_PATH: pc.pkg_config_path,
    PKG_CONFIG_SYSROOT_DIR: pc.pkg_config_sysroot,
  }) {
    run $muon "setup" pm_env.meson_prefix_arg() pm_env.meson_libdir_arg() "-Ddefault_library=shared" "-Ddocumentation=false" "-Ddtd_validation=false" "-Dtests=false" "build"

    if native_scanner != "" {
      let native_scanner_path = fp"{fs.cwd()?}/build/wayland-scanner-native"
      let clang = fp"{build_root}/usr/lib/llvm23/bin/clang-23"

      env ({
        PATH: f"{build_root}/usr/lib/llvm-toolchain/bin:{build_root}/usr/bin:{e"PATH" ?? ""}",
        LD_LIBRARY_PATH: f"{build_root}/usr/lib:{build_root}/usr/lib/llvm23/lib",
      }) {
        run $clang "-o" $native_scanner_path "src/scanner.c" "src/wayland-util.c" "-Ibuild" "-Ibuild/src" "-Isrc" f"-I{build_root}/usr/include" f"-L{build_root}/usr/lib" f"-Wl,-rpath,{build_root}/usr/lib" "-lexpat"
      }

      let ninja = p"build/build.ninja"
      let scanner_text = native_scanner_path.display()
      let ninja_text = ninja.read_text()?

      let ninja_text_build_root = ninja_text.replace(
        f" -- {build_root}/usr/bin/wayland-scanner ",
        with: f" -- {scanner_text} ",
      )

      ninja.write(ninja_text_build_root.replace(" -- src/wayland-scanner ", with: f" -- {scanner_text} "))
    }

    run $muon "-C" "build" samu $jobs_flag

    env ({
      DESTDIR: dest,
    }) {
      run $muon "-C" "build" install
    }
  }?
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  build_wayland(dest)

  for entry in fs.children(fp"{dest}/usr/lib")? {
    if entry.name.starts_with("libwayland-") and ! entry.name.starts_with("libwayland-server.so") {
      entry.path.remove()
    }
  }

  fp"{dest}/usr/bin".remove()
  fp"{dest}/usr/include".remove()
  fp"{dest}/usr/lib/pkgconfig".remove()
  fp"{dest}/usr/share".remove()
}

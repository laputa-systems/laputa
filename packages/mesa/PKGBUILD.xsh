##! Package recipe metadata and build operations.
use pm.env as pm_env
use pm.meson as pm_meson

## Package recipe export.
export const name = "mesa"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "26.2.4"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl", "libdrm", "wayland-libs-client"]

# Mesa's C++ (the GLSL compiler) links libc++ statically through the
# llvm-toolchain wrapper, so no runtime package carries a C++ library.
## Package recipe export.
export const mkdeps_host = [
  "llvm-toolchain",
  "linux-headers",
  "muon",
  "samurai",
  "pkgconf",
  "libdrm",
  "wayland-dev",
  "wayland-libs-client",
  "wayland-protocols",
]

## Package recipe export.
export const mkdeps_target = ["wayland-dev", "wayland-protocols"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://archive.mesa3d.org/mesa-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "bce5f7fbebb934373b86c999a064d52fb5065878dc57f287f95346648ec832e9",
      },
    ],
  },
  {
    source: p"files/generated/mesa-26.2.4-generated.tar.xz => generated",
    kind: "archive",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "48e216f3247792cd4215ad1841ea839c8920dae6348c592b555d7d49e02c8930",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"usr/include/EGL/egl.h",
    kind: "file",
  },
  {
    path: p"usr/include/EGL/eglext.h",
    kind: "file",
  },
  {
    path: p"usr/include/EGL/eglext_angle.h",
    kind: "file",
  },
  {
    path: p"usr/include/EGL/eglmesaext.h",
    kind: "file",
  },
  {
    path: p"usr/include/EGL/eglplatform.h",
    kind: "file",
  },
  {
    path: p"usr/include/GL/internal/dri_interface.h",
    kind: "file",
  },
  {
    path: p"usr/include/GLES2/gl2.h",
    kind: "file",
  },
  {
    path: p"usr/include/GLES2/gl2ext.h",
    kind: "file",
  },
  {
    path: p"usr/include/GLES2/gl2platform.h",
    kind: "file",
  },
  {
    path: p"usr/include/GLES3/gl3.h",
    kind: "file",
  },
  {
    path: p"usr/include/GLES3/gl31.h",
    kind: "file",
  },
  {
    path: p"usr/include/GLES3/gl32.h",
    kind: "file",
  },
  {
    path: p"usr/include/GLES3/gl3ext.h",
    kind: "file",
  },
  {
    path: p"usr/include/GLES3/gl3platform.h",
    kind: "file",
  },
  {
    path: p"usr/include/KHR/khrplatform.h",
    kind: "file",
  },
  {
    path: p"usr/include/gbm.h",
    kind: "file",
  },
  {
    path: p"usr/include/gbm_backend_abi.h",
    kind: "file",
  },
  {
    path: p"usr/lib/gbm/dri_gbm.so",
    kind: "binary",
  },
  {
    path: p"usr/lib/libEGL.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libEGL.so.1",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libEGL.so.1.0.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/libGLESv2.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libGLESv2.so.2",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libGLESv2.so.2.0.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/libgallium-26.2.4.so",
    kind: "binary",
  },
  {
    path: p"usr/lib/libgbm.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libgbm.so.1",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libgbm.so.1.0.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/dri.pc",
    kind: "file",
  },
  {
    path: p"usr/lib/pkgconfig/egl.pc",
    kind: "file",
  },
  {
    path: p"usr/lib/pkgconfig/gbm.pc",
    kind: "file",
  },
  {
    path: p"usr/lib/pkgconfig/glesv2.pc",
    kind: "file",
  },
]

# The smallest real Mesa: EGL (wayland, surfaceless, and drm platforms), GBM,
# and GLES 2/3 on the softpipe and virgl gallium drivers, with no LLVM, no
# Vulkan, no X11, and no desktop GL. The vendored generated sources match
# exactly this option set; changing it means regenerating them.
const mesa_options = [
  "-Dbuildtype=release",
  "-Dplatforms=wayland",
  "-Dgallium-drivers=softpipe,virgl",
  "-Dvulkan-drivers=",
  "-Degl=enabled",
  "-Dgbm=enabled",
  "-Dgles2=enabled",
  "-Dgles1=disabled",
  "-Dopengl=false",
  "-Dllvm=disabled",
  "-Dglx=disabled",
  "-Dxlib-lease=disabled",
  "-Dvalgrind=disabled",
  "-Dlibunwind=disabled",
  "-Dzstd=disabled",
  "-Dexpat=disabled",
  "-Dxmlconfig=disabled",
  "-Dzlib=disabled",
  "-Dlmsensors=disabled",
  "-Dshader-cache=disabled",
  "-Dgallium-va=disabled",
  "-Dvideo-codecs=",
  "-Dtools=",
  "-Dbuild-tests=false",
  "-Dselinux=false",
  "-Dperfetto=false",
  "-Dsysprof=false",
  "-Dgpuvis=false",
  "-Dteflon=false",
  "-Dgallium-rusticl=false",
  "-Dspirv-tools=disabled",
  "-Ddisplay-info=disabled",
  "-Dhtml-docs=disabled",
]

# Mesa runs every Python, bison, and flex generator through this program. The
# recipe removes each build edge that names it and stages the vendored output,
# so it only runs if an output the build needs was never vendored.
const vendored_generator = "build-support/laputa-vendored-output.xsh"

error MesaBuildError = Failed(kind: Str, message: Str)

type TextReplacement = {old: Str, new: Str}

proc replace_once(text: Str, file: Str, old: Str, new: Str) [error] -> Result[Str] {
  if old not in text {
    return Err(MesaBuildError.Failed(kind: "mesa-patch", message: f"{file} no longer contains the text this recipe replaces:\n{old}"))
  }

  text.replace(old, new)
}

proc patch_file(file: Path, replacements: List[TextReplacement]) [fs, error] {
  var text = file.read_text()?

  for replacement in replacements {
    text = replace_once(text, file.display(), replacement.old, replacement.new)?
  }

  fs.write(file, text)
}

proc write_vendored_generator() [fs, error] {
  let script = fp"{vendored_generator}"

  fs.write(
    script,
    """#!/bin/xsh
error VendoredOutputError = Missing(command: Str)

proc main(...argv: List[Str]) [error] {
  Err(VendoredOutputError.Missing(f"this Mesa generator output is not vendored: {argv.join(" ")}"))?
}

main(@args)?
""",
  )

  fs.chmod(script, 0o755)
}

proc patch_build() [fs, error] {
  write_vendored_generator()

  patch_file(
    p"meson.build",
    [
      # muon 0.5 rejects the rust_std project options; this build has no Rust.
      {
        old: """    'rust_std=2021',
    'build.rust_std=2021',
""",
        new: "",
      },
      # No Python in the build world: every Python output is vendored.
      {
        old: """# Find a python executable that meets our version requirement.
# - On Windows, a venv has no versioned aliased to 'python'.
# - On RHEL 9, python3 is 3.9, so we must use python3.12.
python_version_req = '>= 3.10'
python_exec_list = ['python3.16', 'python3.15', 'python3.14', 'python3.13',
                    'python3.12', 'python3.11', 'python3.10', 'python3', 'python']

foreach p : python_exec_list
  prog_python = find_program(p, required : false, version : python_version_req)
  if not prog_python.found()
    continue
  endif

  has_mako = run_command(
    prog_python, '-c',
    '''
import sys

try:
    try:
        from packaging.version import Version
    except:
        from distutils.version import StrictVersion as Version
except:
    sys.exit(2)

try:
    import mako
except:
    sys.exit(1)

if Version(mako.__version__) < Version("0.8.0"):
    sys.exit(1)
''', check: false)
  if has_mako.returncode() != 0
    continue
  endif

  has_yaml = run_command(prog_python, '-c', 'import yaml', check: false)
  if has_yaml.returncode() != 0
    continue
  endif

  break
endforeach

if not prog_python.found()
  error('Python ' + python_version_req + ' not found')
endif

if has_mako.returncode() == 1
  error('Python (3.x) mako module >= 0.8.0 required to build mesa.')
elif has_mako.returncode() == 2
  error('One of Python (3.x) packaging or distutils module is required.')
endif

if has_yaml.returncode() != 0
  error('Python (3.x) yaml module (PyYAML) required to build mesa.')
endif
""",
        new: f"""prog_vendored = find_program('{vendored_generator}')
prog_python = prog_vendored
""",
      },
      # Laputa's bison and flex cannot process Mesa's grammars; the generated
      # parsers and lexers are vendored with the Python outputs.
      {
        old: """  prog_bison = find_program('bison', required : false)

  if not prog_bison.found()
    prog_bison = find_program('byacc', required : needs_flex_bison, disabler : true)
    yacc_is_bison = false
  endif

  # Disable deprecated keyword warnings, since we have to use them for
  # old-bison compat.  See discussion in
  # https://gitlab.freedesktop.org/mesa/mesa/merge_requests/2161
  if find_program('bison', required : false, version : '> 2.3').found()
    prog_bison = [prog_bison, '-Wno-deprecated']
  endif

  prog_flex = find_program('flex', required : needs_flex_bison, disabler : true)
  prog_flex_cpp = prog_flex
""",
        new: """  prog_bison = prog_vendored
  prog_flex = prog_vendored
  prog_flex_cpp = prog_vendored
""",
      },
      # musl packages libm as a libc symlink; link it by name rather than
      # recording the build root's path as a DT_NEEDED entry.
      {
        old: "dep_m = cc.find_library('m', required : false)",
        new: "dep_m = declare_dependency(link_args : ['-lm'])",
      },
      # muon has no wayland module; src/loader runs wayland-scanner itself.
      {
        old: """  # This can be renamed just `wayland` when we require at least 1.8
  mod_wl = import('unstable-wayland')
""",
        new: "",
      },
    ],
  )

  patch_file(
    p"src/loader/meson.build",
    [
      {
        old: """  wp_protos = {
    'fifo-v1': mod_wl.find_protocol('fifo', state : 'staging', version : 1),
    'commit-timing-v1': mod_wl.find_protocol('commit-timing', state : 'staging', version : 1),
    'linux-dmabuf-unstable-v1': mod_wl.find_protocol('linux-dmabuf', state : 'unstable', version : 1),
    'presentation-time': mod_wl.find_protocol('presentation-time'),
    'tearing-control-v1': mod_wl.find_protocol('tearing-control', state : 'staging', version : 1),
    'linux-drm-syncobj-v1': mod_wl.find_protocol('linux-drm-syncobj', state : 'staging', version : 1),
    'color-management-v1': mod_wl.find_protocol('color-management', state : 'staging', version : 1)
  }
  wp_files = {}
  foreach name, xml : wp_protos
    wp_files += {name : mod_wl.scan_xml(xml, include_core_only : false)}
  endforeach
""",
        # Same outputs and names as scan_xml: private code plus a client header.
        new: """  wl_scanner = find_program(dependency('wayland-scanner', native : true).get_variable(pkgconfig : 'wayland_scanner'))
  wl_protocol_dir = dep_wl_protocols.get_variable(pkgconfig : 'pkgdatadir')
  wp_protos = {
    'fifo-v1': wl_protocol_dir / 'staging/fifo/fifo-v1.xml',
    'commit-timing-v1': wl_protocol_dir / 'staging/commit-timing/commit-timing-v1.xml',
    'linux-dmabuf-unstable-v1': wl_protocol_dir / 'unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml',
    'presentation-time': wl_protocol_dir / 'stable/presentation-time/presentation-time.xml',
    'tearing-control-v1': wl_protocol_dir / 'staging/tearing-control/tearing-control-v1.xml',
    'linux-drm-syncobj-v1': wl_protocol_dir / 'staging/linux-drm-syncobj/linux-drm-syncobj-v1.xml',
    'color-management-v1': wl_protocol_dir / 'staging/color-management/color-management-v1.xml',
  }
  wp_files = {}
  foreach name, xml : wp_protos
    wp_code = custom_target(
      name + '-protocol.c',
      input : xml,
      output : name + '-protocol.c',
      command : [wl_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
    )
    wp_client_header = custom_target(
      name + '-client-protocol.h',
      input : xml,
      output : name + '-client-protocol.h',
      command : [wl_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
    )
    wp_files += {name : [wp_code, wp_client_header]}
  endforeach
""",
      },
    ],
  )
}

type NinjaSplit = {kept: List[Str], vendored: List[Str]}

proc edge_outputs(build_line: Str) [error] -> Result[List[Str]] {
  let head = build_line.byte_slice(6).split(": ")[0]

  if "$" in head or "|" in head {
    return Err(MesaBuildError.Failed(kind: "mesa-ninja", message: f"unexpected escaped or implicit outputs: {build_line}"))
  }

  head.split(" ")
}

proc split_edge(split: NinjaSplit, block: List[Str]) [error] -> Result[NinjaSplit] {
  return split when block.len() == 0

  for line in block {
    if line.starts_with(" COMMAND = ") and vendored_generator in line {
      return {kept: split.kept, vendored: split.vendored.extend(edge_outputs(block[0])?)}
    }
  }

  {kept: split.kept.extend(block), vendored: split.vendored}
}

# Removes every build edge that runs the vendored generator, along with its
# `default` line, and copies its outputs from the staged generated tree into
# the build directory before samu runs. Outputs the default target does not
# need (Windows .def files, glvnd and GLX tables) may stay unvendored; samu
# fails if one is needed. Every vendored file must match a removed edge, so a
# stale set fails here.
proc stage_vendored_outputs() [fs, error] {
  let ninja = p"build/build.ninja"
  var split: NinjaSplit = {kept: [], vendored: []}
  var block: List[Str] = []

  for line in ninja.read_text()?.split("\n") {
    if block.len() > 0 and line.starts_with(" ") {
      block += [line]
      continue
    }

    split = split_edge(split, block)?
    block = []

    if line.starts_with("build ") {
      block = [line]
    } else {
      split = {kept: split.kept.push(line), vendored: split.vendored}
    }
  }

  split = split_edge(split, block)?
  let kept = [line for line in split.kept if ! (line.starts_with("default ") and line.byte_slice(8) in split.vendored)]
  fs.write(ninja, kept.join("\n"))
  var unvendored: List[Str] = []

  for output in split.vendored {
    let vendored = fp"generated/{output}"

    if fs.exists(vendored)? {
      fs.install(vendored, fp"build/{output}", 0o644, parents: true, overwrite: true)
    } else {
      unvendored += [output]
    }
  }

  let generated = p"generated".resolve()?

  for entry in fs.walk(generated, gitignore: false)? |> where .kind == "file" {
    let output = entry.path.strip_prefix(generated)?.display()

    if output not in split.vendored {
      return Err(MesaBuildError.Failed(kind: "mesa-generated", message: f"vendored {output} has no generator edge in this configuration"))
    }
  }

  print f"mesa: staged {split.vendored.len() - unvendored.len()} vendored outputs; unvendored: {unvendored.join(" ")}"
}

# muon 0.5 and 0.7 copy internal compile arguments, build-root include paths,
# and private libraries into the public fields of the egl, gbm, and glesv2
# pkg-config files. These are the files meson generates for this
# configuration.
proc write_pkg_config(dest: Path) [fs, error] {
  let dir = fp"{dest}/usr/lib/pkgconfig"
  let header = """prefix=/usr
includedir=\${prefix}/include
libdir=\${prefix}/lib
"""

  fs.write(
    fp"{dir}/egl.pc",
    f"""{header}
Name: egl
Description: Mesa EGL Library
Version: {ver}
Requires.private: libdrm >= 2.4.75
Libs: -L\${{libdir}} -lEGL
Libs.private: -lpthread -pthread -lm
Cflags: -I\${{includedir}}
""",
  )

  fs.write(
    fp"{dir}/gbm.pc",
    f"""{header}
gbmbackendspath=/usr/lib/gbm

Name: gbm
Description: Mesa gbm library
Version: {ver}
Libs: -L\${{libdir}} -lgbm
Cflags: -I\${{includedir}}
""",
  )

  fs.write(
    fp"{dir}/glesv2.pc",
    f"""{header}
Name: glesv2
Description: Mesa OpenGL ES 2.0 library
Version: {ver}
Libs: -L\${{libdir}} -lGLESv2
Libs.private: -lpthread -pthread -lm
Cflags: -I\${{includedir}}
""",
  )
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let muon = process.which("muon")?
  let jobs_flag = f"-j{cpu.count()}"
  let pc = pm_env.pkg_config_context()?
  let setup_args = pm_meson.setup_args(mesa_options)
  patch_build()

  env ({
    LD_LIBRARY_PATH: pc.ld_library_path,
    PKG_CONFIG: pc.pkg_config,
    PKG_CONFIG_LIBDIR: pc.pkg_config_libdir,
    PKG_CONFIG_PATH: pc.pkg_config_path,
    PKG_CONFIG_SYSROOT_DIR: pc.pkg_config_sysroot,
  }) {
    run $muon @setup_args ?
    stage_vendored_outputs()
    run $muon "-C" "build" samu $jobs_flag ?

    env ({
      DESTDIR: dest,
    }) {
      run $muon "-C" "build" install ?
    }
  }

  write_pkg_config(dest)
}

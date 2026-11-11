##! Package recipe metadata and build operations.
use pm.env as pm_env
use pm.meson as pm_meson

# Desktop GL ships headers and a pkg-config file but no libGL: there is no
# GLX (no X11 in Laputa), and desktop contexts are created through EGL,
# which is also how the Ghostty renderer consumes them. Meson writes gl.pc
# only when GLX is enabled.
proc write_gl_pkg_config(dest: Path) {
  fp"{dest}/usr/lib/pkgconfig/gl.pc".write(
    f"""prefix=/usr
includedir=\${{prefix}}/include
libdir=\${{prefix}}/lib

Name: gl
Description: Mesa OpenGL library
Version: {ver}
Requires.private: libdrm >= 2.4.75
Libs: -L\${{libdir}} -lGL
Libs.private: -lpthread -pthread -lm
Cflags: -I\${{includedir}}
""",
  )
}

## Package recipe export.
export const name = "mesa"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "26.2.4"

## Package recipe export.
export const rel = "3"

## Package recipe export.
export const deps = ["musl", "libdrm", "libudev-zero", "wayland-libs-client"]

## Package recipe export.
export const mkdeps_host = [
  "llvm-toolchain",
  "llvm-static",
  "linux-headers",
  "gluon",
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
        sha256: "213259fbfd304e5c92f478b3e649b26c9ae95bd920173e2f7a468643202eebf6",
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
    path: p"usr/include/GL/gl.h",
    kind: "file",
  },
  {
    path: p"usr/include/GL/glcorearb.h",
    kind: "file",
  },
  {
    path: p"usr/include/GL/glext.h",
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
    path: p"usr/lib/libvulkan_lvp.so",
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
    path: p"usr/lib/pkgconfig/gl.pc",
    kind: "file",
  },
  {
    path: p"usr/lib/pkgconfig/glesv2.pc",
    kind: "file",
  },
  {
    path: p"usr/share/vulkan/icd.d/lvp_icd.json",
    kind: "file",
  },
]

# Mesa with EGL (wayland, surfaceless, and drm platforms), GBM, GLES 2/3,
# and desktop GL on the virgl and software gallium drivers, the lavapipe
# Vulkan driver, and no X11. Lavapipe builds llvmpipe, which then serves
# software GL ahead of softpipe; both JIT through statically linked LLVM.
# Desktop GL is required by the Ghostty renderer (OpenGL 4.3 core); the
# software desktop version is probed by the proof. The vendored generated
# sources match exactly this option set; changing it means regenerating them.
const mesa_options = [
  "-Dbuildtype=release",
  "-Dplatforms=wayland",
  "-Dgallium-drivers=softpipe,virgl",
  "-Dvulkan-drivers=swrast",
  "-Dvulkan-manifest-per-architecture=false",
  "-Degl=enabled",
  "-Dgbm=enabled",
  "-Dgles2=enabled",
  "-Dgles1=disabled",
  "-Dopengl=true",
  "-Dllvm=enabled",
  "-Dshared-llvm=disabled",
  "-Dcpp_rtti=false",
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

const vendored_generator = "build-support/laputa-vendored-output.xsh"
const libgallium_link_map = "libgallium-link.map"

error MesaBuildError = Failed(kind: Str, message: Str)

type TextReplacement = {old: Str, new: Str}

proc replace_once(text: Str, file: Str, old: Str, new: Str) [error] -> Result[Str] {
  if old not in text {
    return Err(
      MesaBuildError.Failed(kind: "mesa-patch", message: f"{file} no longer contains the text this recipe replaces:\n{old}"),
    )
  }

  text.replace(old, with: new)
}

proc patch_file(file: Path, replacements: List[TextReplacement]) {
  var text = file.read_text()?

  for replacement in replacements {
    text = replace_once(text, file.display(), replacement.old, replacement.new)?
  }

  file.write(text)
}

proc write_vendored_generator() {
  let script = fp"{vendored_generator}"

  script.write(
    """#!/bin/xsh
error VendoredOutputError = Missing(command: Str)

proc main(...argv: List[Str]) [error] {
  Err(VendoredOutputError.Missing(f"this Mesa generator output is not vendored: {argv.join(" ")}"))?
}

main(@args)?
""",
    mode: 0o755,
  )
}

proc patch_build() {
  write_vendored_generator()

  patch_file(
    p"meson.build",
    [
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
      {
        old: """prog_glslang = find_program(
  'glslangValidator',
  native : true,
  required : with_vulkan_overlay_layer or with_aco_tests or with_bvh
)

if prog_glslang.found()
  _glslang_version = run_command(prog_glslang, ['--version'], check : false).stdout().split(':')[2]
  # Check if glslang has depfile support. Support was added in 11.3.0, but
  # Windows path support was broken until 11.9.0.
  #
  # It is intentional to check the build machine, since we need to ensure that
  # glslang will output valid paths on the build platform
  _glslang_check = build_machine.system() == 'windows' ? '>= 11.9.0' : '>= 11.3.0'
  if _glslang_version.version_compare(_glslang_check)
    glslang_depfile = ['--depfile', '@DEPFILE@']
  else
    glslang_depfile = []
  endif
  if with_bvh and _glslang_version.version_compare('< ' + _glslang_preamble_version)
    error('glslang >= ' + _glslang_preamble_version + ' is required.')
  endif
  if run_command(prog_glslang, [ '--quiet', '--version' ], check : false).returncode() == 0
    glslang_quiet = ['--quiet']
  else
    glslang_quiet = []
  endif
endif
""",
        new: f"""prog_glslang = find_program('{vendored_generator}')
glslang_depfile = []
glslang_quiet = []
""",
      },
    ],
  )

  # The uninstalled devenv manifest names the build directory and host CPU,
  # which arch-independent vendored outputs cannot hold.
  patch_file(
    p"src/gallium/targets/lavapipe/meson.build",
    [
      {
        old: """_dev_icdname = 'lvp_devenv_icd.@0@.json'.format(host_machine.cpu())
_dev_icd = custom_target(
  'lvp_devenv_icd',
  input : [vk_icd_gen, vk_api_xml],
  output : _dev_icdname,
  command : [
    prog_python, '@INPUT0@',
    '--api-version', '1.4', '--xml', '@INPUT1@',
    '--sizeof-pointer', sizeof_pointer,
    '--icd-lib-path', meson.current_build_dir(),
    '--icd-filename', icd_file_name,
    '--out', '@OUTPUT@',
  ],
  build_by_default : true,
)

devenv.append('VK_DRIVER_FILES', _dev_icd.full_path())
""",
        new: "",
      },
    ],
  )

}

type NinjaSplit = {kept: List[Str], vendored: List[Str]}

proc edge_outputs(build_line: Str) [error] -> Result[List[Str]] {
  let head = build_line.byte_slice(6).split(": ")[0]

  if "$" in head or "|" in head {
    return Err(
      MesaBuildError.Failed(kind: "mesa-ninja", message: f"unexpected escaped or implicit outputs: {build_line}"),
    )
  }

  head.split(" ")
}

proc split_edge(split: NinjaSplit, block: List[Str]) -> Result[NinjaSplit] {
  return split when block.is_empty()

  for line in block {
    if line.trim().starts_with("COMMAND = ") and vendored_generator in line {
      return {kept: split.kept, vendored: split.vendored.extend(edge_outputs(block[0])?)}
    }
  }

  {kept: split.kept.extend(block), vendored: split.vendored}
}

proc stage_vendored_outputs() {
  let ninja = p"build/build.ninja"
  var split: NinjaSplit = NinjaSplit(kept: [], vendored: [])
  var block = []

  for line in ninja.read_text()?.split("\n") {
    if ! block.is_empty() and line.starts_with(" ") {
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
  ninja.write(split.kept.join("\n"))
  let unvendored: List[Str] = collect {
    for output in split.vendored {
      let vendored = fp"generated/{output}"

      if vendored.exists() {
        fs.install(vendored, fp"build/{output}", 0o644, parents: true, overwrite: true)
      } else {
        yield output
      }
    }
  }

  let generated = p"generated".resolve()?

  for entry in fs.walk(generated, gitignore: false)? |> where .kind == "file" {
    let output = entry.path.strip_prefix(generated)?.display()

    if output not in split.vendored {
      return Err(
        MesaBuildError.Failed(kind: "mesa-generated", message: f"vendored {output} has no generator edge in this configuration"),
      )
    }
  }

  print f"mesa: staged {split.vendored.len() - unvendored.len()} vendored outputs; unvendored: {unvendored.join(" ")}"
}

proc add_libgallium_link_map() -> Result[Str, Error] {
  let ninja = p"build/build.ninja"
  var output: List[Str] = []
  var in_edge = false
  var library = ""

  for line in ninja.read_text()?.split("\n") {
    if line.starts_with("build ") {
      let head = line.split(": ")[0]
      in_edge = head.ends_with(f"/libgallium-{ver}.so")

      if in_edge {
        library = head.byte_slice(6)
      }
    }

    if in_edge and line.starts_with("  LINK_ARGS = ") {
      let args = line.byte_slice(14)
      output += [f"  LINK_ARGS = -Wl,-Map={libgallium_link_map} {args}"]
      in_edge = false
      continue
    }

    output += [line]
  }

  if library == "" {
    return Err(
      MesaBuildError.Failed(kind: "mesa-link-map", message: f"build.ninja has no libgallium-{ver}.so link edge"),
    )
  }

  ninja.write(output.join("\n"))
  library
}

proc report_libgallium_link_map(link_map_path: Path, library: Path) -> Result[Str, Error] {
  guard link_map_path.exists() else {
    return Err(MesaBuildError.Failed(kind: "mesa-link-map", message: f"the libgallium link wrote no map at {link_map_path}"))
  }

  var llvm_bytes = 0
  var llvm_sections = 0
  var cxx_bytes = 0
  var cxx_sections = 0
  var included_bytes = 0

  for line in link_map_path.read_lines()? {
    let fields = line.fields()
    continue unless fields.len() >= 5

    let input = fields[4]
    continue unless ":(" in input

    let size = f"0x{fields[2]}".parse_int() ?? 0
    included_bytes += size

    if "/usr/lib/llvm-static/" in input {
      llvm_bytes += size
      llvm_sections += 1
    } else if "/usr/lib/llvm23/lib/" in input {
      cxx_bytes += size
      cxx_sections += 1
    }
  }

  if llvm_bytes == 0 {
    return Err(
      MesaBuildError.Failed(kind: "mesa-link-map", message: f"{link_map_path} attributes no live input section to llvm-static"),
    )
  }

  let file_size = fs.stat(library)?.size
  let map_size = fs.stat(link_map_path)?.size
  f"mesa link map: {link_map_path.display()} {map_size} bytes sha256 {hash.sha256(link_map_path)?.hex()}; libgallium {library.display()} {file_size} bytes; LLVM {llvm_bytes} bytes in {llvm_sections} live input sections; llvm-toolchain libc++/unwind {cxx_bytes} bytes in {cxx_sections} live input sections; all live input sections {included_bytes} bytes"
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let meson = process.which("meson")?
  let ninja = process.which("ninja")?
  let jobs_flag = f"-j{cpu.count()}"
  let pc = pm_env.pkg_config_context()?
  let setup_args = pm_meson.setup_args(mesa_options)
  patch_build()

  env ({
    PATH: f"{pc.pkg_config_sysroot}/usr/lib/llvm-static/bin:{e"PATH" ?? ""}",
    LD_LIBRARY_PATH: pc.ld_library_path,
    PKG_CONFIG: pc.pkg_config,
    PKG_CONFIG_LIBDIR: pc.pkg_config_libdir,
    PKG_CONFIG_PATH: pc.pkg_config_path,
    PKG_CONFIG_SYSROOT_DIR: pc.pkg_config_sysroot,
  }) {
    run $meson @setup_args
    stage_vendored_outputs()
    let libgallium = add_libgallium_link_map()?
    run $ninja "-C" "build" $jobs_flag
    print report_libgallium_link_map(fp"build/{libgallium_link_map}", fp"build/{libgallium}")?

    env ({
      DESTDIR: dest,
    }) {
      run $meson "install" "-C" "build"
    }
  }

  write_gl_pkg_config(dest)
}

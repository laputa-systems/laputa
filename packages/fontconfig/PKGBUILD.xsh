##! Shared Fontconfig package.
use pm.env as pm_env
use pm.make
use pm.types

## Package name.
export const name = "fontconfig"
## Package kind.
export const package_kind = "payload"
## Upstream version.
export const ver = "2.18.3"
## Package revision.
export const rel = "2"
## Runtime dependencies.
export const deps = ["musl", "freetype", "expat"]
## Build dependencies.
export const mkdeps_host = ["llvm-toolchain", "muon", "samurai", "pkgconf"]
## Verified source inputs.
export const upstream_sources = [
  {
    source: p"https://gitlab.freedesktop.org/api/v4/projects/890/packages/generic/fontconfig/VERSION/fontconfig-VERSION.tar.xz",
    kind: "auto",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "4f7b554a38cdf78c033f666c8871f3749e14a094f65a07f630c91ed0b43d35e3"}],
  },
  {
    source: p"files/generated/fontconfig-2.18.3-generated.tar.xz => generated",
    kind: "archive",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "41705ed03d85decfd7e78b807999a2cdeca4af5937a576c96d1189520b917247"}],
  },
]
## Installed files.
export const filetree = [
  {path: p"usr/include/fontconfig", kind: "tree"},
  {path: p"usr/lib/libfontconfig.so", kind: "symlink"},
  {path: p"usr/lib/libfontconfig.so.1", kind: "symlink"},
  {path: p"usr/lib/libfontconfig.so.1.17.0", kind: "binary"},
  {path: p"usr/lib/pkgconfig/fontconfig.pc", kind: "file"},
  {path: p"usr/share/xml/fontconfig/fonts.dtd", kind: "file"},
]

type NinjaSplit = {kept: List[Str], removed: List[Str]}

proc split_edge(split: NinjaSplit, block: List[Str]) -> Result[NinjaSplit] {
  return split when block.is_empty()
  let generated = [
    "fcalias.h", "fcaliastail.h", "fcftalias.h", "fcftaliastail.h",
    "fc-case/fccase.h", "fc-lang/fclang.h", "fc-const/fcconst.h",
    "fc-genericfamily/fcgenericfamily.h", "fc-genericfamily/fcgenericfamily.gperf",
    "src/fcobjshash.h", "src/fcobjshash.gperf", "src/preprocess.p/fcobjshash.gperf.h.i",
  ]
  let head = block[0].byte_slice(6).split(": ")[0]
  let outputs = head.split(" ")
  if outputs[0] in generated {
    for output in outputs {
      if output not in generated {
        return Err(types.PmError.PackageContract(f"fontconfig: unexpected generator output {output}"))
      }
    }
    return {kept: split.kept, removed: split.removed.extend(outputs)}
  }
  {kept: split.kept.extend(block), removed: split.removed}
}

proc stage_generated() {
  let ninja = p"build/build.ninja"
  var split: NinjaSplit = {kept: [], removed: []}
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
      split = {kept: split.kept.push(line), removed: split.removed}
    }
  }
  split = split_edge(split, block)?
  let kept = [line for line in split.kept if ! (line.starts_with("default ") and line.byte_slice(8) in split.removed)]
  ninja.write(kept.join("\n"))
  let generated = p"generated".resolve()?
  for entry in fs.walk(generated, gitignore: false)? |> where .kind == "file" {
    let output = entry.path.strip_prefix(generated)?.display()
    if output not in split.removed {
      return Err(types.PmError.PackageContract(f"fontconfig: no generator edge for {output}"))
    }
    fs.install(entry.path, fp"build/{output}", 0o644, parents: true, overwrite: true)
  }
  for output in split.removed {
    if output.ends_with(".h") and ! fp"build/{output}".exists()? {
      return Err(types.PmError.PackageContract(f"fontconfig: missing generated {output}"))
    }
  }
}

## Build the shared library.
export proc build(dest: Path) [fs, process, env, error] {
  let meson = p"meson.build"
  var text = meson.read_text()?
  text = text.replace("python3 = import('python').find_installation()", with: "python3 = find_program('/bin/xsh')")
  let parts = text.split("gperf = find_program('gperf', required: false)")
  guard parts.len() == 2 else {
    return Err(types.PmError.PackageContract("fontconfig: missing gperf setup"))
  }
  let suffix = parts[1].split("message('gperf len type is @0@'.format(gperf_len_type))")
  guard suffix.len() == 2 else {
    return Err(types.PmError.PackageContract("fontconfig: missing gperf setup end"))
  }
  text = parts[0] + "gperf = find_program('/bin/xsh')\ngperf_len_type = 'size_t'\n" + suffix[1]
  text = text.replace("subdir('conf.d')", with: "preferred_hinting = get_option('default-hinting')\npreferred_sub_pixel_rendering = get_option('default-sub-pixel-rendering')\npreferred_bitmap = get_option('bitmap-conf')").replace("subdir('its')", with: "")
  meson.write(text)
  let muon = process.which("muon")?
  let jobs = make.jobs()?
  let pc = pm_env.pkg_config_context()?
  env ({LD_LIBRARY_PATH: pc.ld_library_path, PKG_CONFIG: pc.pkg_config, PKG_CONFIG_LIBDIR: pc.pkg_config_libdir, PKG_CONFIG_PATH: pc.pkg_config_path, PKG_CONFIG_SYSROOT_DIR: pc.pkg_config_sysroot}) {
    run $muon "setup" pm_env.meson_prefix_arg() pm_env.meson_libdir_arg() pm_env.meson_sysconfdir_arg() pm_env.meson_localstatedir_arg() \
      "-Ddefault_library=shared" "-Dxml-backend=expat" "-Dtools=disabled" "-Ddoc=disabled" \
      "-Dnls=disabled" "-Dtests=disabled" "-Dtests-external-fonts=disabled" "-Dcache-build=disabled" \
      "-Ddefault-fonts-dirs=/usr/share/fonts" "-Dadditional-fonts-dirs=" "build"
    stage_generated()
    run $muon "-C" "build" "samu" f"-j{jobs}" "libfontconfig.so.1.17.0"
    env ({DESTDIR: dest}) {
      run $muon "-C" "build" "install"
    }
  }?
  fp"{dest}/etc/fonts".remove(missing_ok: false)
  fp"{dest}/var/cache/fontconfig".mkdir(true)
}

use pm.proof
use pm.util as pm_util

const base_pc = """prefix=/usr
libdir=\${prefix}/lib
includedir=\${prefix}/include
datadir=\${prefix}/share/laputa

Name: laputa-base
Description: base fixture
Version: 1.2.3
Libs: -L\${libdir} -lbase
Libs.private: -lm
Cflags: -I\${includedir}/base -DLAPUTA_BASE=1
"""

const priv_pc = """prefix=/usr
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: laputa-priv
Description: private fixture
Version: 0.9
Libs: -L\${libdir}/priv -lpriv
Libs.private: -lpthread
Cflags: -I\${includedir}/priv
"""

const app_pc = """prefix=/usr
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: laputa-app
Description: app fixture
Version: 2.0.0
Requires: laputa-base >= 1.2
Requires.private: laputa-priv
Libs: -L\${libdir} -lapp
Cflags: -I\${includedir}/app -I\${includedir}
"""

const data_pc = """prefix=/usr
pkgdatadir=\${prefix}/share/laputa-data

Name: laputa-data
Description: data-only fixture
Version: 5
"""

# Runs pkg-config as pm/env.xsh's pkg_config_context does for a build root:
# both search variables name only the root's pkgconfig directories, and the
# root is the sysroot. An empty `sysroot` is the installed-system case.
proc query(pkg_config: Path, dynlinker: Path, libdir: Str, sysroot: Str, args: List[Str]) [process, env, error] -> Result[Str] {
  var out = ""

  env ({
    PKG_CONFIG_LIBDIR: libdir,
    PKG_CONFIG_PATH: libdir,
    PKG_CONFIG_SYSROOT_DIR: sysroot,
  }) {
    out = run.text $dynlinker $pkg_config @args ?
  }

  out.trim()
}

proc expect(pkg_config: Path, dynlinker: Path, libdir: Str, sysroot: Str, args: List[Str], want: Str) [process, env, error] {
  let got = query(pkg_config, dynlinker, libdir, sysroot, args)?
  proof.ensure(got == want, "proof-pkgconf", f"pkg-config {args.join(" ")} (sysroot {sysroot}) gave `{got}`, want `{want}`")
}

proc expect_status(pkg_config: Path, dynlinker: Path, libdir: Str, args: List[Str], ok: Bool) [process, env, error] {
  var status_ok = ! ok

  env ({
    PKG_CONFIG_LIBDIR: libdir,
    PKG_CONFIG_PATH: libdir,
  }) {
    status_ok = (run.status $dynlinker $pkg_config @args 2> /dev/null).ok
  }

  proof.ensure(status_ok == ok, "proof-pkgconf", f"pkg-config {args.join(" ")} exit status ok={status_ok}, want ok={ok}")
}

proc main(rootfs: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(rootfs, "pkgconf")
  proof.target_elf(rootfs, p"usr/bin/pkgconf", "pkgconf")
  proof.target_elf(rootfs, p"usr/lib/libpkgconf.so.8", "pkgconf")

  if ! fs.exists(fp"{rootfs}/usr/bin/pkg-config")? {
    return Err(proof.ProofError.Failed(kind: "proof-pkgconf", message: "missing pkg-config symlink"))?
  }

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "pkgconf ok: cross-built"
    return
  }

  # Every build resolves --cflags and --libs through this binary, so the
  # proof pins the answers recipes depend on (identical to pkgconf 2.5.1's):
  # Requires and Requires.private expansion, --static adding Libs.private,
  # sysroot injection into -I and -L and into path variables, system
  # directory filtering without a sysroot, version constraints, and errors.
  let os = system.uname()?
  let dynlinker = fp"{rootfs}/usr/lib/ld-musl-{os.machine}.so.1"
  let pkg_config = fp"{rootfs}/usr/bin/pkg-config"
  let ver = proof.package_version(rootfs, "pkgconf")?
  let tmp = fp"{rootfs}/var/tmp/proof-pkgconf"
  fs.remove(tmp, missing_ok: true)
  fs.mkdir(fp"{tmp}/sysroot/usr/lib/pkgconfig", true)
  fs.mkdir(fp"{tmp}/sysroot/usr/share/pkgconfig", true)
  defer fs.remove(tmp, missing_ok: true)?
  let sysroot = fp"{tmp}/sysroot".display()
  fs.write(fp"{sysroot}/usr/lib/pkgconfig/laputa-base.pc", base_pc)
  fs.write(fp"{sysroot}/usr/lib/pkgconfig/laputa-priv.pc", priv_pc)
  fs.write(fp"{sysroot}/usr/lib/pkgconfig/laputa-app.pc", app_pc)
  fs.write(fp"{sysroot}/usr/share/pkgconfig/laputa-data.pc", data_pc)
  let libdir = f"{sysroot}/usr/lib/pkgconfig:{sysroot}/usr/share/pkgconfig"
  let s = sysroot

  expect(pkg_config, dynlinker, libdir, "", ["--version"], ver)
  expect(pkg_config, dynlinker, libdir, s, ["--modversion", "laputa-app"], "2.0.0")

  expect(
    pkg_config,
    dynlinker,
    libdir,
    s,
    ["--cflags", "laputa-app"],
    f"-I{s}/usr/include/app -I{s}/usr/include -I{s}/usr/include/base -DLAPUTA_BASE=1 -I{s}/usr/include/priv",
  )

  expect(pkg_config, dynlinker, libdir, s, ["--libs", "laputa-app"], f"-L{s}/usr/lib -lapp -lbase")

  expect(
    pkg_config,
    dynlinker,
    libdir,
    s,
    ["--static", "--libs", "laputa-app"],
    f"-L{s}/usr/lib -lapp -lbase -lm -L{s}/usr/lib/priv -lpriv -lpthread",
  )

  expect(pkg_config, dynlinker, libdir, s, ["--libs", "laputa-base", "laputa-priv"], f"-L{s}/usr/lib -lbase -L{s}/usr/lib/priv -lpriv")
  expect(pkg_config, dynlinker, libdir, s, ["--variable=pkgdatadir", "laputa-data"], f"{s}/usr/share/laputa-data")
  expect(pkg_config, dynlinker, libdir, s, ["--print-requires", "laputa-app"], "laputa-base >= 1.2")
  expect(pkg_config, dynlinker, libdir, s, ["--print-requires-private", "laputa-app"], "laputa-priv")

  # An installed system: /usr/include and /usr/lib are the compiler's own
  # search directories, so they are filtered out.
  expect(
    pkg_config,
    dynlinker,
    libdir,
    "",
    ["--cflags", "--libs", "laputa-app"],
    "-I/usr/include/app -I/usr/include/base -DLAPUTA_BASE=1 -I/usr/include/priv -lapp -lbase",
  )

  expect_status(pkg_config, dynlinker, libdir, ["--exists", "laputa-base >= 1.2"], true)
  expect_status(pkg_config, dynlinker, libdir, ["--exists", "laputa-base >= 1.3"], false)
  expect_status(pkg_config, dynlinker, libdir, ["--cflags", "laputa-missing"], false)

  # The shared library loads and exports only the public pkgconf_ API.
  let readelf = proof.readelf_tool()?
  let symbols = run.text $readelf "--dyn-syms" "-W" fp"{rootfs}/usr/lib/libpkgconf.so.8" ?
  proof.ensure(" pkgconf_compare_version" in symbols, "proof-pkgconf", "libpkgconf does not export pkgconf_compare_version")

  for line in symbols.lines() {
    let words = line.words()
    continue when words.len() < 8 or words[4] != "GLOBAL" or words[6] == "UND"
    proof.ensure(words[7].starts_with("pkgconf_"), "proof-pkgconf", f"libpkgconf exports a non-API symbol: {words[7]}")
  }

  print f"pkgconf ok: {ver} cflags, libs, static, sysroot, system filtering, constraints, exports"
}

main(@args)

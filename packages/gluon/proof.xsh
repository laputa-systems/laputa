use pm.proof
use pm.util as pm_util

proc main(rootfs = p"/rootfs") [fs, process, env, error] -> Result[Unit, Error] {
  proof.package_metadata(rootfs, "gluon")
  proof.target_elf(rootfs, p"usr/bin/meson", "gluon")
  proof.target_elf(rootfs, p"usr/bin/ninja", "gluon")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "gluon ok: cross-built"
    return
  }

  let os = system.uname()?
  let dynlinker = fp"{rootfs}/usr/lib/ld-musl-{os.machine}.so.1"
  let meson = fp"{rootfs}/usr/bin/meson"
  let ninja = fp"{rootfs}/usr/bin/ninja"
  let tmp = fp"{rootfs}/var/tmp/proof-gluon"
  tmp.remove()
  tmp.mkdir(true)
  defer tmp.remove()

  let version = run.text $dynlinker $meson "--version"
  proof.ensure(version.trim() == "1.12.1", "proof-gluon", f"unexpected meson --version: {version.trim()}")
  let ninja_version = run.text $dynlinker $ninja "--version"
  proof.ensure(ninja_version.trim().starts_with("1."), "proof-gluon", f"unexpected ninja --version: {ninja_version.trim()}")

  let src = fp"{tmp}/src"
  src.mkdir(true)
  fp"{src}/meson.build".write(
    """project('proof', version: '1.0')
conf = configuration_data()
conf.set('VERSION', meson.project_version())
configure_file(input: 'version.in', output: 'version.txt', configuration: conf, install_dir: get_option('datadir') / 'proof')
install_data('notes.txt', install_dir: get_option('datadir') / 'proof')
""",
  )
  fp"{src}/version.in".write("@VERSION@\n")
  fp"{src}/notes.txt".write("gluon proof\n")

  let build = fp"{tmp}/build"
  let dest = fp"{tmp}/dest"
  env ({
    GLUON_SHELL: "forbid",
    PATH: f"{rootfs}/usr/bin:{e"PATH" ?? ""}",
  }) {
    run $dynlinker $meson "setup" "--prefix=/usr" $build $src > /dev/null
    run $dynlinker $ninja "-C" $build > /dev/null
    env ({
      DESTDIR: dest.display(),
    }) {
      run $dynlinker $meson "install" "-C" $build > /dev/null
    }
  }

  let installed = fp"{dest}/usr/share/proof/version.txt"
  proof.ensure(installed.exists()?, "proof-gluon", "meson install did not install the configured file")
  proof.ensure(installed.read_text()?.trim() == "1.0", "proof-gluon", "configure_file did not substitute the project version")
  proof.ensure(fp"{dest}/usr/share/proof/notes.txt".exists()?, "proof-gluon", "meson install did not install the data file")
  print "gluon ok: setup, shell-free build, install"
}

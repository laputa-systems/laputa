##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "fontconfig")?
  let lib = p"usr/lib/libfontconfig.so.1.17.0"
  proof.target_elf(root, lib, "fontconfig")?
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/{lib}" ?
  proof.ensure("[libfontconfig.so.1]" in dynamic, "proof-fontconfig", "fontconfig has no libfontconfig.so.1 SONAME")?

  # fonts.conf includes conf.d and skips what it cannot read, so a dangling
  # link silently drops its rules (generic family aliases among them).
  let conf_d = fp"{root}/etc/fonts/conf.d"

  for entry in fs.children(conf_d)? |> where .name.ends_with(".conf") {
    proof.ensure(fs.exists(entry.path)?, "proof-fontconfig", f"conf.d/{entry.name} does not resolve in the root")?
  }

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"fontconfig ok: cross-built {pm_util.target_arch()?}"
    return
  }

  let os = system.uname()?
  let dynlinker = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"
  let home = fp"{root}/tmp/fontconfig-proof"
  fs.mkdir(home)?

  # Loading the whole configuration parses every linked conf.d file and the
  # generated language rules; fontconfig reports any problem on stderr.
  env ({
    LD_LIBRARY_PATH: fp"{root}/usr/lib",
    FONTCONFIG_FILE: fp"{root}/etc/fonts/fonts.conf",
    FONTCONFIG_SYSROOT: root,
    HOME: home,
    XDG_CACHE_HOME: fp"{home}/cache",
  }) {
    let version = run.capture --text $dynlinker fp"{root}/usr/bin/fc-match" "--version" ?
    proof.ensure("2.18.3" in f"{version.stdout}{version.stderr}", "proof-fontconfig", "fc-match is not fontconfig 2.18.3")?
    let cache = run.capture --text $dynlinker fp"{root}/usr/bin/fc-cache" "--really-force" ?
    proof.ensure(cache.status.ok, "proof-fontconfig", f"fc-cache failed: {cache.stderr.trim()}")?
    proof.ensure("Fontconfig" not in cache.stderr, "proof-fontconfig", f"fontconfig reported: {cache.stderr.trim()}")?
  }?

  print "fontconfig ok"
}

main(@args)?

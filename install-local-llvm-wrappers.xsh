# The build-essential image reuses heavy remote packages, but wrapper scripts
# must track the local package repo while world-build treats local XSH as
# canonical. Overlay the lightweight local wrappers after remote install.
proc apply_local_wrappers(pkgbuild: Path, root: Path) [fs, env, error] {
  let exports = module.load(pkgbuild)?
  let install: Proc = exports.get("install_wrappers")?
  install.call(root)?
}

proc install_local_m4(source: Path, root: Path) [fs, error] {
  fs.install(source, fp"${root}/usr/bin/m4", 0o755, parents: true, overwrite: true)?
}

proc main() [fs, env, error] {
  let pkgbuild = /usr/lib/pm/local-llvm-toolchain/PKGBUILD.xsh
  let m4 = /usr/lib/pm/local-m4/m4.xsh

  for root in [/, /build-env, /rootfs] {
    apply_local_wrappers(pkgbuild, root)?
    install_local_m4(m4, root)?
  }
}

main()?

##! PM environment paths and toolchain variables.
## The exported paths define the package build filesystem contract.
## Environment values needed to invoke pkg-config under a package root.
export type PkgConfigContext = {
  pkg_config: Path,
  pkg_config_path: Str,
  pkg_config_libdir: Str,
  pkg_config_sysroot: Str,
  ld_library_path: Str,
}

## Exported PM declaration `prefix`.
export const prefix = p"/usr"

## Exported PM declaration `sysconfdir`.
export const sysconfdir = p"/etc"

## Exported PM declaration `localstatedir`.
export const localstatedir = p"/var"

## Exported PM declaration `libdir_name`.
export const libdir_name = "lib"

## Exported PM declaration `bindir`.
export const bindir = p"/usr/bin"

## Exported PM declaration `includedir`.
export const includedir = p"/usr/include"

## Exported PM declaration `libdir`.
export const libdir = p"/usr/lib"

## Exported PM declaration `mandir`.
export const mandir = p"/usr/share/man"

## Exported PM declaration `meson_prefix_arg`.
export pure meson_prefix_arg() -> Str {
  f"-Dprefix={prefix}"
}

## Exported PM declaration `meson_libdir_arg`.
export pure meson_libdir_arg() -> Str {
  f"-Dlibdir={libdir_name}"
}

## Exported PM declaration `meson_sysconfdir_arg`.
export pure meson_sysconfdir_arg() -> Str {
  f"-Dsysconfdir={sysconfdir}"
}

## Exported PM declaration `meson_localstatedir_arg`.
export pure meson_localstatedir_arg() -> Str {
  f"-Dlocalstatedir={localstatedir}"
}

## Exported PM declaration `cmake_install_prefix_arg`.
export pure cmake_install_prefix_arg() -> Str {
  f"-DCMAKE_INSTALL_PREFIX={prefix}"
}

## Exported PM declaration `cmake_install_libdir_arg`.
export pure cmake_install_libdir_arg() -> Str {
  f"-DCMAKE_INSTALL_LIBDIR={libdir_name}"
}

pure root_is_empty(root: Path) -> Bool {
  root == fp""
}

pure root_is_system(root: Path) -> Bool {
  root == p"/"
}

## Exported PM declaration `target_root`.
export proc target_root() [env] -> Path {
  fp"{e"LAPUTA_ROOT" ?? ""}"
}

## Exported PM declaration `pkg_config_context`.
export proc pkg_config_context() [process, env, error] -> Result[PkgConfigContext, Error] {
  let pkg_config = process.which("pkg-config")?
  var pkg_config_path = f"{libdir}/pkgconfig:/usr/share/pkgconfig"
  var pkg_config_libdir = pkg_config_path
  var pkg_config_sysroot = ""
  var ld_library_path = f"{pkg_config.parent.parent}/lib"
  let root = target_root()

  if ! root_is_empty(root) and ! root_is_system(root) {
    pkg_config_path = f"{root}/usr/lib/pkgconfig:{root}/usr/share/pkgconfig:{pkg_config_path}"
    pkg_config_libdir = f"{root}/usr/lib/pkgconfig:{root}/usr/share/pkgconfig"
    pkg_config_sysroot = f"{root}"
    ld_library_path = f"{root}/usr/lib:{ld_library_path}"
  }

  {pkg_config, pkg_config_path, pkg_config_libdir, pkg_config_sysroot, ld_library_path}
}

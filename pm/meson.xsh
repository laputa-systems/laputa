##! PM meson operations and shared package-manager policy.
use pm.env as pm_env
use pm.make

## Exported PM declaration `setup_args`.
export pure setup_args(options: List[Str]) -> List[Str] {
  ["setup", pm_env.meson_prefix_arg(), pm_env.meson_libdir_arg()].extend(options).push("build")
}

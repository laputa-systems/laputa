##! PM target operations and shared package-manager policy.
use pm.types
use pm.util as pm_util

## Exported PM declaration `MuslAbi`.
export type MuslAbi = {
  arch: Str,
  ptrdiff_bits: Str,
  sig_atomic_bits: Str,
  size_t_bits: Str,
  wchar_t_bits: Str,
  wint_t_bits: Str,
  ptrdiff_suffix: Str,
  sig_atomic_suffix: Str,
  size_t_suffix: Str,
  wchar_t_suffix: Str,
  wint_t_suffix: Str,
  signed_sig_atomic_t: Bool,
  signed_wchar_t: Bool,
}

## Read and validate the selected recipe target.
export proc recipe_target() [env, error] -> Result[types.Target, Error] {
  types.parse_target(pm_util.target_arch()?)?
}

## Read and validate the build tool target.
export proc build_target() [env, error] -> Result[types.Target, Error] {
  types.parse_target(pm_util.build_arch()?)?
}

## Render the Rust target triple of a supported recipe target.
export pure rust_triple(target: types.Target) -> Result[Str, Error] {
  match target {
    types.Aarch64LinuxMusl => "aarch64-unknown-linux-musl"
    types.X86_64LinuxMusl => "x86_64-unknown-linux-musl"
    types.TargetReserved => Err(types.PmError.PackageContract("unsupported recipe target"))
  }
}

## Render the kernel source architecture of a supported recipe target.
export pure kernel_arch(target: types.Target) -> Result[Str, Error] {
  match target {
    types.Aarch64LinuxMusl => "arm64"
    types.X86_64LinuxMusl => "x86"
    types.TargetReserved => Err(types.PmError.PackageContract("unsupported recipe target"))
  }
}

## Return the C type properties of a supported LP64 musl target.
export pure lp64_musl_abi(target: types.Target) -> Result[MuslAbi, Error] {
  let signed_wchar_t = match target {
    types.Aarch64LinuxMusl => false
    types.X86_64LinuxMusl => true
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported musl ABI target")) }
  }
  let arch = types.pm_target_arch(target)

  {
    arch,
    ptrdiff_bits: "64",
    sig_atomic_bits: "32",
    size_t_bits: "64",
    wchar_t_bits: "32",
    wint_t_bits: "32",
    ptrdiff_suffix: "\"L\"",
    sig_atomic_suffix: "\"INT\"",
    size_t_suffix: "\"UL\"",
    wchar_t_suffix: if signed_wchar_t { "\"INT\"" } else { "\"UINT\"" },
    wint_t_suffix: "\"UINT\"",
    signed_sig_atomic_t: true,
    signed_wchar_t,
  }
}

## Exported PM declaration `musl_abi`.
export proc musl_abi() [env, error] -> Result[MuslAbi, Error] {
  lp64_musl_abi(recipe_target()?)?
}

##! PM target operations and shared package-manager policy.
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

# The arch's musl bits/alltypes.h.in decides wchar_t: `unsigned` on aarch64,
# `int` on x86_64.
## The C type properties of a 64-bit musl target, for gnulib-style configure substitutes.
export pure lp64_musl_abi(arch: Str) -> MuslAbi {
  let signed_wchar_t = arch != "aarch64"

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
export proc musl_abi() [env, error] -> Result[MuslAbi] {
  lp64_musl_abi(pm_util.target_arch()?)
}

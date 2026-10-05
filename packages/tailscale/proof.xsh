use pm.proof
use pm.util as pm_util

error ProofError = Failed(kind: Str, message: Str)

proc ensure_executable(path_value: Path, label: Str) {
  guard path_value.executable() else {
    return Err(ProofError.Failed(kind: "proof-tailscale", message: f"missing executable {label}: {path_value}"))
  }
}

proc ensure_file(path_value: Path, label: Str) {
  guard path_value.exists() else {
    return Err(ProofError.Failed(kind: "proof-tailscale", message: f"missing {label}: {path_value}"))
  }
}

proc main(rootfs: Path = /rootfs) [fs, process, env, error] {
  ensure_executable(fp"{rootfs}/usr/bin/tailscale", "tailscale")
  ensure_executable(fp"{rootfs}/usr/bin/tailscaled", "tailscaled")
  # iptables and xinit are runtime-only dependencies: generations install
  # them, but a package proof root holds only this payload's `deps` closure.
  ensure_file(fp"{rootfs}/usr/lib/xinit/services/tailscaled.xsh", "tailscaled service")
  proof.target_elf(rootfs, p"usr/bin/tailscale", "tailscale")
  proof.target_elf(rootfs, p"usr/bin/tailscaled", "tailscale")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "tailscale ok: cross-built"
    return
  }

  # Both binaries are static; each must run and report the pinned release.
  let ver = proof.package_version(rootfs, "tailscale")?

  for tool in ["tailscale", "tailscaled"] {
    let binary = fp"{rootfs}/usr/bin/{tool}"
    let reported = run.text $binary "--version"
    let first = reported.trim().split("\n")[0].trim()
    proof.ensure(first == ver, "proof-tailscale", f"{tool} --version reported {first}, expected {ver}")
  }

  print f"tailscale ok: {ver}"
}

main(@args)

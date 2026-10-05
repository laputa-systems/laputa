##! XSH module `proof` package and build operations.
error ProofError = Failed(kind: Str, message: Str)

# The release the recipe installs its versioned image and config under.
const kernel_release = "7.2.9"

proc ensure_file(path_value: Path, label: Str) {
  guard path_value.exists() else {
    return Err(ProofError.Failed(kind: "proof-linux", message: f"missing {label}: {path_value}"))?
  }

  let meta = path_value.metadata()?

  if meta.size <= 0 {
    return Err(ProofError.Failed(kind: "proof-linux", message: f"empty {label}: {path_value}"))?
  }
}

proc ensure_config(config_path: Path, key: Str, label: Str) {
  guard config_path.exists() else {
    return Err(ProofError.Failed(kind: "proof-linux", message: f"missing config for {label} check: {config_path}"))?
  }

  for raw in config_path.read_text()?.split("\n") {
    let line = raw.trim()

    return when line == f"{key}=y"
  }

  return Err(ProofError.Failed(kind: "proof-linux", message: f"{label}: expected {key}=y not found in {config_path}"))?
}

proc ensure_x86_bzimage(image_path: Path) {
  let meta = image_path.metadata()?

  if meta.size < 518 {
    return Err(ProofError.Failed(kind: "proof-linux", message: f"x86_64 boot image is too small: {image_path}"))?
  }

  let image = image_path.read_bytes()?
  let mz = bytes.from_text("MZ")
  let hdrs = bytes.from_text("HdrS")

  if image[..2] != mz {
    return Err(
      ProofError.Failed(
        kind: "proof-linux",
        message: f"x86_64 boot image is not a bzImage: missing MZ header in {image_path}",
      ),
    )?
  }

  if image[514..518] != hdrs {
    return Err(
      ProofError.Failed(
        kind: "proof-linux",
        message: f"x86_64 boot image is not a bzImage: missing HdrS setup header in {image_path}",
      ),
    )?
  }
}

proc main(rootfs = /rootfs) [fs, env, error] {
  ensure_file(fp"{rootfs}/boot/vmlinuz", "kernel image")
  ensure_file(fp"{rootfs}/boot/vmlinuz-{kernel_release}", "versioned kernel image")
  ensure_file(fp"{rootfs}/usr/share/linux/config-{kernel_release}", "kernel config")
  let config_path = fp"{rootfs}/usr/share/linux/config-{kernel_release}"
  let os = system.uname()?
  let host_machine = os.machine
  let proof_arch = e"XSH_PM_TARGET_ARCH" ?? e"XSH_PM_ARCH" ?? host_machine

  if proof_arch == "x86_64" or proof_arch == "amd64" {
    ensure_config(config_path, "CONFIG_X86_64", "x86_64 arch check")
    ensure_x86_bzimage(fp"{rootfs}/boot/vmlinuz")
  } else if proof_arch == "aarch64" or proof_arch == "arm64" {
    ensure_config(config_path, "CONFIG_ARM64", "arm64 arch check")
  } else {
    return Err(ProofError.Failed(kind: "proof-linux", message: f"unsupported proof arch: {proof_arch}"))?
  }

  print "linux ok: vmlinuz"
}

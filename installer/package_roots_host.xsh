##! Run the installer's own native ARM64 package build and select its complete root archives.
use laputa.docker as docker

error InstallerPackageHostError = Failed(message: Str) : InvalidData

proc local_xsh(root: Path) [fs, env, error] -> Result[Path] {
  let configured_root = (env.get("XSH_SOURCE_ROOT") ?? "").trim()
  let xsh_root = if configured_root == "" { fp"${root.parent}/xsh" } else { fp"${configured_root}" }
  let configured_binary = (env.get("LAPUTA_LOCAL_XSH_BIN") ?? "").trim()
  let binary = if configured_binary == "" {
    fp"${xsh_root}/target/aarch64-unknown-linux-musl/debug/xsh"
  } else {
    fp"${configured_binary}"
  }

  if ! fs.exists(binary)? or fs.metadata(binary)?.kind != "file" {
    return Err(InstallerPackageHostError.Failed(f"native ARM64 XSH binary is missing: ${binary}"))
  }

  binary
}

## Select a complete package bundle built by the native ARM64 runner.
export proc prepare(
  root: Path,
  repo_url: Str,
  kernel_package: Str,
  smoke: Bool,
  jobs: Int,
) [fs, process, env, error] -> Result[Path] {
  guard jobs >= 1 else {
    return Err(InstallerPackageHostError.Failed("installer package jobs must be positive"))
  }

  let binary = local_xsh(root)?
  let base = docker.build_config(root, "installer-aarch64-packages")?
  let config = {...base, repo_url, container_xsh: docker.CheckedOutXsh(binary)}
  docker.docker_run(
    config,
    [
      "/bin/xsh",
      "/src/laputa/installer/package_roots_container.xsh",
      "--",
      if smoke { "1" } else { "0" },
      kernel_package,
      f"${jobs}",
    ],
  )?

  let bundle = fp"${config.output_root}/current"
  for name in ["build-plan.json", "target-root.tar.gz", "installer-root.tar.gz", "tools-root.tar.gz"] {
    let file = fp"${bundle}/${name}"
    if ! fs.exists(file)? or fs.metadata(file)?.kind != "file" or fs.metadata(file)?.size <= 0 {
      return Err(InstallerPackageHostError.Failed(f"installer package bundle is missing ${name}"))
    }
  }

  bundle
}

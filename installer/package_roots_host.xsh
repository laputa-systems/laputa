##! Compose the installer's target, installer, and tools roots from the local mirror.
use seed.world
use seed.images
use seed.xsh_seed

error InstallerPackageHostError = Failed : InvalidData

## Where `prepare` composes the installer's three roots.
export type InstallerRoots = {target: Path, installer: Path, tools: Path}

## The target root's packages. The `oxish` service needs the `firewall` oneshot, so the smoke target carries `crabtables` with it.
export pure installer_target_roots(kernel_package: Str, smoke: Bool) -> List[Str] {
  var roots = ["baselayout", "doas-rs", "xsh", "xinit", "laputa-pm", "laputa-net", "ca-certificates", kernel_package]
  if smoke {
    roots += ["oxish", "crabtables"]
  }

  roots
}

pure installer_roots() -> List[Str] {
  ["baselayout", "xsh", "xinit", "laputa-pm", "laputa-fs", "laputa-net"]
}

pure tools_roots() -> List[Str] {
  ["xsh", "laputa-fs"]
}

proc compose(repo_url: Str, plan: Path, store: Path, output: Path, roots: List[Str]) {
  world.host_pm_compose(repo_url, input: plan, store:, runtime_roots: roots, output:)
}

proc plan_in_package_tools(root: Path, arch: Str, repo_url: Str, roots: List[Str], output: Path) {
  let docker = images.docker_program()?
  let target = xsh_seed.xsh_seed_arch(arch)?
  let seed = xsh_seed.xsh_seed_require(root, arch)?
  let image = images.ensure_package_tools(docker, root, target)?
  let container_repo = repo_url.replace("http://127.0.0.1:", with: "http://host.docker.internal:").replace("http://localhost:", with: "http://host.docker.internal:")
  let selection: List[Str] = collect {
    for name in roots { yield @["--root", name] }
  }
  let argv = [
    docker.display(), "run", "--rm", "--platform", target.docker_platform,
    "--mount", f"type=bind,src={root},dst=/src/laputa,readonly",
    @xsh_seed.xsh_seed_mount_argv(seed),
    "--mount", f"type=bind,src={output.parent()},dst=/output",
    "--workdir", "/src/laputa", "--env", "XSH_MODULE_PATH=/src/laputa",
    "--env", f"XSH_PM_REPO={container_repo}", image,
    "/bin/xsh", "/src/laputa/pm.xsh", "--", "repo", "plan",
    "--repo", "/src/laputa", @selection, "--target", f"{arch}-linux-musl", "--output", f"/output/{output.name}",
  ]
  let status = process.run(process.command_argv(docker, argv, root))?
  guard status.ok else { return Err(InstallerPackageHostError.Failed("package-tools installer plan failed")) }
  let id = unix.id()?
  let ownership = process.run(process.command_argv(docker, [docker.display(), "run", "--rm", "--network", "none", "--mount", f"type=bind,src={output.parent()},dst=/output", image, "chown", f"{id.uid}:{id.gid}", f"/output/{output.name}"], root))?
  guard ownership.ok else { return Err(InstallerPackageHostError.Failed("installer plan ownership repair failed")) }
}

## Import the installer's package closure for ARCH from the mirror at REPO_URL into PACKAGES, which must not exist yet, then compose ROOTS.
export proc prepare(
  root: Path,
  arch: Str,
  repo_url: Str,
  kernel_package: Str,
  smoke: Bool,
  jobs: Int,
  packages: Path,
  roots: InstallerRoots,
) [fs, net, process, env, time, error] {
  guard jobs >= 1 else {
    return Err(InstallerPackageHostError.Failed("installer package jobs must be positive"))
  }

  guard repo_url != "" else {
    return Err(
      InstallerPackageHostError.Failed("the installer needs LAPUTA_REPO_URL, the local mirror (`make mirror`)"),
    )
  }

  if packages.exists() {
    return Err(InstallerPackageHostError.Failed(f"{packages} already exists; the installer build removes it first"))
  }

  packages.mkdir()
  let plan = fp"{packages}/build-plan.json"
  let store = fp"{packages}/store"
  var plan_roots = []

  for name in [@installer_target_roots(kernel_package, smoke), @installer_roots(), @tools_roots()] {
    if name not in plan_roots {
      plan_roots += [name]
    }
  }

  if system.uname()?.sysname == "Darwin" {
    plan_in_package_tools(root, arch, repo_url, plan_roots, plan)
  } else {
    world.host_pm_plan(
      repo_url,
      repo_root: root,
      roots: plan_roots,
      target: f"{arch}-linux-musl",
      output: plan,
    )
  }
  world.require_mirror_plan(plan, repo_url)
  world.host_pm_build(repo_url, input: plan, store:, jobs:)

  compose(repo_url, plan, store, roots.target, installer_target_roots(kernel_package, smoke))
  compose(repo_url, plan, store, roots.installer, installer_roots())
  compose(repo_url, plan, store, roots.tools, tools_roots())
}

##! Compose the installer's target, installer, and tools roots from the local mirror.
# Like `make root`, the host plans the roots against the mirror, requires every
# node to be an exact mirror artifact, and imports them into a fresh store.
# Composing is file extraction, so it runs on the host as well: no container
# writes root-owned files into the work tree, and no package builds here.
use seed.world as world

error InstallerPackageHostError = Failed(message: Str) : InvalidData

## Where `prepare` composes the installer's three roots.
export type InstallerRoots = {target: Path, installer: Path, tools: Path}

pure target_roots(kernel_package: Str, smoke: Bool) -> List[Str] {
  var roots = ["baselayout", "sudo-rs", "xsh", "xinit", "laputa-pm", "laputa-net", kernel_package]
  if smoke {
    roots += ["dropbear"]
  }

  roots
}

pure installer_roots() -> List[Str] {
  ["baselayout", "xsh", "xinit", "laputa-pm", "laputa-fs", "laputa-net"]
}

pure tools_roots() -> List[Str] {
  ["xsh", "laputa-fs"]
}

pure root_args(flag: Str, names: List[Str]) -> List[Str] {
  var args: List[Str] = []
  for name in names {
    args += [flag, name]
  }

  args
}

proc compose(repo_url: Str, plan: Path, store: Path, output: Path, roots: List[Str]) [fs, net, process, env, time, error] {
  world.host_pm(
    repo_url,
    ["root", "compose", plan.display(), "--store", store.display(), @root_args("--runtime-root", roots), "--output", output.display()],
  )?
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
    return Err(InstallerPackageHostError.Failed("the installer needs LAPUTA_REPO_URL, the local mirror (`make mirror`)"))
  }

  if fs.exists(packages)? {
    return Err(InstallerPackageHostError.Failed(f"{packages} already exists; the installer build removes it first"))
  }

  fs.mkdir(packages)?
  let plan = fp"{packages}/build-plan.json"
  let store = fp"{packages}/store"
  # Every root the installer composes comes from one plan, so the three roots
  # agree on each shared package.
  var plan_roots: List[Str] = []

  for name in [@target_roots(kernel_package, smoke), @installer_roots(), @tools_roots()] {
    if name not in plan_roots {
      plan_roots += [name]
    }
  }

  world.host_pm(
    repo_url,
    [
      "repo",
      "plan",
      "--repo",
      root.display(),
      @root_args("--root", plan_roots),
      "--target",
      f"{arch}-linux-musl",
      "--output",
      plan.display(),
    ],
  )?
  world.require_mirror_plan(plan, repo_url)?
  world.host_pm(repo_url, ["repo", "build", plan.display(), "--store", store.display(), "--jobs", f"{jobs}"])?

  compose(repo_url, plan, store, roots.target, target_roots(kernel_package, smoke))?
  compose(repo_url, plan, store, roots.installer, installer_roots())?
  compose(repo_url, plan, store, roots.tools, tools_roots())?
}

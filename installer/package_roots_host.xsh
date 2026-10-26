##! Compose the installer's target, installer, and tools roots from the local mirror.
use seed.world

error InstallerPackageHostError = Failed : InvalidData

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

proc compose(repo_url: Str, plan: Path, store: Path, output: Path, roots: List[Str]) {
  world.host_pm_compose(repo_url, input: plan, store:, runtime_roots: roots, output:)
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

  for name in [@target_roots(kernel_package, smoke), @installer_roots(), @tools_roots()] {
    if name not in plan_roots {
      plan_roots += [name]
    }
  }

  world.host_pm_plan(
    repo_url,
    repo_root: root,
    roots: plan_roots,
    target: f"{arch}-linux-musl",
    output: plan,
  )
  world.require_mirror_plan(plan, repo_url)
  world.host_pm_build(repo_url, input: plan, store:, jobs:)

  compose(repo_url, plan, store, roots.target, target_roots(kernel_package, smoke))
  compose(repo_url, plan, store, roots.installer, installer_roots())
  compose(repo_url, plan, store, roots.tools, tools_roots())
}

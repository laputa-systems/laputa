#!/bin/xsh
##! Compose the installer's package roots from one saved native ARM64 BuildPlan.
use laputa.container_output as container_output

error InstallerPackageRootsError = Failed(message: Str) : InvalidData

pure pm_argv(args: List[Str]) -> List[Str] {
  ["/bin/xsh", "/src/packages/pm.xsh", "--"].extend(args)
}

proc run_pm(args: List[Str]) [fs, process, error] {
  let status = process.run(process.command_argv(p"/bin/xsh", pm_argv(args), p"/src/packages"))?
  if ! status.ok {
    return Err(InstallerPackageRootsError.Failed(f"PM failed: ${args.join(" ")}"))
  }
}

pure target_roots(kernel_package: Str, smoke: Bool) -> List[Str] {
  var roots = ["baselayout", "sudo-rs", "xsh", "xinit", "laputa-pm", "laputa-net", kernel_package]
  if smoke {
    roots = roots.push("dropbear")
  }
  roots
}

pure installer_roots() -> List[Str] {
  ["baselayout", "xsh", "xinit", "laputa-pm", "laputa-fs", "laputa-net"]
}

pure tools_roots() -> List[Str] {
  ["xsh", "laputa-fs"]
}

pure plan_roots(kernel_package: Str, smoke: Bool) -> List[Str] {
  var roots = ["baselayout", "sudo-rs", "xsh", "xinit", "laputa-pm", "laputa-net", "laputa-fs", kernel_package]
  if smoke {
    roots = roots.push("dropbear")
  }
  roots
}

pure root_args(names: List[Str]) -> List[Str] {
  var args: List[Str] = []
  for name in names {
    args = args.extend(["--runtime-root", name])
  }
  args
}

proc compose_archive(plan: Path, work: Path, label: Str, roots: List[Str]) [fs, process, error] -> Result[Path] {
  let generation = fp"${work}/${label}-generation"
  run_pm(["root", "compose", plan.display(), "--store", "/artifacts"].extend(root_args(roots)).extend(["--output", generation.display()]))?
  let archive_path = fp"${work}/${label}-root.tar.gz"
  archive.tar_create(archive_path, generation, [p"."], compression: "gz")?
  archive_path
}

proc main(...argv: List[Str]) [fs, process, error] {
  if argv.len() != 3 or argv[0] not in ["0", "1"] {
    return Err(InstallerPackageRootsError.Failed("usage: package_roots_container <0|1 smoke> <kernel-package> <jobs>"))
  }

  let smoke = argv[0] == "1"
  let kernel_package = argv[1]
  let jobs = argv[2].parse_int()?
  if jobs < 1 {
    return Err(InstallerPackageRootsError.Failed("jobs must be positive"))
  }

  let handle = fs.tempdir()?
  defer fs.close_root(handle)?
  let work = fs.root_path(handle)?
  let plan = fp"${work}/build-plan.json"
  var plan_args = ["repo", "plan", "--repo", "/src/packages", "--target", "aarch64-linux-musl", "--output", plan.display()]
  for name in plan_roots(kernel_package, smoke) {
    plan_args = plan_args.extend(["--root", name])
  }
  run_pm(plan_args)?
  run_pm(["repo", "build", plan.display(), "--store", "/artifacts", "--jobs", f"${jobs}"])?

  let target_archive = compose_archive(plan, work, "target", target_roots(kernel_package, smoke))?
  let installer_archive = compose_archive(plan, work, "installer", installer_roots())?
  let tools_archive = compose_archive(plan, work, "tools", tools_roots())?
  let key = bytes.from_text(
    f"installer-roots-1\n${hash.sha256(plan)?.hex()}\n${hash.sha256(target_archive)?.hex()}\n${hash.sha256(installer_archive)?.hex()}\n${hash.sha256(tools_archive)?.hex()}\n",
  ).sha256().hex()
  container_output.publish_bundle(
    p"/output",
    key,
    [
      {name: "build-plan.json", source: plan},
      {name: "target-root.tar.gz", source: target_archive},
      {name: "installer-root.tar.gz", source: installer_archive},
      {name: "tools-root.tar.gz", source: tools_archive},
    ],
  )?
}

main(@args)?

##! Verification of intentional kernel recipe stops and their completed stage artifacts.
use packages.linux.kbuild
use packages.linux.PKGBUILD-shared as linux_shared
use pm.sources
use pm.types
use pm.util

## Kernel preparation, discovery, and planning boundaries that do not authorize a complete build.
export enum LinuxKbuildStop {
  Prepare,
  Discover,
  Plan,
}

## The recipe environment value for one bounded kernel stage.
export pure linux_kbuild_stop_name(stage: LinuxKbuildStop) -> Str {
  match stage {
    Prepare => "prepare"
    Discover => "discover"
    Plan => "plan"
  }
}

## Accepts only the requested recipe stop with readable configuration and valid stage reports.
## Other errors retain their original structured cause.
export proc linux_kbuild_verify_stopped(
  stage: LinuxKbuildStop,
  outcome: Result[Unit, Error],
  source_root: Path,
) [fs, error] -> Result[Unit, Error] {
  let expected = linux_kbuild_stop_name(stage)
  match outcome {
    Err(kbuild.ScriptError.Failed {kind, message}) => {
      if kind != "linux-kbuild-stopped" or message != f"stopped after {expected}" {
        return outcome
      }
    }
    Err(problem) => return Err(problem)
    Ok(_) => return Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-stop-missing", message: f"expected stop after {expected}"))
  }

  let config = fp"{source_root}/.config"
  let _ = kbuild.load_config(config)?
  let autoconf = fp"{source_root}/include/generated/autoconf.h"
  if config.read_text()?.trim() == "" or autoconf.read_text()?.trim() == "" {
    return Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-stop-artifacts", message: "preparation requires nonempty configuration and autoconf header"))
  }

  if stage != Prepare {
    let discovered = kbuild.read_discovered_plan(fp"{source_root}/.xsh-kbuild-plan.json")?
    if p"." not in discovered.dirs or discovered.objects.is_empty() or ! discovered.unsupported.is_empty() {
      return Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-stop-artifacts", message: "discovery report requires the root directory, selected objects, and no unsupported inputs"))
    }
  }
  if stage == Plan {
    let planned = kbuild.read_archive_plan_report(fp"{source_root}/.xsh-kbuild-archive-plan.json")?
    if planned.tasks.is_empty() or planned.task_count != planned.tasks.len() or ! planned.missing_sources.is_empty() or ! planned.generated_objects.is_empty() or ! planned.duplicate_outputs.is_empty() {
      return Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-stop-artifacts", message: "archive report requires a complete nonempty task graph"))
    }
  }
}


proc linux_kbuild_discovery_stop() [env, error] -> Result[Unit, Error] {
  env ({XSH_LINUX_KBUILD_STOP_AFTER: "discover"}) {
    linux_shared.stop_after("discover")?
  }
}

proc linux_kbuild_config_source(pkg: types.Package, arch: Str) [error] -> Result[types.UpstreamSource, Error] {
  let expected = f"files/config/{arch}/base-{arch}.fragment"
  let matches = [
    input
    for input in pkg.upstream_sources
    if util.parse_source_line(input.source)?.source == expected and
      (input.architectures.is_empty() or "all" in input.architectures or arch in input.architectures)
  ]
  if matches.len() != 1 {
    return Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-case-input", message: f"expected one declared {arch} configuration source"))
  }
  matches[0]
}

## Discovers a controller-prepared pinned source using its verified recipe configuration.
## Writes stay under this checkout's .work/tmp and use no compiler, subprocess, or plan cache.
## The caller retains exclusive source ownership and owns staging, freshness, admission, and the expected inventory.
export proc linux_kbuild_discover_prepared(
  source_root: Path,
  pkg: types.Package,
  target: types.Target,
) [fs, env, error] -> Result[kbuild.KbuildPlan, Error] {
  if pkg.name != "linux" or target == types.TargetReserved {
    return Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-case-input", message: "discovery requires the linux package and a supported target"))
  }
  let arch = types.pm_target_arch(target)
  let input = linux_kbuild_config_source(pkg, arch)?
  let checksum = sources.source_checksum(input, arch)?
  if checksum == "SKIP" {
    return Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-case-input", message: "discovery configuration requires a pinned checksum"))
  }
  let recipe_root = pkg.dir.resolve()?
  let relative = util.parse_source_line(input.source)?.source
  let config = fp"{recipe_root}/{relative}".resolve()?
  if ! config.display().starts_with(recipe_root.display() + "/") {
    return Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-case-input", message: "configuration leaves the recipe directory"))
  }
  sources.verify_source_checksum(config, checksum, "file")?
  let repository = fs.cwd()?
  let scratch_path = fp"{repository}/.work/tmp"
  let scratch = scratch_path.resolve()?
  if scratch != scratch_path {
    return Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-case-input", message: "discovery scratch must not contain symlink components"))
  }
  let source = source_root.resolve()?
  if ! source.display().starts_with(scratch.display() + "/") or source.metadata()?.kind != "dir" {
    return Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-case-input", message: "discovery source must be an owned directory under .work/tmp"))
  }
  for relative_output in [
    p".config", p".xsh-kbuild-plan.json", p"include", p"include/generated",
    p"include/generated/autoconf.h", p"include/config", p"include/config/auto.conf",
  ] {
    let output = fp"{source}/{relative_output}"
    match fs.stat(output) {
      Ok(metadata) => {
        if metadata.kind == "symlink" {
          return Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-case-input", message: f"discovery output is a symlink: {relative_output}"))
        }
      }
      Err(problem) => { return Err(problem) unless problem is NotFound }
    }
  }
  let staged_config = fp"{source}/.config"
  config.copy(to: staged_config, overwrite: true)?
  let srcarch = if target == types.X86_64LinuxMusl { "x86" } else { "arm64" }
  kbuild.write_config_headers(staged_config, source, pkg.ver, srcarch)?
  let loaded = kbuild.load_config(staged_config)?
  let options: kbuild.DiscoverOptions = {
    progress: false, progress_every: 100, jobs: 1,
    local_records: false, local_record_cache: false, build_plan: true,
  }
  let plan = kbuild.discover_plan_with_options(source, loaded, srcarch, options)?
  kbuild.write_discovered_plan(plan, fp"{source}/.xsh-kbuild-plan.json")?
  linux_kbuild_verify_stopped(Discover, linux_kbuild_discovery_stop(), source)?
  plan
}

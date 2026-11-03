##! Verification of intentional kernel recipe stops and their completed stage artifacts.
use packages.linux.kbuild

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

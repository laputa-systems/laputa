##! The outcome vocabulary, tallying, and command exit rules.

use xinfra.host
use xinfra.plan

## The closed outcome vocabulary reported for one action.
export enum Outcome: Str {
  Unchanged = "unchanged",
  Changed = "changed",
  Skipped = "skipped",
  Blocked = "blocked",
  Failed = "failed",
  Unknown = "unknown",
  Partial = "partial",
}

## Per-outcome totals for one run.
export type Counts = {
  unchanged: Int,
  changed: Int,
  skipped: Int,
  blocked: Int,
  failed: Int,
  unknown: Int,
  partial: Int,
}

## Returns the wire spelling of a planner operation.
export pure operation_text(value: plan.Operation) -> Str {
  match value {
    plan.EnsureDirectory => "ensure_directory",
    plan.RemoveDirectory => "remove_directory",
    plan.EnsureFile => "ensure_file",
    plan.RemoveFile => "remove_file",
    plan.EnsureSymlink => "ensure_symlink",
    plan.RemoveSymlink => "remove_symlink",
    plan.EnsurePackage => "ensure_package",
    plan.RemovePackage => "remove_package",
    plan.EnsureUser => "ensure_user",
    plan.RemoveUser => "remove_user",
    plan.EnsureGroup => "ensure_group",
    plan.RemoveGroup => "remove_group",
    plan.RunCommand => "run_command",
    plan.StartService => "start_service",
    plan.StopService => "stop_service",
    plan.ConfigureService => "configure_service",
  }
}

## Returns the wire spelling of an outcome.
export pure wire(value: Outcome) -> Str {
  match value {
    Unchanged => "unchanged",
    Changed => "changed",
    Skipped => "skipped",
    Blocked => "blocked",
    Failed => "failed",
    Unknown => "unknown",
    Partial => "partial",
  }
}

## Maps an observed apply status to a report outcome.
export pure of_status(status: host.ApplyStatus) -> Outcome {
  match status {
    host.Unchanged => Unchanged,
    host.Changed => Changed,
    host.Skipped => Skipped,
    host.Blocked => Blocked,
    host.Failed => Failed,
    host.Unknown => Unknown,
    host.Partial => Partial,
  }
}

## Maps a planner prediction to a report outcome.
export pure of_prediction(prediction: plan.Prediction) -> Outcome {
  match prediction {
    plan.Unchanged => Unchanged,
    plan.Changed => Changed,
    plan.Blocked => Blocked,
    plan.Undetermined => Unknown,
  }
}

## Tallies a list of outcomes.
export pure counts(outcomes: List[Outcome]) -> Counts {
  var unchanged = 0
  var changed = 0
  var skipped = 0
  var blocked = 0
  var failed = 0
  var unknown = 0
  var partial = 0
  for value in outcomes {
    match value {
      Unchanged => unchanged = unchanged + 1,
      Changed => changed = changed + 1,
      Skipped => skipped = skipped + 1,
      Blocked => blocked = blocked + 1,
      Failed => failed = failed + 1,
      Unknown => unknown = unknown + 1,
      Partial => partial = partial + 1,
    }
  }

  Counts(
    unchanged: unchanged,
    changed: changed,
    skipped: skipped,
    blocked: blocked,
    failed: failed,
    unknown: unknown,
    partial: partial,
  )
}

## Apply exits 1 for any failed, blocked, unknown, or partial outcome.
export pure apply_exit(totals: Counts) -> Int {
  if totals.failed > 0 or totals.blocked > 0 or totals.unknown > 0 or totals.partial > 0 {
    return 1
  }

  0
}

## Check exits 2 for indeterminate outcomes, 1 for drift, and 0 when compliant.
export pure check_exit(totals: Counts) -> Int {
  if totals.failed > 0 or totals.blocked > 0 or totals.unknown > 0 or totals.partial > 0 {
    return 2
  }

  if totals.changed > 0 {
    return 1
  }

  0
}

## Interrupted apply uses the conventional 130 status.
export pure interrupted_exit() -> Int {
  130
}

## Doctor exits 1 when any check is unhealthy.
export pure doctor_exit(totals: Counts) -> Int {
  if totals.failed > 0 or totals.unknown > 0 or totals.partial > 0 {
    return 1
  }

  0
}

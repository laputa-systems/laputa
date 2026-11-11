##! What happened to a resource on a host, as data. A failure is never a
##! success, and a mutation that may or may not have happened is its own case.

use infra.compare

## The phase of reconciling one resource on one host.
export enum Phase: Str {
  Connect = "connect",
  Lock = "lock",
  Observe = "observe",
  Stage = "stage",
  Validate = "validate",
  Apply = "apply",
  Promote = "promote",
  Verify = "verify",
  Notify = "notify",
  Cleanup = "cleanup",
}

## Why a step did not complete. `Failed` means the step did not take effect,
## `Partial` that earlier steps of the same resource did and this one did not,
## and `Unknown` that the host may or may not have applied the step.
export error StepError =
  Failed(phase: Phase, message: Str) |
  Partial(phase: Phase, message: Str) |
  Unknown(phase: Phase, message: Str)

## A recorded failure of a resource on a host.
export type Failure = {phase: Phase, message: Str}

## A resource that was changed: what changed, and whether a re-observation
## confirmed the declared state.
export type Applied = {changes: List[compare.Change], verified: Bool}

## The recorded result of reconciling one resource on one host.
export enum Outcome {
  Unchanged,
  Changed(Applied),
  Skipped(Str),
  Blocked(Str),
  Failed(Failure),
  PartiallyApplied(Failure),
  OutcomeUnknown(Failure),
}

## The outcome name reports use.
export pure name(outcome: Outcome) -> Str {
  match outcome {
    Unchanged => "unchanged"
    Changed(_) => "changed"
    Skipped(_) => "skipped"
    Blocked(_) => "blocked"
    Failed(_) => "failed"
    PartiallyApplied(_) => "partial"
    OutcomeUnknown(_) => "unknown"
  }
}

## Whether later work that needs this resource may proceed.
export pure settled(outcome: Outcome) -> Bool {
  match outcome {
    Unchanged => true
    Changed(_) => true
    Skipped(_) => true
    Blocked(_) => false
    Failed(_) => false
    PartiallyApplied(_) => false
    OutcomeUnknown(_) => false
  }
}

## Whether the outcome means the host needs the operator's attention.
export pure bad(outcome: Outcome) -> Bool {
  match outcome {
    Failed(_) => true
    PartiallyApplied(_) => true
    OutcomeUnknown(_) => true
    else => false
  }
}

## The outcome a step error records.
export pure of_error(error: StepError) -> Outcome {
  match error {
    StepError.Failed {phase, message} => Failed(Failure(phase:, message:))
    StepError.Partial {phase, message} => PartiallyApplied(Failure(phase:, message:))
    StepError.Unknown {phase, message} => OutcomeUnknown(Failure(phase:, message:))
  }
}


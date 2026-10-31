##! The host-operation boundary and shared apply results for local resources.

use xinfra.model
use xinfra.plan

## Filesystem metadata observed through the host boundary.
export type PathStat = {
  kind: Str,
  mode: Int,
  uid: Int,
  gid: Int,
  owner: Str? = null,
  group: Str? = null,
  size: Int = 0,
  mtime_ns: Int = 0,
  digest: Str? = null,
  target: Path? = null,
  empty: Bool = true,
}

## Whether a managed path exists, and its metadata when it does.
export enum Inspection {
  Missing,
  Found(PathStat),
}

## The outcome of applying one resource.
export enum ApplyStatus: Str {
  Unchanged = "unchanged",
  Changed = "changed",
  Skipped = "skipped",
  Blocked = "blocked",
  Failed = "failed",
  Unknown = "unknown",
  Partial = "partial",
}

## One resource's observed apply result.
export type ApplyResult = {
  id: Str,
  host: Str,
  status: ApplyStatus,
  verified: Bool,
  cause: Str? = null,
}

## The host operations a resource needs.
export type HostOps = {
  name: pure() -> Str,
  inspect_path: proc(host_path: Path) [fs, env, error] -> Result[Inspection, Error],
  parent_secure: proc(host_path: Path, expected_owner: Str?) [fs, env, error] -> Result[Bool, Error],
  mkdir_path: proc(host_path: Path, mode: Int) [fs, env, error] -> Result[Unit, Error],
  remove_dir_path: proc(host_path: Path) [fs, env, error] -> Result[Unit, Error],
  reserve_staging: proc(destination: Path) [fs, env, error] -> Result[Path, Error],
  write_staging: proc(staged: Path, data: Bytes) [fs, env, error] -> Result[Unit, Error],
  set_metadata: proc(host_path: Path, mode: Int, owner: Str?, group_name: Str?) [fs, env, error] -> Result[Unit, Error],
  digest_path: proc(host_path: Path) [fs, env, error] -> Result[Str, Error],
  validate: proc(argv: List[Str], staged: Path) [fs, env, error] -> Result[Unit, Error],
  promote: proc(staged: Path, destination: Path) [fs, env, error] -> Result[Unit, Error],
  remove_path: proc(host_path: Path) [fs, env, error] -> Result[Unit, Error],
  symlink: proc(target: Path, link_path: Path) [fs, env, error] -> Result[Unit, Error],
  read_file_path: proc(host_path: Path) [fs, env, error] -> Result[Bytes, Error],
  resolve_secret: proc(reference: model.SecretRef) [fs, env, error] -> Result[Bytes, Error],
}

## Converts observed metadata into the planner's fact shape.
export pure observed(inspection: Inspection) -> plan.Observed {
  match inspection {
    Missing => plan.Absent,
    Found(stat) => plan.Existing(
      plan.PathFacts(
        kind: stat.kind,
        mode: stat.mode,
        owner: stat.owner,
        group: stat.group,
        digest: stat.digest,
        target: stat.target,
        empty: stat.empty,
      ),
    ),
  }
}

## Builds an apply result for a host and resource.
export pure result(
  ops: HostOps,
  id: Str,
  status: ApplyStatus,
  verified: Bool,
  cause: Str? = null,
) -> ApplyResult {
  ApplyResult(id:, host: ops.name(), status:, verified:, cause:)
}

## Builds a failed apply result with the host's name.
export pure failed(ops: HostOps, id: Str, cause: Str) -> ApplyResult {
  result(ops, id, Failed, verified: false, cause: cause)
}

## Maps a planner prediction onto an apply status.
export pure predicted_status(prediction: plan.Prediction) -> ApplyStatus {
  match prediction {
    plan.Unchanged => Unchanged,
    plan.Changed => Changed,
    plan.Blocked => Blocked,
    plan.Undetermined => Unknown,
  }
}

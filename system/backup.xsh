##! Quiesced, checked, retained rustic backups with a restore-bound receipt.

## Version of one backup configuration file.
export const BACKUP_CONFIG_FORMAT = "laputa-backup-config-1"
## Version of one backup receipt.
export const BACKUP_RECEIPT_FORMAT = "laputa-backup-receipt-1"
## The generation-owned default configuration path.
export const BACKUP_CONFIG_PATH = p"/etc/laputa/backup.json"
## The volatile scratch directory for tool output.
export const BACKUP_RUN_DIR = p"/run/laputa-backup"
## The receipt file name stored beside a repository.
export const BACKUP_RECEIPT_NAME = "laputa-backup-receipt.json"
## Maximum backup source paths.
export const BACKUP_MAX_SOURCES = 16
## Maximum hook argv length.
export const BACKUP_MAX_ARGV = 64
## Maximum retained snapshot count.
export const BACKUP_MAX_KEEP_LAST = 90
## Maximum hook timeout in milliseconds.
export const BACKUP_MAX_HOOK_TIMEOUT_MS = 3600000
## Default hook timeout in milliseconds.
export const BACKUP_DEFAULT_HOOK_TIMEOUT_MS = 60000
## The packaged rustic binary.
export const BACKUP_RUSTIC = "/usr/bin/rustic"

const BACKUP_SNAPSHOT_ID_RE = rx"^[0-9a-f]{64}$"
const BACKUP_USAGE = """usage: backup [run|init] [--config PATH] [--help]

run   quiesce, back up, check the repository, prune to retention, write a receipt
init  initialize the configured repository (operator key ceremony is separate)
"""

## One quiesce or release hook.
export type BackupHook = {command: List[Str], timeout_ms: Int}

## A validated backup configuration.
export type BackupConfig = {
  repository: Str,
  password_file: Str,
  receipt: Str,
  sources: List[Str],
  exclude_if_present: Str,
  keep_last: Int,
  quiesce: BackupHook?,
  release: BackupHook?,
  rustic: Str,
}

## The repository check recorded by a receipt.
export type BackupCheck = {ok: Bool, wall_ms: Int}

## The restore-bound outcome of one successful backup.
export type BackupReceipt = {
  format: Str,
  created_wall_ms: Int,
  snapshot_id: Str,
  sources: List[Str],
  keep_last: Int,
  kept_snapshot_ids: List[Str],
  check: BackupCheck,
}

type BackupOptions = {action: Str, config: Str, help: Bool}

## Whether a value is a repository snapshot id.
export pure backup_snapshot_id_ok(value: Str) -> Bool {
  BACKUP_SNAPSHOT_ID_RE.matches(value)
}

## Trim trailing slashes from an absolute path.
export pure backup_normalize_path(value: Str) -> Str {
  var text = value.trim()
  while text.byte_len() > 1 and text.ends_with("/") {
    text = text[..text.byte_len() - 1]
  }
  text
}

## Whether a path is equal to or beneath a root.
export pure backup_path_under(candidate: Str, root: Str) -> Bool {
  candidate == root or candidate.starts_with(root + "/")
}

## Whether two paths contain one another.
export pure backup_paths_overlap(first: Str, second: Str) -> Bool {
  backup_path_under(first, second) or backup_path_under(second, first)
}

pure backup_absolute_path(value: Str, label: Str) -> Result[Str, Error] {
  let text = backup_normalize_path(value)
  guard text != "" else {
    return Err(error.failure(f"{label} is required"))
  }
  guard text.starts_with("/") else {
    return Err(error.failure(f"{label} must be an absolute path"))
  }
  guard text != "/" else {
    return Err(error.failure(f"{label} must not be the filesystem root"))
  }
  Ok(text)
}

pure backup_unknown_keys(value: Any, allowed: List[Str]) -> List[Str] {
  let record = value.require(Record) ?? {}
  [key for key in record.keys() if ! (key in allowed)]
}

pure backup_hook(value: Any, label: Str) -> Result[BackupHook?, Error] {
  if value == null {
    return Ok(null)
  }
  let unknown = backup_unknown_keys(value, ["command", "timeout_ms"])
  guard unknown.is_empty() else {
    return Err(error.failure(f"{label} has unknown keys: {unknown.join(",")}"))
  }
  let command = json.get(value, ["command"], []).require(List[Str])?
  guard ! command.is_empty() and command.len() <= BACKUP_MAX_ARGV else {
    return Err(error.failure(f"{label}.command must hold 1..{BACKUP_MAX_ARGV} arguments"))
  }
  guard command[0].starts_with("/") else {
    return Err(error.failure(f"{label}.command[0] must be an absolute path"))
  }
  let timeout_ms = json.get(value, ["timeout_ms"], BACKUP_DEFAULT_HOOK_TIMEOUT_MS).require(Int)?
  guard timeout_ms >= 1 and timeout_ms <= BACKUP_MAX_HOOK_TIMEOUT_MS else {
    return Err(error.failure(f"{label}.timeout_ms must be 1..{BACKUP_MAX_HOOK_TIMEOUT_MS}"))
  }
  Ok({command: command, timeout_ms: timeout_ms})
}

## Validate and decode one backup configuration.
export pure backup_config_from_json(value: Any) -> Result[BackupConfig, Error] {
  let unknown = backup_unknown_keys(
    value,
    ["format", "repository", "password_file", "receipt", "sources", "exclude_if_present", "retention", "quiesce", "release", "rustic"],
  )
  guard unknown.is_empty() else {
    return Err(error.failure(f"unknown keys: {unknown.join(",")}"))
  }
  let format = json.get(value, ["format"], "").require(Str)?
  guard format == BACKUP_CONFIG_FORMAT else {
    return Err(error.failure(f"format must be {BACKUP_CONFIG_FORMAT}"))
  }
  let repository = backup_absolute_path(json.get(value, ["repository"], "").require(Str)?, "repository")?
  let password_file = backup_absolute_path(json.get(value, ["password_file"], "").require(Str)?, "password_file")?
  let sources_value = json.get(value, ["sources"], []).require(List[Str])?
  guard ! sources_value.is_empty() and sources_value.len() <= BACKUP_MAX_SOURCES else {
    return Err(error.failure(f"sources must hold 1..{BACKUP_MAX_SOURCES} paths"))
  }
  var sources: List[Str] = []
  for source_value in sources_value {
    let source = backup_absolute_path(source_value, "sources[]")?
    guard ! (source in sources) else {
      return Err(error.failure(f"duplicate source {source}"))
    }
    guard ! backup_paths_overlap(repository, source) else {
      return Err(error.failure(f"repository {repository} overlaps source {source}"))
    }
    guard ! backup_path_under(password_file, source) else {
      return Err(error.failure(f"password_file {password_file} is inside source {source}"))
    }
    sources += [source]
  }
  let receipt_value = json.get(value, ["receipt"], "").require(Str)?
  let receipt = if receipt_value.trim() == "" {
    f"{repository}/{BACKUP_RECEIPT_NAME}"
  } else {
    backup_absolute_path(receipt_value, "receipt")?
  }
  for source in sources {
    guard ! backup_path_under(receipt, source) else {
      return Err(error.failure(f"receipt {receipt} is inside source {source}"))
    }
  }
  let exclude_if_present = json.get(value, ["exclude_if_present"], ".no-backup").require(Str)?
  guard exclude_if_present != "" and ! ("/" in exclude_if_present) else {
    return Err(error.failure("exclude_if_present must be a file name"))
  }
  let retention = json.get(value, ["retention"], null)
  guard retention != null else {
    return Err(error.failure("retention is required"))
  }
  let retention_unknown = backup_unknown_keys(retention, ["keep_last"])
  guard retention_unknown.is_empty() else {
    return Err(error.failure(f"unknown retention keys: {retention_unknown.join(",")}"))
  }
  let keep_last = json.get(retention, ["keep_last"], 0).require(Int)?
  guard keep_last >= 1 and keep_last <= BACKUP_MAX_KEEP_LAST else {
    return Err(error.failure(f"retention.keep_last must be 1..{BACKUP_MAX_KEEP_LAST}"))
  }
  let quiesce = backup_hook(json.get(value, ["quiesce"], null), "quiesce")?
  let release = backup_hook(json.get(value, ["release"], null), "release")?
  guard quiesce == null == (release == null) else {
    return Err(error.failure("quiesce and release must be configured together"))
  }
  let rustic = backup_absolute_path(json.get(value, ["rustic"], BACKUP_RUSTIC).require(Str)?, "rustic")?
  Ok({
    repository: repository,
    password_file: password_file,
    receipt: receipt,
    sources: sources,
    exclude_if_present: exclude_if_present,
    keep_last: keep_last,
    quiesce: quiesce,
    release: release,
    rustic: rustic,
  })
}

## Extract snapshot ids from rustic snapshot JSON.
export pure backup_snapshot_ids(value: Any) -> Result[List[Str], Error] {
  let entries = value.require(List[Any])?
  var ids: List[Str] = []
  for entry in entries {
    let grouped = json.get(entry, ["snapshots"], null)
    if grouped != null {
      for snap in grouped.require(List[Any])? {
        let id = json.get(snap, ["id"], "").require(Str)?
        guard backup_snapshot_id_ok(id) else {
          return Err(error.failure("snapshot entry has an invalid id"))
        }
        guard ! (id in ids) else {
          return Err(error.failure(f"duplicate snapshot id {id}"))
        }
        ids += [id]
      }
    } else {
      let id = json.get(entry, ["id"], "").require(Str)?
      guard backup_snapshot_id_ok(id) else {
        return Err(error.failure("snapshot entry has an invalid id"))
      }
      guard ! (id in ids) else {
        return Err(error.failure(f"duplicate snapshot id {id}"))
      }
      ids += [id]
    }
  }
  ids
}

## The newest policy-count snapshots.
export pure backup_retention_keep_newest(ids: List[Str], keep_last: Int) -> List[Str] {
  var kept: List[Str] = []
  var index = 0
  while index < ids.len() and index < keep_last {
    kept += [ids[index]]
    index += 1
  }
  kept
}

## The snapshots outside the newest policy count.
export pure backup_retention_forget(ids: List[Str], keep_last: Int) -> List[Str] {
  var dropped: List[Str] = []
  var index = keep_last
  while index < ids.len() {
    dropped += [ids[index]]
    index += 1
  }
  dropped
}

## Build a checked receipt for one successful backup.
export pure backup_receipt_new(
  created_wall_ms: Int,
  snapshot_id: Str,
  sources: List[Str],
  keep_last: Int,
  kept_snapshot_ids: List[Str],
  check_wall_ms: Int,
) -> BackupReceipt {
  {
    format: BACKUP_RECEIPT_FORMAT,
    created_wall_ms: created_wall_ms,
    snapshot_id: snapshot_id,
    sources: sources,
    keep_last: keep_last,
    kept_snapshot_ids: kept_snapshot_ids,
    check: {ok: true, wall_ms: check_wall_ms},
  }
}

## Validate and decode one receipt.
export pure backup_receipt_from_json(value: Any) -> Result[BackupReceipt, Error] {
  let format = json.get(value, ["format"], "").require(Str)?
  guard format == BACKUP_RECEIPT_FORMAT else {
    return Err(error.failure(f"receipt format must be {BACKUP_RECEIPT_FORMAT}"))
  }
  let created_wall_ms = json.get(value, ["created_wall_ms"], 0).require(Int)?
  guard created_wall_ms > 0 else {
    return Err(error.failure("receipt created_wall_ms must be positive"))
  }
  let snapshot_id = json.get(value, ["snapshot_id"], "").require(Str)?
  guard backup_snapshot_id_ok(snapshot_id) else {
    return Err(error.failure("receipt snapshot_id is invalid"))
  }
  let sources = json.get(value, ["sources"], []).require(List[Str])?
  guard ! sources.is_empty() else {
    return Err(error.failure("receipt sources are empty"))
  }
  let keep_last = json.get(value, ["keep_last"], 0).require(Int)?
  guard keep_last >= 1 and keep_last <= BACKUP_MAX_KEEP_LAST else {
    return Err(error.failure("receipt keep_last is outside the supported range"))
  }
  let kept_snapshot_ids = json.get(value, ["kept_snapshot_ids"], []).require(List[Str])?
  for kept in kept_snapshot_ids {
    guard backup_snapshot_id_ok(kept) else {
      return Err(error.failure("receipt kept_snapshot_ids holds an invalid id"))
    }
  }
  let check_value = json.get(value, ["check"], null)
  guard check_value != null else {
    return Err(error.failure("receipt check is missing"))
  }
  let check_ok = json.get(check_value, ["ok"], false).require(Bool)?
  let check_wall_ms = json.get(check_value, ["wall_ms"], 0).require(Int)?
  guard check_wall_ms >= 0 else {
    return Err(error.failure("receipt check.wall_ms must not be negative"))
  }
  Ok({
    format: format,
    created_wall_ms: created_wall_ms,
    snapshot_id: snapshot_id,
    sources: sources,
    keep_last: keep_last,
    kept_snapshot_ids: kept_snapshot_ids,
    check: {ok: check_ok, wall_ms: check_wall_ms},
  })
}

## Bind a receipt to the snapshots a repository lists.
export pure backup_receipt_bind(receipt: BackupReceipt, available: List[Str]) -> Result[Unit, Error] {
  guard receipt.format == BACKUP_RECEIPT_FORMAT else {
    return Err(error.failure("receipt format is not current"))
  }
  guard receipt.check.ok else {
    return Err(error.failure("receipt records no successful repository check"))
  }
  guard backup_snapshot_id_ok(receipt.snapshot_id) else {
    return Err(error.failure("receipt snapshot_id is invalid"))
  }
  guard receipt.snapshot_id in available else {
    return Err(error.failure(f"receipt snapshot {receipt.snapshot_id} is absent from the repository"))
  }
  guard ! receipt.kept_snapshot_ids.is_empty() else {
    return Err(error.failure("receipt retains no snapshots"))
  }
  guard receipt.kept_snapshot_ids.len() <= receipt.keep_last else {
    return Err(error.failure("receipt retains more snapshots than its policy"))
  }
  guard receipt.snapshot_id in receipt.kept_snapshot_ids else {
    return Err(error.failure("receipt snapshot is not inside its retained set"))
  }
  for kept in receipt.kept_snapshot_ids {
    guard kept in available else {
      return Err(error.failure(f"retained snapshot {kept} is absent from the repository"))
    }
  }
  Ok()
}

pure backup_options(argv: List[Str]) -> Result[BackupOptions, Str] {
  var options = BackupOptions(action: "run", config: BACKUP_CONFIG_PATH.display(), help: false)
  var saw_action = false
  var index = 0
  while index < argv.len() {
    let word = argv[index]
    index += 1
    if word == "--help" or word == "-h" or word == "help" {
      options.help = true
      continue
    }
    if word == "--config" {
      guard index < argv.len() else {
        return Err("--config requires a path")
      }
      let value = argv[index]
      index += 1
      guard value.starts_with("/") else {
        return Err("--config requires an absolute path")
      }
      options.config = value
      continue
    }
    if word.starts_with("-") {
      return Err(f"unknown option {word}")
    }
    guard ! saw_action and word in ["run", "init"] else {
      return Err(f"unexpected argument {word}")
    }
    options.action = word
    saw_action = true
  }
  Ok(options)
}

proc backup_log(line: Str) [io, error] -> Result[Unit, Error] {
  print $line
  io.flush_stdout()
}

pure backup_tail(text: Str, limit: Int) -> Str {
  if text.byte_len() <= limit {
    text
  } else {
    text[text.byte_len() - limit..]
  }
}

proc backup_scratch() [fs, error] -> Result[Path] {
  BACKUP_RUN_DIR.mkdir(parents: true)?
  Ok(BACKUP_RUN_DIR)
}

proc backup_rustic(
  config: BackupConfig,
  args: List[Str],
  label: Str,
) [fs, process, error] -> Result[Str, Error] {
  let scratch = backup_scratch()?
  let home = fp"{scratch}/home"
  home.mkdir(parents: true)?
  let out = fp"{scratch}/rustic-{label}.out"
  let errors = fp"{scratch}/rustic-{label}.err"
  out.remove(missing_ok: true)?
  errors.remove(missing_ok: true)?
  let environment = {
    RUSTIC_REPOSITORY: config.repository,
    RUSTIC_PASSWORD_FILE: config.password_file,
    RUSTIC_NO_CACHE: "true",
    HOME: home.display(),
  }
  let status = process.run(process.command_argv(
    config.rustic,
    [config.rustic, "--no-cache", @args],
    cwd: p"/",
    env: environment,
    stdin: p"/dev/null",
    stdout: out,
    stderr: errors,
  ))?
  let errors_text = if errors.exists() { errors.read_text()? } else { "" }
  guard status.ok else {
    out.remove(missing_ok: true)?
    errors.remove(missing_ok: true)?
    return Err(error.failure(f"{label} failed: {backup_tail(errors_text, 2000)}"))
  }
  let text = if out.exists() { out.read_text()? } else { "" }
  out.remove(missing_ok: true)?
  errors.remove(missing_ok: true)?
  Ok(text)
}

proc backup_list_snapshots(config: BackupConfig, label: Str) [fs, process, error] -> Result[List[Str], Error] {
  let text = backup_rustic(config, ["snapshots", "--json"], label)?
  match json.decode(text) {
    Ok(value) => backup_snapshot_ids(value),
    Err(problem) => Err(error.failure(f"{label} output is not JSON: {problem.message}")),
  }
}

proc backup_run_hook(hook: BackupHook?, label: Str) [fs, process, io, error] -> Result[Unit, Error] {
  guard let value = hook else {
    return Ok()
  }
  let scratch = backup_scratch()?
  let out = fp"{scratch}/hook-{label}.out"
  let errors = fp"{scratch}/hook-{label}.err"
  out.remove(missing_ok: true)?
  errors.remove(missing_ok: true)?
  let status = match process.run(process.command_argv(
    value.command[0],
    value.command,
    cwd: p"/",
    stdin: p"/dev/null",
    stdout: out,
    stderr: errors,
    timeout: time.millis(value.timeout_ms),
  )) {
    Ok(result) => result,
    Err(problem) => {
      return Err(error.failure(f"{label} hook did not run: {problem.message}"))
    }
  }
  let errors_text = if errors.exists() { errors.read_text()? } else { "" }
  out.remove(missing_ok: true)?
  errors.remove(missing_ok: true)?
  guard status.ok else {
    return Err(error.failure(f"{label} hook failed: {backup_tail(errors_text, 2000)}"))
  }
  backup_log(f"event=backup-hook name={label} outcome=ok")?
  Ok()
}

proc backup_new_snapshot(config: BackupConfig, before: List[Str]) [fs, process, error] -> Result[Str, Error] {
  let text = backup_rustic(config, ["backup", "--json", "--exclude-if-present", config.exclude_if_present, @config.sources], "backup")?
  match json.decode(text) {
    Ok(value) => {
      let id = json.get(value, ["id"], "").require(Str) ?? ""
      if backup_snapshot_id_ok(id) {
        return Ok(id)
      }
    }
    Err(_) => {}
  }
  let listed = backup_list_snapshots(config, "snapshots-after-backup")?
  for id in listed {
    if ! (id in before) {
      return Ok(id)
    }
  }
  Err(error.failure("backup produced no new snapshot"))
}

proc backup_write_receipt(config: BackupConfig, receipt: BackupReceipt) [fs, error] -> Result[Unit, Error] {
  let file = fp"{config.receipt}"
  file.parent().mkdir(parents: true)?
  let body = json.encode(receipt)? + "\n"
  atomically replace file as next {
    next.write(body, mode: 0o600)
    fs.fsync(next)
  }
  fs.fsync(file.parent())
}

proc backup_init(config: BackupConfig) [fs, process, io, error] -> Result[Unit, Error] {
  let repository = fp"{config.repository}"
  let marker = fp"{repository}/config"
  if marker.exists() {
    backup_log(f"event=backup-init repository={config.repository} state=already-initialized")?
    return Ok()
  }
  repository.mkdir(parents: true)?
  let text = backup_rustic(config, ["init"], "init")?
  backup_log(f"event=backup-init repository={config.repository} state=initialized bytes={text.byte_len()}")?
  Ok()
}

proc backup_run(config: BackupConfig) [fs, process, time, io, error] -> Result[Unit, Error] {
  let attempt = e"LAPUTA_TIMER_ATTEMPT" ?? "0"
  let job = e"LAPUTA_TIMER_NAME" ?? ""
  guard fp"{config.password_file}".exists() else {
    return Err(error.failure(f"backup password file is missing: {config.password_file}"))
  }
  guard fp"{config.rustic}".exists() else {
    return Err(error.failure(f"rustic is missing: {config.rustic}"))
  }
  let before = backup_list_snapshots(config, "snapshots-before")?
  backup_log(f"event=backup-start job={job} attempt={attempt} repository={config.repository} snapshots={before.len()} keep_last={config.keep_last}")?
  var release_needed = false
  let outcome = try {
    release_needed = config.release != null
    backup_run_hook(config.quiesce, "quiesce")?
    let snapshot_id = backup_new_snapshot(config, before)?
    backup_log(f"event=backup-snapshot job={job} snapshot={snapshot_id}")?
    let _ = backup_rustic(config, ["check"], "check")?
    let checked_wall_ms = time.now()
    backup_log(f"event=backup-check job={job} outcome=ok")?
    let _ = backup_rustic(config, ["forget", "--keep-last", f"{config.keep_last}", "--prune"], "forget")?
    let listed = backup_list_snapshots(config, "snapshots-after-prune")?
    guard snapshot_id in listed else {
      fail f"retention pruned the new snapshot {snapshot_id}"
    }
    guard listed.len() <= config.keep_last else {
      fail f"retention kept {listed.len()} snapshots with keep_last={config.keep_last}"
    }
    backup_write_receipt(
      config,
      backup_receipt_new(time.now(), snapshot_id, config.sources, config.keep_last, listed, checked_wall_ms),
    )?
    backup_log(f"event=backup-finish job={job} outcome=ok snapshot={snapshot_id} kept={listed.len()}")?
  }
  let release = if release_needed {
    backup_run_hook(config.release, "release")
  } else {
    Ok()
  }
  outcome?
  release?
  Ok()
}

proc backup_read_config(options: BackupOptions) [fs, error] -> Result[BackupConfig, Error] {
  let file = fp"{options.config}"
  guard file.exists() and file.is_file() else {
    return Err(error.failure(f"backup config is missing: {options.config}"))
  }
  backup_config_from_json(json.read(file)?)
}

## Run or initialize one configured backup.
export proc backup_main(...argv: List[Str]) [fs, process, time, io, env, error] -> Result[Unit, Error] {
  let parsed = match backup_options(argv) {
    Ok(value) => value,
    Err(problem) => {
      eprint f"laputa-backup: {problem}"
      eprint $BACKUP_USAGE
      exit 2
    }
  }
  if parsed.help {
    print $BACKUP_USAGE
    return Ok()
  }
  let config = backup_read_config(parsed)?
  match parsed.action {
    "run" => backup_run(config),
    "init" => backup_init(config),
    else => Err(error.failure(f"unknown backup action {parsed.action}")),
  }
}

## Entry point when this module runs as a script.
export proc main(...argv: List[Str]) [fs, process, time, io, env, error] -> Result[Unit, Error] {
  backup_main(@argv)
}

use system.backup
use system.timers

const BASE = 1767225600000
const HOUR = 3600000
const MINUTE = 60000
const ID_A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const ID_B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const ID_C = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

pure raw_config(fields: Record) -> Result[Any, Error] {
  let base = {
    format: "laputa-backup-config-1",
    repository: "/mnt/backup/repo",
    password_file: "/mnt/backup/keys/password",
    sources: ["/etc", "/home", "/var"],
    exclude_if_present: ".no-backup",
    retention: {keep_last: 3},
    rustic: "/usr/bin/rustic",
  }
  var merged: Map[Any] = {}
  for key in base.keys() {
    merged[key] = base[key]
  }
  for key in fields.keys() {
    merged[key] = fields[key]
  }
  json.decode(json.encode(merged)?)?
}

pure raw_receipt(fields: Record) -> Result[Any, Error] {
  let base = {
    format: "laputa-backup-receipt-1",
    created_wall_ms: BASE,
    snapshot_id: ID_A,
    sources: ["/etc", "/home", "/var"],
    keep_last: 3,
    kept_snapshot_ids: [ID_A, ID_B],
    check: {ok: true, wall_ms: BASE + 1},
  }
  var merged: Map[Any] = {}
  for key in base.keys() {
    merged[key] = base[key]
  }
  for key in fields.keys() {
    merged[key] = fields[key]
  }
  json.decode(json.encode(merged)?)?
}

test test_shipped_job_is_a_bounded_daily_calendar_backup [fs, error] {
  let value = json.read(p"profiles/qemu-maintained/etc/laputa/timers/jobs.d/backup.json")?
  let job = timers.timer_job_from_json("backup", value)?
  assert job.schedule == "calendar"
  assert job.hour == 3 and job.minute == 47
  assert job.argv == ["/usr/bin/xsh", "/usr/lib/laputa/backup.xsh", "run"]
  assert job.timeout_ms == 3600000
  assert job.overlap == "skip"
  assert job.missed == "coalesce"
  assert job.retries == 2
  assert job.retry_delay_ms == 300000
  assert timers.timer_calendar_next(3, 47, BASE) == BASE + 3 * HOUR + 47 * MINUTE
}

type QuiesceBound = {transition_ms: Int, release_ms: Int, retry_ms: Int, attempts: Int}

pure quiesce_flag(command: List[Str], flag: Str) -> Result[Int, Error] {
  var index = 0
  while index < command.len() - 1 {
    if command[index] == flag {
      return Ok(command[index + 1].parse_int()?)
    }
    index += 1
  }
  Err(error.failure(f"the shipped quiesce command does not publish {flag}"))
}

pure quiesce_bound(command: List[Str]) -> Result[QuiesceBound, Error] {
  Ok({
    transition_ms: quiesce_flag(command, "--timeout-ms")?,
    release_ms: quiesce_flag(command, "--recover-timeout-ms")?,
    retry_ms: quiesce_flag(command, "--recover-retry-ms")?,
    attempts: quiesce_flag(command, "--recover-attempts")?,
  })
}

test test_shipped_config_defines_the_backup_contract [fs, error] {
  let value = json.read(p"profiles/qemu-maintained/etc/laputa/backup.json")?
  let config = backup.backup_config_from_json(value)?
  assert config.repository == "/mnt/backup/repo"
  assert config.password_file == "/mnt/backup/keys/password"
  assert config.receipt == "/mnt/backup/repo/laputa-backup-receipt.json"
  assert config.sources == ["/etc", "/home", "/var"]
  assert config.exclude_if_present == ".no-backup"
  assert config.keep_last == 3
  assert config.rustic == "/usr/bin/rustic"
  if let quiesce = config.quiesce {
    assert quiesce.command[0] == "/usr/bin/xsh"
    assert quiesce.command[1] == "/usr/lib/laputa/backup-quiesce.xsh"
    assert "stop" in quiesce.command
    assert "logger" in quiesce.command
    assert "dhcp-eth0" in quiesce.command
    let published = quiesce_bound(quiesce.command)?
    assert published.transition_ms == 30000 and published.release_ms == 60000
    assert published.retry_ms == 30000 and published.attempts == 5
    assert quiesce.timeout_ms >= 2 * published.transition_ms
    if let release = config.release {
      assert release.timeout_ms >= 2 * published.release_ms
    }
  } else {
    fail "the shipped config has no quiesce hook"
  }
  if let release = config.release {
    assert "start" in release.command
  } else {
    fail "the shipped config has no release hook"
  }
}

test test_retention_keeps_exactly_the_newest_policy_count [error] {
  let newest_first = ["s5", "s4", "s3", "s2", "s1"]
  assert backup.backup_retention_keep_newest(newest_first, 3) == ["s5", "s4", "s3"]
  assert backup.backup_retention_forget(newest_first, 3) == ["s2", "s1"]
  assert backup.backup_retention_keep_newest(["s2", "s1"], 3) == ["s2", "s1"]
  assert backup.backup_retention_forget(["s2", "s1"], 3) == []
  assert backup.backup_retention_keep_newest([], 3) == []
}

test test_receipt_roundtrip_and_binding [error] {
  let receipt = backup.backup_receipt_new(BASE, ID_A, ["/etc", "/home", "/var"], 3, [ID_A, ID_B], BASE + 5)
  let encoded = json.encode(receipt)?
  let decoded = backup.backup_receipt_from_json(json.decode(encoded)?)?
  assert decoded.format == backup.BACKUP_RECEIPT_FORMAT
  assert decoded.created_wall_ms == BASE
  assert decoded.snapshot_id == ID_A
  assert decoded.sources == ["/etc", "/home", "/var"]
  assert decoded.keep_last == 3
  assert decoded.kept_snapshot_ids == [ID_A, ID_B]
  assert decoded.check.ok
  assert decoded.check.wall_ms == BASE + 5
  let _ = backup.backup_receipt_bind(decoded, [ID_A, ID_B, ID_C])?
}

test test_receipt_binding_rejects_a_missing_snapshot [error] {
  let receipt = backup.backup_receipt_new(BASE, ID_A, ["/etc"], 3, [ID_A], BASE)
  assert backup.backup_receipt_bind(receipt, [ID_B]) is Err(_)
}

test test_receipt_binding_rejects_an_unchecked_repository [error] {
  let receipt = backup.backup_receipt_new(BASE, ID_A, ["/etc"], 3, [ID_A], BASE)
  let unchecked = {...receipt, check: {ok: false, wall_ms: BASE}}
  assert backup.backup_receipt_bind(unchecked, [ID_A]) is Err(_)
}

test test_receipt_binding_rejects_a_missing_retained_entry [error] {
  let receipt = backup.backup_receipt_new(BASE, ID_A, ["/etc"], 3, [ID_A, ID_B], BASE)
  assert backup.backup_receipt_bind(receipt, [ID_A]) is Err(_)
}

test test_receipt_binding_rejects_a_new_snapshot_outside_the_retained_set [error] {
  let receipt = backup.backup_receipt_new(BASE, ID_A, ["/etc"], 3, [ID_B], BASE)
  assert backup.backup_receipt_bind(receipt, [ID_A, ID_B]) is Err(_)
}

test test_receipt_decoding_rejects_an_old_format [error] {
  let value = raw_receipt({format: "laputa-backup-receipt-0"})?
  assert backup.backup_receipt_from_json(value) is Err(_)
}

test test_receipt_decoding_rejects_an_invalid_snapshot_id [error] {
  let value = raw_receipt({snapshot_id: "latest"})?
  assert backup.backup_receipt_from_json(value) is Err(_)
}

test test_config_defaults_the_receipt_beside_the_repository [error] {
  let config = backup.backup_config_from_json(raw_config({})?)?
  assert config.receipt == "/mnt/backup/repo/laputa-backup-receipt.json"
  assert config.exclude_if_present == ".no-backup"
}

test test_config_rejects_relative_paths [error] {
  assert backup.backup_config_from_json(raw_config({repository: "repo"})?) is Err(_)
  assert backup.backup_config_from_json(raw_config({password_file: "keys/password"})?) is Err(_)
  assert backup.backup_config_from_json(raw_config({rustic: "rustic"})?) is Err(_)
  assert backup.backup_config_from_json(raw_config({sources: ["/etc", "home"]})?) is Err(_)
}

test test_config_rejects_a_repository_or_key_inside_a_source [error] {
  assert backup.backup_config_from_json(raw_config({repository: "/var/lib/backup"})?) is Err(_)
  assert backup.backup_config_from_json(raw_config({password_file: "/etc/laputa/backup/password"})?) is Err(_)
  assert backup.backup_config_from_json(raw_config({receipt: "/var/lib/backup/receipt.json"})?) is Err(_)
}

test test_config_rejects_duplicate_or_root_sources [error] {
  assert backup.backup_config_from_json(raw_config({sources: ["/etc", "/etc"]})?) is Err(_)
  assert backup.backup_config_from_json(raw_config({sources: ["/"]})?) is Err(_)
  assert backup.backup_config_from_json(raw_config({sources: []})?) is Err(_)
}

test test_config_rejects_out_of_range_retention [error] {
  assert backup.backup_config_from_json(raw_config({retention: {keep_last: 0}})?) is Err(_)
  assert backup.backup_config_from_json(raw_config({retention: {keep_last: 91}})?) is Err(_)
  assert backup.backup_config_from_json(raw_config({retention: {}})?) is Err(_)
}

test test_config_rejects_unknown_keys [error] {
  assert backup.backup_config_from_json(raw_config({retain: 3})?) is Err(_)
  assert backup.backup_config_from_json(raw_config({retention: {keep_last: 3, keep_daily: 2}})?) is Err(_)
}

test test_config_rejects_a_partial_hook_pair [error] {
  let quiesce = {
    command: ["/usr/bin/true"],
    timeout_ms: 1000,
  }
  assert backup.backup_config_from_json(raw_config({quiesce: quiesce})?) is Err(_)
  assert backup.backup_config_from_json(raw_config({release: quiesce})?) is Err(_)
}

test test_config_rejects_an_unbounded_or_relative_hook [error] {
  let relative = {command: ["true"], timeout_ms: 1000}
  let zero_timeout = {command: ["/usr/bin/true"], timeout_ms: 0}
  let both = {command: ["/usr/bin/true"], timeout_ms: 1000}
  assert backup.backup_config_from_json(raw_config({quiesce: relative, release: both})?) is Err(_)
  assert backup.backup_config_from_json(raw_config({quiesce: zero_timeout, release: both})?) is Err(_)
}

test test_config_rejects_an_exclude_name_with_a_path [error] {
  assert backup.backup_config_from_json(raw_config({exclude_if_present: "dir/.no-backup"})?) is Err(_)
  assert backup.backup_config_from_json(raw_config({exclude_if_present: ""})?) is Err(_)
}

test test_snapshot_listing_accepts_plain_and_grouped_shapes [error] {
  let plain = json.decode(f"""[{{"id": "{ID_A}"}}, {{"id": "{ID_B}"}}]""")?
  assert backup.backup_snapshot_ids(plain)? == [ID_A, ID_B]
  let grouped = json.decode(f"""[{{"group_key": {{}}, "snapshots": [{{"id": "{ID_A}"}}]}}, {{"group_key": {{}}, "snapshots": [{{"id": "{ID_B}"}}]}}]""")?
  assert backup.backup_snapshot_ids(grouped)? == [ID_A, ID_B]
}

test test_snapshot_listing_rejects_a_bad_id [error] {
  let value = json.decode("""[{"id": "latest"}]""")?
  assert backup.backup_snapshot_ids(value) is Err(_)
}

test test_path_overlap_is_bidirectional [error] {
  assert backup.backup_path_under("/etc", "/etc")
  assert backup.backup_path_under("/etc/laputa", "/etc")
  assert ! backup.backup_path_under("/etcetera", "/etc")
  assert backup.backup_paths_overlap("/etc", "/etc/laputa")
  assert backup.backup_paths_overlap("/mnt/backup/repo", "/mnt/backup")
  assert ! backup.backup_paths_overlap("/etc", "/home")
}

test test_removing_the_required_repository_is_rejected [error] {
  let value = json.remove(raw_config({})?, ["repository"])?
  assert backup.backup_config_from_json(value) is Err(_)
}

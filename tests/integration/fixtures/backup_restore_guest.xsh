#!/bin/xsh
##! Receipt-bound restore phase for the scheduled-backup guest proof.

const backup_mount = p"/mnt/backup"
const blank_mount = p"/mnt/blank"
const backup_dev = b"/dev/vdc"
const blank_dev = b"/dev/vdd"

proc console(text: Str) {
  p"/dev/console".write(text + "\n")
}

proc tool_text(args: List[Str]) -> Result[Str, Error] {
  let out = fp"{backup_mount}/restore.out"
  let err = fp"{backup_mount}/restore.err"
  out.write("")?
  err.write("")?
  let environment = {
    RUSTIC_REPOSITORY: fp"{backup_mount}/repo".display(),
    RUSTIC_PASSWORD_FILE: fp"{backup_mount}/keys/password".display(),
    RUSTIC_NO_CACHE: "true",
    HOME: fp"{backup_mount}/home".display(),
  }
  let status = process.run(process.command_argv(
    p"/usr/bin/rustic",
    ["rustic", "--no-cache", @args],
    cwd: p"/",
    env: environment,
    stdin: p"/dev/null",
    stdout: out,
    stderr: err,
  ))?
  guard status.ok else {
    fail f"rustic {args.join(" ")} failed: {err.read_text()?[-2000..]}"
  }
  out.read_text()?
}

proc snapshot_ids(text: Str) -> Result[List[Str], Error] {
  let entries = json.decode(text)?.require(List[Any])?
  var ids: List[Str] = []
  for entry in entries {
    let grouped = json.get(entry, ["snapshots"], null)
    if grouped != null {
      for snap in grouped.require(List[Any])? {
        ids += [json.get(snap, ["id"], "").require(Str)?]
      }
    } else {
      ids += [json.get(entry, ["id"], "").require(Str)?]
    }
  }
  ids
}

proc mount_disks() {
  p"/mnt".mkdir()
  backup_mount.mkdir()
  blank_mount.mkdir()
  linux.mount(backup_dev, backup_mount, fstype: "ext4", options: ["nosuid", "nodev"])
  linux.mount(blank_dev, blank_mount, fstype: "ext4", options: ["nosuid", "nodev"])
  guard fp"{backup_mount}/keys/password".exists()? else { fail "the backup disk has no fixture key" }
}

proc verify_identity() {
  let manifest = fp"{blank_mount}/var/lib/backup-proof/identity-hashes.txt".read_text()?
  var checked = 0
  for line in manifest.lines() {
    if line.trim() == "" { continue }
    let fields = line.split("  ")
    guard fields.len() == 2 else { fail f"unparseable identity line: {line}" }
    let restored = fp"{blank_mount}{fields[1]}"
    guard restored.exists()? else { fail f"the restore is missing {fields[1]}" }
    guard hash.sha256(restored)?.hex() == fields[0] else {
      fail f"restored {fields[1]} does not match the pre-backup hash"
    }
    checked += 1
  }
  guard checked > 0 else { fail "the identity manifest is empty" }
  console(f"BACKUP_RESTORE_IDENTITY_OK files={checked}")
}

proc verify_quiescence() {
  let record = json.read(fp"{blank_mount}/var/lib/backup-proof/quiesce.json")?
  guard json.get(record, ["state"], "").require(Str)? == "quiesced" else {
    fail "the restored state has no quiesce marker"
  }
  guard json.get(record, ["logger"], "").require(Str)? == "down" else {
    fail "the logger was not down at the backup boundary"
  }
  guard json.get(record, ["dhcp"], "").require(Str)? == "down" else {
    fail "the dhcp client was not down at the backup boundary"
  }
  let expected = json.get(record, ["writer_lines"], 0).require(Int)?
  let log = fp"{blank_mount}/var/lib/backup-proof/writer.log".read_text()?
  let lines = log.lines() |> where .trim() != "" |> collect
  guard lines.len() == expected else {
    fail f"the restored writer log has {lines.len()} lines, not the quiesced {expected}"
  }
  console(f"BACKUP_RESTORE_QUIESCE_OK writer_lines={expected}")
}

proc verify_receipt() -> Result[Str, Error] {
  let receipt = json.read(fp"{backup_mount}/repo/laputa-backup-receipt.json")?
  guard json.get(receipt, ["format"], "").require(Str)? == "laputa-backup-receipt-1" else {
    fail "the receipt format is not laputa-backup-receipt-1"
  }
  guard json.get(receipt, ["check", "ok"], false).require(Bool)? else {
    fail "the receipt records no successful repository check"
  }
  let snapshot = json.get(receipt, ["snapshot_id"], "").require(Str)?
  guard snapshot.byte_len() == 64 else { fail "the receipt snapshot id is malformed" }
  let listed = snapshot_ids(tool_text(["snapshots", "--json"])?)?
  guard snapshot in listed else { fail f"the receipt snapshot {snapshot} is absent from the repository" }
  let keep_last = json.get(receipt, ["keep_last"], 0).require(Int)?
  guard listed.len() <= keep_last else {
    fail f"the repository holds {listed.len()} snapshots with keep_last={keep_last}"
  }
  let kept = json.get(receipt, ["kept_snapshot_ids"], []).require(List[Str])?
  guard kept.len() == listed.len() else {
    fail f"the receipt holds {kept.len()} retained ids, the repository holds {listed.len()}"
  }
  for id in kept {
    guard id in listed else { fail f"the receipt retains absent snapshot {id}" }
  }
  guard snapshot in kept else { fail "the receipt snapshot is outside its retained set" }
  Ok(snapshot)
}

proc restore_phase() {
  mount_disks()
  let snapshot = verify_receipt()?
  let _ = tool_text(["restore", snapshot, blank_mount.display()])?
  verify_identity()
  verify_quiescence()
  fp"{blank_mount}/format".write("laputa-maintained-state-1\n")?
  console(f"BACKUP_RESTORE_OK snapshot={snapshot}")
}

proc main() -> Result[Unit, Error] {
  match restore_phase() {
    Ok(_) => {}
    Err(problem) => {
      console(f"BACKUP_RESTORE_FAILED {problem.message}")
      return Err(problem)
    }
  }
}

main()?

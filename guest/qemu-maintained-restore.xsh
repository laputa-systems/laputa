#!/bin/xsh

##! Restore-drill guest phases for LAP-48. Installed in the maintained image
##! beside the proof script and selected per boot by a kernel cmdline token;
##! without a token the script exits silently like the proof script does.
##! Tools and the repository live on the attached backup disk, never in the
##! backup set. Drill passwords and the backup exclusion sentinel are staged
##! on the state disk by the host harness, never in the image.
##!
##! LAPUTA_RESTORE_BACKUP=1  back up /etc /home /var to the backup disk repo
##! LAPUTA_RESTORE_RESTORE=1 restore the latest snapshot onto the blank disk
##! LAPUTA_RESTORE_VERIFY=1  check the repo (rustic and restic), re-back up,
##!   and require the re-backup diff to touch volatile paths only.

const drill = p"/etc/laputa/drill"

## All drill temp files live on the backup disk, which every phase mounts.
## The restored state disk never carries drill scaffolding.
const backup_mount = p"/mnt/backup"
const blank_mount = p"/mnt/blank"
const backup_dev = b"/dev/vdc"
const blank_dev = b"/dev/vdd"

proc console(text: Str) {
  p"/dev/console".write(text + "\n")
}

proc tool_env(password: Path) -> Result[Record] {
  let home = fp"{backup_mount}/home"
  home.mkdir(true)
  Ok({
    RUSTIC_REPOSITORY: fp"{backup_mount}/repo".display(),
    RUSTIC_PASSWORD_FILE: password.display(),
    RUSTIC_NO_CACHE: "true",
    LD_LIBRARY_PATH: fp"{backup_mount}/tools/lib".display(),
    HOME: home.display(),
  })
}

## Run a tool, capturing stdout and stderr separately. Returns stdout on
## success and fails with the stderr tail otherwise, so log noise never
## reaches the JSON parser.
proc tool_text(tool: Path, args: List[Str], password: Path) -> Result[Str] {
  let out = fp"{backup_mount}/tool.out"
  out.write("")
  let err = fp"{backup_mount}/tool.err"
  err.write("")
  let status = process.run(
    process.command_argv(tool, args, p"/", tool_env(password)?, b"", out, err),
  )?
  guard status.ok else {
    let tail = err.read_text()?
    fail f"{tool.display()} {args.join(" ")} failed: {tail[-2000..]}"
  }
  out.read_text()?
}

proc rustic(args: List[Str], password: Path) -> Result[Str] {
  let argv = ["rustic", "--no-cache"].extend(args)
  tool_text(fp"{backup_mount}/tools/rustic", argv, password)?
}

proc restic(args: List[Str], password: Path) -> Result[Str] {
  let environ = {
    RESTIC_REPOSITORY: fp"{backup_mount}/repo".display(),
    RESTIC_PASSWORD_FILE: password.display(),
    LD_LIBRARY_PATH: fp"{backup_mount}/tools/lib".display(),
    HOME: fp"{backup_mount}/home".display(),
  }
  let out = fp"{backup_mount}/tool.out"
  out.write("")
  let err = fp"{backup_mount}/tool.err"
  err.write("")
  let argv = ["restic"].extend(args)
  let status = process.run(
    process.command_argv(fp"{backup_mount}/tools/restic", argv, p"/", environ, b"", out, err),
  )?
  guard status.ok else {
    let tail = err.read_text()?
    fail f"restic {args.join(" ")} failed: {tail[-2000..]}"
  }
  out.read_text()?
}

proc mount_backup() {
  p"/mnt".mkdir()
  backup_mount.mkdir()
  linux.mount(backup_dev, backup_mount, fstype: "ext4", options: ["nosuid", "nodev"])
  guard fp"{backup_mount}/tools/rustic".exists()? else { fail "backup disk has no rustic tool" }
  guard fp"{backup_mount}/tools/restic".exists()? else { fail "backup disk has no restic tool" }
}

proc backup_sources() -> List[Str] {
  ["/etc", "/home", "/var"]
}

proc password(name: Str) -> Result[Path] {
  let file = fp"{backup_mount}/keys/{name}"
  guard file.exists()? else { fail f"drill password {name} is missing" }
  file
}

proc snapshot_ids(text: Str) -> Result[List[Str]] {
  let groups = json.decode(text)?.require(List[Record])?
  var ids: List[Str] = []
  for grp in groups {
    for snap in grp.get("snapshots")?.require(List[Record])? {
      ids += [snap.get("id")?.require(Str)?]
    }
  }
  ids
}

proc snapshot_paths(text: Str) -> Result[List[Str]] {
  let groups = json.decode(text)?.require(List[Record])?
  var paths: List[Str] = []
  for grp in groups {
    for snap in grp.get("snapshots")?.require(List[Record])? {
      for snap_path in snap.get("paths")?.require(List[Str])? {
        paths += [snap_path]
      }
    }
  }
  paths
}

proc identity_files() -> Result[List[Path]] {
  let applied = p"/etc/laputa/first-boot/applied".read_text()?
  let operator = applied.lines() |> where .starts_with("operator ") |> collect
  guard operator.len() == 1 else { fail "one provisioned operator required" }
  let name = operator[0].split(" ")[1]
  [
    p"/etc/dropbear/dropbear_ed25519_host_key",
    fp"/home/{name}/.ssh/authorized_keys",
    p"/etc/passwd",
    p"/etc/group",
    p"/etc/shadow",
    p"/etc/hostname",
    p"/etc/laputa/first-boot/applied",
  ]
}

proc hash_manifest(files: List[Path]) -> Result[Str] {
  [f"{hash.sha256(item)?.hex()}  {item.display()}" for item in files].join("\n") + "\n"
}

proc steady_state() {
  wait until p"/run/xinit/dropbear.json".exists()? within 30s every 100ms
  wait until json.get(json.read(p"/run/xinit/dropbear.json")?, ["state"], "").require(Str)? == "running" within 30s every 100ms
  wait until p"/run/dhcpc/eth0.status".exists()? within 30s every 100ms
  var leased = ""
  var waited = 0
  while waited < 60 {
    leased = json.get(json.read(p"/run/dhcpc/eth0.status")?, ["state"], "").require(Str)?
    if leased == "bound" {
      break
    }
    time.sleep(1s)?
    waited += 1
  }
  guard leased == "bound" else { fail "dhcp lease never bound before backup" }
  let resolv = p"/etc/resolv.conf".read_text()?
  guard "# Managed by dhcpc" in resolv else { fail "resolv.conf is not owned by dhcpc" }
}

proc phase_backup() {
  mount_backup()
  steady_state()
  let pw1 = password("password1")?
  let pw2 = password("password2")?
  let repo = fp"{backup_mount}/repo"
  guard ! repo.exists()? else { fail "backup repo already exists" }
  let _ = rustic(["init"], pw1)?
  let _ = rustic(["key", "add", "--new-password-file", pw2.display()], pw1)?
  let exported = rustic(["key", "export"], pw1)?
  guard exported.trim() != "" else { fail "masterkey export is empty" }
  fp"{backup_mount}/tools/masterkey.export".write(exported)
  let _ = try {
    process.run(process.command_argv(/usr/bin/chmod, ["chmod", "600", fp"{backup_mount}/tools/masterkey.export".display()], p"/", {}, b"", fp"{backup_mount}/tool.out", fp"{backup_mount}/tool.out"))?
  }
  let _ = rustic(["backup", "--exclude-if-present", ".no-backup", @backup_sources()], pw1)?
  let listed = rustic(["snapshots", "--json"], pw1)?
  let ids = snapshot_ids(listed)?
  guard ids.len() == 1 else { fail f"expected one snapshot, have {ids.len()}" }
  for snap_path in snapshot_paths(listed)? {
    guard snap_path == "/etc" or snap_path == "/home" or snap_path == "/var" else {
      fail f"backup set is not exactly the state dirs: {snap_path}"
    }
  }
  fp"{backup_mount}/snap1.id".write(ids[0] + "\n")
  let manifest = hash_manifest(identity_files()?)?
  fp"{backup_mount}/hashes-before.txt".write(manifest)
  linux.umount(backup_mount)?
  console(f"RESTORE_BACKUP_OK snapshot={ids[0]}")
}

proc phase_restore() {
  mount_backup()
  blank_mount.mkdir()
  linux.mount(blank_dev, blank_mount, fstype: "ext4", options: ["nosuid", "nodev"])
  let pw1 = password("password1")?
  let snap1 = fp"{backup_mount}/snap1.id".read_text()?.trim()
  guard snap1 != "" else { fail "snap1.id is missing" }
  let _ = rustic(["restore", "latest", blank_mount.display()], pw1)?
  let before = fp"{backup_mount}/hashes-before.txt".read_text()?.lines() |> where .trim() != "" |> collect
  guard before.len() > 0 else { fail "hash manifest is empty" }
  var bare: List[Str] = []
  for entry in before {
    let fields = entry.split("  ")
    guard fields.len() == 2 else { fail f"unparseable manifest line: {entry}" }
    let restored = fp"{blank_mount}{fields[1]}"
    guard restored.exists()? else { fail f"restore is missing {fields[1]}" }
    guard hash.sha256(restored)?.hex() == fields[0] else {
      fail f"restored {fields[1]} does not match the pre-loss hash"
    }
    bare += [fields[0]]
  }
  ## Seed the maintained proof baseline the verify boot checks: the pre-loss
  ## identity hashes plus the deterministic supervised-services line.
  let baseline_dir = fp"{blank_mount}/var/lib/laputa"
  baseline_dir.mkdir(true)
  fp"{baseline_dir}/maintained-proof-before-reboot".write(
    bare.join("\n") + "\nlogger=running dhcp-eth0=running lease=bound\n",
  )
  ## The state-format marker lives beside the backed-up trees, not inside
  ## them; lay it down as part of reinstalling the base.
  fp"{blank_mount}/format".write("laputa-maintained-state-1\n")
  linux.umount(blank_mount)?
  linux.umount(backup_mount)?
  console("RESTORE_RESTORE_OK identity files match the pre-loss hashes")
}

## Paths whose content legitimately changes across a boot cycle. Everything
## else must be byte-identical between the backup and re-backup snapshots.
pure volatile_prefixes() -> List[Str] {
  ["var/log/", "var/lib/dhcpc/"]
}

## Paths the drill itself seeds between the two snapshots: the proof baseline
## written onto the blank disk during restore (the maintained proof gate
## checks its content independently on the verify boot).
pure expected_additions() -> List[Str] {
  ["var/lib/laputa/maintained-proof-before-reboot"]
}

proc diff_paths(text: Str) -> Result[List[Str]] {
  var changed: List[Str] = []
  for line in text.lines() {
    let trimmed = line.trim()
    if trimmed == "" or trimmed.starts_with("Files") or trimmed.starts_with("Dirs") {
      continue
    }
    let first = trimmed[..1]
    if first == "+" or first == "-" or first == "M" or first == "U" {
      let parts = trimmed.split("\"")
      guard parts.len() >= 3 else { fail f"unparseable diff line: {trimmed}" }
      var changed_path = parts[1]
      if changed_path.starts_with("/") {
        changed_path = changed_path[1..]
      }
      changed += [changed_path]
    }
  }
  changed
}

proc phase_verify() {
  mount_backup()
  let pw1 = password("password1")?
  let pw2 = password("password2")?
  let snap1 = fp"{backup_mount}/snap1.id".read_text()?.trim()
  let _ = rustic(["check"], pw1)?
  console("RESTORE_CHECK_OK rustic check passed")
  let cross = restic(["check"], pw1)?
  guard "no errors" in cross else { fail "restic cross-read check reported errors" }
  let seen = restic(["snapshots"], pw1)?
  guard snap1[..8] in seen else { fail "restic cross-read does not list the rustic snapshot" }
  console("RESTORE_RESTIC_OK independent reader lists the snapshot with no errors")
  let snap1_listing = rustic(["find", snap1, "--path", "/etc/passwd"], pw1)?
  console(f"RESTORE_SNAP1_BEGIN\n{snap1_listing}RESTORE_SNAP1_END")
  let _ = rustic(["backup", "--exclude-if-present", ".no-backup", @backup_sources()], pw1)?
  let listed = rustic(["snapshots", "--json"], pw1)?
  let ids = snapshot_ids(listed)?
  guard snap1 in ids else { fail "the backup snapshot is gone from the repo" }
  guard ids.len() >= 2 else { fail "re-backup produced no new snapshot" }
  let snap2 = [id for id in ids if id != snap1][-1]
  let diffed = rustic(["diff", snap1, snap2], pw1)?
  console(f"RESTORE_DIFF_BEGIN\n{diffed}RESTORE_DIFF_END")
  for changed_path in diff_paths(diffed)? {
    var allowed = changed_path in expected_additions()
    for prefix in volatile_prefixes() {
      if changed_path.starts_with(prefix) {
        allowed = true
      }
    }
    guard allowed else { fail f"re-backup changed a non-volatile path: {changed_path}" }
  }
  console("RESTORE_REBACKUP_OK re-backup touches volatile paths only")
  let wrong = fp"{backup_mount}/wrong-password"
  wrong.write("definitely-the-wrong-password\n")
  let denied = process.run(
    process.command_argv(
      fp"{backup_mount}/tools/rustic",
      ["rustic", "--no-cache", "snapshots"],
      p"/",
      tool_env(wrong)?,
      b"",
      fp"{backup_mount}/tool.out",
      fp"{backup_mount}/tool.out",
    ),
  )?
  guard ! denied.ok else { fail "repo opened with the wrong password" }
  console("RESTORE_KEYLOSS_OK unknown password cannot open the repo")
  let listed2 = rustic(["snapshots", "--json"], pw2)?
  guard snap1 in listed2 else { fail "second key cannot list the repo snapshots" }
  console("RESTORE_SECOND_KEY_OK second key opens the repo")
  linux.umount(backup_mount)?
  console("RESTORE_VERIFY_OK")
}

proc dispatch() {
  let cmdline = p"/proc/cmdline".read_text()?
  if "LAPUTA_RESTORE_BACKUP=1" in cmdline {
    console("RESTORE_DRILL_START phase=backup")
    phase_backup()?
    return
  }
  if "LAPUTA_RESTORE_RESTORE=1" in cmdline {
    console("RESTORE_DRILL_START phase=restore")
    phase_restore()?
    return
  }
  if "LAPUTA_RESTORE_VERIFY=1" in cmdline {
    console("RESTORE_DRILL_START phase=verify")
    phase_verify()?
    return
  }
  return
}

proc main() -> Result[Unit, Error] {
  match dispatch() {
    Ok(_) => {}
    Err(problem) => {
      console(f"RESTORE_FAILED {problem.message}")
      return Err(problem)
    }
  }
}

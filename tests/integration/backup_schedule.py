#!/usr/bin/env python3
"""Prove scheduled, quiesced, checked, retained backups and a receipt-bound restore.

The test boots the rebuilt qemu-maintained generation twice. The first boot runs
the shipped backup runner from a laputa-timers interval job against a fixture
repository on an attached disk; the second boot restores the snapshot named by
the newest receipt onto a blank disk and verifies the quiesced state. It reuses
the restore-drill provisioning, launch, and serial helpers.
"""

import argparse
import datetime
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import traceback

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import dhcp_lifecycle as dl
import restore_drill as rd

ROOT = dl.ROOT
SCRATCH_ROOT = dl.SCRATCH_ROOT
AGENT_FIXTURE = ROOT / "tests/integration/fixtures/backup_schedule_agent.xsh"
RESTORE_FIXTURE = ROOT / "tests/integration/fixtures/backup_restore_guest.xsh"
APPLY_FIXTURE = ROOT / "tests/integration/fixtures/maintained-state-apply.xsh"
PROFILE_JOB = ROOT / "profiles/qemu-maintained/etc/laputa/timers/jobs.d/backup.json"
DAILY_SYNC_JOB = ROOT / "profiles/qemu-maintained/etc/laputa/timers/jobs.d/daily-sync.json"
PROFILE_CONFIG = ROOT / "profiles/qemu-maintained/etc/laputa/backup.json"

STATE_SIZE = 256 * 1024 * 1024
STATE_MKFS_SIZE = "256M"
BACKUP_SIZE = "768M"
BLANK_SIZE = "256M"
KEEP_LAST = 3
PROOF_RUNS = KEEP_LAST + 2
PROOF_INTERVAL_MS = 10000
FAIL_INTERVAL_MS = 8000
DAILY_HOUR = 3
DAILY_MINUTE = 17
BACKUP_HOUR = 3
BACKUP_MINUTE = 47

AGENT_READY = "LAPUTA_BACKUP_AGENT_READY"
AGENT_FAILED = "LAPUTA_BACKUP_AGENT_FAILED"
RESTORE_OK = "BACKUP_RESTORE_OK"
RESTORE_FAILED = "BACKUP_RESTORE_FAILED"
FAILED = "LAPUTA_MAINTAINED_PROOF_FAILED"

WRITER = """#!/usr/bin/xsh
proc main(log_path: Str, pid_path: Str) {
  let log = Path(log_path)
  let pid = Path(pid_path)
  pid.write(f"{process.current_pid()?}\\n")?
  var count = 0
  loop {
    let current = if log.exists()? { log.read_text()? } else { "" }
    log.write(current + f"tick {count}\\n")?
    count += 1
    time.sleep(50ms)?
  }
}
main(@args)?
"""

QUIESCE = """#!/usr/bin/xsh
proc console(text: Str) {
  p"/dev/console".write(text + "\\n")
}
proc main() {
  var waited = 0
  while ! p"/etc/oxish/host_ed25519_key".exists()? and waited < 30000 {
    time.sleep(100ms)?
    waited += 100
  }
  guard p"/etc/oxish/host_ed25519_key".exists()? else { fail "no host key before backup" }
  waited = 0
  while ! p"/var/lib/backup-proof/writer.pid".exists()? and waited < 30000 {
    time.sleep(100ms)?
    waited += 100
  }
  guard p"/var/lib/backup-proof/writer.pid".exists()? else { fail "the proof writer did not start" }
  let pid = p"/var/lib/backup-proof/writer.pid".read_text()?.trim().parse_int()?
  process.kill(pid, signal: "STOP")?
  time.sleep(200ms)?
  let status = process.run(process.command_argv(
    p"/usr/bin/xsh",
    ["xsh", "/usr/lib/laputa/backup-quiesce.xsh", "stop", "logger", "dhcp-eth0", "--timeout-ms", "20000"],
  ))?
  guard status.ok else { fail "the shipped quiesce hook failed" }
  let lines = p"/var/lib/backup-proof/writer.log".read_text()?.lines() |> where .trim() != "" |> collect
  guard ! lines.is_empty() else { fail "the proof writer wrote no state" }
  let identity = [
    p"/etc/oxish/host_ed25519_key",
    p"/etc/oxish/accounts",
    p"/etc/passwd",
    p"/etc/group",
    p"/etc/shadow",
    p"/etc/hostname",
    p"/etc/laputa/first-boot/applied",
  ]
  var manifest = ""
  for item in identity {
    guard item.exists()? else { fail f"identity file is missing: {item.display()}" }
    manifest += f"{hash.sha256(item)?.hex()}  {item.display()}\\n"
  }
  p"/var/lib/backup-proof/identity-hashes.txt".write(manifest)?
  let record = {
    state: "quiesced",
    writer_lines: lines.len(),
    logger: "down",
    dhcp: "down",
    wall_ms: time.now(),
  }
  p"/var/lib/backup-proof/quiesce.json".write(json.encode(record)? + "\\n")?
  console(f"BACKUP_PROOF_QUIESCED writer_lines={lines.len()}")
}
main()?
"""

RELEASE = """#!/usr/bin/xsh
proc main() {
  let status = process.run(process.command_argv(
    p"/usr/bin/xsh",
    ["xsh", "/usr/lib/laputa/backup-quiesce.xsh", "start", "logger", "dhcp-eth0", "--timeout-ms", "20000"],
  ))?
  guard status.ok else { fail "the shipped release hook failed" }
  let pid = p"/var/lib/backup-proof/writer.pid".read_text()?.trim().parse_int()?
  process.kill(pid, signal: "CONT")?
  p"/var/lib/backup-proof/release.log".write(f"released wall_ms={time.now()}\\n")?
}
main()?
"""

MOUNT_HOOK = """#!/bin/xsh
proc main() {
  p"/mnt".mkdir()
  p"/mnt/backup".mkdir()
  var waited = 0
  while ! p"/dev/vdc".exists()? and waited < 10000 {
    time.sleep(100ms)?
    waited += 100
  }
  guard p"/dev/vdc".exists()? else {
    p"/dev/console".write("BACKUP_MOUNT_FAILED no /dev/vdc\\n")
    fail "the backup disk did not appear"
  }
  linux.mount(b"/dev/vdc", p"/mnt/backup", fstype: "ext4", options: ["nosuid", "nodev"])
  guard p"/mnt/backup/keys/password".exists()? else {
    p"/dev/console".write("BACKUP_MOUNT_FAILED no fixture key\\n")
    fail "the backup disk is not mounted"
  }
  p"/mnt/backup/home".mkdir()
  p"/dev/console".write("BACKUP_MOUNT_OK\\n")
}
main()?
"""

RESTORE_HOOK = """#!/bin/xsh
proc main() {
  let cmdline = p"/proc/cmdline".read_text()?
  if "LAPUTA_BACKUP_RESTORE=1" in cmdline {
    let status = process.run(process.command_argv(
      p"/usr/bin/xsh",
      ["xsh", "/etc/laputa/backup-restore/restore.xsh"],
      cwd: p"/",
    ))?
    if ! status.ok {
      p"/dev/console".write("BACKUP_RESTORE_FAILED boot hook\\n")
    }
  }
}
main()?
"""

INIT_HOOK = """#!/bin/xsh
proc main() {
  let status = process.run(process.command_argv(
    p"/usr/bin/xsh",
    ["xsh", "/usr/lib/laputa/backup.xsh", "init", "--config", "/etc/laputa/backup-proof.json"],
    cwd: p"/",
  ))?
  if status.ok {
    p"/dev/console".write("BACKUP_INIT_OK\\n")
  } else {
    p"/dev/console".write("BACKUP_INIT_FAILED\\n")
  }
}
main()?
"""

WRITER_HOOK = """#!/bin/xsh
let _ = unix.spawn_process_group(process.command_argv(
  p"/usr/bin/xsh",
  ["/usr/bin/xsh", "/etc/laputa/backup-proof/writer.xsh", "/var/lib/backup-proof/writer.log", "/var/lib/backup-proof/writer.pid"],
))?
"""

AGENT_HOOK = """#!/bin/xsh
let _ = unix.spawn_process_group(process.command_argv(
  p"/usr/bin/xsh",
  ["/usr/bin/xsh", "/etc/laputa/backup-proof/agent.xsh"],
))?
"""


def require_prerequisites(args):
    missing = []
    for name, path in (
        ("xsh", args.xsh),
        ("core", args.core),
        ("bundle", args.bundle),
        ("kernel", args.bundle / "vmlinuz"),
        ("disk", args.bundle / "disk.img"),
        ("agent fixture", AGENT_FIXTURE),
        ("restore fixture", RESTORE_FIXTURE),
        ("apply fixture", APPLY_FIXTURE),
        ("profile job", PROFILE_JOB),
        ("daily-sync job", DAILY_SYNC_JOB),
        ("profile config", PROFILE_CONFIG),
        ("mkfs.ext4", pathlib.Path("/sbin/mkfs.ext4")),
        ("qemu-system-x86_64", pathlib.Path(shutil.which("qemu-system-x86_64") or "/nonexistent")),
        ("kvm", pathlib.Path("/dev/kvm")),
    ):
        if not path.exists():
            missing.append(f"{name}: {path}")
    if os.uname().machine != "x86_64":
        missing.append(f"host architecture {os.uname().machine} is not x86_64")
    if missing:
        print("SKIP: missing prerequisites:\n  " + "\n  ".join(missing), file=sys.stderr)
        sys.exit(77)


def next_daily(hour, minute, now):
    target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if target <= now:
        target += datetime.timedelta(days=1)
    return int(target.timestamp() * 1000)


def timer_job(name, schedule, command, interval_or_timeout, retries=None):
    document = {
        "format": "laputa-timer-job-1",
        "name": name,
        "schedule": schedule,
        "command": command,
        "timeout_ms": interval_or_timeout,
        "overlap": "skip",
        "missed": "skip",
    }
    if retries is not None:
        document["retries"] = retries
    return json.dumps(document, indent=2, sort_keys=True) + "\n"


def stage_base(staging):
    for name in ("etc", "home", "var"):
        (staging / name).mkdir(parents=True)
    base_etc = ROOT / "packages/baselayout/files/rootfs/etc"
    for entry in sorted(base_etc.iterdir()):
        if entry.name == "inittab":
            continue
        dest = staging / "etc" / entry.name
        if entry.is_symlink() or entry.is_file():
            subprocess.run(["cp", "-a", str(entry), str(dest)], check=True)
        elif entry.is_dir():
            shutil.copytree(entry, staging / "etc" / entry.name, symlinks=True, dirs_exist_ok=True)
    shutil.copy(ROOT / "profiles/qemu-maintained/etc/inittab", staging / "etc/inittab")
    shutil.copy(ROOT / "packages/crabtables/nftables.conf", staging / "etc/nftables.conf")
    (staging / "etc/network").mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / "packages/laputa-net/interfaces", staging / "etc/network/interfaces")
    for directory, mode in (
        ("var/lib/dhcpc", 0o700),
        ("var/lib/laputa", 0o755),
        ("var/lib/laputa-timers", 0o755),
        ("var/lib/backup-proof", 0o755),
        ("var/log", 0o755),
    ):
        path = staging / directory
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(mode)
    (staging / "format").write_text("laputa-maintained-state-1\n")


def write_jobs(staging):
    jobs = staging / "etc/laputa/timers/jobs.d"
    jobs.mkdir(parents=True, exist_ok=True)
    shutil.copy(PROFILE_JOB, jobs / "backup.json")
    shutil.copy(DAILY_SYNC_JOB, jobs / "daily-sync.json")
    (jobs / "backup-proof.json").write_text(timer_job(
        "backup-proof",
        {"kind": "interval", "every_ms": PROOF_INTERVAL_MS},
        ["/usr/bin/xsh", "/usr/lib/laputa/backup.xsh", "run", "--config", "/etc/laputa/backup-proof.json"],
        120000,
    ))
    (jobs / "backup-fail.json").write_text(timer_job(
        "backup-fail",
        {"kind": "interval", "every_ms": FAIL_INTERVAL_MS},
        ["/usr/bin/xsh", "/usr/lib/laputa/backup.xsh", "run", "--config", "/etc/laputa/backup-fail.json"],
        30000,
        retries={"max": 1, "delay_ms": 200},
    ))
    cancel = staging / "var/lib/laputa-timers/cancel/backup"
    cancel.parent.mkdir(parents=True, exist_ok=True)
    cancel.write_text("cancelled\n")


def write_configs(staging):
    profile = json.loads(PROFILE_CONFIG.read_text())
    proof = dict(profile)
    proof["sources"] = ["/etc", "/home", "/var"]
    proof["retention"] = {"keep_last": KEEP_LAST}
    proof["quiesce"] = {
        "command": ["/usr/bin/xsh", "/etc/laputa/backup-proof/quiesce.xsh"],
        "timeout_ms": 60000,
    }
    proof["release"] = {
        "command": ["/usr/bin/xsh", "/etc/laputa/backup-proof/release.xsh"],
        "timeout_ms": 60000,
    }
    (staging / "etc/laputa/backup.json").write_text(json.dumps(proof, indent=2, sort_keys=True) + "\n")
    (staging / "etc/laputa/backup-proof.json").write_text(json.dumps(proof, indent=2, sort_keys=True) + "\n")
    failing = {
        "format": "laputa-backup-config-1",
        "repository": "/mnt/backup/fail-repo",
        "password_file": "/mnt/backup/keys/missing",
        "sources": ["/etc", "/home", "/var"],
        "exclude_if_present": ".no-backup",
        "retention": {"keep_last": KEEP_LAST},
        "rustic": "/usr/bin/rustic",
    }
    (staging / "etc/laputa/backup-fail.json").write_text(json.dumps(failing, indent=2, sort_keys=True) + "\n")


def write_scripts(staging):
    directory = staging / "etc/laputa/backup-proof"
    directory.mkdir(parents=True, exist_ok=True)
    for name, body in (
        ("writer.xsh", WRITER),
        ("quiesce.xsh", QUIESCE),
        ("release.xsh", RELEASE),
        ("agent.xsh", AGENT_FIXTURE.read_text()),
    ):
        target = directory / name
        target.write_text(body)
        target.chmod(0o755)
    hooks = staging / "etc/rc.d"
    hooks.mkdir(parents=True, exist_ok=True)
    for name, body in (
        ("95-backup-mount.boot", MOUNT_HOOK),
        ("96-backup-init.boot", INIT_HOOK),
        ("97-backup-writer.boot", WRITER_HOOK),
        ("98-backup-agent.boot", AGENT_HOOK),
    ):
        target = hooks / name
        target.write_text(body)
        target.chmod(0o755)


def backup_state(args, scratch):
    staging = scratch / "backup-staging"
    staging.mkdir(parents=True)
    stage_base(staging)
    write_jobs(staging)
    write_configs(staging)
    write_scripts(staging)
    dl.run_xsh(args, APPLY_FIXTURE, staging)
    image = scratch / "backup-state.ext4"
    dl.run_xsh(
        args,
        ROOT / "system/maintained_state_image.xsh",
        "--",
        staging,
        image,
        str(STATE_SIZE),
        ROOT / "packages/laputa-fs/files/mkfs.ext4.xsh",
        args.xsh,
        timeout=300,
    )
    image.chmod(0o600)
    shutil.rmtree(staging)
    return image


def restore_state(args, scratch):
    staging = scratch / "restore-staging"
    staging.mkdir(parents=True)
    stage_base(staging)
    directory = staging / "etc/laputa/backup-restore"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "restore.xsh").write_text(RESTORE_FIXTURE.read_text())
    (directory / "restore.xsh").chmod(0o755)
    hooks = staging / "etc/rc.d"
    hooks.mkdir(parents=True, exist_ok=True)
    (hooks / "99-backup-restore.boot").write_text(RESTORE_HOOK)
    (hooks / "99-backup-restore.boot").chmod(0o755)
    image = scratch / "restore-state.ext4"
    subprocess.run(["/sbin/mkfs.ext4", "-q", "-F", "-d", str(staging), str(image), STATE_MKFS_SIZE], check=True)
    image.chmod(0o600)
    shutil.rmtree(staging)
    return image


def backup_disk(scratch, password):
    staging = scratch / "backup-disk-staging"
    staging.mkdir(parents=True)
    keys = staging / "keys"
    keys.mkdir(mode=0o700)
    (keys / "password").write_text(password + "\n")
    (keys / "password").chmod(0o600)
    (staging / "home").mkdir()
    image = scratch / "backup.ext4"
    subprocess.run(["/sbin/mkfs.ext4", "-q", "-F", "-d", str(staging), str(image), str(BACKUP_SIZE)], check=True)
    image.chmod(0o600)
    shutil.rmtree(staging)
    return image


def blank_disk(scratch):
    staging = scratch / "blank-staging"
    staging.mkdir(parents=True)
    image = scratch / "blank.ext4"
    subprocess.run(["/sbin/mkfs.ext4", "-q", "-F", "-d", str(staging), str(image), str(BLANK_SIZE)], check=True)
    image.chmod(0o600)
    shutil.rmtree(staging)
    return image


def launch_with_agent(argv, console, errlog, control, extra_drives):
    fixed = list(argv)
    control.unlink(missing_ok=True)
    fixed.extend([
        "-chardev", f"socket,id=ctl,path={control},server=on,wait=off",
        "-device", "virtio-serial-pci",
        "-device", "virtserialport,chardev=ctl,name=laputa-ctl",
    ])
    return rd.launch(fixed, console, errlog, extra_drives=extra_drives, strip_proof_flag=True)


def timers(agent, *arguments):
    reply = agent.request("timers", args=list(arguments))
    if reply.get("exit") != 0:
        raise AssertionError(f"timers {' '.join(arguments)} failed: {reply}")
    return reply["stdout"]


def status(agent):
    text = timers(agent, "status", "--json")
    lines = [line for line in text.splitlines() if line.strip()]
    if not lines:
        raise AssertionError("timers status printed no line")
    return json.loads(lines[-1])


def named(status_value, name):
    for item in status_value["jobs"]:
        if item["name"] == name:
            return item
    raise AssertionError(f"job {name} is absent: {[item['name'] for item in status_value['jobs']]}")


def snapshot_ids(value):
    entries = value if isinstance(value, list) else [value]
    ids = []
    for entry in entries:
        if isinstance(entry, dict) and "snapshots" in entry:
            ids.extend(snap["id"] for snap in entry["snapshots"])
        else:
            ids.append(entry["id"])
    return ids


def agent_snapshots(agent):
    reply = agent.request("snapshots")
    if reply.get("exit") != 0:
        raise AssertionError(f"rustic snapshots failed: {reply}")
    return snapshot_ids(json.loads(reply["stdout"]))


def attempt_lines(text):
    attempts = []
    for line in text.splitlines():
        if "name=backup-fail" not in line:
            continue
        if "event=job-finish" not in line and "event=job-retry" not in line:
            continue
        for token in line.split():
            if token.startswith("attempt="):
                attempts.append(int(token.split("=", 1)[1]))
    return attempts


def wait_service(agent, timeout=300):
    def ready():
        value = agent.request("status")
        service = value.get("service") or {}
        if service.get("state") == "running" and service.get("ready") is True and service.get("pid", 0) > 0:
            return value
        return None

    return dl.wait_until(ready, timeout, "laputa-timers running")


def wait_job(agent, name, predicate, timeout, what):
    def ready():
        value = status(agent)
        item = named(value, name)
        return item if predicate(item) else None

    return dl.wait_until(ready, timeout, what)


def phase_scheduled(args, scratch, state, backup, expected_daily):
    shutil.copy(str(state), str(rd.state_image))
    rd.state_image.chmod(0o600)
    control = scratch / "control.sock"
    console = scratch / "scheduled-console.log"
    guest = errlog = agent = None
    try:
        guest, errlog = launch_with_agent(
            rd.boot_base_argv(), console, scratch / "scheduled.qemu.log", control,
            [("backup", backup)],
        )
        dl.wait_console(console, AGENT_READY, 420, bad=(AGENT_FAILED, FAILED))
        agent = dl.Agent(control)
        agent.ping()
        dl.log("guest control agent answered")
        wait_service(agent)
        observation = agent.request("status")
        if observation.get("receipt") is not None:
            raise AssertionError("a receipt existed before the first backup")
        value = status(agent)
        if value["invalid"]:
            raise AssertionError(f"invalid job definitions: {value['invalid']}")
        for name in ("backup", "backup-proof", "backup-fail", "daily-sync"):
            named(value, name)
        if named(value, "backup")["state"] != "cancelled":
            raise AssertionError(f"the shipped backup job is not cancelled: {named(value, 'backup')['state']}")
        daily = named(value, "daily-sync")
        if daily["next"]["wall_ms"] != expected_daily:
            raise AssertionError(f"the shipped daily-sync next is {daily['next']} not {expected_daily}")
        print(f"PASS armed: shipped backup cancelled, daily-sync next={expected_daily}")

        failing = wait_job(
            agent, "backup-fail",
            lambda item: item["counts"]["failures"] >= 2 and item["last"]["outcome"] == "failed",
            60, "the failing backup to be counted",
        )
        text = agent.request("status").get("scheduler_log") or ""
        attempts = attempt_lines(text)
        if not attempts:
            raise AssertionError("the failing backup produced no start lines")
        if max(attempts) != 2:
            raise AssertionError(f"the failing backup was not bounded to two attempts: {attempts}")
        if failing["last"]["exit_code"] in (None, 0):
            raise AssertionError(f"the failing backup recorded no nonzero exit: {failing['last']}")
        timers(agent, "cancel", "backup-fail")
        held = wait_job(agent, "backup-fail", lambda item: item["state"] == "cancelled", 15, "backup-fail cancelled")
        held_failures = held["counts"]["failures"]
        time.sleep((FAIL_INTERVAL_MS / 1000) * 2.5)
        after = named(status(agent), "backup-fail")
        if after["counts"]["failures"] != held_failures:
            raise AssertionError(f"a cancelled failing backup kept retrying: {held_failures} -> {after['counts']['failures']}")
        print(f"PASS failure: attempts={attempts[:6]} failures={held_failures} bounded and stopped after cancel")

        proof = wait_job(
            agent, "backup-proof",
            lambda item: item["counts"]["runs"] >= PROOF_RUNS
            and item["state"] == "idle"
            and item["last"]["outcome"] == "ok",
            360, "the scheduled backups and pruning",
        )
        if proof["last"]["outcome"] != "ok":
            raise AssertionError(f"the scheduled backup last outcome is {proof['last']}")
        timers(agent, "cancel", "backup-proof")
        wait_job(agent, "backup-proof", lambda item: item["state"] == "cancelled", 15, "backup-proof cancelled")
        time.sleep(2)

        observation = agent.request("status")
        receipt = observation.get("receipt")
        if not isinstance(receipt, dict):
            raise AssertionError(f"the scheduled backup wrote no receipt: {observation.get('receipt')}")
        if receipt.get("format") != "laputa-backup-receipt-1":
            raise AssertionError(f"the receipt format is {receipt.get('format')}")
        if not (receipt.get("check") or {}).get("ok"):
            raise AssertionError(f"the receipt records no check: {receipt.get('check')}")
        snapshot = receipt.get("snapshot_id")
        if not isinstance(snapshot, str) or len(snapshot) != 64:
            raise AssertionError(f"the receipt snapshot id is malformed: {snapshot}")
        kept = receipt.get("kept_snapshot_ids") or []
        if len(kept) != KEEP_LAST:
            raise AssertionError(f"the receipt retains {len(kept)} snapshots, not {KEEP_LAST}: {kept}")
        if receipt.get("keep_last") != KEEP_LAST:
            raise AssertionError(f"the receipt policy is {receipt.get('keep_last')}")
        if snapshot not in kept:
            raise AssertionError("the receipt snapshot is outside its retained set")
        listed = agent_snapshots(agent)
        if len(listed) != KEEP_LAST:
            raise AssertionError(f"pruning left {len(listed)} snapshots, not {KEEP_LAST}: {listed}")
        if sorted(listed) != sorted(kept):
            raise AssertionError(f"the receipt retained ids differ from the repository: {kept} vs {listed}")
        if snapshot not in listed:
            raise AssertionError("the receipt snapshot is absent from the repository")
        quiesce = observation.get("quiesce")
        if not isinstance(quiesce, dict):
            raise AssertionError("the backup wrote no quiesce marker")
        if quiesce.get("logger") != "down" or quiesce.get("dhcp") != "down":
            raise AssertionError(f"the backup was not quiesced: {quiesce}")
        if quiesce.get("writer_lines", 0) <= 0:
            raise AssertionError(f"the quiesce marker recorded no writer state: {quiesce}")
        scheduler_log = observation.get("scheduler_log") or ""
        if "event=backup-check" not in scheduler_log:
            raise AssertionError("the scheduler log does not record the repository check")
        if f"event=backup-finish job=backup-proof outcome=ok snapshot={snapshot}" not in scheduler_log:
            raise AssertionError("the scheduler log does not record the successful snapshot")
        print(
            f"PASS scheduled: runs={proof['counts']['runs']} snapshot={snapshot} "
            f"kept={len(listed)} quiesced_writer_lines={quiesce['writer_lines']} check=ok"
        )
        return receipt
    finally:
        if agent is not None:
            agent.close()
        if guest is not None:
            dl.stop_guest(guest, errlog)
        if console.exists() and FAILED in console.read_text(errors="replace"):
            raise RuntimeError(f"guest reported {FAILED}; inspect {console}")


def phase_restore(args, scratch, state, backup, blank, receipt):
    shutil.copy(str(state), str(rd.state_image))
    rd.state_image.chmod(0o600)
    console = scratch / "restore-console.log"
    guest = None
    errlog = None
    try:
        guest, errlog = rd.launch(
            rd.boot_base_argv(), console, scratch / "restore.qemu.log",
            extra_cmdline=" LAPUTA_BACKUP_RESTORE=1",
            extra_drives=[("backup", backup), ("blank", blank)],
            strip_proof_flag=True,
        )
        dl.wait_console(console, RESTORE_OK, 420, bad=(RESTORE_FAILED, FAILED))
        text = console.read_text(errors="replace")
        for marker in ("BACKUP_RESTORE_IDENTITY_OK", "BACKUP_RESTORE_QUIESCE_OK"):
            if marker not in text:
                raise AssertionError(f"the restore reported no {marker}")
        if receipt["snapshot_id"] not in text:
            raise AssertionError("the restored snapshot is not the receipt snapshot")
        rd.fail_if_bad(console)
        print(f"PASS restore: blank disk carries snapshot={receipt['snapshot_id']} with quiesced state")
    finally:
        if guest is not None:
            dl.stop_guest(guest, errlog)
        if console.exists() and RESTORE_FAILED in console.read_text(errors="replace"):
            raise RuntimeError(f"guest reported {RESTORE_FAILED}; inspect {console}")


def run(args):
    require_prerequisites(args)
    rd.binary = args.xsh
    SCRATCH_ROOT.mkdir(parents=True, exist_ok=True)
    (SCRATCH_ROOT / "tmp").mkdir(parents=True, exist_ok=True)
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="backup-schedule.", dir=SCRATCH_ROOT))
    dl.log(f"scratch {scratch}")
    try:
        state = backup_state(args, scratch)
        skeleton = restore_state(args, scratch)
        password = "fixture-" + os.urandom(16).hex()
        backup = backup_disk(scratch, password)
        blank = blank_disk(scratch)
        now = datetime.datetime.now(datetime.timezone.utc)
        expected_daily = next_daily(DAILY_HOUR, DAILY_MINUTE, now)
        receipt = phase_scheduled(args, scratch, state, backup, expected_daily)
        phase_restore(args, scratch, skeleton, backup, blank, receipt)
        print("PASS scheduled-backup: timer job, quiescence, check, retention, receipt-bound restore")
    finally:
        if args.keep:
            dl.log(f"kept {scratch}")
        else:
            shutil.rmtree(scratch, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description="Prove scheduled backups and a receipt-bound restore on the maintained guest.")
    parser.add_argument("--xsh", type=pathlib.Path, default=dl.DEFAULT_XSH)
    parser.add_argument("--core", type=pathlib.Path, default=dl.DEFAULT_CORE)
    parser.add_argument("--bundle", type=pathlib.Path, default=dl.DEFAULT_BUNDLE)
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    try:
        run(args)
    except AssertionError as problem:
        print(f"FAIL: {problem}", file=sys.stderr)
        return 1
    except Exception as problem:
        traceback.print_exc()
        print(f"ERROR: {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

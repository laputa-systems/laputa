#!/usr/bin/env python3
"""Prove the supervised timer scheduler on the maintained qemu-maintained image.

One virtio-serial agent, installed only on the disposable state disk, drives the
guest. The test runs a short-interval job and a bounded-retry job, cancels and
resumes a job, pauses the VM through QMP, hard-resets it, restarts the scheduler
through xinit, and reads the same status through the existing remote program.
It exercises only the state disk; the immutable generation is unchanged.
"""

import argparse
import base64
import datetime
import json
import os
import pathlib
import shutil
import sys
import time
import traceback

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import dhcp_lifecycle as dl

ROOT = dl.ROOT
SCRATCH_ROOT = dl.SCRATCH_ROOT
AGENT_FIXTURE = ROOT / "tests/integration/fixtures/timers_guest_agent.xsh"
APPLY_FIXTURE = dl.APPLY_FIXTURE
REMOTE_PROGRAM = ROOT / "system/remote_guest.xsh"
PROFILE_JOB = ROOT / "profiles/qemu-maintained/etc/laputa/timers/jobs.d/daily-sync.json"
STATE_SIZE = 256 * 1024 * 1024

INTERVAL_MS = 3000
FAIL_INTERVAL_MS = 4000
PAUSE_SECONDS = 20
POST_PAUSE_WINDOW = 7
DAILY_HOUR = 3
DAILY_MINUTE = 17

PROBE = """#!/usr/bin/xsh
proc main(target: Str) [fs, env, error] {
  let name = e"LAPUTA_TIMER_NAME" ?? "?"
  let attempt = e"LAPUTA_TIMER_ATTEMPT" ?? "?"
  let missed = e"LAPUTA_TIMER_MISSED" ?? "?"
  let scheduled = e"LAPUTA_TIMER_SCHEDULED_WALL_MS" ?? "?"
  let started = e"LAPUTA_TIMER_START_WALL_MS" ?? "?"
  let boot = p"/proc/sys/kernel/random/boot_id".read_text()?.trim()
  let line = f"{name} attempt={attempt} missed={missed} scheduled={scheduled} started={started} boot={boot}\\n"
  let file = Path(target)
  let current = if file.exists()? { file.read_text()? } else { "" }
  file.write(current + line)?
}
"""

FAIL = """#!/usr/bin/xsh
proc main(target: Str) [fs, env, error] {
  let name = e"LAPUTA_TIMER_NAME" ?? "?"
  let attempt = e"LAPUTA_TIMER_ATTEMPT" ?? "?"
  let missed = e"LAPUTA_TIMER_MISSED" ?? "?"
  let scheduled = e"LAPUTA_TIMER_SCHEDULED_WALL_MS" ?? "?"
  let started = e"LAPUTA_TIMER_START_WALL_MS" ?? "?"
  let line = f"{name} attempt={attempt} missed={missed} scheduled={scheduled} started={started}\\n"
  let file = Path(target)
  let current = if file.exists()? { file.read_text()? } else { "" }
  file.write(current + line)?
  fail "intentional failure"
}
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
        ("apply fixture", APPLY_FIXTURE),
        ("remote program", REMOTE_PROGRAM),
        ("profile job", PROFILE_JOB),
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


def reexec_in_user_net_namespace():
    if os.environ.get("LAPUTA_TIMERS_GUEST_NETNS") == "1":
        return
    unshare = shutil.which("unshare")
    if unshare is None:
        print("SKIP: unshare is required to own the tap without host privileges", file=sys.stderr)
        sys.exit(77)
    os.environ["LAPUTA_TIMERS_GUEST_NETNS"] = "1"
    os.execv(unshare, [unshare, "-Urn", sys.executable, str(pathlib.Path(__file__).resolve()), *sys.argv[1:]])


def next_occurrence(hour, minute, now):
    target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if target <= now:
        target += datetime.timedelta(days=1)
    return int(target.timestamp() * 1000)


def calendar_target(now):
    return (now + datetime.timedelta(minutes=15)).replace(second=0, microsecond=0)


def job(name, schedule, command, overlap, missed, timeout_ms=0, retries=None):
    document = {
        "format": "laputa-timer-job-1",
        "name": name,
        "schedule": schedule,
        "command": command,
        "timeout_ms": timeout_ms,
        "overlap": overlap,
        "missed": missed,
    }
    if retries is not None:
        document["retries"] = retries
    return json.dumps(document, indent=2, sort_keys=True) + "\n"


def provision_state(args, scratch):
    staging = scratch / "state-staging"
    state = scratch / "state.ext4"
    shutil.rmtree(staging, ignore_errors=True)
    for directory in ("etc", "home", "var"):
        (staging / directory).mkdir(parents=True)
    base_etc = ROOT / "packages/baselayout/files/rootfs/etc"
    for entry in sorted(base_etc.iterdir()):
        if entry.name == "inittab":
            continue
        if entry.is_dir():
            shutil.copytree(entry, staging / "etc" / entry.name, symlinks=True, dirs_exist_ok=True)
        else:
            shutil.copy(entry, staging / "etc" / entry.name, follow_symlinks=False)
    shutil.copy(ROOT / "profiles/qemu-maintained/etc/inittab", staging / "etc/inittab")
    shutil.copy(ROOT / "packages/nftables/nftables.conf", staging / "etc/nftables.conf")
    (staging / "etc/network").mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / "packages/laputa-net/interfaces", staging / "etc/network/interfaces")
    for directory, mode in (
        ("var/lib/dhcpc", 0o700),
        ("var/lib/laputa", 0o755),
        ("var/lib/laputa-timers", 0o755),
        ("var/lib/timers-proof", 0o755),
        ("var/log", 0o755),
    ):
        path = staging / directory
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(mode)

    timer_root = staging / "etc/laputa/timers"
    jobs = timer_root / "jobs.d"
    jobs.mkdir(parents=True)
    shutil.copy(PROFILE_JOB, jobs / "daily-sync.json")

    now = datetime.datetime.now(datetime.timezone.utc)
    calendar_at = calendar_target(now)
    log = "/var/lib/timers-proof"
    jobs_documents = {
        "interval.json": job(
            "interval",
            {"kind": "interval", "every_ms": INTERVAL_MS},
            ["/usr/bin/xsh", "/etc/laputa/timers/probe.xsh", f"{log}/interval.log"],
            "skip",
            "coalesce",
            timeout_ms=10000,
        ),
        "calendar.json": job(
            "calendar",
            {"kind": "calendar", "hour": calendar_at.hour, "minute": calendar_at.minute},
            ["/usr/bin/xsh", "/etc/laputa/timers/probe.xsh", f"{log}/calendar.log"],
            "skip",
            "coalesce",
            timeout_ms=10000,
        ),
        "failing.json": job(
            "failing",
            {"kind": "interval", "every_ms": FAIL_INTERVAL_MS},
            ["/usr/bin/xsh", "/etc/laputa/timers/fail.xsh", f"{log}/failing.log"],
            "skip",
            "coalesce",
            timeout_ms=10000,
            retries={"max": 2, "delay_ms": 200},
        ),
    }
    for name, document in jobs_documents.items():
        (jobs / name).write_text(document)
    (timer_root / "probe.xsh").write_text(PROBE)
    (timer_root / "probe.xsh").chmod(0o755)
    (timer_root / "fail.xsh").write_text(FAIL)
    (timer_root / "fail.xsh").chmod(0o755)
    shutil.copy(AGENT_FIXTURE, staging / "etc/laputa/timers-agent.xsh")
    (staging / "etc/laputa/timers-agent.xsh").chmod(0o755)
    boot_hooks = staging / "etc/rc.d"
    boot_hooks.mkdir(parents=True, exist_ok=True)
    (boot_hooks / "99-timers-agent.boot").write_text(
        "#!/usr/bin/xsh\n"
        "let _ = unix.spawn_process_group(process.command_argv(p\"/usr/bin/xsh\", [\"/usr/bin/xsh\", \"/etc/laputa/timers-agent.xsh\"]))?\n"
    )
    (boot_hooks / "99-timers-agent.boot").chmod(0o755)
    shutil.copy(REMOTE_PROGRAM, staging / "etc/laputa/remote_guest.xsh")
    (staging / "etc/laputa/remote_guest.xsh").chmod(0o755)
    (staging / "format").write_text("laputa-maintained-state-1\n")

    dl.run_xsh(args, APPLY_FIXTURE, staging)
    state.unlink(missing_ok=True)
    dl.run_xsh(
        args,
        ROOT / "system/maintained_state_image.xsh",
        "--",
        staging,
        state,
        str(STATE_SIZE),
        ROOT / "packages/laputa-fs/files/mkfs.ext4.xsh",
        args.xsh,
        timeout=300,
    )
    state.chmod(0o600)
    shutil.rmtree(staging)
    return state, calendar_at, next_occurrence(DAILY_HOUR, DAILY_MINUTE, now)


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


def counts(reply, field):
    value = (reply.get("counts") or {}).get(field)
    return value if isinstance(value, int) else -1


def attempt_lines(text):
    attempts = []
    for line in text.splitlines():
        for token in line.split():
            if token.startswith("attempt="):
                attempts.append(int(token.split("=", 1)[1]))
    return attempts


def observation(agent):
    return agent.request("status")


def wait_scheduler(agent, timeout=300):
    def ready():
        value = observation(agent)
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


def wait_log(agent, field, predicate, timeout, what):
    def ready():
        value = observation(agent)
        text = value.get(field) or ""
        return text if predicate(text) else None

    return dl.wait_until(ready, timeout, what)


def debug(agent):
    try:
        value = observation(agent)
        print("DEBUG observation " + json.dumps({key: value[key] for key in value if key not in ("scheduler_log", "interval_log", "calendar_log", "failing_log")}, default=str)[:4000], flush=True)
        print("DEBUG scheduler log\n" + (value.get("scheduler_log") or "")[-8000:], flush=True)
        print("DEBUG interval log\n" + (value.get("interval_log") or "")[-4000:], flush=True)
        print("DEBUG failing log\n" + (value.get("failing_log") or "")[-4000:], flush=True)
    except Exception as problem:
        print(f"DEBUG unavailable: {problem}", flush=True)


def run(args):
    require_prerequisites(args)
    SCRATCH_ROOT.mkdir(parents=True, exist_ok=True)
    (SCRATCH_ROOT / "tmp").mkdir(parents=True, exist_ok=True)
    scratch = pathlib.Path(__import__("tempfile").mkdtemp(prefix="timers-guest.", dir=SCRATCH_ROOT))
    dl.log(f"scratch {scratch}")
    guest = errlog = qmp = agent = tap_fd = None
    try:
        tap_fd = dl.create_tap(args, "ttap0", "192.0.4.1")
        state, calendar_at, daily_next = provision_state(args, scratch)
        console = scratch / "timers-console.log"
        guest, errlog, control, qmp_path = dl.launch(args, scratch, "timers", state, tap_fd, console)
        os.close(tap_fd)
        tap_fd = None
        dl.wait_console(console, "LAPUTA_TIMERS_AGENT_READY", 420, bad=("LAPUTA_TIMERS_AGENT_FAILED",))
        agent = dl.Agent(control)
        agent.ping()
        qmp = dl.Qmp(qmp_path)
        dl.log("guest control agent answered")

        first = wait_scheduler(agent)
        scheduler_pid = (first.get("service") or {}).get("pid")
        value = status(agent)
        if value["invalid"]:
            raise AssertionError(f"invalid job definitions: {value['invalid']}")
        for name in ("interval", "calendar", "failing", "daily-sync"):
            named(value, name)
        daily = named(value, "daily-sync")
        if daily["next"]["wall_ms"] != daily_next:
            raise AssertionError(f"shipped daily-sync next is {daily['next']} not {daily_next}")
        if daily["counts"]["runs"] != 0:
            raise AssertionError(f"shipped daily-sync already ran: {daily['counts']}")
        calendar = named(value, "calendar")
        expected_calendar = int(calendar_at.timestamp() * 1000)
        if calendar["next"]["wall_ms"] != expected_calendar:
            raise AssertionError(f"calendar next is {calendar['next']} not {expected_calendar}")
        print(f"PASS armed: scheduler pid={scheduler_pid} jobs=4 daily-sync next={daily_next} calendar next={expected_calendar}")

        interval = wait_job(agent, "interval", lambda item: item["counts"]["runs"] >= 2 and item["last"]["outcome"] == "ok", 20, "two completed interval runs")
        if interval["last"]["outcome"] != "ok":
            raise AssertionError(f"interval last outcome is {interval['last']}")
        print(f"PASS interval: runs={interval['counts']['runs']} last={interval['last']['outcome']} next_in={interval['next']['in_ms']}ms source={interval['next']['source']}")

        failing_log = wait_log(agent, "failing_log", lambda text: max(attempt_lines(text) or [0]) >= 3, 25, "three bounded attempts")
        attempts = attempt_lines(failing_log)
        if max(attempts) != 3:
            raise AssertionError(f"retries exceeded the bound of 3 attempts: {attempts}")
        failing = named(status(agent), "failing")
        if failing["counts"]["failures"] < 3:
            raise AssertionError(f"failures were not counted: {failing['counts']}")
        print(f"PASS retries: attempts={attempts[:6]} failures={failing['counts']['failures']} bounded=3")

        if timers(agent, "cancel", "interval").strip() == "":
            raise AssertionError("cancel printed no confirmation")
        wait_job(agent, "interval", lambda item: item["state"] == "cancelled", 10, "interval cancelled")
        if not (observation(agent).get("cancel_marker") or False):
            raise AssertionError("the cancellation marker is absent from the state disk")
        cancelled_runs = named(status(agent), "interval")["counts"]["runs"]
        time.sleep((INTERVAL_MS / 1000) * 2.5)
        held = named(status(agent), "interval")
        if held["counts"]["runs"] != cancelled_runs:
            raise AssertionError(f"a cancelled job ran: {cancelled_runs} -> {held['counts']['runs']}")
        print(f"PASS cancellation: state={held['state']} runs stayed {cancelled_runs} across two intervals")
        timers(agent, "resume", "interval")
        resumed = wait_job(agent, "interval", lambda item: item["counts"]["runs"] > cancelled_runs, 15, "interval resumed")
        print(f"PASS resume: runs={resumed['counts']['runs']} state={resumed['state']}")

        before = observation(agent)
        before_status = status(agent)
        before_interval = named(before_status, "interval")
        before_calendar = named(before_status, "calendar")
        qmp.execute("stop")
        time.sleep(PAUSE_SECONDS)
        qmp.execute("cont")
        time.sleep(POST_PAUSE_WINDOW)
        after = observation(agent)
        after_status = status(agent)
        after_interval = named(after_status, "interval")
        wall_delta = after["wall_ms"] - before["wall_ms"]
        boot_delta = after["boot_ns"] - before["boot_ns"]
        runs_delta = after_interval["counts"]["runs"] - before_interval["counts"]["runs"]
        coalesced_delta = after_interval["counts"]["coalesced"] - before_interval["counts"]["coalesced"]
        wait = after_status["resume"]
        if runs_delta > 4:
            raise AssertionError(f"the pause produced a catch-up burst: {runs_delta} runs")
        if (after.get("service") or {}).get("pid") != scheduler_pid or (after.get("service") or {}).get("restarts", 0) != 0:
            raise AssertionError(f"the scheduler restarted across the pause: {after.get('service')}")
        if wait == "gap":
            if coalesced_delta < 1:
                raise AssertionError(f"a measured guest gap did not coalesce: {after_interval['counts']}")
        if wait not in ("gap", "wall-forward", "wall-backward", "steady"):
            raise AssertionError(f"unexpected resume classification {wait}")
        print(
            f"PASS pause: resume={wait} wall_delta={wall_delta}ms boot_delta={boot_delta}ns "
            f"runs_delta={runs_delta} coalesced_delta={coalesced_delta}"
        )
        named(after_status, "calendar")
        if after_status["resume"] != before_status["resume"] and after_status["last_step"] is None:
            raise AssertionError("the resume classification has no recorded step")

        reboot_before = observation(agent)
        reboot_status = status(agent)
        reboot_interval = named(reboot_status, "interval")
        reboot_calendar_next = named(reboot_status, "calendar")["next"]["wall_ms"]
        reboot_daily_next = named(reboot_status, "daily-sync")["next"]["wall_ms"]
        boot_id = reboot_before["boot_id"]
        dl.stop_guest(guest, errlog, qmp)
        guest = errlog = qmp = None
        agent.close()
        agent = None
        dl.log("guest stopped; cold booting the same state disk")
        tap_fd = dl.create_tap(args, "ttap1", "192.0.4.1")
        console2 = scratch / "timers-console-2.log"
        guest, errlog, control, qmp_path = dl.launch(args, scratch, "reboot", state, tap_fd, console2)
        os.close(tap_fd)
        tap_fd = None
        qmp = dl.Qmp(qmp_path)
        dl.wait_console(console2, "LAPUTA_TIMERS_AGENT_READY", 420, bad=("LAPUTA_TIMERS_AGENT_FAILED",))
        agent = dl.Agent(control)
        agent.ping()
        second = wait_scheduler(agent)
        dl.wait_until(lambda: observation(agent)["boot_id"] != boot_id, 60, "a new boot id")
        caught_up = wait_job(
            agent,
            "interval",
            lambda item: item["counts"]["runs"] > reboot_interval["counts"]["runs"],
            30,
            "the interval catch-up after reboot",
        )
        reboot_runs_delta = caught_up["counts"]["runs"] - reboot_interval["counts"]["runs"]
        if caught_up["counts"]["coalesced"] <= reboot_interval["counts"]["coalesced"]:
            raise AssertionError(f"reboot downtime did not coalesce: {reboot_interval['counts']} -> {caught_up['counts']}")
        if reboot_runs_delta > 3:
            raise AssertionError(f"reboot downtime backfilled {reboot_runs_delta} runs")
        if caught_up["last"]["start_wall_ms"] is None or caught_up["last"]["start_wall_ms"] <= (reboot_interval["last"]["start_wall_ms"] or 0):
            raise AssertionError(f"last start did not advance: {caught_up['last']}")
        after_reboot = status(agent)
        if named(after_reboot, "calendar")["next"]["wall_ms"] != reboot_calendar_next:
            raise AssertionError(f"the calendar anchor did not persist: {reboot_calendar_next} -> {named(after_reboot, 'calendar')['next']}")
        if named(after_reboot, "daily-sync")["next"]["wall_ms"] != reboot_daily_next:
            raise AssertionError("the shipped job definition did not persist")
        print(
            f"PASS reboot: boot={reboot_before['boot_id']} -> {observation(agent)['boot_id']} "
            f"runs_delta={reboot_runs_delta} coalesced={caught_up['counts']['coalesced']} "
            f"calendar_anchor={reboot_calendar_next}"
        )

        reload_status = status(agent)
        old_pid = reload_status["scheduler_pid"]
        runs_before_restart = named(reload_status, "interval")["counts"]["runs"]
        reply = agent.request("restart")
        if reply.get("exit") != 0:
            raise AssertionError(f"xinit restart failed: {reply}")
        dl.wait_until(
            lambda: (lambda value: value if value["scheduler_pid"] not in (0, old_pid) else None)(status(agent)),
            60,
            "the restarted scheduler",
        )
        continued = wait_job(agent, "interval", lambda item: item["counts"]["runs"] > runs_before_restart, 20, "runs after restart")
        restarted = status(agent)
        restarted_interval = named(restarted, "interval")
        if restarted_interval["counts"]["runs"] < runs_before_restart:
            raise AssertionError(f"the restarted scheduler reset state: {restarted_interval['counts']}")
        print(
            f"PASS restart: pid {old_pid} -> {restarted['scheduler_pid']} "
            f"runs={restarted_interval['counts']['runs']} state kept"
        )

        remote = agent.request("remote")
        if remote.get("exit") != 0:
            raise AssertionError(f"the remote program failed: {remote}")
        lines = [line for line in remote["stdout"].splitlines() if line.strip()]
        if len(lines) != 1:
            raise AssertionError(f"the remote reply is not one line: {lines}")
        envelope = json.loads(lines[0])
        if envelope.get("protocol") != "laputa-remote-1" or not envelope.get("ok"):
            raise AssertionError(f"the remote program refused: {envelope}")
        result = envelope["result"]
        if result["exit_code"] != 0:
            raise AssertionError(f"the remote timer status exited {result['exit_code']}: {result.get('stderr_b64')}")
        payload = base64.b64decode(result["stdout_b64"]).decode()
        remote_status = json.loads(payload.strip().splitlines()[-1])
        for name in ("interval", "calendar", "failing", "daily-sync"):
            named(remote_status, name)
        print(f"PASS remote: inspect op run argv reached the timer status with {len(remote_status['jobs'])} jobs")

        print("PASS timers guest: interval, retries, cancellation, pause, reboot, restart, remote status")
    except Exception:
        if agent is not None:
            debug(agent)
        raise
    finally:
        if guest is not None:
            dl.stop_guest(guest, errlog, qmp)
        if agent is not None:
            agent.close()
        if tap_fd is not None:
            os.close(tap_fd)
        if args.keep:
            dl.log(f"kept {scratch}")
        else:
            shutil.rmtree(scratch, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description="Prove the supervised timer scheduler on the maintained guest.")
    parser.add_argument("--xsh", type=pathlib.Path, default=dl.DEFAULT_XSH)
    parser.add_argument("--core", type=pathlib.Path, default=dl.DEFAULT_CORE)
    parser.add_argument("--bundle", type=pathlib.Path, default=dl.DEFAULT_BUNDLE)
    parser.add_argument("--ip-tool", type=pathlib.Path)
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    if args.ip_tool is None:
        candidate = args.core / "ip"
        args.ip_tool = candidate if candidate.exists() else args.core / "ip.xsh"
    reexec_in_user_net_namespace()
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

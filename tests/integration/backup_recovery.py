#!/usr/bin/env python3
"""Prove that a backup attempt lost after a successful quiesce is released.

One virtio-serial agent, installed only on the disposable state disk, drives a
maintained guest. Timer jobs run the shipped quiesce hook with the shipped
recovery flags over `logger` and `dhcp-eth0`, plus `oxish`, which the
test stops first, and then block, as a backup does while rustic runs. Each job
is lost a different way: its timeout expires, an operator cancels it, its leader
is killed with SIGKILL, and the scheduler restarts. Every case must return the
acquired services to service within the bound BACKUP.md publishes, keep the
previously stopped service down, start no new attempt after a cancellation, and
leave the repeated recovery as a no-op.
Another lost attempt must preserve an operator stop issued after acquisition.
"""

import argparse
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
AGENT_FIXTURE = ROOT / "tests/integration/fixtures/backup_recovery_agent.xsh"
APPLY_FIXTURE = dl.APPLY_FIXTURE
PROFILE_BACKUP = ROOT / "profiles/qemu-maintained/etc/laputa/backup.json"
STATE_SIZE = 256 * 1024 * 1024
PROOF_DIR = "/var/lib/backup-recovery"
RUNNER = "/etc/laputa/backup-recovery/runner.xsh"
STOPPED = "oxish"
WATCHED = ["logger", "dhcp-eth0", STOPPED]
TIMEOUT_JOB_MS = 20000
QUIESCE_DIR = "/var/lib/laputa-timers/quiesce"
SCHEDULER_BEFORE = {}

RUNNER_SOURCE = """#!/usr/bin/xsh
proc main(...argv: List[Str]) [fs, process, time, env, error] -> Result[Unit, Error] {
  let job = e"LAPUTA_TIMER_NAME" ?? ""
  let dir = p"/var/lib/backup-recovery"
  dir.mkdir(parents: true)?
  let attempts = fp"{dir}/{job}.attempts"
  let seen = if attempts.exists()? { attempts.read_text()? } else { "" }
  attempts.write(seen + f"attempt={e"LAPUTA_TIMER_ATTEMPT" ?? "?"} pid={process.current_pid()?}\\n")?
  let status = process.run(process.command_argv(p"/usr/bin/xsh", ["xsh", "/usr/lib/laputa/backup-quiesce.xsh", "stop"] + argv))?
  guard status.ok else { fail "the shipped quiesce hook failed" }
  fp"{dir}/{job}.quiesced".write(f"{process.current_pid()?}\\n")?
  time.sleep(900s)?
}
"""


WINDOW_RUNNER = """#!/usr/bin/xsh
use backup_quiesce

proc mark(job: Str, cut: Str) [fs, process, time, error] -> Result[Unit, Error] {
  fp"/var/lib/backup-recovery/{job}.window".write(f"{cut} {process.current_pid()?}\\n")?
  time.sleep(900s)?
}

proc main(...argv: List[Str]) [fs, process, time, io, env, error] -> Result[Unit, Error] {
  let job = e"LAPUTA_TIMER_NAME" ?? ""
  let attempt = (e"LAPUTA_TIMER_ATTEMPT" ?? "0").parse_int()?
  let cut = argv[0]
  let options = match backup_quiesce.quiesce_options(["stop"] + argv[1..]) {
    Ok(value) => value,
    Err(problem) => { return Err(error.failure(problem)) },
  }
  let qe = backup_quiesce.quiesce_env_default()
  let record = backup_quiesce.quiesce_plan(qe, job, attempt, options.services, p"/proc/sys/kernel/random/boot_id".read_text()?.trim(), time.now(), options)?
  backup_quiesce.quiesce_write_record(qe, record)?
  if cut == "record" { mark(job, cut)? }
  var stopped = 0
  for service in record.services {
    if service.acquired {
      backup_quiesce.quiesce_stop_service(qe, record, service.name)?
      stopped += 1
      if stopped == 1 and cut == "first-stop" { mark(job, cut)? }
    }
  }
  if cut == "all-stops" or cut == "retry" { mark(job, cut)? }
  var released = 0
  for service in record.services {
    if service.acquired {
      backup_quiesce.quiesce_release_service(qe, record, service.name, record.release_timeout_ms)?
      released += 1
      if released == 1 and cut == "first-release" { mark(job, cut)? }
    }
  }
  if cut == "last-release" { mark(job, cut)? }
  let _ = backup_quiesce.quiesce_release_record(qe, job, 0)?
  if cut == "retired" { mark(job, cut)? }
}
"""

WINDOWS = ("record", "first-stop", "all-stops", "first-release", "last-release", "retired", "retry")
RETRY_OPTIONS = {"--recover-timeout-ms": 1000, "--recover-retry-ms": 3000, "--recover-attempts": 5}


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
        ("backup configuration", PROFILE_BACKUP),
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
    if os.environ.get("LAPUTA_BACKUP_RECOVERY_NETNS") == "1":
        return
    unshare = shutil.which("unshare")
    if unshare is None:
        print("SKIP: unshare is required to own the tap without host privileges", file=sys.stderr)
        sys.exit(77)
    os.environ["LAPUTA_BACKUP_RECOVERY_NETNS"] = "1"
    os.execv(unshare, [unshare, "-Urn", sys.executable, str(pathlib.Path(__file__).resolve()), *sys.argv[1:]])


def shipped_quiesce():
    """The services and recovery flags of the shipped quiesce hook."""
    command = json.loads(PROFILE_BACKUP.read_text())["quiesce"]["command"]
    words = command[command.index("stop") + 1:]
    split = next(index for index, word in enumerate(words) if word.startswith("--"))
    services, flags = words[:split], words[split:]
    for service in ("logger", "dhcp-eth0"):
        assert service in services, f"the shipped hook no longer quiesces {service}: {services}"
    options = dict(zip(flags[0::2], (int(value) for value in flags[1::2])))
    return services, flags, options


def published_bound_seconds(acquired, options):
    """BACKUP.md: detection 0.5 s, the writer proven stopped within 4 s, then one release of at
    most the per-service bound for each acquired service when xinit does not answer."""
    return 0.5 + 4 + acquired * options["--recover-timeout-ms"] / 1000


def job_document(name, retries=None):
    document = {
        "format": "laputa-timer-job-1",
        "name": name,
        "schedule": None,
        "command": None,
        "timeout_ms": 0,
        "overlap": "skip",
        "missed": "coalesce",
    }
    if retries is not None:
        document["retries"] = retries
    return document


def provision_state(args, scratch, jobs):
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
    shutil.copy(ROOT / "packages/crabtables/nftables.conf", staging / "etc/nftables.conf")
    (staging / "etc/network").mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / "packages/laputa-net/interfaces", staging / "etc/network/interfaces")
    for directory, mode in (
        ("var/lib/dhcpc", 0o700),
        ("var/lib/laputa", 0o755),
        ("var/lib/laputa-timers", 0o755),
        ("var/lib/backup-recovery", 0o755),
        ("var/log", 0o755),
    ):
        path = staging / directory
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(mode)

    job_dir = staging / "etc/laputa/timers/jobs.d"
    job_dir.mkdir(parents=True)
    for document in jobs:
        (job_dir / f"{document['name']}.json").write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    runner = staging / RUNNER.lstrip("/")
    runner.parent.mkdir(parents=True)
    runner.write_text(RUNNER_SOURCE)
    runner.chmod(0o755)
    (runner.parent / "window.xsh").write_text(WINDOW_RUNNER)
    shutil.copyfile(ROOT / "system/backup_quiesce.xsh", runner.parent / "backup_quiesce.xsh")
    shutil.copy(AGENT_FIXTURE, staging / "etc/laputa/recovery-agent.xsh")
    (staging / "etc/laputa/recovery-agent.xsh").chmod(0o755)
    boot_hooks = staging / "etc/rc.d"
    boot_hooks.mkdir(parents=True, exist_ok=True)
    (boot_hooks / "99-recovery-agent.boot").write_text(
        "#!/usr/bin/xsh\n"
        "let _ = unix.spawn_process_group(process.command_argv(p\"/usr/bin/xsh\", [\"/usr/bin/xsh\", \"/etc/laputa/recovery-agent.xsh\"]))?\n"
    )
    (boot_hooks / "99-recovery-agent.boot").chmod(0o755)
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
    return state


class Guest:
    def __init__(self, agent):
        self.agent = agent

    def exec(self, *argv, limit=30):
        reply = self.agent.request("exec", argv=list(argv), limit_s=limit)
        return reply

    def timers(self, *arguments):
        reply = self.exec("/usr/bin/xsh", "/usr/lib/laputa/timers.xsh", *arguments)
        if reply["exit"] != 0:
            raise AssertionError(f"timers {' '.join(arguments)} failed: {reply}")
        return reply["stdout"]

    def xinit(self, *arguments):
        reply = self.exec("/usr/bin/xinit", *arguments, limit=60)
        if reply["exit"] != 0:
            raise AssertionError(f"xinit {' '.join(arguments)} failed: {reply}")
        return reply["stdout"]

    def observe(self, *files):
        return self.agent.request("observe", services=WATCHED, files=list(files))

    def status(self):
        lines = [line for line in self.timers("status", "--json").splitlines() if line.strip()]
        return json.loads(lines[-1])

    def job(self, name):
        for item in self.status()["jobs"]:
            if item["name"] == name:
                return item
        raise AssertionError(f"job {name} is absent")

    def reconcile(self, name):
        reply = self.exec("/usr/bin/xsh", "/usr/lib/laputa/backup-quiesce.xsh", "reconcile", name, limit=180)
        if reply["exit"] != 0:
            raise AssertionError(f"reconcile {name} failed: {reply}")
        return reply["stdout"]


def service_of(observation, name):
    return observation["services"][name]["service"] or {}


def is_up(observation, name):
    service = service_of(observation, name)
    return service.get("desired") == "up" and service.get("state") == "running"


def is_down(observation, name):
    service = service_of(observation, name)
    return service.get("desired") == "down"


def identity(observation, name):
    service = service_of(observation, name)
    return (service.get("pid"), service.get("restarts"), service.get("desired"), service.get("state"))


def wait_scheduler(guest, timeout=300):
    def ready():
        value = guest.observe()
        service = value.get("scheduler") or {}
        if service.get("state") == "running" and service.get("ready") is True and service.get("pid", 0) > 0:
            return value
        return None

    return dl.wait_until(ready, timeout, "laputa-timers running")


def count_events(text, event, job):
    return sum(1 for line in text.splitlines() if f"event={event}" in line and f"name={job}" in line)


def lost_attempt(guest, job, bound, stimulus, after=None, operator_stop=None):
    """Run one job to its blocked, quiesced state, lose it, and check the recovery."""
    before = guest.observe()
    for name in ("logger", "dhcp-eth0"):
        assert is_up(before, name), f"{name} is not up before {job}: {service_of(before, name)}"
    assert is_down(before, STOPPED), f"{STOPPED} is not down before {job}: {service_of(before, STOPPED)}"
    stopped_before = identity(before, STOPPED)
    marker = f"{PROOF_DIR}/{job}.quiesced"
    record_path = f"{QUIESCE_DIR}/{job}.json"
    requested_at = time.monotonic()
    guest.timers("run-now", job)
    observed = dl.wait_until(
        lambda: (lambda value: value if value["files"][marker].strip() else None)(guest.observe(marker, record_path)),
        120,
        f"{job} to quiesce",
        interval=1,
    )
    leader = int(observed["files"][marker].strip())
    record = json.loads(observed["files"][record_path])
    token = record["token"]
    acquired = {item["name"]: item["acquired"] for item in record["services"]}
    assert acquired == {"logger": True, "dhcp-eth0": True, STOPPED: False}, f"{job}: unexpected acquisition {record['services']}"
    for name in ("logger", "dhcp-eth0"):
        assert is_down(observed, name), f"{job}: {name} is not stopped while quiesced"
        assert observed["services"][name]["control"] == token, f"{job}: {name} is not owned by {token}"
    assert identity(observed, STOPPED) == stopped_before, f"{job}: {STOPPED} changed during the quiesce"
    dl.log(f"{job}: quiesced by {token}, leader pid {leader}")

    if operator_stop is not None:
        guest.xinit("stop", operator_stop)
        dl.wait_until(
            lambda: (lambda value: is_down(value, operator_stop) and value["services"][operator_stop]["control"] == "")(guest.observe()),
            60,
            f"{job} operator stop to supersede the quiesce token",
        )

    started, how = stimulus(guest, job, leader, requested_at)

    def recovered():
        value = guest.observe(record_path, marker)
        states_match = all(
            is_down(value, name) if name == operator_stop else is_up(value, name)
            for name in ("logger", "dhcp-eth0")
        )
        if states_match and not value["files"][record_path].strip():
            return value
        return None

    value = dl.wait_until(recovered, bound + 5, f"{job} recovery", interval=1)
    elapsed = time.monotonic() - started
    assert elapsed <= bound, f"{job}: recovery took {elapsed:.1f}s, past the published {bound:.1f}s"
    assert is_down(value, STOPPED), f"{job}: {STOPPED} was started: {service_of(value, STOPPED)}"
    assert value["services"][STOPPED]["control"] == before["services"][STOPPED]["control"], f"{job}: {STOPPED} control changed"
    assert identity(value, STOPPED) == stopped_before, f"{job}: {STOPPED} changed during recovery"
    for name in ("logger", "dhcp-eth0"):
        assert value["services"][name]["control"] != token or is_up(value, name), f"{job}: {name} still owned by {token}"
        assert not value["services"][name]["queued"], f"{job}: {name} still has a queued request"
    dl.wait_until(
        lambda: count_events(guest.observe().get("scheduler_log", ""), "quiesce-released", job) == 1,
        15,
        f"{job} release in the scheduler log",
    )
    assert "quiesce-release-exhausted" not in guest.observe().get("scheduler_log", ""), f"{job}: the release was exhausted"

    settled = guest.observe()
    for text in (guest.reconcile(job), guest.reconcile(job)):
        assert f"quiesce job={job} released=false" in text.lower(), f"{job}: a repeated recovery was not a no-op: {text!r}"
    again = guest.observe(record_path)
    assert not again["files"][record_path].strip(), f"{job}: the record came back"
    for name in WATCHED:
        assert identity(again, name) == identity(settled, name), f"{job}: repeated recovery moved {name}"
        assert again["services"][name]["control"] == settled["services"][name]["control"], f"{job}: repeated recovery changed {name} ownership"
    assert count_events(again["scheduler_log"], "quiesce-released", job) == 1, f"{job}: the scheduler released again"
    if after is not None:
        after(guest, job, again)
    return elapsed, how


def stimulus_timeout(guest, job, leader, requested_at):
    dl.wait_until(
        lambda: count_events(guest.observe().get("scheduler_log", ""), "job-timeout", job) > 0,
        TIMEOUT_JOB_MS / 1000 + 60,
        f"{job} to time out",
        interval=0.5,
    )
    return requested_at + TIMEOUT_JOB_MS / 1000, "timeout"


def stimulus_cancel(guest, job, leader, requested_at):
    started = time.monotonic()
    guest.timers("cancel", job)
    return started, "cancel"


def stimulus_kill(guest, job, leader, requested_at):
    started = time.monotonic()
    reply = guest.exec("/usr/bin/kill", "-KILL", str(leader))
    if reply["exit"] != 0:
        raise AssertionError(f"could not kill the attempt leader: {reply}")
    return started, "sigkill"


def stimulus_restart(guest, job, leader, requested_at):
    SCHEDULER_BEFORE[job] = (guest.observe().get("scheduler") or {}).get("pid")
    started = time.monotonic()
    guest.xinit("restart", "laputa-timers")
    return started, "scheduler-restart"


def after_cancel(guest, job, observation):
    attempts = guest.observe(f"{PROOF_DIR}/{job}.attempts")["files"][f"{PROOF_DIR}/{job}.attempts"]
    assert len(attempts.strip().splitlines()) == 1, f"{job}: a cancelled job started again: {attempts!r}"
    time.sleep(8)
    later = guest.observe(f"{PROOF_DIR}/{job}.attempts")["files"][f"{PROOF_DIR}/{job}.attempts"]
    assert len(later.strip().splitlines()) == 1, f"{job}: a retry started after the cancellation: {later!r}"
    item = guest.job(job)
    assert item["state"] == "cancelled", f"{job}: state is {item['state']}"
    assert not guest.observe(f"{QUIESCE_DIR}/{job}.json")["files"][f"{QUIESCE_DIR}/{job}.json"].strip()


def after_kill(guest, job, observation):
    time.sleep(5)
    attempts = guest.observe(f"{PROOF_DIR}/{job}.attempts")["files"][f"{PROOF_DIR}/{job}.attempts"]
    assert len(attempts.strip().splitlines()) == 1, f"{job}: the killed attempt started again: {attempts!r}"


def after_restart(guest, job, observation):
    pid = (observation.get("scheduler") or {}).get("pid")
    assert pid and pid != SCHEDULER_BEFORE[job], f"{job}: the scheduler did not restart ({SCHEDULER_BEFORE[job]} -> {pid})"


def window_attempt(guest, cut, bound, retry_options):
    job = f"backup-window-{cut}"
    marker = f"{PROOF_DIR}/{job}.window"
    record_path = f"{QUIESCE_DIR}/{job}.json"
    before = guest.observe()
    assert all(is_up(before, name) for name in ("logger", "dhcp-eth0"))
    assert is_down(before, STOPPED)
    guest.timers("run-now", job)
    writer_path = f"/var/lib/laputa-timers/runs/{job}.json"
    observed = dl.wait_until(
        lambda: (lambda value: value if value["files"][marker].strip() else None)(guest.observe(marker, record_path, writer_path)),
        120, f"{job} marker", interval=1,
    )
    label, pid = observed["files"][marker].split()
    assert label == cut
    leader = int(pid)
    assert leader > 1
    assert json.loads(observed["files"][writer_path])["pid"] == leader
    owned = ()
    if cut != "retired":
        record = json.loads(observed["files"][record_path])
        assert {item["name"]: item["acquired"] for item in record["services"]} == {"logger": True, "dhcp-eth0": True, STOPPED: False}
        token = record["token"]
        owned = {"record": (), "first-stop": ("logger",), "all-stops": ("logger", "dhcp-eth0"), "retry": ("logger", "dhcp-eth0"), "first-release": ("dhcp-eth0",), "last-release": ()}[cut]
        for name in ("logger", "dhcp-eth0"):
            assert (observed["services"][name]["control"] == token) == (name in owned), (cut, name, observed["services"][name])
            if name in owned:
                assert is_down(observed, name), (cut, name, service_of(observed, name))
        if cut == "record":
            assert all(is_up(observed, name) for name in ("logger", "dhcp-eth0"))
        if cut == "first-stop":
            assert is_up(observed, "dhcp-eth0")
    else:
        assert not observed["files"][record_path].strip()
    untouched = tuple(name for name in ("logger", "dhcp-eth0") if name not in owned)
    observed = dl.wait_until(
        lambda: (lambda value: value if all(is_up(value, name) for name in untouched) else None)(guest.observe(record_path)),
        60, f"{job} untouched services ready",
    )
    assert identity(observed, STOPPED) == identity(before, STOPPED)
    scanner = None
    try:
        if cut == "retry":
            scanner = json.loads(guest.observe("/run/xinit/scanner.json")["files"]["/run/xinit/scanner.json"])["pid"]
            assert scanner > 1, f"refusing to stop scanner pid {scanner}"
            reply = guest.exec("/usr/bin/kill", "-STOP", str(scanner))
            assert reply["exit"] == 0, reply
        started, _ = stimulus_kill(guest, job, leader, time.monotonic())
        if cut == "retry":
            failed = dl.wait_until(lambda: (lambda value: value if count_events(value["scheduler_log"], "quiesce-release-failed", job) else None)(guest.observe(record_path)), 30, f"{job} release failure", interval=0.2)
            assert failed["files"][record_path].strip(), "failed release retired its record"
            assert count_events(failed["scheduler_log"], "quiesce-release-exhausted", job) == 0
    finally:
        if scanner is not None:
            reply = guest.exec("/usr/bin/kill", "-CONT", str(scanner))
            assert reply["exit"] == 0, reply
    def recovered():
        value = guest.observe(record_path)
        return value if all(is_up(value, name) for name in ("logger", "dhcp-eth0")) and not value["files"][record_path].strip() else None
    recovery_bound = bound
    if cut == "retry":
        acquired_count = sum(item["acquired"] for item in record["services"])
        retry_cycle_ms = acquired_count * retry_options["--recover-timeout-ms"] + retry_options["--recover-retry-ms"]
        recovery_bound = published_bound_seconds(acquired_count, retry_options) + (retry_options["--recover-attempts"] - 1) * retry_cycle_ms / 1000
    value = dl.wait_until(recovered, recovery_bound + 5, f"{job} recovery", interval=0.5)
    assert time.monotonic() - started <= recovery_bound
    assert identity(value, STOPPED) == identity(before, STOPPED)
    for name in untouched:
        assert identity(value, name) == identity(observed, name), f"{job}: recovery restarted untouched {name}"
    assert value["services"][STOPPED]["control"] == before["services"][STOPPED]["control"]
    for name in ("logger", "dhcp-eth0"):
        assert not value["services"][name]["queued"]
    if cut != "retired":
        dl.wait_until(lambda: count_events(guest.observe()["scheduler_log"], "quiesce-released", job) == 1, 15, f"{job} released")
    settled = guest.observe()
    for _ in range(2):
        assert f"quiesce job={job} released=false" in guest.reconcile(job).lower()
    again = guest.observe(record_path)
    assert not again["files"][record_path].strip()
    for name in WATCHED:
        assert identity(again, name) == identity(settled, name)
        assert again["services"][name]["control"] == settled["services"][name]["control"]
    assert count_events(again["scheduler_log"], "quiesce-release-exhausted", job) == 0
    if cut == "retry":
        assert 1 <= count_events(again["scheduler_log"], "quiesce-release-failed", job) < retry_options["--recover-attempts"]
    print(f"PASS backup-window-{cut}: recovered and repeated reconcile was a no-op")


def run(args):
    require_prerequisites(args)
    services, flags, options = shipped_quiesce()
    bound = published_bound_seconds(len(services), options)
    SCRATCH_ROOT.mkdir(parents=True, exist_ok=True)
    (SCRATCH_ROOT / "tmp").mkdir(parents=True, exist_ok=True)
    scratch = pathlib.Path(__import__("tempfile").mkdtemp(prefix="backup-recovery.", dir=SCRATCH_ROOT))
    dl.log(f"scratch {scratch}")
    quiesce_words = [*services, STOPPED, *flags]
    command = ["/usr/bin/xsh", RUNNER, *quiesce_words]
    far = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=6)).replace(second=0, microsecond=0)
    schedule = {"kind": "calendar", "hour": far.hour, "minute": far.minute}
    jobs = []
    for name, timeout_ms, retries in (
        ("backup-timeout", TIMEOUT_JOB_MS, None),
        ("backup-cancel", 0, {"max": 2, "delay_ms": 3000}),
        ("backup-kill", 0, None),
        ("backup-restart", 0, None),
        ("backup-operator", 0, None),
    ):
        document = job_document(name, retries)
        document["schedule"] = schedule
        document["command"] = command
        document["timeout_ms"] = timeout_ms
        jobs.append(document)
    retry_options = {**options, **RETRY_OPTIONS}
    for cut in WINDOWS:
        document = job_document(f"backup-window-{cut}")
        document["schedule"] = schedule
        window_flags = [word for key, value in retry_options.items() for word in (key, str(value))] if cut == "retry" else flags
        document["command"] = ["/usr/bin/xsh", "/etc/laputa/backup-recovery/window.xsh", cut, *services, STOPPED, *window_flags]
        jobs.append(document)
    guest = errlog = qmp = agent = tap_fd = None
    try:
        tap_fd = dl.create_tap(args, "rtap0", "192.0.5.1")
        state = provision_state(args, scratch, jobs)
        console = scratch / "recovery-console.log"
        guest, errlog, control, qmp_path = dl.launch(args, scratch, "recovery", state, tap_fd, console)
        os.close(tap_fd)
        tap_fd = None
        dl.wait_console(console, "LAPUTA_RECOVERY_AGENT_READY", 420, bad=("LAPUTA_RECOVERY_AGENT_FAILED",))
        agent = dl.Agent(control)
        agent.ping()
        qmp = dl.Qmp(qmp_path)
        harness = Guest(agent)
        copy_path = "/etc/laputa/backup-recovery/backup_quiesce.xsh"
        shipped_path = "/usr/lib/laputa/backup-quiesce.xsh"
        copies = harness.observe(copy_path, shipped_path)["files"]
        assert copies[copy_path] == copies[shipped_path] == (ROOT / "system/backup_quiesce.xsh").read_text(), "installed quiesce helper differs from pinned source"
        wait_scheduler(harness)
        dl.wait_until(lambda: all(is_up(harness.observe(), name) for name in ("logger", "dhcp-eth0")), 120, "logger and dhcp-eth0 up")
        harness.xinit("stop", STOPPED)
        dl.wait_until(lambda: is_down(harness.observe(), STOPPED), 60, f"{STOPPED} stopped")
        print(f"PASS armed: published recovery bound {bound:.1f}s, {STOPPED} stopped by the operator, jobs={[item['name'] for item in jobs]}")

        for job, stimulus, after in (
            ("backup-timeout", stimulus_timeout, None),
            ("backup-cancel", stimulus_cancel, after_cancel),
            ("backup-kill", stimulus_kill, after_kill),
            ("backup-restart", stimulus_restart, after_restart),
        ):
            elapsed, how = lost_attempt(harness, job, bound, stimulus, after)
            print(
                f"PASS {job}: {how} released logger and dhcp-eth0 in {elapsed:.1f}s of {bound:.1f}s, "
                f"{STOPPED} stayed down, repeated recovery was a no-op"
            )
        elapsed, _ = lost_attempt(harness, "backup-operator", bound, stimulus_kill, after_kill, operator_stop="logger")
        print(f"PASS backup-operator: recovery in {elapsed:.1f}s preserved the operator's later logger stop and restored dhcp-eth0")
        harness.xinit("start", "logger")
        dl.wait_until(lambda: is_up(harness.observe(), "logger"), 60, "logger restored for windows")
        for cut in WINDOWS:
            window_attempt(harness, cut, bound, retry_options)
        print("PASS backup recovery: timeout, cancellation, SIGKILL and scheduler restart restored acquired services and preserved later operator intent")
    except Exception:
        if agent is not None:
            try:
                value = Guest(agent).observe()
                print("DEBUG scheduler log\n" + value.get("scheduler_log", "")[-6000:], flush=True)
                print("DEBUG services " + json.dumps(value["services"], default=str)[:3000], flush=True)
            except Exception as problem:
                print(f"DEBUG unavailable: {problem}", flush=True)
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
    parser = argparse.ArgumentParser(description="Prove backup quiescence recovery on the maintained guest.")
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
    except (AssertionError, RuntimeError) as problem:
        traceback.print_exc()
        print(f"FAIL: {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

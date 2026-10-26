import argparse
import fcntl
import json
import os
from pathlib import Path
import random
import signal
import shutil
import subprocess
import sys
import time
import uuid


SCRIPT = Path(__file__).resolve()
ACTIONS = ("restart", "stop-start", "crash", "close-ready", "timeout-ready")
REPLAY_ACTIONS = (*ACTIONS, "scanner-restart")


class ScenarioFailure(AssertionError):
    def __init__(self, actions, kind, reason, detail, phase):
        self.actions, self.kind, self.reason, self.phase = actions, kind, reason, phase
        super().__init__(f"prefix={','.join(actions)}: {reason}\n{detail}")


def record(root, event):
    fd = os.open(root / "events", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, (event + "\n").encode())
    finally:
        os.close(fd)


def worker(root, name):
    lock = open(root / (name + ".lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        record(root, "duplicate " + name)
        return 80
    child = os.fork()
    if child == 0:
        if "NOTIFY_FD" in os.environ:
            os.close(int(os.environ["NOTIFY_FD"]))
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        while True:
            signal.pause()
    def stop(*_):
        os.kill(child, signal.SIGTERM)
        os.waitpid(child, 0)
        record(root, "stop " + name)
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    record(root, f"start {name} {os.getpid()} {child} {os.getpgrp()}")
    notify = os.environ.get("NOTIFY_FD")
    if notify:
        mode = (root / "readiness").read_text()
        if mode == "ready":
            os.write(int(notify), b"1")
        if mode != "timeout":
            os.close(int(notify))
    while True:
        signal.pause()


def processes():
    result = {}
    for entry in Path("/proc").iterdir():
        if entry.name.isdecimal():
            try:
                stat = (entry / "stat").read_text().split(") ", 1)[1].split()
                result[int(entry.name)] = (stat[0], int(stat[1]), int(stat[2]), stat[19])
            except (FileNotFoundError, ProcessLookupError):
                pass
    return result


def same_process(pid, identity):
    current = processes().get(pid)
    return current is not None and current[0] != "Z" and current[2:] == identity[2:]


def wait_for(predicate, label, scanner=None):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        if predicate():
            return
        if scanner is not None and scanner.poll() is not None:
            raise AssertionError(f"scanner exited {scanner.returncode} while waiting for {label}")
        time.sleep(0.01)
    raise AssertionError("deadline: " + label)


def state(root, name):
    try:
        return json.loads((root / "run" / (name + ".json")).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def live_worker_groups(root):
    groups = set()
    events = (root / "events").read_text() if (root / "events").exists() else ""
    for line in events.splitlines():
        fields = line.split()
        if fields[0] == "start":
            groups.add(int(fields[4]))
    return {pid: info for pid, info in processes().items() if info[2] in groups}


def service(root, name, need):
    command = json.dumps(["python3", str(SCRIPT), "--worker", str(root), name])
    dependencies = '{need: ["base"]}' if need else "{}"
    text = f'''##! A foreground process group for scanner lifecycle tests.

## The scanner owns this service and its descendants.
export let service = {{
  name: "{name}",
  command: process.command_argv("python3", {command}),
  targets: ["storm"],
  dependencies: {dependencies},
  readiness: "notify",
  ready_timeout_ms: 150,
  stop_timeout_ms: 50,
  restart: {{mode: "always", delay_ms: 200, max_delay_ms: 800, stable_after_ms: 1000}},
  logging: "off",
}}

## Record completion of the exited service instance.
export proc finish() [fs, process, env, error] -> Result[Unit, Error] {{
  run python3 "{SCRIPT}" --finish "{root}" "{name}"
}}
'''
    (root / "services" / (name + ".xsh")).write_text(text)


def configuration_checks(root, env):
    app = root / "services/app.xsh"
    valid = app.read_text()
    def read_only(*args):
        return subprocess.run(["/tools/xsh", "/laputa/xinit/xinit.xsh", "--", *args],
                              env=env, capture_output=True, text=True, timeout=6)
    try:
        for malformed, field in (
            (valid.replace('  logging: "off",', '  logging: "off", typo: true,'), "typo"),
            (valid.replace('  logging: "off",', '  logging: "off", log: {mode: "append"},'), "logging"),
            (valid.replace('  ready_timeout_ms: 150,', '  ready_timeout_ms: null,'), "ready_timeout_ms"),
        ):
            app.write_text(malformed)
            result = read_only("check", str(app))
            assert result.returncode != 0 and field in result.stderr and str(app) in result.stderr, result
        app.write_text(valid)
        result = read_only("inspect", "app")
        assert result.returncode == 0, result.stderr
        inspected = json.loads(result.stdout)
        assert inspected["command"] == "redacted" and inspected["source"] == str(app)
        result = read_only("start-plan", "app")
        assert result.returncode == 0, result.stderr
        assert [item["name"] for item in json.loads(result.stdout)] == ["base", "app"]
        assert not (root / "run").exists() and not (root / "logs").exists()
        assert not (root / "events").exists(), "read-only configuration commands launched a service"
    finally:
        app.write_text(valid)


def scenario(root, actions, shutdown_signal, boundary=None):
    root.mkdir()
    (root / "services").mkdir()
    (root / "readiness").write_text("ready")
    service(root, "base", False)
    service(root, "app", True)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("XINIT_TEST_", "XSH_INIT_", "XSH_UNIX_"))}
    env.update(XINIT_SERVICE_DIR=str(root / "services"), XINIT_RUN_DIR=str(root / "run"),
               XINIT_LOG_ROOT=str(root / "logs"), XSH_ROOT="/xsh", XSH_MODULE_PATH="/laputa",
               XSH_UNIX_DRY_RUN="1", XINIT_TEST_FAKE_PIDS="1", XINIT_TEST_MAX_EVENTS="0")
    configuration_checks(root, env)
    if boundary == "spawn":
        (root / "readiness").write_text("timeout")
        for name in ("base", "app"):
            path = root / "services" / (name + ".xsh")
            path.write_text(path.read_text().replace("ready_timeout_ms: 150", "ready_timeout_ms: 5000"))
    scanner_log = open(root / "scanner.log", "w+")
    def launch_scanner():
        return subprocess.Popen(["/tools/xsh", "/laputa/xinit/xinit.xsh", "--", "scan", "storm"],
                                env=env, stdout=scanner_log, stderr=scanner_log)
    scanner = launch_scanner()
    foreign = subprocess.Popen(["sleep", "120"], start_new_session=True)
    foreign_identity = processes()[foreign.pid]
    completed = []
    def command(verb):
        result = subprocess.run(["/tools/xsh", "/laputa/xinit/xinit.xsh", "--", verb, "app"],
                                env=env, capture_output=True, text=True, timeout=6)
        assert result.returncode == 0, result.stderr
        assert "queued" in result.stdout, result.stdout
        os.kill(scanner.pid, signal.SIGHUP)
    def running():
        return all(state(root, name).get("state") == "running" for name in ("base", "app"))
    try:
        if boundary == "spawn":
            wait_for(lambda: (root / "run/scanner.json").exists(), "scanner ownership before spawn", scanner)
            assert state(root, "app").get("pid", 0) == 0
        else:
            wait_for(running, "initial ready services", scanner)
            assert all(state(root, name).get("ready") for name in ("base", "app"))
        if boundary == "finish":
            (root / "hold-finish").write_text("app")
            pid = state(root, "app")["pid"]
            assert pid in live_worker_groups(root)
            os.kill(pid, signal.SIGKILL)
            wait_for(lambda: (root / "finishing").exists(), "finish hook barrier", scanner)
            assert state(root, "app").get("state") == "finishing"
            os.kill(scanner.pid, shutdown_signal)
            (root / "finish-release").write_text("1")
        for action in actions:
            completed.append(action)
            before = state(root, "app")
            previous = before.get("pid")
            if action == "crash":
                assert previous in live_worker_groups(root), "crash target is not an owned worker"
                os.kill(previous, signal.SIGKILL)
                wait_for(lambda: state(root, "app").get("state") == "dead", "crash backoff", scanner)
                assert state(root, "app").get("pid") == 0
            elif action == "scanner-restart":
                old_base = state(root, "base").get("pid")
                os.kill(scanner.pid, signal.SIGTERM)
                assert scanner.wait(timeout=6) == 0
                wait_for(lambda: not live_worker_groups(root), "old scanner groups reaped")
                scanner = launch_scanner()
                wait_for(lambda: running() and state(root, "base").get("pid") != old_base,
                         "fresh scanner clock origin", scanner)
            elif action == "stop-start":
                command("stop")
                wait_for(lambda: state(root, "app").get("desired") == "down", "stop request", scanner)
                command("start")
            else:
                mode = {"close-ready": "close", "timeout-ready": "timeout"}.get(action, "ready")
                (root / "readiness").write_text(mode)
                command("restart")
            wait_for(lambda: running() and state(root, "app").get("pid") != previous,
                     "replacement after " + action, scanner)
            if action == "crash":
                assert state(root, "app").get("restarts") == before.get("restarts") + 1
            assert state(root, "app").get("ready") == (action not in ("close-ready", "timeout-ready"))
            (root / "readiness").write_text("ready")
            assert "duplicate " not in (root / "events").read_text()
            assert same_process(foreign.pid, foreign_identity), "foreign process changed"
            live = live_worker_groups(root)
            leaders = [pid for pid, info in live.items() if pid == info[2] and info[0] != "Z"]
            assert sorted(leaders) == sorted(state(root, name)["pid"] for name in ("base", "app")), live
        if boundary != "finish":
            os.kill(scanner.pid, shutdown_signal)
        assert scanner.wait(timeout=6) == 0
        wait_for(lambda: not live_worker_groups(root), "all owned groups reaped")
        wait_for(lambda: set(processes()) <= {1, foreign.pid}, "namespace children reaped")
        assert all(state(root, name).get("desired") == "down" and state(root, name).get("pid") == 0
                   for name in ("base", "app"))
        stops = [line for line in (root / "events").read_text().splitlines() if line.startswith("stop ")]
        if boundary is None:
            assert stops[-2:] == ["stop app", "stop base"], stops
        assert same_process(foreign.pid, foreign_identity), "foreign process changed at shutdown"
        events = (root / "events").read_text().splitlines()
        assert "duplicate " not in "\n".join(events)
        if boundary == "spawn":
            assert "finish app" not in events, "finish ran for an unstarted dependent"
            assert not any(line.startswith("start app ") for line in events)
        elif boundary == "finish":
            assert "finish-return app" in events, "interruption skipped finish cleanup"
        else:
            for name in ("base", "app"):
                starts = sum(line.startswith("start " + name + " ") for line in events)
                finishes = events.count("finish " + name)
                assert starts == finishes, (name, starts, finishes)
    except Exception as problem:
        scanner_log.flush()
        events = (root / "events").read_text() if (root / "events").exists() else ""
        groups = live_worker_groups(root)
        kind = "duplicate-service" if "duplicate " in events else "scenario-failed"
        if scanner.poll() is not None and (groups or set(processes()) - {1, foreign.pid}):
            kind = "owned-groups-remain"
        detail = f"{(root / 'scanner.log').read_text()}\nevents={events}\ngroups={groups}\nnamespace={processes()}"
        raise ScenarioFailure(completed, kind, str(problem), detail, root.name) from problem
    finally:
        if scanner.poll() is None:
            scanner.kill()
        scanner.wait(timeout=6)
        for pid in live_worker_groups(root):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        foreign.terminate()
        foreign.wait(timeout=6)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
                if pid == 0:
                    time.sleep(0.01)
                else:
                    continue
            except ChildProcessError:
                break
        scanner_log.close()


def guest(args):
    assert os.getpid() == 1, "signal storm requires its own disposable PID namespace"
    root = Path("/laputa/.work/tmp/signal-storm-" + uuid.uuid4().hex)
    root.mkdir()
    try:
        if args.mode == "boundaries":
            for boundary in ("spawn", "finish"):
                for name, number in (("term", signal.SIGTERM), ("int", signal.SIGINT)):
                    print(f"boundary={boundary} signal={name}", flush=True)
                    scenario(root / (boundary + "-" + name), [], number, boundary)
            print("PASS controlled spawn+finish TERM+INT", flush=True)
        else:
            actions = random.Random(args.seed).choices(ACTIONS, k=args.steps) if args.replay is None else (args.replay.split(",") if args.replay else [])
            assert 0 <= len(actions) <= 16 and all(action in REPLAY_ACTIONS for action in actions), actions
            print(f"seed={args.seed} actions={','.join(actions)}", flush=True)
            scenario(root / "term", actions, signal.SIGTERM)
            scenario(root / "int", actions, signal.SIGINT)
            print(f"PASS seed={args.seed} SIGTERM+SIGINT actions={len(actions)}", flush=True)
    except ScenarioFailure as problem:
        print("LAP36_FAILURE " + json.dumps({"actions": problem.actions, "kind": problem.kind, "reason": problem.reason, "phase": problem.phase}), flush=True)
        raise
    shutil.rmtree(root)


def docker_command(args, repo, name, entrypoint, argv, env=None):
    command = ["docker", "run", "--rm", "--name", name, "--network", "none", "--user", f"{os.getuid()}:{os.getgid()}", "--cap-drop", "ALL",
               "--read-only", "--pids-limit", "64", "--memory", "512m", "--cpus", "1",
               "--mount", f"type=bind,src={repo},dst=/laputa,readonly",
               "--mount", f"type=bind,src={repo / '.work/tmp'},dst=/laputa/.work/tmp",
               "--mount", f"type=bind,src={args.tools.resolve()},dst=/tools,readonly",
               "--mount", f"type=bind,src={args.xsh_root.resolve()},dst=/xsh,readonly",
               "--env", "TMPDIR=/laputa/.work/tmp", "--env", "PYTHONDONTWRITEBYTECODE=1",
               "--env", "XSH_ROOT=/xsh", "--env", "XSH_MODULE_PATH=/laputa",
               "--workdir", "/laputa", "--entrypoint", entrypoint]
    for key, value in (env or {}).items():
        command += ["--env", key + "=" + value]
    return command + ["xsh-test", *argv]


def remove_container(name, primary_error=None):
    try:
        result = subprocess.run(["docker", "rm", "--force", name], capture_output=True, text=True, timeout=10)
        if result.returncode and "No such container" not in result.stderr:
            raise RuntimeError(result.stderr)
    except Exception as cleanup:
        if primary_error is None:
            raise
        print(f"container cleanup failed after {primary_error}: {cleanup}", file=sys.stderr)


def run_container(command, name, capture=False, timeout=180):
    primary_error = None
    try:
        return subprocess.run(command, timeout=timeout, capture_output=capture, text=capture)
    except BaseException as problem:
        primary_error = problem
        raise
    finally:
        remove_container(name, primary_error)


def pid1_hook(root, kind):
    assert os.getpid() == 1 if kind == "restart" else os.getppid() == 1
    caps = next(line.split()[1] for line in Path("/proc/1/status").read_text().splitlines()
                if line.startswith("CapEff:"))
    assert int(caps, 16) == 0, "PID1 proof must have no reboot or other capabilities"
    assert not live_worker_groups(root), "PID1 reached its lifecycle hook before reaping owned groups"
    assert set(processes()) <= ({1} if kind == "restart" else {1, os.getpid()})
    record(root, kind)
    print("PID1_HOOK " + kind, flush=True)


def pid1_cases(args, repo):
    for name, number, outcome in (("hup", "HUP", "restart"), ("usr1", "USR1", "halt"),
                                  ("usr2", "USR2", "poweroff"), ("int", "INT", "poweroff"),
                                  ("term", "TERM", "reboot")):
        print("pid1 signal=" + name, flush=True)
        case_name = "pid1-" + uuid.uuid4().hex
        root = repo / ".work/tmp" / case_name
        root.mkdir()
        guest_root = Path("/laputa/.work/tmp") / case_name
        script = "/laputa/xinit/tests/fixtures/signal_storm.py"
        (root / "inittab").write_text(
            f"::once:python3 {script} --worker {guest_root} owned\n"
            f"::restart:python3 {script} --pid1-hook {guest_root} restart\n"
            f"::shutdown:python3 {script} --pid1-hook {guest_root} shutdown\n")
        container_name = "laputa-" + case_name
        command = docker_command(args, repo, container_name, "/tools/xsh",
                                 ["/laputa/xinit/xinit.xsh", "--", str(guest_root / "inittab")], {
            "XINIT_TEST_ALLOW_NON_PID1": "1", "XINIT_TEST_FAKE_PIDS": "1",
            "XINIT_TEST_EXIT_WHEN_IDLE": "1", "XINIT_TEST_FAST_SHUTDOWN": "1",
            "XINIT_TEST_SKIP_FINAL_CLEANUP": "1", "XINIT_TEST_ACTION_LOG": str(guest_root / "forbidden-action"),
            "XSH_INIT_FAST_SHUTDOWN": "1", "XSH_INIT_FINAL_CLEANUP": "0",
        })
        job = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        primary_error = None
        try:
            wait_for(lambda: (root / "events").exists() and "start owned " in (root / "events").read_text(),
                     "PID1 owned group startup", job)
            delivered = subprocess.run(["docker", "kill", "--signal", number, container_name],
                                       capture_output=True, text=True, timeout=10)
            assert delivered.returncode == 0, delivered.stderr
            output, _ = job.communicate(timeout=15)
            events = (root / "events").read_text().splitlines()
            assert "stop owned" in events, events
            assert not (root / "forbidden-action").exists(), "PID1 honored a test-only action override"
            if outcome == "restart":
                assert job.returncode == 0 and "restart" in events and "shutdown" not in events, output
            else:
                assert job.returncode == 3 and "shutdown" in events and "restart" not in events, output
                assert "linux-" + outcome in output and "Operation not permitted" in output, output
            print(f"PASS PID1 {number} -> {outcome} owned groups reaped; capabilities=0", flush=True)
            shutil.rmtree(root)
        except BaseException as problem:
            primary_error = problem
            raise
        finally:
            remove_container(container_name, primary_error)
            if primary_error is not None:
                output, _ = job.communicate(timeout=10)
                print(output, file=sys.stderr)


def scanner_run(args, repo, replay, capture=False, timeout=180):
    name = "laputa-signal-storm-" + uuid.uuid4().hex
    mode = "scanner" if args.mode == "shrink" else args.mode
    argv = ["/laputa/xinit/tests/fixtures/signal_storm.py", "--guest", "--seed", str(args.seed),
            "--steps", str(args.steps), "--mode", mode]
    if replay is not None:
        argv += ["--replay", replay]
    command = docker_command(args, repo, name, "python3", argv)
    return run_container(command, name, capture, timeout)


def failure_record(result):
    for line in result.stdout.splitlines():
        if line.startswith("LAP36_FAILURE "):
            return json.loads(line.removeprefix("LAP36_FAILURE "))
    return None


def shrink_failure(args, repo):
    original = scanner_run(args, repo, args.replay, capture=True)
    print(original.stdout, end="", flush=True)
    print(original.stderr, end="", file=sys.stderr, flush=True)
    failure = failure_record(original)
    if original.returncode == 0 or failure is None:
        print("No reproducible action failure to reduce", flush=True)
        return original.returncode
    current = failure["actions"]
    key = failure["phase"], failure["kind"], failure["reason"] if failure["kind"] == "scenario-failed" else ""
    trials, chunk = 0, max(1, len(current) // 2)
    deadline = time.monotonic() + 120
    while current and trials < 8 and time.monotonic() < deadline:
        improved = False
        for start in range(0, len(current), chunk):
            if trials == 8 or time.monotonic() >= deadline:
                break
            candidate = current[:start] + current[start + chunk:]
            trials += 1
            result = scanner_run(args, repo, ",".join(candidate), capture=True,
                                 timeout=max(1, deadline - time.monotonic()))
            found = failure_record(result)
            found_key = (found["phase"], found["kind"], found["reason"] if found["kind"] == "scenario-failed" else "") if found else None
            print(f"SHRINK trial={trials} actions={','.join(candidate)} outcome={found_key or result.returncode}", flush=True)
            if result.returncode and found_key != key:
                print(result.stderr, file=sys.stderr)
                print("Reduction stopped on a different failure signature", flush=True)
                return original.returncode
            if result.returncode and found_key == key:
                current, improved = found["actions"], True
                chunk = max(1, min(chunk, len(current) // 2))
                break
        if not improved:
            if chunk == 1:
                break
            chunk = max(1, chunk // 2)
    print(f"REDUCED kind={failure['kind']} actions={','.join(current)} trials={trials}", flush=True)
    return original.returncode


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        return worker(Path(sys.argv[2]), sys.argv[3])
    if len(sys.argv) > 1 and sys.argv[1] == "--pid1-hook":
        return pid1_hook(Path(sys.argv[2]), sys.argv[3])
    if len(sys.argv) > 1 and sys.argv[1] == "--finish":
        root, name = Path(sys.argv[2]), sys.argv[3]
        record(root, "finish " + name)
        if (root / "hold-finish").exists() and (root / "hold-finish").read_text() == name:
            (root / "finishing").touch()
            wait_for(lambda: (root / "finish-release").exists(), "finish hook release")
        record(root, "finish-return " + name)
        return 0
    parser = argparse.ArgumentParser()
    parser.add_argument("--guest", action="store_true")
    parser.add_argument("--mode", choices=("scanner", "boundaries", "pid1", "shrink"), default="scanner")
    parser.add_argument("--seed", type=int, default=43)
    parser.add_argument("--steps", type=int, choices=range(1, 17), default=6)
    parser.add_argument("--replay")
    parser.add_argument("--tools", type=Path)
    parser.add_argument("--xsh-root", type=Path)
    args = parser.parse_args()
    if args.guest:
        if args.mode not in ("scanner", "boundaries"):
            parser.error("PID1 dispatch and reduction require the host controller")
        guest(args)
        return 0
    if args.tools is None or args.xsh_root is None:
        parser.error("--tools and --xsh-root are required")
    repo = SCRIPT.parents[3]
    assert subprocess.run(["git", "check-ignore", ".work/"], cwd=repo, capture_output=True).returncode == 0
    (repo / ".work/tmp").mkdir(parents=True, exist_ok=True)
    if args.mode == "pid1":
        pid1_cases(args, repo)
        return 0
    if args.mode == "shrink":
        return shrink_failure(args, repo)
    return scanner_run(args, repo, args.replay).returncode


if __name__ == "__main__":
    sys.exit(main())

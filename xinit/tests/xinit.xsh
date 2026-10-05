# The captured outcome of one xinit run.
type XinitRun = {success: Bool, stdout: Str, stderr: Str}

# Tests run from the monorepo root.
pure xinit_script() -> Path {
  p"xinit/xinit.xsh"
}

# Run xinit through the native-test harness rather than a bare command: the
# `unix` and `linux` fakes a test installs (`test.unix_fake`, `test.linux_fake`)
# reach only scripts the harness runs. `XSH_UNIX_DRY_RUN=1` in `vars` is xinit's
# own test switch (mocked pids skip liveness probes and scanner detection).
proc run_xinit(ctx: TestContext, args: List[Str], vars: Record) [fs, process, error] -> Result[XinitRun] {
  let result = test.run_xsh(ctx, xinit_script().read_text()?, [], args, vars, name: "xinit.xsh")?
  {success: result.success, stdout: result.stdout, stderr: result.stderr}
}

# Run xinit and return its stdout, failing the test unless it exits 0.
proc xinit_text(ctx: TestContext, args: List[Str], vars: Record) -> Result[Str] {
  let result = run_xinit(ctx, args, vars)?
  assert result.success, f"xinit {args.join(" ")} failed: {result.stderr}"
  result.stdout
}

proc write_demo_service(path_value: Path, command: Str, restart_mode: Str, log_none: Bool, cpu_max: Int) [fs, error] {
  var extra = ""

  if log_none {
    extra = f"""{extra}  logging: "off",
"""
  }

  if cpu_max > 0 {
    extra = f"""{extra}  resources: {{cpu_max: {cpu_max}}},
"""
  }

  path_value.write(f"""##! Service fixture.

## The service declaration.
export let service = {{
  name: "demo",
  kind: "longrun",
  command: {command},
  restart: {{mode: "{restart_mode}", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000}},
  targets: ["boot"],
{extra}}}
""")
}

proc write_named_service(
  path_value: Path,
  name: Str,
  command: Str,
  targets: List[Str],
  deps: Str,
  extra = "",
) {
  path_value.write(f"""##! Service fixture.

## The service declaration.
export let service = {{
  name: "{name}",
  kind: "longrun",
  command: {command},
  restart: {{mode: "never", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000}},
  targets: {json.encode(targets)?},
  dependencies: {{{deps}}},
{extra}}}
""")
}

proc assert_failed_with(result: XinitRun, expected: Str) {
  assert ! result.success, "expected command to fail"
  assert expected in result.stderr
}

test test_inittab_parsing_and_lifecycle [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "inittab")?
  let valid = fp"{root}/valid.inittab"
  let unsupported = fp"{root}/unsupported.inittab"
  let shell_syntax = fp"{root}/shell-syntax.inittab"

  valid.write("""# comment

::sysinit:/bin/echo "boot: ok"
::wait:/bin/echo "wait: ok"
::once:/bin/echo "once: ok"
::restart:/bin/echo restart
::shutdown:/bin/echo "down: ok"
ttyS0::respawn:/bin/echo "login: ttyS0"
ttyS1::poweroff:/bin/echo "login: ttyS1"
""")

  unsupported.write("""::bogus:/bin/echo nope
""")

  shell_syntax.write("""::sysinit:/bin/echo ok && /bin/echo no
""")

  test.unix_fake(ctx, {signal: "TERM"})
  test.linux_fake(ctx, {})
  let output = xinit_text(
    ctx,
    [valid.display()],
    {XINIT_TEST_ALLOW_NON_PID1: "1", XSH_INIT_TEST_MAX_RESPAWNS: "1", XSH_UNIX_DRY_RUN: "1"},
  )?

  assert output == """boot: ok
wait: ok
down: ok
"""

  test.unix_fake(ctx, {})
  let unsupported_status = run_xinit(
    ctx,
    [unsupported.display()],
    {XINIT_TEST_ALLOW_NON_PID1: "1", XSH_INIT_TEST_MAX_RESPAWNS: "1", XSH_UNIX_DRY_RUN: "1"},
  )?
  assert_failed_with(unsupported_status, "unsupported action 'bogus'")
  let shell_status = run_xinit(
    ctx,
    [shell_syntax.display()],
    {XINIT_TEST_ALLOW_NON_PID1: "1", XSH_INIT_TEST_MAX_RESPAWNS: "1", XSH_UNIX_DRY_RUN: "1"},
  )?
  assert_failed_with(shell_status, "shell syntax")
}

test test_wait_once_respawn_and_poweroff [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "lifecycle")?
  let inittab = fp"{root}/inittab"
  let unix_log = fp"{root}/unix.jsonl"
  let linux_log = fp"{root}/linux.jsonl"

  inittab.write("""::sysinit:/bin/echo boot
::wait:/bin/echo wait
::once:/usr/bin/once-service
::respawn:/usr/bin/respawn-service
""")

  test.unix_fake(ctx, {log: unix_log, event_kind: "child", pid: 1001})
  test.linux_fake(ctx, {})
  let output = xinit_text(
    ctx,
    [inittab.display()],
    {
      XINIT_TEST_ALLOW_NON_PID1: "1",
      XSH_INIT_TEST_EXIT_WHEN_IDLE: "1",
      XSH_INIT_TEST_MAX_RESPAWNS: "1",
      XSH_INIT_TEST_RESPAWN_DELAY_MS: "1",
      XSH_UNIX_DRY_RUN: "1",
    },
  )?

  assert output == """boot
wait
"""

  let unix_log_text = unix_log.read_text()?
  assert "once-service" in unix_log_text
  assert "respawn-service" in unix_log_text
  let poweroff_inittab = fp"{root}/poweroff.inittab"

  poweroff_inittab.write("""::sysinit:/bin/echo boot
ttyAMA0::poweroff:/bin/xshi --no-config
""")

  test.unix_fake(ctx, {event_kind: "child", pid: 1000})
  test.linux_fake(ctx, {log: linux_log})
  let poweroff_output = xinit_text(
    ctx,
    [poweroff_inittab.display()],
    {XINIT_TEST_ALLOW_NON_PID1: "1", XSH_UNIX_DRY_RUN: "1"},
  )?

  assert poweroff_output == """boot
"""

  assert "\"op\":\"poweroff\"" in linux_log.read_text()?
}

test test_fast_shutdown_uses_owned_process_groups [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "fast-shutdown")?
  let inittab = fp"{root}/inittab"
  let unix_log = fp"{root}/unix.jsonl"
  let linux_log = fp"{root}/linux.jsonl"

  inittab.write("""::sysinit:/bin/echo boot
::shutdown:/bin/echo down
::respawn:/usr/bin/daemon
ttyAMA0::poweroff:/bin/xshi --no-config
""")

  test.unix_fake(ctx, {log: unix_log, event_kind: "child", pid: 1001})
  test.linux_fake(ctx, {log: linux_log})
  let output = xinit_text(
    ctx,
    [inittab.display()],
    {XINIT_TEST_ALLOW_NON_PID1: "1", XSH_INIT_FAST_SHUTDOWN: "1", XSH_INIT_FINAL_CLEANUP: "0", XSH_UNIX_DRY_RUN: "1"},
  )?

  assert output == """boot
down
"""

  let unix_log_text = unix_log.read_text()?
  assert "\"op\":\"pid1_shutdown\"" in unix_log_text
  assert "\"groups\":\"1000\"" in unix_log_text
  assert "\"term_timeout_ms\":\"0\"" in unix_log_text
  let linux_log_text = linux_log.read_text()?
  assert "\"op\":\"kill_all\"" not in linux_log_text
  assert "\"op\":\"poweroff\"" in linux_log_text
}

test test_service_start_status_stop_and_check [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "service")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  let unix_log = fp"{root}/unix.jsonl"
  service_dir.mkdir()
  write_demo_service(fp"{service_dir}/demo.xsh", "process.command_argv(\"service\", [\"service\"])", "never", false, 0)
  test.unix_fake(ctx, {log: unix_log})
  let started = xinit_text(
    ctx,
    ["start", "demo"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XSH_UNIX_DRY_RUN: "1",
    },
  )?

  assert started == """demo running pid=1000 ready=true log=append desired=up restarts=0
"""

  let state = fp"{run_dir}/demo.json".read_text()?
  assert "\"state\":\"running\"" in state
  assert "\"log\":\"append\"" in state
  assert "log_pid" not in state
  let log_text = unix_log.read_text()?
  assert "spawn_process_group" in log_text
  assert "log_path" in log_text
  test.unix_fake(ctx, {})
  let status = xinit_text(ctx, ["status", "demo"], {XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"})?

  assert status == """demo running pid=1000 ready=true log=append desired=up restarts=0
"""

  test.unix_fake(ctx, {log: unix_log})
  let stopped = xinit_text(
    ctx,
    ["stop", "demo"],
    {XINIT_SERVICE_DIR: service_dir.display(), XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"},
  )?

  assert stopped == """demo down pid=0 ready=false log=append desired=down restarts=0
"""

  let checked = xinit_text(ctx, ["check", f"{service_dir}/demo.xsh"], {})?

  assert checked == """valid 1 service(s): demo
"""
}

test test_check_reports_errors [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "check-errors")?
  let bad = fp"{root}/bad.xsh"
  let missing = fp"{root}/missing.xsh"

  bad.write("""##! Service fixture whose module body fails to check.

pure bad(xs: List[Str]) -> List[Str] {
  xs = ["service"]
  return xs
}

## The service declaration.
export let service = {
  name: "bad",
  command: process.command_argv("service", bad([])),
}
""")

  let bad_status = run_xinit(ctx, ["check", bad.display()], {})?
  assert_failed_with(bad_status, "module-load")
  assert "failed to check" in bad_status.stderr
  let missing_status = run_xinit(ctx, ["check", missing.display()], {})?
  assert_failed_with(missing_status, "xinit-service")
  assert "failed to read service file" in missing_status.stderr
  assert missing.display() in missing_status.stderr
  let old_status = run_xinit(ctx, ["validate", "demo"], {})?
  assert_failed_with(old_status, "xinit-control")
  assert "usage: xinit" in old_status.stderr
}

test test_dependency_planning_boot_list_graph_and_stop_refusal [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "deps")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  let unix_log = fp"{root}/unix.jsonl"
  service_dir.mkdir()

  write_named_service(
    fp"{service_dir}/logger.xsh",
    "logger",
    "process.command_argv(\"logger\", [\"logger\"])",
    ["boot"],
    "",
  )

  write_named_service(
    fp"{service_dir}/firewall.xsh",
    "firewall",
    "process.command_argv(\"firewall\", [\"firewall\"])",
    ["boot"],
    "before: [\"net\"]",
  )

  write_named_service(
    fp"{service_dir}/net.xsh",
    "net",
    "process.command_argv(\"net\", [\"net\"])",
    ["boot"],
    "need: [\"logger\"], after: [\"firewall\"]",
  )

  write_named_service(
    fp"{service_dir}/app.xsh",
    "app",
    "process.command_argv(\"app\", [\"app\"])",
    ["boot"],
    "need: [\"net\"], uses: [\"logger\"]",
  )

  let graph = xinit_text(ctx, ["graph", "app"], {XINIT_SERVICE_DIR: service_dir.display()})?
  assert "logger: deps=" in graph
  assert "firewall: deps=" in graph
  assert "net: deps=logger,firewall" in graph
  assert "app: deps=net,logger" in graph
  test.unix_fake(ctx, {log: unix_log})
  let boot = xinit_text(
    ctx,
    ["boot"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XSH_UNIX_DRY_RUN: "1",
    },
  )?
  assert "app running" in boot
  assert fp"{run_dir}/logger.json".exists()?
  assert fp"{run_dir}/firewall.json".exists()?
  assert fp"{run_dir}/net.json".exists()?
  assert fp"{run_dir}/app.json".exists()?
  test.unix_fake(ctx, {})
  let listed = xinit_text(
    ctx,
    ["list"],
    {XINIT_SERVICE_DIR: service_dir.display(), XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"},
  )?
  assert "app longrun targets=boot state=running ready=true" in listed
  assert "net longrun targets=boot state=running ready=true" in listed
  let stop_net = run_xinit(
    ctx,
    ["stop", "net"],
    {XINIT_SERVICE_DIR: service_dir.display(), XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"},
  )?
  assert_failed_with(stop_net, "running dependents: app")
}

test test_ready_and_status_hooks [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "ready")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  service_dir.mkdir()

  fs.write(
    fp"{service_dir}/demo.xsh",
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "demo",
  kind: "longrun",
  command: process.command_argv("demo", ["demo"]),
  restart: {mode: "never"},
}

## The `ready` lifecycle hook.
export proc ready() [fs, process, env, time, error] -> Result[Bool] {
  return true
}

## The `status` lifecycle hook.
export proc status() [fs, process, env, error] -> Result[Str] {
  return "detail=ok"
}
""",
  )

  test.unix_fake(ctx, {})
  let started = xinit_text(
    ctx,
    ["start", "demo"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XSH_UNIX_DRY_RUN: "1",
    },
  )?

  assert started == """demo running pid=1000 ready=true log=append desired=up restarts=0
"""

  let status = xinit_text(
    ctx,
    ["status", "demo"],
    {XINIT_SERVICE_DIR: service_dir.display(), XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"},
  )?

  assert status == """demo running pid=1000 ready=true log=append desired=up restarts=0 detail=ok
"""
}

test test_append_logs_and_log_none [fs, process, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "logs")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  service_dir.mkdir()

  write_demo_service(
    fp"{service_dir}/demo.xsh",
    "process.command_argv(\"/bin/sh\", [\"-c\", \"printf service-out; printf service-err >&2\"])",
    "never",
    false,
    0,
  )

  let started = xinit_text(
    ctx,
    ["start", "demo"],
    {XINIT_SERVICE_DIR: service_dir.display(), XINIT_RUN_DIR: run_dir.display(), XINIT_LOG_ROOT: log_root.display()},
  )?
  assert "demo running" in started
  time.sleep(100ms)
  let log_text = fp"{log_root}/demo/current".read_text()?
  assert "service-out" in log_text
  assert "service-err" in log_text
  let logs = xinit_text(ctx, ["logs", "demo"], {XINIT_LOG_ROOT: log_root.display()})?
  assert logs == log_text
  let none_service_dir = fp"{root}/none-services"
  let none_run_dir = fp"{root}/none-run"
  let none_log_root = fp"{root}/none-logs"
  none_service_dir.mkdir()

  write_demo_service(
    fp"{none_service_dir}/demo.xsh",
    "process.command_argv(\"/bin/true\", [\"true\"])",
    "never",
    true,
    0,
  )

  test.unix_fake(ctx, {})
  let none_started = xinit_text(
    ctx,
    ["start", "demo"],
    {
      XINIT_SERVICE_DIR: none_service_dir.display(),
      XINIT_RUN_DIR: none_run_dir.display(),
      XINIT_LOG_ROOT: none_log_root.display(),
      XSH_UNIX_DRY_RUN: "1",
    },
  )?

  assert none_started == """demo running pid=1000 ready=true log=none desired=up restarts=0
"""

  assert ! fp"{none_log_root}/demo/current".exists()?
}

test test_append_log_rotates_over_size_cap [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "rotate")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  service_dir.mkdir()

  fs.write(
    fp"{service_dir}/demo.xsh",
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "demo",
  kind: "longrun",
  command: process.command_argv("/bin/true", ["true"]),
  log: {mode: "append", max_size: 10, keep: 2},
  restart: {mode: "never"},
}
""",
  )

  # Pre-fill `current` past the cap; the next start must rotate it to current.1
  # and begin a fresh `current`.
  fp"{log_root}/demo".mkdir()
  fp"{log_root}/demo/current".write("0123456789AB")
  test.unix_fake(ctx, {})
  let _ = xinit_text(
    ctx,
    ["start", "demo"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XSH_UNIX_DRY_RUN: "1",
    },
  )?
  assert fp"{log_root}/demo/current.1".read_text()? == "0123456789AB"
  assert fp"{log_root}/demo/current".read_text()? == ""
}

test test_status_compat_cgroup_and_log_open_failure [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "status")?
  let run_dir = fp"{root}/run"
  run_dir.mkdir()

  fp"{run_dir}/demo.json".write(
    "{\"name\":\"demo\",\"desired\":\"up\",\"state\":\"running\",\"pid\":1000,\"log_pid\":1001,\"restarts\":0}",
  )

  test.unix_fake(ctx, {})
  let status = xinit_text(ctx, ["status", "demo"], {XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"})?

  assert status == """demo running pid=1000 ready=true log=append desired=up restarts=0
"""

  let service_dir = fp"{root}/services"
  let cgroup_run_dir = fp"{root}/cgroup-run"
  let log_root = fp"{root}/logs"
  service_dir.mkdir()

  write_demo_service(
    fp"{service_dir}/demo.xsh",
    "process.command_argv(\"service\", [\"service\"])",
    "never",
    false,
    80,
  )

  let cgroup = xinit_text(
    ctx,
    ["start", "demo"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: cgroup_run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XSH_UNIX_DRY_RUN: "1",
    },
  )?

  assert cgroup == """demo running pid=1000 ready=true log=append desired=up restarts=0 cgroup=dry-run:/xinit/demo
"""

  assert "\"cgroup_path\":\"dry-run:/xinit/demo\"" in fp"{cgroup_run_dir}/demo.json".read_text()?
  let blocker = fp"{root}/not-a-dir"
  let failed_run = fp"{root}/failed-run"
  blocker.write("file")
  let failed = run_xinit(
    ctx,
    ["start", "demo"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: failed_run.display(),
      XINIT_LOG_ROOT: blocker.display(),
      XSH_UNIX_DRY_RUN: "1",
    },
  )?
  assert_failed_with(failed, "xinit-log")
  assert ! fp"{root}/failed-run/demo.json".exists()?
}

test test_idempotent_start_and_supervise_restart [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "restart")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  let unix_log = fp"{root}/unix.jsonl"
  service_dir.mkdir()
  write_demo_service(fp"{service_dir}/demo.xsh", "process.command_argv(\"service\", [\"service\"])", "never", false, 0)

  for _ in [0, 1] {
    test.unix_fake(ctx, {log: unix_log})
    let output = xinit_text(
      ctx,
      ["start", "demo"],
      {
        XINIT_SERVICE_DIR: service_dir.display(),
        XINIT_RUN_DIR: run_dir.display(),
        XINIT_LOG_ROOT: log_root.display(),
        XSH_UNIX_DRY_RUN: "1",
      },
    )?

    assert output == """demo running pid=1000 ready=true log=append desired=up restarts=0
"""
  }

  assert unix_log.read_text()?.split("spawn_process_group").len() == 2
  let supervise_service_dir = fp"{root}/supervise-services"
  let supervise_run_dir = fp"{root}/supervise-run"
  let supervise_log_root = fp"{root}/supervise-logs"
  let supervise_unix_log = fp"{root}/supervise-unix.jsonl"
  supervise_service_dir.mkdir()

  write_demo_service(
    fp"{supervise_service_dir}/demo.xsh",
    "process.command_argv(\"service\", [\"service\"])",
    "always",
    false,
    0,
  )

  test.unix_fake(ctx, {log: supervise_unix_log, event_kind: "child", pid: 1000, status_code: 1})
  let supervise = xinit_text(
    ctx,
    ["supervise", "demo"],
    {
      XINIT_SERVICE_DIR: supervise_service_dir.display(),
      XINIT_RUN_DIR: supervise_run_dir.display(),
      XINIT_LOG_ROOT: supervise_log_root.display(),
      XINIT_TEST_MAX_EVENTS: "1",
      XSH_UNIX_DRY_RUN: "1",
    },
  )?
  assert supervise == ""
  test.unix_fake(ctx, {})
  let status = xinit_text(ctx, ["status", "demo"], {XINIT_RUN_DIR: supervise_run_dir.display(), XSH_UNIX_DRY_RUN: "1"})?

  assert status == """demo running pid=1001 ready=true log=append desired=up restarts=1
"""

  assert supervise_unix_log.read_text()?.split("spawn_process_group").len() == 3
}

test test_status_reconciles_stale_pid [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "liveness")?
  let run_dir = fp"{root}/run"
  run_dir.mkdir()

  # Use this test process's own pid as a known-live, same-user pid: the status
  # subprocess can signal it with signal 0, so a real (non-dry-run) status read
  # must preserve the running state rather than reconcile it away.
  let self_pid = process.current_pid()?

  fp"{run_dir}/alive.json".write(
    f"{{\"name\":\"alive\",\"desired\":\"up\",\"state\":\"running\",\"pid\":{self_pid},\"restarts\":0}}",
  )

  let alive = xinit_text(ctx, ["status", "alive"], {XINIT_RUN_DIR: run_dir.display()})?

  assert alive == f"""alive running pid={self_pid} ready=true log=append desired=up restarts=0
"""

  # A pid far above any real process id is gone, so a saved "running" state must
  # reconcile to "dead" with the tracked pid cleared. This is what stops `status`
  # reporting a phantom and stops `stop` signalling a recycled pid.
  fp"{run_dir}/gone.json".write(
    "{\"name\":\"gone\",\"desired\":\"up\",\"state\":\"running\",\"pid\":2147480000,\"restarts\":2}",
  )

  let gone = xinit_text(ctx, ["status", "gone"], {XINIT_RUN_DIR: run_dir.display()})?

  assert gone == """gone dead pid=0 ready=false log=append desired=up restarts=2
"""
}

test test_status_detects_recycled_pid [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "identity")?
  let run_dir = fp"{root}/run"
  run_dir.mkdir()

  # This test process is a known-live, same-user pid; find its kernel start time.
  let self_pid = process.current_pid()?
  var self_start = 0

  for entry in process.list()? {
    if entry.pid == self_pid {
      self_start = entry.start_time_ms
    }
  }

  # A matching recorded start time means the pid is still our instance: running.
  fp"{run_dir}/ours.json".write(
    f"{{\"name\":\"ours\",\"desired\":\"up\",\"state\":\"running\",\"pid\":{self_pid},\"start_time_ms\":{self_start},\"restarts\":0}}",
  )

  let ours = xinit_text(ctx, ["status", "ours"], {XINIT_RUN_DIR: run_dir.display()})?

  assert ours == f"""ours running pid={self_pid} ready=true log=append desired=up restarts=0
"""

  # A non-matching recorded start time means the pid was recycled into a
  # different process after ours exited, so the saved state reconciles to dead.
  fp"{run_dir}/recycled.json".write(
    f"{{\"name\":\"recycled\",\"desired\":\"up\",\"state\":\"running\",\"pid\":{self_pid},\"start_time_ms\":1,\"restarts\":0}}",
  )

  let recycled = xinit_text(ctx, ["status", "recycled"], {XINIT_RUN_DIR: run_dir.display()})?

  assert recycled == """recycled dead pid=0 ready=false log=append desired=up restarts=0
"""
}

test test_supervise_defers_restart_with_backoff [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "backoff")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  let unix_log = fp"{root}/unix.jsonl"
  service_dir.mkdir()

  # A nonzero base delay must defer the respawn behind a next_ms gate rather
  # than block the scanner: after the crash event the unit is scheduled ("dead"),
  # not yet relaunched, and only one spawn has happened so far. This is the
  # non-blocking backoff the scanner model gives us (delay_ms: 0 relaunches
  # immediately, exercised by the idempotent-restart test).
  fs.write(
    fp"{service_dir}/demo.xsh",
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "demo",
  kind: "longrun",
  command: process.command_argv("service", ["service"]),
  restart: {mode: "always", delay_ms: 30000, max_delay_ms: 30000, stable_after_ms: 100000},
}
""",
  )

  test.unix_fake(ctx, {log: unix_log, event_kind: "child", pid: 1000, status_code: 1})
  let supervise = xinit_text(
    ctx,
    ["supervise", "demo"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XINIT_TEST_MAX_EVENTS: "1",
      XSH_UNIX_DRY_RUN: "1",
    },
  )?
  assert supervise == ""
  test.unix_fake(ctx, {})
  let status = xinit_text(ctx, ["status", "demo"], {XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"})?

  assert status == """demo dead pid=0 ready=false log=append desired=up restarts=0
"""

  assert unix_log.read_text()?.split("spawn_process_group").len() == 2
}

test test_scan_respawns_one_unit_independently [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "scan")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  let unix_log = fp"{root}/unix.jsonl"
  service_dir.mkdir()

  # Two independent (dependency-free) services in one boot target. Faked spawn
  # pids increment per call, so the bring-up gives logger=1000, worker=1001.
  # Killing worker (pid 1001) must respawn only worker (-> 1002) while logger
  # stays untouched, demonstrating independent per-unit supervision.
  fs.write(
    fp"{service_dir}/logger.xsh",
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "logger",
  kind: "longrun",
  command: process.command_argv("logger", ["logger"]),
  targets: ["boot"],
  restart: {mode: "always", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000},
}
""",
  )

  fs.write(
    fp"{service_dir}/worker.xsh",
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "worker",
  kind: "longrun",
  command: process.command_argv("worker", ["worker"]),
  targets: ["boot"],
  restart: {mode: "always", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000},
}
""",
  )

  test.unix_fake(ctx, {log: unix_log, event_kind: "child", pid: 1001, status_code: 1})
  let scan = xinit_text(
    ctx,
    ["scan", "boot"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XINIT_TEST_MAX_EVENTS: "1",
      XSH_UNIX_DRY_RUN: "1",
    },
  )?
  assert scan == ""
  test.unix_fake(ctx, {})
  let logger_status = xinit_text(ctx, ["status", "logger"], {XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"})?

  assert logger_status == """logger running pid=1000 ready=true log=append desired=up restarts=0
"""

  let worker_status = xinit_text(ctx, ["status", "worker"], {XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"})?

  assert worker_status == """worker running pid=1002 ready=true log=append desired=up restarts=1
"""

  assert unix_log.read_text()?.split("spawn_process_group").len() == 4
}

test test_scan_gates_start_on_dependency_readiness [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "gate")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  let unix_log = fp"{root}/unix.jsonl"
  service_dir.mkdir()

  # logger uses notify readiness and never signals, so it stays "starting".
  fs.write(
    fp"{service_dir}/logger.xsh",
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "logger",
  kind: "longrun",
  command: process.command_argv("logger", ["logger"]),
  readiness: "notify",
  ready_timeout_ms: 100000,
  restart: {mode: "never"},
}
""",
  )

  # app needs logger, so it must not start until logger is ready.
  fs.write(
    fp"{service_dir}/app.xsh",
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "app",
  kind: "longrun",
  command: process.command_argv("app", ["app"]),
  dependencies: {need: ["logger"]},
  restart: {mode: "never"},
}
""",
  )

  test.unix_fake(ctx, {log: unix_log, event_kind: "poll", ready: 0})
  let scan = xinit_text(
    ctx,
    ["scan", "app"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XINIT_TEST_MAX_EVENTS: "3",
      XSH_UNIX_DRY_RUN: "1",
    },
  )?
  assert scan == ""
  test.unix_fake(ctx, {})
  let logger_status = xinit_text(ctx, ["status", "logger"], {XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"})?

  assert logger_status == """logger starting pid=1000 ready=false log=append desired=up restarts=0
"""

  # app never started: its need is not ready, so no instance was spawned.
  let app_status = xinit_text(ctx, ["status", "app"], {XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"})?

  assert app_status == """app down pid=0 ready=false log=append desired=down restarts=0
"""

  assert unix_log.read_text()?.split("spawn_process_group").len() == 2
}

test test_scan_honors_inbox_down_request [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "inbox")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  let unix_log = fp"{root}/unix.jsonl"
  service_dir.mkdir()
  fp"{run_dir}/inbox".mkdir()

  fs.write(
    fp"{service_dir}/logger.xsh",
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "logger",
  kind: "longrun",
  command: process.command_argv("logger", ["logger"]),
  restart: {mode: "always", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000},
}
""",
  )

  fs.write(
    fp"{service_dir}/app.xsh",
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "app",
  kind: "longrun",
  command: process.command_argv("app", ["app"]),
  dependencies: {need: ["logger"]},
  restart: {mode: "always", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000},
}
""",
  )

  # Pre-post a desired-state "down" request for app. The scanner must drain the
  # inbox before reconciling, so app is parked (never spawned) while logger
  # still comes up — the control plane overriding the default desired state.
  fp"{run_dir}/inbox/app".write("down")
  test.unix_fake(ctx, {log: unix_log, event_kind: "poll"})
  let scan = xinit_text(
    ctx,
    ["scan", "app"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XINIT_TEST_MAX_EVENTS: "1",
      XSH_UNIX_DRY_RUN: "1",
    },
  )?
  assert scan == ""
  test.unix_fake(ctx, {})
  let logger_status = xinit_text(ctx, ["status", "logger"], {XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"})?

  assert logger_status == """logger running pid=1000 ready=true log=append desired=up restarts=0
"""

  let app_status = xinit_text(ctx, ["status", "app"], {XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"})?

  assert app_status == """app down pid=0 ready=false log=append desired=down restarts=0
"""

  assert ! fp"{run_dir}/inbox/app".exists()?
  assert unix_log.read_text()?.split("spawn_process_group").len() == 2
}

test test_scan_notify_readiness_reaches_running [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "notify-ready")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  let unix_log = fp"{root}/unix.jsonl"
  service_dir.mkdir()

  fs.write(
    fp"{service_dir}/demo.xsh",
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "demo",
  kind: "longrun",
  command: process.command_argv("demo", ["demo"]),
  readiness: "notify",
  restart: {mode: "never", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000},
}
""",
  )

  # A notify service is spawned with a readiness pipe (state "starting", not
  # ready); the scanner polls notify_ready and promotes it to running. The unix
  # fake reports the service ready (its `ready` setting defaults to 1).
  test.unix_fake(ctx, {log: unix_log, event_kind: "poll"})
  let scan = xinit_text(
    ctx,
    ["scan", "demo"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XINIT_TEST_MAX_EVENTS: "2",
      XSH_UNIX_DRY_RUN: "1",
    },
  )?
  assert scan == ""
  test.unix_fake(ctx, {})
  let status = xinit_text(ctx, ["status", "demo"], {XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"})?

  assert status == """demo running pid=1000 ready=true log=append desired=up restarts=0
"""

  let log_text = unix_log.read_text()?
  assert "\"op\":\"notify_ready\"" in log_text
  assert "\"op\":\"notify_close\"" in log_text
}

test test_scan_notify_readiness_times_out [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "notify-timeout")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  service_dir.mkdir()

  fs.write(
    fp"{service_dir}/demo.xsh",
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "demo",
  kind: "longrun",
  command: process.command_argv("demo", ["demo"]),
  readiness: "notify",
  ready_timeout_ms: 0,
  restart: {mode: "never", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000},
}
""",
  )

  # The service never signals readiness (unix fake `ready: 0`) and the ready
  # timeout is zero, so the scanner promotes it to running but not ready rather
  # than wedging.
  test.unix_fake(ctx, {event_kind: "poll", ready: 0})
  let scan = xinit_text(
    ctx,
    ["scan", "demo"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XINIT_TEST_MAX_EVENTS: "2",
      XSH_UNIX_DRY_RUN: "1",
    },
  )?
  assert scan == ""
  test.unix_fake(ctx, {})
  let status = xinit_text(ctx, ["status", "demo"], {XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"})?

  assert status == """demo running pid=1000 ready=false log=append desired=up restarts=0
"""
}

test test_start_tolerates_optional_uses_failure [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "uses-optional")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  service_dir.mkdir()

  # A oneshot whose command fails: it cannot start.
  fs.write(
    fp"{service_dir}/flaky.xsh",
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "flaky",
  kind: "oneshot",
  command: process.command_argv("/bin/false", ["false"]),
}
""",
  )

  # app only *uses* flaky (optional), so flaky's start failure must be tolerated
  # and app still comes up.
  fs.write(
    fp"{service_dir}/app.xsh",
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "app",
  kind: "longrun",
  command: process.command_argv("app", ["app"]),
  dependencies: {uses: ["flaky"]},
  restart: {mode: "never"},
}
""",
  )

  test.unix_fake(ctx, {})
  let started = xinit_text(
    ctx,
    ["start", "app"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XSH_UNIX_DRY_RUN: "1",
    },
  )?

  assert started == """app running pid=1000 ready=true log=append desired=up restarts=0
"""

  # needy *needs* flaky, so the same failure must abort its start.
  fs.write(
    fp"{service_dir}/needy.xsh",
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "needy",
  kind: "longrun",
  command: process.command_argv("needy", ["needy"]),
  dependencies: {need: ["flaky"]},
  restart: {mode: "never"},
}
""",
  )

  let needy_status = run_xinit(
    ctx,
    ["start", "needy"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XSH_UNIX_DRY_RUN: "1",
    },
  )?
  assert_failed_with(needy_status, "flaky: start failed")
}

test test_reload_runs_hook_then_falls_back_to_sighup [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "reload")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let unix_log = fp"{root}/unix.jsonl"
  let touched = fp"{root}/reloaded"
  service_dir.mkdir()
  run_dir.mkdir()

  # A service exporting reload(): the hook runs and SIGHUP is not sent.
  fs.write(
    fp"{service_dir}/hooked.xsh",
    f"""##! Service fixture.

## The service declaration.
export let service = {{
  name: "hooked",
  kind: "longrun",
  command: process.command_argv("hooked", ["hooked"]),
  restart: {{mode: "never"}},
}}

## The `reload` lifecycle hook.
export proc reload() [fs, process, env, error] -> Result[Unit] {{
  fs.write(Path({json.encode(touched.display())?}), "reloaded")?
}}
""",
  )

  fp"{run_dir}/hooked.json".write(
    "{\"name\":\"hooked\",\"desired\":\"up\",\"state\":\"running\",\"pid\":1000,\"restarts\":0}",
  )

  test.unix_fake(ctx, {log: unix_log})
  let hooked = xinit_text(
    ctx,
    ["reload", "hooked"],
    {XINIT_SERVICE_DIR: service_dir.display(), XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"},
  )?
  assert "hooked running" in hooked

  # The hook ran (wrote the sentinel) and, since reload runs the hook XOR sends
  # SIGHUP, no signal was sent (the unix fake log was never even created).
  assert touched.read_text()? == "reloaded"
  assert ! unix_log.exists()?

  # A service without reload(): the saved process group is sent SIGHUP.
  let plain_log = fp"{root}/plain.jsonl"

  fs.write(
    fp"{service_dir}/plain.xsh",
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "plain",
  kind: "longrun",
  command: process.command_argv("plain", ["plain"]),
  restart: {mode: "never"},
}
""",
  )

  fp"{run_dir}/plain.json".write(
    "{\"name\":\"plain\",\"desired\":\"up\",\"state\":\"running\",\"pid\":1000,\"restarts\":0}",
  )

  test.unix_fake(ctx, {log: plain_log})
  let _ = xinit_text(
    ctx,
    ["reload", "plain"],
    {XINIT_SERVICE_DIR: service_dir.display(), XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"},
  )?
  let plain_text = plain_log.read_text()?
  assert "\"op\":\"kill_process_group\"" in plain_text
  assert "\"signal\":\"HUP\"" in plain_text
}

test test_finish_hook_runs_after_exit [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "finish")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  let touched = fp"{root}/finished"
  service_dir.mkdir()

  # A service that exits and won't restart, with a finish() cleanup hook. When
  # its child dies the scanner runs finish() before parking it.
  fs.write(
    fp"{service_dir}/demo.xsh",
    f"""##! Service fixture.

## The service declaration.
export let service = {{
  name: "demo",
  kind: "longrun",
  command: process.command_argv("demo", ["demo"]),
  restart: {{mode: "never"}},
}}

## The `finish` lifecycle hook.
export proc finish() [fs, process, env, error] -> Result[Unit] {{
  fs.write(Path({json.encode(touched.display())?}), "finished")?
}}
""",
  )

  test.unix_fake(ctx, {event_kind: "child", pid: 1000, status_code: 1})
  let scan = xinit_text(
    ctx,
    ["scan", "demo"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XINIT_TEST_MAX_EVENTS: "1",
      XSH_UNIX_DRY_RUN: "1",
    },
  )?
  assert scan == ""
  assert touched.read_text()? == "finished"
  test.unix_fake(ctx, {})
  let status = xinit_text(ctx, ["status", "demo"], {XINIT_RUN_DIR: run_dir.display(), XSH_UNIX_DRY_RUN: "1"})?

  assert status == """demo down pid=0 ready=false log=append desired=down restarts=0
"""
}

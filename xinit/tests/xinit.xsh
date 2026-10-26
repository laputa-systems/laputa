type XinitRun = {success: Bool, stdout: Str, stderr: Str}

pure xinit_script() -> Path {
  p"xinit/xinit.xsh"
}

# Native Unix and Linux fakes do not propagate into externally executed XSH binaries.
proc run_xinit(ctx: TestContext, args: List[Str], vars: Record) [fs, process, error] -> Result[XinitRun] {
  let result = test.run_xsh(ctx, xinit_script().read_text()?, [], args, vars, name: "xinit.xsh")?
  {success: result.success, stdout: result.stdout, stderr: result.stderr}
}

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

proc write_named_service(path_value: Path, name: Str, command: Str, targets: List[Str], deps: Str, extra = "") {
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
    {XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"},
  )?

  assert output == """boot: ok
wait: ok
down: ok
"""

  test.unix_fake(ctx, {})
  let unsupported_status = run_xinit(
    ctx,
    [unsupported.display()],
    {XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"},
  )?
  assert_failed_with(unsupported_status, "unsupported action 'bogus'")
  let shell_status = run_xinit(
    ctx,
    [shell_syntax.display()],
    {XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"},
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
    [inittab.display(), "--launch-limit", "1", "--respawn-delay-ms", "1"],
    {
      XINIT_TEST_EXIT_WHEN_IDLE: "1",
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
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
    {XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"},
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
    {XINIT_TEST_FAST_SHUTDOWN: "1", XINIT_TEST_SKIP_FINAL_CLEANUP: "1", XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"},
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
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
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
  let status = xinit_text(ctx, ["status", "demo"], {XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"})?

  assert status == """demo running pid=1000 ready=true log=append desired=up restarts=0
"""

  test.unix_fake(ctx, {log: unix_log})
  let stopped = xinit_text(
    ctx,
    ["stop", "demo"],
    {XINIT_SERVICE_DIR: service_dir.display(), XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"},
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
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
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
    {XINIT_SERVICE_DIR: service_dir.display(), XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"},
  )?
  assert "app longrun targets=boot state=running ready=true" in listed
  assert "net longrun targets=boot state=running ready=true" in listed
  let stop_net = run_xinit(
    ctx,
    ["stop", "net"],
    {XINIT_SERVICE_DIR: service_dir.display(), XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"},
  )?
  assert_failed_with(stop_net, "running dependents: app")
}

test test_ready_and_status_hooks [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "ready")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  service_dir.mkdir()

  fp"{service_dir}/demo.xsh".write(
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "demo",
  kind: "longrun",
  command: process.command_argv("demo", ["demo"]),
  restart: {mode: "never"},
}

## The `ready` lifecycle hook.
export proc ready() [fs, process, env, time, error] -> Result[Bool, Error] {
  return true
}

## The `status` lifecycle hook.
export proc status() [fs, process, env, error] -> Result[Str, Error] {
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
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
    },
  )?

  assert started == """demo running pid=1000 ready=true log=append desired=up restarts=0
"""

  let status = xinit_text(
    ctx,
    ["status", "demo"],
    {XINIT_SERVICE_DIR: service_dir.display(), XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"},
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
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
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

  fp"{service_dir}/demo.xsh".write(
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
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
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
  let status = xinit_text(ctx, ["status", "demo"], {XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"})?

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
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
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
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
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
        XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
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
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
    },
  )?
  assert supervise == ""
  test.unix_fake(ctx, {})
  let status = xinit_text(ctx, ["status", "demo"], {XINIT_RUN_DIR: supervise_run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"})?

  assert status == """demo running pid=1001 ready=true log=append desired=up restarts=1
"""

  assert supervise_unix_log.read_text()?.split("spawn_process_group").len() == 3
}

test test_status_reconciles_stale_pid [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "liveness")?
  let run_dir = fp"{root}/run"
  run_dir.mkdir()

  let self_pid = process.current_pid()?

  fp"{run_dir}/alive.json".write(
    f"{{\"name\":\"alive\",\"desired\":\"up\",\"state\":\"running\",\"pid\":{self_pid},\"restarts\":0}}",
  )

  let alive = xinit_text(ctx, ["status", "alive"], {XINIT_RUN_DIR: run_dir.display()})?

  assert alive == f"""alive running pid={self_pid} ready=true log=append desired=up restarts=0
"""

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

  let self_pid = process.current_pid()?
  var self_start = 0

  for entry in process.list()? {
    if entry.pid == self_pid {
      self_start = entry.start_time_ms
    }
  }

  fp"{run_dir}/ours.json".write(
    f"{{\"name\":\"ours\",\"desired\":\"up\",\"state\":\"running\",\"pid\":{self_pid},\"start_time_ms\":{self_start},\"restarts\":0}}",
  )

  let ours = xinit_text(ctx, ["status", "ours"], {XINIT_RUN_DIR: run_dir.display()})?

  assert ours == f"""ours running pid={self_pid} ready=true log=append desired=up restarts=0
"""

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

  fp"{service_dir}/demo.xsh".write(
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
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
    },
  )?
  assert supervise == ""
  test.unix_fake(ctx, {})
  let status = xinit_text(ctx, ["status", "demo"], {XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"})?

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

  fp"{service_dir}/logger.xsh".write(
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

  fp"{service_dir}/worker.xsh".write(
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
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
    },
  )?
  assert scan == ""
  test.unix_fake(ctx, {})
  let logger_status = xinit_text(ctx, ["status", "logger"], {XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"})?

  assert logger_status == """logger running pid=1000 ready=true log=append desired=up restarts=0
"""

  let worker_status = xinit_text(ctx, ["status", "worker"], {XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"})?

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

  fp"{service_dir}/logger.xsh".write(
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

  fp"{service_dir}/app.xsh".write(
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
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
    },
  )?
  assert scan == ""
  test.unix_fake(ctx, {})
  let logger_status = xinit_text(ctx, ["status", "logger"], {XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"})?

  assert logger_status == """logger starting pid=1000 ready=false log=append desired=up restarts=0
"""

  let app_status = xinit_text(ctx, ["status", "app"], {XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"})?

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

  fp"{service_dir}/logger.xsh".write(
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

  fp"{service_dir}/app.xsh".write(
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
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
    },
  )?
  assert scan == ""
  test.unix_fake(ctx, {})
  let logger_status = xinit_text(ctx, ["status", "logger"], {XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"})?

  assert logger_status == """logger running pid=1000 ready=true log=append desired=up restarts=0
"""

  let app_status = xinit_text(ctx, ["status", "app"], {XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"})?

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

  fp"{service_dir}/demo.xsh".write(
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

  test.unix_fake(ctx, {log: unix_log, event_kind: "poll"})
  let scan = xinit_text(
    ctx,
    ["scan", "demo"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XINIT_TEST_MAX_EVENTS: "2",
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
    },
  )?
  assert scan == ""
  test.unix_fake(ctx, {})
  let status = xinit_text(ctx, ["status", "demo"], {XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"})?

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

  fp"{service_dir}/demo.xsh".write(
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

  test.unix_fake(ctx, {event_kind: "poll", ready: 0})
  let scan = xinit_text(
    ctx,
    ["scan", "demo"],
    {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: log_root.display(),
      XINIT_TEST_MAX_EVENTS: "2",
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
    },
  )?
  assert scan == ""
  test.unix_fake(ctx, {})
  let status = xinit_text(ctx, ["status", "demo"], {XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"})?

  assert status == """demo running pid=1000 ready=false log=append desired=up restarts=0
"""
}

test test_start_tolerates_optional_uses_failure [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "uses-optional")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let log_root = fp"{root}/logs"
  service_dir.mkdir()

  fp"{service_dir}/flaky.xsh".write(
    """##! Service fixture.

## The service declaration.
export let service = {
  name: "flaky",
  kind: "oneshot",
  command: process.command_argv("/bin/false", ["false"]),
}
""",
  )

  fp"{service_dir}/app.xsh".write(
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
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
    },
  )?

  assert started == """app running pid=1000 ready=true log=append desired=up restarts=0
"""

  fp"{service_dir}/needy.xsh".write(
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
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
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

  fp"{service_dir}/hooked.xsh".write(
    f"""##! Service fixture.

## The service declaration.
export let service = {{
  name: "hooked",
  kind: "longrun",
  command: process.command_argv("hooked", ["hooked"]),
  restart: {{mode: "never"}},
}}

## The `reload` lifecycle hook.
export proc reload() [fs, process, env, error] -> Result[Unit, Error] {{
  Path({json.encode(touched.display())?}).write("reloaded")?
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
    {XINIT_SERVICE_DIR: service_dir.display(), XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"},
  )?
  assert "hooked running" in hooked

  assert touched.read_text()? == "reloaded"
  assert ! unix_log.exists()?

  let plain_log = fp"{root}/plain.jsonl"

  fp"{service_dir}/plain.xsh".write(
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
    {XINIT_SERVICE_DIR: service_dir.display(), XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"},
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

  fp"{service_dir}/demo.xsh".write(
    f"""##! Service fixture.

## The service declaration.
export let service = {{
  name: "demo",
  kind: "longrun",
  command: process.command_argv("demo", ["demo"]),
  restart: {{mode: "never"}},
}}

## The `finish` lifecycle hook.
export proc finish() [fs, process, env, error] -> Result[Unit, Error] {{
  Path({json.encode(touched.display())?}).write("finished")?
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
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
    },
  )?
  assert scan == ""
  assert touched.read_text()? == "finished"
  test.unix_fake(ctx, {})
  let status = xinit_text(ctx, ["status", "demo"], {XINIT_RUN_DIR: run_dir.display(), XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1"})?

  assert status == """demo down pid=0 ready=false log=append desired=down restarts=0
"""
}

test test_crashed_leader_group_cleanup_precedes_finish_and_respawn [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "crash-group-replay")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let unix_log = fp"{root}/unix.jsonl"
  service_dir.mkdir()
  fp"{service_dir}/demo.xsh".write(f"""##! Replay a leader exit while its group still owns descendants.

## The scanner owns this foreground service group.
export let service = {{
  name: "demo",
  command: process.command_argv("demo", ["demo"]),
  logging: "off",
  restart: {{mode: "always", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000}},
}}

## Finish observes teardown before the replacement instance can start.
export proc finish() [fs, process, env, error] -> Result[Unit, Error] {{
  let events = Path({json.encode(unix_log.display())?}).read_text()?
  assert "pid1_shutdown" in events
  assert "\\\"groups\\\":\\\"1000\\\"" in events
}}
""")
  test.unix_fake(ctx, {log: unix_log, event_kind: "child", pid: 1000, status_code: 137})
  let output = xinit_text(ctx, ["supervise", "demo"], {
    XINIT_SERVICE_DIR: service_dir.display(),
    XINIT_RUN_DIR: run_dir.display(),
    XINIT_TEST_MAX_EVENTS: "1",
    XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
  })?
  assert output == ""
  let phases = unix_log.read_text()?.split("pid1_shutdown")
  assert phases.len() == 2
  assert phases[0].split("spawn_process_group").len() == 2
  assert phases[1].split("spawn_process_group").len() == 2
  assert "\"groups\":\"1000\"" in unix_log.read_text()?
  test.unix_fake(ctx, {})
  let status = xinit_text(ctx, ["status", "demo"], {
    XINIT_RUN_DIR: run_dir.display(),
    XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
  })?
  assert "running pid=1001" in status
  assert "restarts=1" in status
}

test test_service_configuration_rejects_invalid_fields_before_application [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "strict-services")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  service_dir.mkdir()
  test.unix_fake(ctx, {})
  let cases = [
    {fields: "typo: true,", field: "typo"},
    {fields: "restart: {delai_ms: 1},", field: "restart.delai_ms"},
    {fields: "dependencies: {needs: []},", field: "dependencies.needs"},
    {fields: "log: {mode: \"append\", max_sise: 1},", field: "log.max_sise"},
    {fields: "resources: {memory: 1},", field: "resources.memory"},
    {fields: "logging: \"off\", log: {mode: \"append\"},", field: "logging"},
    {fields: "kind: \"daemon\",", field: "kind"},
    {fields: "restart: {mode: \"sometimes\"},", field: "restart.mode"},
    {fields: "restart: {delay_ms: -1},", field: "restart.delay_ms"},
    {fields: "restart: {delay_ms: 20, max_delay_ms: 10},", field: "restart.max_delay_ms"},
    {fields: "restart: {stable_after_ms: -1},", field: "restart.stable_after_ms"},
    {fields: "logging: \"quiet\",", field: "logging"},
    {fields: "log: {mode: \"append\", keep: -1},", field: "log.keep"},
    {fields: "log: {mode: \"append\", max_size: -1},", field: "log.max_size"},
    {fields: "resources: {cpu_max: -1},", field: "resources.cpu_max"},
    {fields: "readiness: \"socket\",", field: "readiness"},
    {fields: "kind: \"oneshot\", readiness: \"notify\",", field: "readiness"},
    {fields: "ready_timeout_ms: -1,", field: "ready_timeout_ms"},
    {fields: "stop_timeout_ms: -1,", field: "stop_timeout_ms"},
    {fields: "targets: [\"../outside\"],", field: "targets"},
    {fields: "dependencies: {need: [\"demo\"]},", field: "dependencies.need"},
    {fields: "dependencies: {need: [\"net\", \"net\"]},", field: "dependencies.need"},
    {fields: "dependencies: {need: [\"net\"], uses: [\"net\"]},", field: "dependencies.uses"},
    {fields: "restart: null,", field: "restart"},
    {fields: "restart: {delay_ms: null},", field: "restart.delay_ms"},
    {fields: "dependencies: {need: [1]},", field: "dependencies.need"},
    {fields: "logging: null,", field: "logging"},
    {fields: "targets: null,", field: "targets"},
  ]
  for item in cases {
    let fixture = fp"{service_dir}/demo.xsh"
    fixture.write(f"""##! Invalid service declaration.

## Configuration must fail before application.
export let service = {{
  name: "demo",
  command: process.command_argv("service", ["service"]),
  {item.fields}
}}
""")
    let result = run_xinit(ctx, ["start", "demo"], {
      XINIT_SERVICE_DIR: service_dir.display(),
      XINIT_RUN_DIR: run_dir.display(),
      XINIT_LOG_ROOT: fp"{root}/logs".display(),
      XINIT_TEST_ALLOW_NON_PID1: "1", XINIT_TEST_FAKE_PIDS: "1",
    })?
    assert ! result.success, item.fields
    assert item.field in result.stderr, result.stderr
    assert fixture.display() in result.stderr, result.stderr
    assert ! run_dir.exists()?, item.fields
  }
  for declaration in [
    "name: \"../outside\", command: process.command_argv(\"service\", [\"service\"])",
    "name: null, command: process.command_argv(\"service\", [\"service\"])",
    "command: process.command_argv(\"service\", [\"service\"])",
    "name: \"demo\", command: null",
    "name: \"demo\"",
  ] {
    let fixture = fp"{service_dir}/demo.xsh"
    fixture.write(f"""##! Invalid required field.

## Configuration must fail before application.
export let service = {{{declaration}}}
""")
    let result = run_xinit(ctx, ["check", fixture.display()], {})?
    assert ! result.success, declaration
    assert fixture.display() in result.stderr, result.stderr
    assert ! run_dir.exists()?
  }
}

test test_check_detects_cycles_and_duplicate_service_names [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "strict-graph")?
  let service_dir = fp"{root}/services"
  service_dir.mkdir()
  write_named_service(fp"{service_dir}/a.xsh", "a", "process.command_argv(\"a\", [\"a\"])", ["boot"], "need: [\"b\"]")
  write_named_service(fp"{service_dir}/b.xsh", "b", "process.command_argv(\"b\", [\"b\"])", ["boot"], "need: [\"a\"]")
  let cycle = run_xinit(ctx, ["check"], {XINIT_SERVICE_DIR: service_dir.display()})?
  assert_failed_with(cycle, "dependency cycle")
  write_named_service(fp"{service_dir}/a.xsh", "same", "process.command_argv(\"a\", [\"a\"])", ["boot"], "")
  write_named_service(fp"{service_dir}/b.xsh", "same", "process.command_argv(\"b\", [\"b\"])", ["boot"], "")
  let duplicate = run_xinit(ctx, ["check"], {XINIT_SERVICE_DIR: service_dir.display()})?
  assert_failed_with(duplicate, "duplicate service name")
}

type PlannedServiceIdentity = {name: Str}
type InspectedService = {name: Str, source: Str, command: Str, kind: Str, ready_timeout_ms: Int, stop_timeout_ms: Int}

test test_inspect_and_start_plan_are_redacted_and_do_not_apply_services [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "inspect-plan")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let unix_log = fp"{root}/unix.jsonl"
  service_dir.mkdir()
  write_named_service(fp"{service_dir}/base.xsh", "base", "process.command_argv(\"base\", [\"base\", \"secret-token\"])", ["boot"], "")
  write_named_service(fp"{service_dir}/app.xsh", "app", "process.command_argv(\"app\", [\"app\"])", ["boot"], "need: [\"base\"]")
  let vars = {XINIT_SERVICE_DIR: service_dir.display(), XINIT_RUN_DIR: run_dir.display()}
  test.unix_fake(ctx, {log: unix_log})
  let inspected = xinit_text(ctx, ["inspect", "base"], vars)?
  assert "secret-token" not in inspected
  let config = json.decode(inspected)?.require(InspectedService)?
  assert config.command == "redacted"
  assert config.source == fp"{service_dir}/base.xsh".display()
  assert config.kind == "longrun"
  assert config.ready_timeout_ms == 5000
  assert config.stop_timeout_ms == 200
  let plan = xinit_text(ctx, ["start-plan", "app"], vars)?
  let names = json.decode(plan)?.require(List[PlannedServiceIdentity])?
  assert [item.name for item in names] == ["base", "app"]
  assert "secret-token" not in plan
  assert ! run_dir.exists()?
  assert ! unix_log.exists()?
}

test test_inittab_policy_is_typed_and_does_not_read_legacy_test_overrides [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "inittab-policy")?
  let inittab = fp"{root}/inittab"
  let unix_log = fp"{root}/unix.jsonl"
  inittab.write("::respawn:/usr/bin/daemon\n")
  test.unix_fake(ctx, {log: unix_log, event_kind: "child", pid: 1000})
  let result = run_xinit(ctx, [inittab.display(), "--launch-limit", "1", "--respawn-delay-ms", "0"], {
    XINIT_TEST_ALLOW_NON_PID1: "1",
    XINIT_TEST_EXIT_WHEN_IDLE: "1",
    XSH_INIT_TEST_MAX_RESPAWNS: "invalid",
    XSH_INIT_TEST_RESPAWN_DELAY_MS: "invalid",
  })?
  assert result.success, result.stderr
  assert unix_log.read_text()?.split("spawn_process_group").len() == 2
  for invalid in ["--launch-limit", "--respawn-delay-ms"] {
    let rejected = run_xinit(ctx, [inittab.display(), invalid, "-1"], {XINIT_TEST_ALLOW_NON_PID1: "1"})?
    assert ! rejected.success
    assert invalid.replace("--", with: "").replace("-", with: "_") in rejected.stderr
  }
}

test test_fake_pid_and_event_flags_require_explicit_test_control [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "test-control")?
  let run_dir = fp"{root}/run"
  run_dir.mkdir()
  fp"{run_dir}/gone.json".write("{\"name\":\"gone\",\"state\":\"running\",\"desired\":\"up\",\"pid\":2147480000}")
  let result = test.run_xsh(ctx, xinit_script().read_text()?, [], ["status", "gone"], {
    XINIT_RUN_DIR: run_dir.display(),
    XSH_UNIX_DRY_RUN: "1",
    XINIT_TEST_FAKE_PIDS: "1",
    XINIT_TEST_MAX_EVENTS: "0",
    XINIT_TEST_ALLOW_NON_PID1: "0",
  }, name: "xinit.xsh")?
  assert result.success, result.stderr
  assert "gone dead pid=0" in result.stdout
}

test test_legacy_non_pid1_switch_does_not_bypass_pid1_requirement [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "legacy-non-pid1")?
  let inittab = fp"{root}/inittab"
  inittab.write("")
  let result = test.run_xsh(ctx, xinit_script().read_text()?, [], [inittab.display()], {
    XSH_INIT_TEST_ALLOW_NON_PID1: "1",
    XSH_INIT_TEST_EXIT_WHEN_IDLE: "1",
    XINIT_TEST_ALLOW_NON_PID1: "0",
  }, name: "xinit.xsh")?
  assert ! result.success
  assert "pid1-required" in result.stderr
}

proc xinit_policy_source() [fs, error] -> Result[Str] {
  let source = xinit_script().read_text()?
  let entry = "proc main(...argv: List[Str])"
  assert source.split(entry).len() == 2
  source.replace(entry, with: "proc xinit_cli(...argv: List[Str])")
}

test test_restart_delay_caps_before_multiplication [fs, process, error] { |ctx|
  let source = xinit_policy_source()? + """
for item in [
  {used: 0, cap: 0, expected: 0},
  {used: 100, cap: 0, expected: 200},
  {used: 100, cap: 800, expected: 200},
  {used: 400, cap: 800, expected: 800},
  {used: 500, cap: 800, expected: 800},
  {used: 800, cap: 800, expected: 800},
  {used: 4611686018427387904, cap: 9223372036854775807, expected: 9223372036854775807},
] {
  assert escalate_delay(item.used, item.cap) == item.expected
}
"""
  let result = test.run_xsh(ctx, source, name: "restart-cap.xsh")?
  assert result.success, result.stderr
  let overflow = test.run_xsh(ctx, xinit_policy_source()? + "\nprint escalate_delay(9223372036854775807, 0)\n", name: "uncapped-overflow.xsh")?
  assert ! overflow.success
  assert "integer-overflow" in overflow.stderr
}

test test_pure_restart_policy_uses_explicit_observations [fs, process, error] { |ctx|
  let source = xinit_policy_source()? + """
let service = service_from_record(p"policy.xsh", {
  name: "app",
  command: process.command_argv("unused", ["unused"]),
  restart: {mode: "always", delay_ms: 100, max_delay_ms: 800, stable_after_ms: 1000},
})?
for item in [
  {observed: 10999, expected: 400},
  {observed: 11000, expected: 100},
  {observed: 11001, expected: 100},
  {observed: 9999, expected: 400},
  {observed: 0, expected: 400},
] {
  assert restart_delay(service, 400, 10000, item.observed) == item.expected
}
let immediate = {...service, delay_ms: 0, stable_after_ms: 0}
assert restart_delay(immediate, 400, 10000, 10000) == 0
assert restart_delay(immediate, 400, 10000, 9999) == 400
let timed = {...unit_init(service), next_ms: 1000}
for item in [
  {observed: 900, due: 100, spawn: false},
  {observed: 999, due: 1, spawn: false},
  {observed: 1000, due: 0, spawn: true},
  {observed: 1001, due: 0, spawn: true},
] {
  assert due_ms(timed, item.observed) == item.due
  assert spawn_due(0, item.observed, 1000) == item.spawn
  assert ! spawn_due(42, item.observed, 1000)
}
let base = unit_init({...service, name: "base"})
let dependent = {...service, need: ["base"]}
let optional = {...service, uses: ["base"]}
let ordered = {...service, after: ["base"]}
for item in [
  {state: "pending", required: false, tolerated: false},
  {state: "starting", required: false, tolerated: false},
  {state: "dead", required: false, tolerated: false},
  {state: "running", required: true, tolerated: true},
  {state: "stopped", required: false, tolerated: true},
] {
  let observed = [{...base, state: item.state}]
  assert gate_satisfied(observed, dependent) == item.required
  assert gate_satisfied(observed, optional) == item.tolerated
  assert gate_satisfied(observed, ordered) == item.tolerated
  assert unit_blocked(observed, unit_init(dependent)) == ! item.required
  assert ! unit_blocked(observed, {...unit_init(dependent), state: "dead"})
}
assert gate_satisfied([], dependent)
assert service_from_record(p"invalid-policy.xsh", {
  name: "invalid",
  command: process.command_argv("unused", ["unused"]),
  restart: {delay_ms: -1},
}) is Err(_)
"""
  let result = test.run_xsh(ctx, source, name: "restart-observations.xsh")?
  assert result.success, result.stderr
}

test test_restart_policy_rejects_hidden_clock_effects [fs, process, error] { |ctx|
  let source = xinit_policy_source()?
  let body = "pure restart_delay(service: Service, current_delay: Int, started_at: Int, now: Int) -> Int {"
  assert source.split(body).len() == 2
  let invalid = source.replace(body, with: f"{body}\n  let _ = time.now()")
  let result = test.run_xsh(ctx, invalid, name: "invalid-clock-policy.xsh")?
  assert ! result.success
  assert "check.pure-effect" in result.stderr
}

test test_elapsed_clock_converts_nanoseconds_and_samples_monotonic_origin [fs, process, error] { |ctx|
  let source = xinit_policy_source()? + """
for item in [
  {ns: 0, ms: 0},
  {ns: 999999, ms: 0},
  {ns: 1000000, ms: 1},
  {ns: 1999999, ms: 1},
  {ns: 1000000000, ms: 1000},
  {ns: 9223372036854775807, ms: 9223372036854},
] {
  assert clock_millis(item.ns.require(UInt)?) == item.ms
}
let before = time.monotonic()?
let sample = elapsed_now_ms()?
let after = time.monotonic()?
assert sample >= before / 1000000
assert sample <= after / 1000000
"""
  let result = test.run_xsh(ctx, source, name: "elapsed-clock.xsh")?
  assert result.success, result.stderr
}

test test_readiness_and_restart_budgets_use_elapsed_milliseconds [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "elapsed-budgets")?
  let run_dir = fp"{root}/run"
  let source = xinit_policy_source()? + """
let service = service_from_record(p"elapsed-service.xsh", {
  name: "demo",
  command: process.command_argv("unused", ["unused"]),
  readiness: "notify",
  ready_timeout_ms: 1000,
  restart: {mode: "always", delay_ms: 500},
})?
let starting = {...unit_init(service), state: "starting", pid: 1000, started_at: 1000}
for item in [
  {ns: 1000000000, state: "starting"},
  {ns: 1999999999, state: "starting"},
  {ns: 2000000000, state: "running"},
] {
  let observed = clock_millis(item.ns.require(UInt)?)
  let next = advance_readiness(starting, observed)?
  assert next.state == item.state
  assert ! next.ready
}
let dead = {...unit_init(service), state: "dead", next_ms: 1500}
for item in [
  {ns: 1000000000, wait_ms: 500},
  {ns: 1250000000, wait_ms: 250},
  {ns: 1500000000, wait_ms: 0},
  {ns: 2500000000, wait_ms: 0},
] {
  assert due_ms(dead, clock_millis(item.ns.require(UInt)?)) == item.wait_ms
}
let fresh = unit_init(service)
assert fresh.next_ms == 0
assert fresh.started_at == 0
assert spawn_due(fresh.pid, 0, fresh.next_ms)
"""
  let result = test.run_xsh(ctx, source, env: {XINIT_RUN_DIR: run_dir.display()}, name: "elapsed-budgets.xsh")?
  assert result.success, result.stderr
  assert "\"state\":\"running\"" in fp"{run_dir}/demo.json".read_text()?
}

test test_scan_does_not_run_stop_or_finish_for_unstarted_dependents [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "unstarted-cleanup")?
  let service_dir = fp"{root}/services"
  let run_dir = fp"{root}/run"
  let stopped = fp"{root}/app-stopped"
  let finished = fp"{root}/app-finished"
  let unix_log = fp"{root}/unix.jsonl"
  service_dir.mkdir()
  write_named_service(fp"{service_dir}/base.xsh", "base", "process.command_argv(\"base\", [\"base\"])", ["boot"], "", "readiness: \"notify\", ready_timeout_ms: 100000, logging: \"off\",")
  let app = fp"{service_dir}/app.xsh"
  write_named_service(app, "app", "process.command_argv(\"app\", [\"app\"])", ["boot"], "need: [\"base\"]", "logging: \"off\",")
  app.write(app.read_text()? + f"""
## Stop applies only to an instance that was started.
export proc stop() [fs, process, env, time, error] -> Result[Unit, Error] {{
  Path({json.encode(stopped.display())?}).write("stopped")?
}}

## Finish applies only to an instance that was started.
export proc finish() [fs, process, env, error] -> Result[Unit, Error] {{
  Path({json.encode(finished.display())?}).write("finished")?
}}
""")
  test.unix_fake(ctx, {log: unix_log, signal: "TERM", ready: 0})
  let output = xinit_text(ctx, ["scan", "app"], {
    XINIT_SERVICE_DIR: service_dir.display(),
    XINIT_RUN_DIR: run_dir.display(),
    XINIT_TEST_ALLOW_NON_PID1: "1",
    XINIT_TEST_FAKE_PIDS: "1",
  })?
  assert output == ""
  assert ! stopped.exists()?
  assert ! finished.exists()?
  assert unix_log.read_text()?.split("spawn_process_group").len() == 2
}

#!/bin/xsh --
use pm.generation as generation
error ClockGuestError = Failed(message: Str)

type ClockGuestStatus = {state: Str, pid: Int, ready: Bool, restarts: Int}

proc require_disposable_guest() {
  let cmdline = p"/proc/cmdline".read_text()?.trim().split(" ")
  assert "LAPUTA_SELF_HOSTING=1" in cmdline, "clock mutation requires the disposable VM kernel marker"
  let receipt = generation.read_generation_receipt(p"/")?
  assert receipt.profile.name == "qemu-self-hosting", "clock mutation requires the disposable VM profile"
}

proc clock_ms() -> Result[Int] {
  time.monotonic()? / 1000000
}

proc clock_status(root: Path) -> Result[ClockGuestStatus] {
  json.read(fp"{root}/run/clock.json")?.require(ClockGuestStatus)?
}

proc wait_state(root: Path, wanted: Str) -> Result[ClockGuestStatus] {
  let deadline = clock_ms()? + 8000

  while clock_ms()? < deadline {
    if fp"{root}/run/clock.json".exists() {
      let status = clock_status(root)?

      return status when status.state == wanted
    }

    time.sleep(20ms)
  }

  Err(ClockGuestError.Failed(message: f"deadline waiting for clock service state {wanted}"))
}

proc wait_replacement(root: Path, old_pid: Int) -> Result[ClockGuestStatus] {
  let deadline = clock_ms()? + 8000

  while clock_ms()? < deadline {
    let status = clock_status(root)?

    return status when status.pid > 0 and status.pid != old_pid

    time.sleep(20ms)
  }

  Err(ClockGuestError.Failed(message: "deadline waiting for replacement service"))
}

proc wait_worker(root: Path, pid: Int) {
  let deadline = clock_ms()? + 8000

  while clock_ms()? < deadline {
    if fp"{root}/worker.pid".exists() and fp"{root}/worker.pid".read_text()?.parse_int()? == pid {
      assert process.group_id(pid)? == pid
      return
    }

    time.sleep(20ms)
  }

  Err(ClockGuestError.Failed(message: "service identity did not match the owned process group"))
}

proc worker(root: Path) {
  unix.pid1_setup(["TERM"], subreaper: false, allow_non_pid1: true)
  fp"{root}/worker.pid".write_atomic(f"{process.current_pid()?}")

  while true {
    let event = unix.wait_pid1_event(timeout: 100ms)?

    if event.kind == "signal" and event.signal == "TERM" and ! fp"{root}/ignore-term".exists()? {
      return
    }
  }
}

proc exercise_clock(root: Path) {
  assert ! root.exists()?, "clock fixture runtime directory already exists"
  root.mkdir()
  fp"{root}/services".mkdir()
  let original_wall = time.now()
  let origin = clock_ms()?
  assert original_wall > 86400000
  defer {
    linux.set_system_clock(original_wall + clock_ms()? - origin)
  }
  unix.pid1_setup(["TERM", "INT"], subreaper: true, allow_non_pid1: true)
  let fixture = p"/mnt/self-hosting/inputs/laputa/xinit/tests/fixtures/clock_budget_guest.xsh"
  let xinit = p"/mnt/self-hosting/inputs/laputa/xinit/xinit.xsh"
  let argv = json.encode(["xsh", fixture.display(), "--", "worker", root.display()])?
  fp"{root}/services/clock.xsh".write(f"""##! A foreground service for elapsed-clock qualification.

## The scanner owns this service process group.
export let service = {{
  name: "clock",
  command: process.command_argv("/usr/bin/xsh", {argv}),
  readiness: "notify",
  ready_timeout_ms: 2000,
  stop_timeout_ms: 200,
  restart: {{mode: "always", delay_ms: 2000, max_delay_ms: 8000, stable_after_ms: 100000}},
  logging: "off",
}}
""")
  let command = process.command_argv("/usr/bin/xsh", ["xsh", xinit.display(), "--", "supervise", "clock"], env: {
    XSH_ROOT: "/usr/lib/xsh",
    XINIT_SERVICE_DIR: fp"{root}/services".display(),
    XINIT_RUN_DIR: fp"{root}/run".display(),
    XINIT_LOG_ROOT: fp"{root}/logs".display(),
    XINIT_TEST_ALLOW_NON_PID1: "0",
  })
  let launch = clock_ms()?
  let scanner = unix.spawn_process_group(command)?
  var owned_groups = [scanner.pid]
  defer {
    let cleanup = unix.shutdown_process_groups(owned_groups, 2s, 100ms)?
    assert cleanup.remaining.is_empty(), "clock fixture retained owned process groups"
  }
  let starting = wait_state(root, "starting")?
  owned_groups = owned_groups.push(starting.pid)
  linux.set_system_clock(original_wall + 86400000)
  time.sleep(100ms)
  assert clock_status(root)?.state == "starting", "forward wall jump expired readiness early"
  linux.set_system_clock(original_wall - 86400000)
  time.sleep(100ms)
  assert clock_status(root)?.state == "starting", "backward wall jump changed readiness admission"
  let first = wait_state(root, "running")?
  assert ! first.ready
  assert clock_ms()? - launch >= 2000
  wait_worker(root, first.pid)
  let crash = clock_ms()?
  process.kill(first.pid, signal: "KILL")
  let dead = wait_state(root, "dead")?
  assert dead.pid == 0
  linux.set_system_clock(original_wall + 86400000)
  time.sleep(100ms)
  assert clock_status(root)?.state == "dead", "forward wall jump skipped restart backoff"
  linux.set_system_clock(original_wall - 86400000)
  time.sleep(100ms)
  assert clock_status(root)?.state == "dead", "backward wall jump changed restart admission"
  let pause_before = clock_ms()?
  let wall_before = time.now()
  print "LAP27_PAUSE_READY"
  io.flush_stdout()
  time.sleep(2s)
  let pause_delta = clock_ms()? - pause_before
  let wall_delta = time.now() - wall_before
  print f"LAP27_RESUME_OBSERVED monotonic_delta_ms={pause_delta} wall_delta_ms={wall_delta}"
  io.flush_stdout()
  let replacement = wait_replacement(root, first.pid)?
  owned_groups = owned_groups.push(replacement.pid)
  assert clock_ms()? - crash >= 2000, "restart occurred before its monotonic budget"
  assert replacement.restarts == first.restarts + 1
  wait_worker(root, replacement.pid)
  let settled = wait_state(root, "running")?
  assert ! settled.ready
  fp"{root}/ignore-term".write_atomic("1")
  let stopping = clock_ms()?
  process.kill(scanner.pid, signal: "TERM")
  linux.set_system_clock(original_wall + 86400000)
  time.sleep(50ms)
  linux.set_system_clock(original_wall - 86400000)
  let stop_deadline = clock_ms()? + 6000
  var reaped = false

  while ! reaped and clock_ms()? < stop_deadline {
    let event = unix.wait_pid1_event(timeout: 100ms)?

    for child in event.children {
      if child.pid == scanner.pid {
        assert child.status.exited_with(0)
        reaped = true
      }
    }
  }

  assert reaped, "scanner exceeded its monotonic stop budget"
  assert clock_ms()? - stopping >= 200
  let stopped = clock_status(root)?
  assert stopped.state == "down" and stopped.pid == 0

  for entry in process.list()? {
    assert entry.pid != first.pid and entry.pid != replacement.pid, "service survived scanner shutdown"
  }

  print "LAP27_BUDGETS_OK readiness=true restart=true stop=true"
}

proc main(...argv: List[Str]) {
  require_disposable_guest()

  if argv.len() == 2 and argv[0] == "worker" {
    worker(Path(argv[1]))
  } else {
    assert argv.is_empty(), "usage: clock_budget_guest.xsh"
    exercise_clock(fp"/run/xinit-clock-{process.current_pid()?}")
    print "LAP27_CLOCK_OK"
  }
}

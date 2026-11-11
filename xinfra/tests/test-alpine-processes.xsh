use infra.declare
use infra.engine
use infra.lock
use infra.report
use infra.workload
use infra.model
use infra.testing
use infra.transport

const slow_deploy = r"""
##! A deployment whose single command holds the host for a while.

use infra.declare
use infra.model

## The resources one host should have.
export proc resources(host: model.Host) [fs, error] -> Result[List[model.Resource], Error] {
  [declare.command(id: "hold", argv: ["sleep", "5"], always: true, timeout_seconds: 30)?]
}
"""

proc fixtures() [env, error] -> Result[Path, Error] {
  Ok(fp"{env.get("XINFRA_TEST_INVENTORY")?}")
}

proc apply_args(inventory: Path, deploy: Path, lock_path: Str) -> List[Str] {
  ["bin/xinfra.xsh", "apply", f"{inventory}", f"{deploy}", "--limit", "fx-2", "--lock-path", lock_path, "--format", "jsonl"]
}

proc wait_for_lock(connection: transport.Connection, lock_path: Str) [env, process, time, error] -> Result[Bool, Error] {
  for _ in range(100) {
    if lock.inspect(connection, lock_path)? != null {
      return Ok(true)
    }

    time.sleep(100ms)
  }

  Ok(false)
}

proc setup(dir: Path) [fs, error] -> Result[Path, Error] {
  let deploy = fp"{dir}/deploy.xsh"
  deploy.write(slow_deploy)
  Ok(deploy)
}

test a_second_apply_is_refused_while_the_first_holds_the_host_lock { |ctx|
  guard let host = testing.fixture_host("fx-2")? else {
    test.skip("fixture environment is absent")
    return
  }

  let deploy = setup(test.temp_dir(ctx)?)?
  let inventory = fixtures()?
  let lock_path = "/var/tmp/xt-compete.lock"
  let connection = transport.connect(host)?
  let first_out = fp"{deploy.parent()}/first.out"
  let first = spawn run xsh @(apply_args(inventory, deploy, lock_path)) > $first_out ?
  assert wait_for_lock(connection, lock_path)?, "the first apply never took the lock"
  let second = run.capture --text xsh @(apply_args(inventory, deploy, lock_path))
  assert second.status.exit_code()? == 3
  assert "holds" in second.stdout
  let finished = wait first ?
  assert finished.exit_code()? == 0
  assert lock.inspect(connection, lock_path)? == null
}

test a_controller_killed_without_cleanup_leaves_a_lock_only_an_operator_can_break { |ctx|
  guard let host = testing.fixture_host("fx-2")? else {
    test.skip("fixture environment is absent")
    return
  }

  let deploy = setup(test.temp_dir(ctx)?)?
  let inventory = fixtures()?
  let lock_path = "/var/tmp/xt-crash.lock"
  let connection = transport.connect(host)?
  let first_out = fp"{deploy.parent()}/first.out"
  let first = spawn run xsh @(apply_args(inventory, deploy, lock_path)) > $first_out ?
  assert wait_for_lock(connection, lock_path)?, "the first apply never took the lock"
  first.cancel(signal: "KILL", kill_after: 1s)
  assert lock.inspect(connection, lock_path)? != null

  let blocked = run.capture --text xsh @(apply_args(inventory, deploy, lock_path))
  assert blocked.status.exit_code()? == 3
  assert "holds" in blocked.stdout

  let holder = lock.inspect(connection, lock_path)? ?? ""
  let token = holder.fields()[0]
  let shown = run.text xsh bin/xinfra.xsh unlock $inventory fx-2 --lock-path $lock_path
  assert token in shown
  let wrong = run.capture --text xsh bin/xinfra.xsh unlock $inventory fx-2 --token deadbeef --lock-path $lock_path
  assert wrong.status.exit_code()? == 2
  assert lock.inspect(connection, lock_path)? != null
  run xsh bin/xinfra.xsh unlock $inventory fx-2 --token $token --lock-path $lock_path
  assert lock.inspect(connection, lock_path)? == null
}

test a_terminated_controller_releases_its_lock { |ctx|
  guard let host = testing.fixture_host("fx-2")? else {
    test.skip("fixture environment is absent")
    return
  }

  let deploy = setup(test.temp_dir(ctx)?)?
  let inventory = fixtures()?
  let lock_path = "/var/tmp/xt-term.lock"
  let connection = transport.connect(host)?
  let first_out = fp"{deploy.parent()}/first.out"
  let first = spawn run xsh @(apply_args(inventory, deploy, lock_path)) > $first_out ?
  assert wait_for_lock(connection, lock_path)?, "the first apply never took the lock"
  first.cancel(signal: "TERM", kill_after: 5s)
  time.sleep(500ms)
  assert lock.inspect(connection, lock_path)? == null
}

test a_transfer_that_outlives_its_timeout_leaves_the_destination_and_reports_an_unknown_outcome { |ctx|
  guard let found = testing.fixture_host("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  let host: model.Host = {...found, transfer_timeout_ms: 150}
  let dir = test.temp_dir(ctx)?
  let base = f"/var/tmp/{testing.scratch_name(dir)}"
  let blob = fp"{dir}/big.bin"
  run truncate -s 600M $blob
  let small = fp"{dir}/small.bin"
  small.write("original\n")
  let settings = engine.Settings(jobs: 1, policy: .Host, lock_path: f"{base}.lock")
  let first = engine.apply(workload.prepare([workload.Workload(host:, resources: [
    declare.directory(id: "base", at: base, parents: true)?,
    declare.file(id: "bin", at: f"{base}/app.bin", source: small, needs: ["base"])?,
  ])])?, settings)
  assert testing.status_of(first, host.name, "bin") == "changed"

  let second = engine.apply(workload.prepare([workload.Workload(host:, resources: [
    declare.directory(id: "base", at: base, parents: true)?,
    declare.file(id: "bin", at: f"{base}/app.bin", source: blob, needs: ["base"])?,
  ])])?, settings)
  assert testing.status_of(second, host.name, "bin") == "unknown", report.text(second, true)
  assert report.exit_status(second) == 3

  let reader = testing.fixture_host("fx-1")? ?? found
  let after = testing.remote_text(reader, "cat \"$1\"/app.bin", [base], privileged: true)?
  assert after == "original\n"

  let healed = engine.apply(workload.prepare([workload.Workload(host: reader, resources: [
    declare.directory(id: "base", at: base, parents: true)?,
    declare.file(id: "bin", at: f"{base}/app.bin", source: small, needs: ["base"])?,
  ])])?, settings)
  assert testing.status_of(healed, host.name, "bin") == "unchanged"
}

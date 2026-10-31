##! Differential check against pyinfra 3.10.0.

use xinfra.host as host
use xinfra.model as model
use xinfra.resources.command as command
use xinfra.resources.dir as dir
use xinfra.resources.file as file
use xinfra.resources.group as group_resource
use xinfra.resources.package as package
use xinfra.resources.service as service
use xinfra.resources.user as user_resource
use xinfra.transport as transport
use xinfra.validate as validate

const BASE = "/home/xinfra/xinfra-q1"

type Fixture = {host: Str, port: Int, username: Str, key: Path, host_key: Str}

type Capture = {status: Status, stdout: Str, stderr: Str}

proc required(name: Str) [env, error] -> Result[Str, Error] {
  match env.get(name) {
    Ok(value) => Ok(value),
    Err(error) => Err(error.failure(f"missing {name}: {error.message}")),
  }
}

proc fixture(suffix: Str) [env, error] -> Result[Fixture, Error] {
  let host = required(f"XINFRA_FIXTURE_{suffix}_HOST")?
  let port_text = required(f"XINFRA_FIXTURE_{suffix}_PORT")?
  let port = match port_text.parse_int() {
    Ok(value) => value,
    Err(error) => { return Err(error) },
  }
  let username = required("XINFRA_FIXTURE_USER")?
  let key_text = required("XINFRA_FIXTURE_KEY")?
  let host_key = required(f"XINFRA_FIXTURE_{suffix}_HOST_KEY")?
  Ok({host: host, port: port, username: username, key: fp"{key_text}", host_key: host_key})
}

proc require(condition: Bool, message: Str) -> Result[Unit, Error] {
  if condition { Ok() } else { Err(error.failure(message)) }
}

proc connect(fixture: Fixture) [error] -> Result[transport.Session, Error] {
  match transport.connect_endpoint(fixture.host, fixture.port, fixture.username, fixture.key, fixture.host_key) {
    Ok(value) => Ok(value),
    Err(message) => Err(error.failure(message)),
  }
}

proc execute(session: transport.Session, argv: List[Str]) -> Result[transport.ExecResult, Error] {
  match transport.exec(session, argv) {
    Ok(value) => Ok(value),
    Err(message) => Err(error.failure(message)),
  }
}

proc reset(session: transport.Session, elevate: List[Str]) -> Result[Unit, Error] {
  let _ = execute(session, [@elevate, "rc-service", "crond", "stop"])?
  let _ = execute(session, [@elevate, "rc-update", "del", "crond", "default"])?
  let _ = execute(session, [@elevate, "deluser", "xinfra-q1-user"])?
  let _ = execute(session, [@elevate, "delgroup", "xinfra-q1-group"])?
  let _ = execute(session, [@elevate, "apk", "del", "tree"])?
  let _ = execute(session, [@elevate, "rm", "-rf", BASE])?
  let _ = execute(session, [@elevate, "mkdir", "-p", BASE])?
  let _ = execute(session, [@elevate, "chown", "xinfra:xinfra", BASE])?
  let _ = execute(session, [@elevate, "chmod", "755", BASE])?
  Ok()
}

proc apply_all(session: transport.Session, host_name: Str, elevate: List[Str]) -> Result[List[host.ApplyStatus], Error] {
  let directory = model.DirectorySpec(id: "dir", path: p"/home/xinfra/xinfra-q1/dir", mode: 0o755)
  let directory_result = dir.apply_remote(session, host_name, directory)
  require(directory_result.status == host.Changed or directory_result.status == host.Unchanged, "directory apply failed")?

  let motd_text = "hello from the oracle\n"
  let motd = model.FileSpec(id: "motd", path: p"/home/xinfra/xinfra-q1/dir/motd", mode: 0o644)
  let motd_source = validate.Content(validate.ContentSource(text: motd_text, digest: hash.sha256(bytes.from_text(motd_text)).hex()))
  let motd_result = file.apply_remote(session, host_name, motd, motd_source)
  require(motd_result.status == host.Changed or motd_result.status == host.Unchanged, "file apply failed")?

  let tree = model.PackageSpec(id: "tree", name: "tree")
  let package_result = match package.apply_remote(session, host_name, tree, elevate) {
    Ok(value) => value.result,
    Err(error) => { return Err(error) },
  }
  require(package_result.status == host.Changed or package_result.status == host.Unchanged, "package apply failed")?

  let group_result = group_resource.apply_remote(session, host_name, model.GroupSpec(id: "group", name: "xinfra-q1-group", gid: 1600), elevate)?
  require(group_result.status == host.Changed or group_result.status == host.Unchanged, "group apply failed")?

  let user_spec = model.UserSpec(
    id: "user",
    name: "xinfra-q1-user",
    gid: 1600,
    home: p"/home/xinfra/xinfra-q1/home",
    shell: p"/bin/sh",
    create_home: true,
  )
  let user_result = user_resource.apply_remote(session, host_name, user_spec, elevate)?
  require(user_result.status == host.Changed or user_result.status == host.Unchanged, "user apply failed")?

  let command_spec = model.CommandSpec(id: "command", shell: f"printf pyinfra > {BASE}/command")
  let command_result = command.apply_remote(session, host_name, command_spec, elevate, true)?
  require(command_result.status == host.Changed or command_result.status == host.Unchanged, "command apply failed")?

  let service_spec = model.ServiceSpec(id: "crond", name: "crond", state: model.Started, enabled: true)
  let service_result = service.apply_remote(session, host_name, service_spec, elevate)?
  require(service_result.status == host.Changed or service_result.status == host.Unchanged, "service apply failed")?
  Ok([
    directory_result.status,
    motd_result.status,
    package_result.status,
    group_result.status,
    user_result.status,
    command_result.status,
    service_result.status,
  ])
}

## A normalized state snapshot for one guest.
export proc state(session: transport.Session) -> Result[Str, Error] {
  let script = r"""
base=/home/xinfra/xinfra-q1
printf 'dir=%s\n' "$(stat -c '%F|%a|%U|%G' "$base/dir" 2>&1)"
printf 'motd=%s|%s\n' "$(stat -c '%a|%U|%G|%s' "$base/dir/motd" 2>&1)" "$(sha256sum "$base/dir/motd" 2>/dev/null | cut -d' ' -f1)"
printf 'command=%s|%s\n' "$(stat -c '%a|%U|%G|%s' "$base/command" 2>&1)" "$(cat "$base/command" 2>/dev/null)"
printf 'group=%s\n' "$(getent group xinfra-q1-group 2>&1)"
printf 'user=%s\n' "$(getent passwd xinfra-q1-user 2>&1)"
printf 'package=%s\n' "$(apk list -I tree 2>/dev/null | head -n1)"
printf 'service=%s\n' "$(rc-service crond status 2>&1)"
printf 'enabled=%s\n' "$(rc-update show 2>/dev/null | grep '^ *crond ' || true)"
"""
  let result = execute(session, ["sh", "-c", script])?
  Ok(result.stdout.utf8() ?? "")
}

proc repo_root() [process, error] -> Result[Path, Error] {
  let script = process.script_path()?
  let absolute = path.absolute(script)?
  Ok(absolute.parent().parent())
}

proc pyinfra(
  root: Path,
  home: Path,
  fixture: Fixture,
  deploy: Str,
) [fs, process, env, error, io] -> Result[Capture, Error] {
  let binary = match env.get("XINFRA_PYINFRA") {
    Ok(value) => fp"{value}",
    Err(_) => fp"{root}/.work/oracle/venv/bin/pyinfra",
  }
  let result = env ({
    HOME: home,
    Q1_HOST: fixture.host,
    Q1_PORT: f"{fixture.port}",
    Q1_USER: fixture.username,
    Q1_KEY: fixture.key,
  }) {
    run.capture --text $binary -y --sudo --serial --limit q1 dev/oracle/inventory.py $deploy
  }?
  Ok(result)
}

## Execute the pyinfra differential.
export proc check_differential() [fs, process, env, error, io] -> Result[Unit, Error] {
  let root = repo_root()?
  let home = fp"{root}/.work/oracle/home"
  home.mkdir(parents: true)?
  fp"{home}/.ssh".mkdir(parents: true)?
  let a = fixture("A")?
  let b = fixture("B")?

  with pyinfra_session = connect(a)? {
    with xinfra_session = connect(b)? {
      let _ = reset(pyinfra_session, ["sudo", "-n"])?
      let _ = reset(xinfra_session, ["doas", "-n"])?

      let oracle = pyinfra(root, home, a, "dev/oracle/deploy.py")?
      if ! oracle.status.ok {
        return Err(error.failure(f"pyinfra deploy failed: {oracle.stderr.trim()}"))
      }
      let oracle_changes = oracle.stderr.lines() |> where { |line| "[q1] Success" in line } |> count()
      let oracle_noops = oracle.stderr.lines() |> where { |line| "[q1] No changes" in line } |> count()
      if oracle_changes != 7 or oracle_noops != 0 {
        return Err(error.failure(f"first pyinfra apply changed {oracle_changes} and skipped {oracle_noops} operations"))
      }
      let first_statuses = apply_all(xinfra_session, b.host, ["doas", "-n"])?
      if ! (first_statuses |> all { |status| status == host.Changed }) {
        return Err(error.failure("first xinfra apply did not report every resource changed"))
      }

      let oracle_state = state(pyinfra_session)?
      let xinfra_state = state(xinfra_session)?
      if oracle_state != xinfra_state {
        return Err(error.failure(f"differential state mismatch:\npyinfra:\n{oracle_state}\nxinfra:\n{xinfra_state}"))
      }

      let second_oracle = pyinfra(root, home, a, "dev/oracle/deploy.py")?
      if ! second_oracle.status.ok {
        return Err(error.failure(f"second pyinfra deploy failed: {second_oracle.stderr.trim()}"))
      }
      let second_changes = second_oracle.stderr.lines() |> where { |line| "[q1] Success" in line } |> count()
      let second_noops = second_oracle.stderr.lines() |> where { |line| "[q1] No changes" in line } |> count()
      if second_changes != 1 or second_noops != 6 {
        return Err(error.failure(f"second pyinfra apply changed {second_changes} and skipped {second_noops} operations"))
      }
      let second_statuses = apply_all(xinfra_session, b.host, ["doas", "-n"])?
      if second_statuses[5] != host.Changed {
        return Err(error.failure("second xinfra apply did not rerun the unguarded command"))
      }
      for index in range(second_statuses.len()) {
        if index == 5 {
          continue
        }
        if second_statuses[index] != host.Unchanged {
          return Err(error.failure(f"second xinfra apply changed resource {index}"))
        }
      }
      let second_state = state(xinfra_session)?
      if second_state != xinfra_state {
        return Err(error.failure("second xinfra apply changed the state"))
      }

      let fail_oracle = pyinfra(root, home, a, "dev/oracle/fail.py")?
      if fail_oracle.status.ok {
        return Err(error.failure("pyinfra accepted a missing package"))
      }
      let missing = model.PackageSpec(id: "missing", name: "xinfra-no-such-package")
      match package.apply_remote(xinfra_session, b.host, missing, ["doas", "-n"]) {
        Ok(value) => {
          if value.result.status == host.Changed or value.result.status == host.Unchanged {
            return Err(error.failure("xinfra accepted a missing package"))
          }
        }
        Err(_) => {}
      }

      print "differential: pyinfra and xinfra agree"
    }
  }
  Ok()
}

check_differential()?

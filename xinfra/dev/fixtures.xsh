#!/usr/bin/env -S xsh --
##! Disposable Alpine fixtures for integration and differential checks.

const FIXTURES = ["xinfra-a", "xinfra-b"]
const FIXTURE_USER = "xinfra"
const TEMPLATE = "dev/fixtures/alpine.yaml"

error FixtureError = CommandFailed(command: Str, detail: Str) | MissingSshOption(option: Str) | MissingFixture(name: Str) | Failed(check: Str, detail: Str)

type GuestSsh = {
  name: Str,
  config: Path,
  host: Str,
  port: Str,
  known_hosts: Path,
  user: Str,
  key: Path,
  fingerprint: Str,
}

proc repo_root() [process, error] -> Result[Path, Error] {
  let script = process.script_path()?
  let absolute = path.absolute(script)?
  absolute.parent().parent()
}

proc lima_home(root: Path) [env, error] -> Result[Path, Error] {
  let configured = env.get_or("LIMA_HOME", "")?.trim()
  return fp"{configured}" when configured != ""
  fp"{root}/.work/fixtures/lima"
}

proc run_checked(argv: List[Str]) [process, error, io] -> Result[Str, Error] {
  let result = run.capture --text @argv
  if ! result.status.ok {
    let detail = result.stderr.trim()
    return Err(
      FixtureError.CommandFailed(
        command: argv.join(" "),
        detail: if detail == "" { f"exit {result.status.exit_code()?}" } else { detail },
      ),
    )
  }

  result.stdout
}

proc guest_state(name: Str) [process, error, io] -> Result[Str, Error] {
  let listed = run_checked(["limactl", "list", "--format", "{{.Name}} {{.Status}}"])?
  for line in listed.lines() {
    let fields = line.fields()
    if fields.len() >= 2 and fields[0] == name {
      return fields[1]
    }
  }

  "absent"
}

proc ensure_guest(root: Path, name: Str) [fs, process, env, error, io] -> Result[Unit, Error] {
  let template_path = fp"{root}/{TEMPLATE}"
  let state = guest_state(name)?
  if state == "absent" {
    let _ = run_checked(["limactl", "start", "--tty=false", "--name", name, template_path.display()])?
  } else if state != "Running" {
    let _ = run_checked(["limactl", "start", "--tty=false", name])?
  }

  Ok()
}

proc ensure_running(root: Path, name: Str) [fs, process, env, error, io] -> Result[Unit, Error] {
  let state = guest_state(name)?
  if state == "absent" {
    return Err(FixtureError.MissingFixture(name:))
  }

  let host_key = fp"{root}/.work/fixtures/host_keys/{name}.pub"
  if state != "Running" {
    let _ = run_checked(["limactl", "start", "--tty=false", name])?
    let _ = capture_host_key(root, name)?
  } else if ! host_key.exists() {
    let _ = capture_host_key(root, name)?
  }

  Ok()
}

proc ensure_key(root: Path) [fs, process, error, io] -> Result[Path, Error] {
  let key = fp"{root}/.work/fixtures/keys/{FIXTURE_USER}"
  let public = fp"{key}.pub"
  fp"{root}/.work/fixtures/keys".mkdir(parents: true)?
  if ! key.exists() {
    let _ = run_checked([
      "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "xinfra-fixture", "-f", key.display(),
    ])?
  }

  if ! public.exists() {
    let derived = run_checked(["ssh-keygen", "-y", "-f", key.display()])?
    public.write(derived.trim() + "\n")?
  }

  key.chmod(0o600)?
  public.chmod(0o644)?
  key
}

proc provision_script() -> Str {
  """
#!/bin/sh
set -eu
apk add --no-cache openssh sudo doas
if ! id xinfra >/dev/null 2>&1; then
  adduser -D -s /bin/sh xinfra
fi
mkdir -p /home/xinfra/.ssh
cp /tmp/xinfra.pub /home/xinfra/.ssh/authorized_keys
chown -R xinfra:xinfra /home/xinfra/.ssh
chmod 700 /home/xinfra/.ssh
chmod 600 /home/xinfra/.ssh/authorized_keys
mkdir -p /etc/sudoers.d
echo 'xinfra ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/xinfra
chmod 440 /etc/sudoers.d/xinfra
echo 'permit nopass xinfra as root' > /etc/doas.conf
chmod 600 /etc/doas.conf
if [ -d /etc/doas.d ]; then
  echo 'permit nopass xinfra as root' > /etc/doas.d/xinfra.conf
  chmod 600 /etc/doas.d/xinfra.conf
fi
if ! grep -q '^RekeyLimit ' /etc/ssh/sshd_config; then
  echo 'RekeyLimit 1M' >> /etc/ssh/sshd_config
fi
rc-service sshd reload >/dev/null 2>&1 || true
"""
}

proc provision(root: Path, name: Str) [fs, process, env, error, io] -> Result[Unit, Error] {
  let key = ensure_key(root)?
  let public = fp"{key}.pub"
  let script = fp"{root}/.work/fixtures/provision.sh"
  script.write(provision_script())?
  let _ = run_checked([
    "limactl", "copy", "--backend=scp", script.display(), f"{name}:/tmp/xinfra-provision.sh",
  ])?
  let _ = run_checked(["limactl", "copy", "--backend=scp", public.display(), f"{name}:/tmp/xinfra.pub"])?
  let _ = run_checked(["limactl", "shell", "--tty=false", name, "sudo", "sh", "/tmp/xinfra-provision.sh"])?
  Ok()
}

proc ssh_option(config: Path, alias: Str, option: Str) [process, error, io] -> Result[Str, Error] {
  let resolved = run.capture --text ssh -G -F $config $alias
  if ! resolved.status.ok {
    return Err(FixtureError.CommandFailed(command: f"ssh -G -F {config} {alias}", detail: resolved.stderr.trim()))
  }

  for line in resolved.stdout.lines() {
    let fields = line.fields()
    if fields.len() >= 2 and fields[0] == option {
      return fields[1]
    }
  }

  return Err(FixtureError.MissingSshOption(option:))
}

proc host_fingerprint(public_key: Path) [fs, process, error, io] -> Result[Str, Error] {
  if ! public_key.exists() {
    return Err(FixtureError.Failed(check: "host key", detail: f"missing {public_key}"))
  }

  let listed = run.capture --text ssh-keygen -lf $public_key
  if ! listed.status.ok {
    return Err(FixtureError.CommandFailed(command: f"ssh-keygen -lf {public_key}", detail: listed.stderr.trim()))
  }

  for line in listed.stdout.lines() {
    let fields = line.fields()
    if fields.len() >= 2 and fields[1].starts_with("SHA256:") {
      return fields[1]
    }
  }

  return Err(FixtureError.Failed(check: "host key", detail: f"no SHA256 fingerprint in {public_key}"))
}

proc capture_host_key(root: Path, name: Str) [fs, process, env, error, io] -> Result[Unit, Error] {
  let home = lima_home(root)?
  let config = fp"{home}/{name}/ssh.config"
  if ! config.exists() {
    return Err(FixtureError.MissingFixture(name:))
  }

  let host = ssh_option(config, f"lima-{name}", "hostname")?
  let port = ssh_option(config, f"lima-{name}", "port")?
  let public = run_checked([
    "limactl", "shell", "--tty=false", name, "sudo", "cat", "/etc/ssh/ssh_host_ed25519_key.pub",
  ])?.trim()
  let directory = fp"{root}/.work/fixtures/host_keys"
  directory.mkdir(parents: true)?
  let public_key = fp"{directory}/{name}.pub"
  public_key.write(public + "\n")?
  fp"{directory}/{name}.known_hosts".write(f"[{host}]:{port} {public}\n")?
  Ok()
}

proc guest_ssh(root: Path, name: Str) [fs, process, env, error, io] -> Result[GuestSsh, Error] {
  let home = lima_home(root)?
  let config = fp"{home}/{name}/ssh.config"
  if ! config.exists() {
    return Err(FixtureError.MissingFixture(name:))
  }

  let alias = f"lima-{name}"
  let host = ssh_option(config, alias, "hostname")?
  let port = ssh_option(config, alias, "port")?
  let known_hosts = fp"{root}/.work/fixtures/host_keys/{name}.known_hosts"
  let key = fp"{root}/.work/fixtures/keys/{FIXTURE_USER}"
  let fingerprint = host_fingerprint(fp"{root}/.work/fixtures/host_keys/{name}.pub")?
  GuestSsh(
    name: name,
    config: config,
    host: host,
    port: port,
    known_hosts: known_hosts,
    user: FIXTURE_USER,
    key: key,
    fingerprint: fingerprint,
  )
}

proc ssh_run(target: GuestSsh, script: Str) [process, error, io] -> Result[Str, Error] {
  run_checked([
    "ssh",
    "-F",
    target.config.display(),
    "-p",
    target.port,
    "-l",
    target.user,
    "-i",
    target.key.display(),
    "-o",
    "IdentitiesOnly=yes",
    "-o",
    "BatchMode=yes",
    "-o",
    f"UserKnownHostsFile={target.known_hosts}",
    "-o",
    "StrictHostKeyChecking=yes",
    target.host,
    script,
  ])
}

proc verify_script(role: Str) -> Str {
  let escalation = if role == "sudo" {
    "sudo -n true 2>/dev/null && escalation=yes || escalation=no"
  } else {
    "doas -n true 2>/dev/null && escalation=yes || escalation=no"
  }
  """
set -u
__ESCALATION__
alpine="$(cat /etc/alpine-release 2>/dev/null || true)"
openrc="$(rc-status --version 2>&1 | head -n 1 || true)"
apk="$(apk --version 2>&1 | head -n 1 || true)"
openssh="$(ssh -V 2>&1 | head -n 1 || true)"
stat_ok=no
[ -n "$(stat -c '%a' / 2>/dev/null)" ] && stat_ok=yes
scratch="$(mktemp -d 2>/dev/null || true)"
mv_ok=no
if [ -n "$scratch" ]; then
  : > "$scratch/src"
  : > "$scratch/dst"
  mv -T "$scratch/src" "$scratch/dst" 2>/dev/null && mv_ok=yes
  rm -rf "$scratch"
fi
printf 'alpine=%s\n' "$alpine"
printf 'openrc=%s\n' "$openrc"
printf 'apk=%s\n' "$apk"
printf 'openssh=%s\n' "$openssh"
printf 'stat=%s\n' "$stat_ok"
printf 'mv_t=%s\n' "$mv_ok"
printf 'escalation=%s\n' "$escalation"
""".replace("__ESCALATION__", with: escalation)
}

proc line_value(output: Str, key: Str) -> Str? {
  for line in output.lines() {
    let parts = line.split("=", maxsplit: 1)
    if parts.len() == 2 and parts[0] == key {
      return parts[1]
    }
  }

  null
}

proc check_value(output: Str, key: Str, expected: Str) -> Result[Unit, Error] {
  let actual = line_value(output, key)
  if actual == null {
    return Err(FixtureError.Failed(check: key, detail: "missing"))
  }

  return Ok() when actual == expected
  Err(FixtureError.Failed(check: key, detail: f"expected {expected}, found {actual}"))
}

proc check_contains(output: Str, key: Str, needle: Str) -> Result[Unit, Error] {
  let actual = line_value(output, key)
  if actual == null {
    return Err(FixtureError.Failed(check: key, detail: "missing"))
  }

  return Ok() when needle in actual
  Err(FixtureError.Failed(check: key, detail: f"expected {needle}, found {actual}"))
}

proc verify_guest(root: Path, name: Str) [fs, process, env, error, io] -> Result[Unit, Error] {
  let target = guest_ssh(root, name)?
  let role = if name == "xinfra-a" { "sudo" } else { "doas" }
  let output = ssh_run(target, verify_script(role))?
  var failures = []
  let checks = [
    f"{name}:alpine",
    f"{name}:openrc",
    f"{name}:apk",
    f"{name}:openssh",
    f"{name}:stat -c",
    f"{name}:mv -T",
    f"{name}:{role}",
  ]
  let outcomes = [
    check_value(output, "alpine", "3.23.4"),
    check_contains(output, "openrc", "OpenRC"),
    check_contains(output, "apk", "apk-tools"),
    check_contains(output, "openssh", "OpenSSH"),
    check_value(output, "stat", "yes"),
    check_value(output, "mv_t", "yes"),
    check_value(output, "escalation", "yes"),
  ]
  for index, outcome in outcomes {
    match outcome {
      Ok(_) => print f"ok   {checks[index]}",
      Err(error) => {
        failures += [f"{checks[index]}: {error.message}"]
        print f"FAIL {checks[index]}: {error.message}"
      }
    }
  }

  return Ok() when failures.is_empty()
  Err(FixtureError.Failed(check: name, detail: failures.join("; ")))
}

## Create or start both disposable fixtures and install the fixture user.
cli main up() [fs, process, env, error, io] {
  let root = repo_root()?
  let home = lima_home(root)?
  home.mkdir(parents: true)?
  let _ = ensure_key(root)?
  env LIMA_HOME=$home {
    for name in FIXTURES {
      let state = guest_state(name)?
      print f"fixture {name}: {state}"
      ensure_guest(root, name)?
      let _ = capture_host_key(root, name)?
      provision(root, name)?
      print f"fixture {name}: ready"
    }
  }
}

## Check Alpine, OpenRC, apk, OpenSSH, stat, mv -T, and passwordless escalation.
cli main verify() [fs, process, env, error, io] {
  let root = repo_root()?
  let home = lima_home(root)?
  env LIMA_HOME=$home {
    var failures = []
    for name in FIXTURES {
      ensure_running(root, name)?
      match verify_guest(root, name) {
        Ok(_) => {}
        Err(error) => failures += [error.message]
      }
    }

    if ! failures.is_empty() {
      fail f"fixture verification failed: {failures.join("; ")}"
    }
  }

  print "fixtures: ok"
}

## Run a command on the controller with fixture connection metadata in its environment.
cli main exec(cwd: Path = p".", ...command: List[Str]) [fs, process, env, error, io] {
  if command.is_empty() {
    fail "exec requires a command after --"
  }

  let root = repo_root()?
  let home = lima_home(root)?
  let pyinfra = env.get("XINFRA_PYINFRA") ?? f"{root}/.work/oracle/venv/bin/pyinfra"
  env LIMA_HOME=$home {
    for name in FIXTURES {
      ensure_running(root, name)?
    }

    let a = guest_ssh(root, "xinfra-a")?
    let b = guest_ssh(root, "xinfra-b")?
    let executable = if "/" in command[0] {
      if command[0].starts_with("/") { fp"{command[0]}" } else { fp"{cwd}/{command[0]}" }
    } else {
      process.which(command[0])?
    }
    let status = process.run(
      process.command_argv(
        executable,
        command,
        cwd: cwd,
        env: {
          XINFRA_FIXTURE_A_HOST: a.host,
          XINFRA_FIXTURE_A_PORT: a.port,
          XINFRA_FIXTURE_A_HOST_KEY: a.fingerprint,
          XINFRA_FIXTURE_A_SSH_CONFIG: a.config.display(),
          XINFRA_FIXTURE_B_HOST: b.host,
          XINFRA_FIXTURE_B_PORT: b.port,
          XINFRA_FIXTURE_B_HOST_KEY: b.fingerprint,
          XINFRA_FIXTURE_B_SSH_CONFIG: b.config.display(),
          XINFRA_FIXTURE_USER: FIXTURE_USER,
          XINFRA_FIXTURE_KEY: a.key.display(),
          XINFRA_PYINFRA: pyinfra,
        },
      ),
    )?
    if status.exited() {
      exit status.exit_code()?
    }

    exit 130
  }
}

## Delete every xinfra-* fixture in this LIMA_HOME.
cli main down() [process, env, error, io] {
  let root = repo_root()?
  let home = lima_home(root)?
  env LIMA_HOME=$home {
    let listed = run_checked(["limactl", "list", "--quiet"])?
    for name in listed.lines() {
      let fixture = name.trim()
      if fixture.starts_with("xinfra-") {
        let _ = run_checked(["limactl", "delete", "--force", fixture])?
        print f"deleted {fixture}"
      }
    }
  }
}

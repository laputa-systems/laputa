##! Differential check against pyinfra on separate disposable hosts. pyinfra
##! runs in an isolated container and never ships. `diff` applies the
##! equivalent deployments with pyinfra to a fresh Alpine container and with
##! xsh-infra to an already running fixture host, stage by stage, and compares
##! the resulting state, whether each run changed anything, and whether it
##! succeeded. Scenarios: files, packages, services, commands, failures, all.
##! Requires `fixtures/alpine.xsh up` first.

const image = "xinfra-pyinfra:dev"
type State = {containers: List[Str]}

type Stage = {name: Str, deploy: Str, before: Str}
type Scenario = {name: Str, reset: Str, probe: Str, stages: List[Stage]}
type Run = {ok: Bool, changed: Bool}

const files_probe = "stat -c '%a %U %G %F' /var/tmp/pi/dir /var/tmp/pi/dir/motd; cat /var/tmp/pi/dir/motd; readlink /var/tmp/pi/dir/current; getent group pig; getent passwd piu; ls -A /var/tmp/pi/dir; id -Gn piu"
const packages_probe = "for p in jq tree; do apk info -e $p || echo absent-$p; done"
const services_probe = "rc-service xinfradiff status 2>&1; ls /etc/runlevels/default | grep -x xinfradiff; stat -c '%a %U %G' /etc/init.d/xinfradiff"
const commands_probe = "ls -A /var/tmp/pi; wc -l < /var/tmp/pi/creates.log; wc -l < /var/tmp/pi/always.log"
const failures_probe = "ls -A /var/tmp/pi"
const cleanup_pi = "rm -rf /var/tmp/pi"

pure scenario_of(name: Str) -> Result[Scenario, Error] {
  match name {
    "files" => Ok(Scenario(name:, reset: "deluser piu >/dev/null 2>&1; delgroup pig >/dev/null 2>&1; rm -rf /var/tmp/pi /home/piu", probe: files_probe, stages: [
      Stage(name: "first", deploy: "files-converge", before: ""),
      Stage(name: "second", deploy: "files-converge", before: ""),
    ]))
    "packages" => Ok(Scenario(name:, reset: "apk del -q jq tree >/dev/null 2>&1; true", probe: packages_probe, stages: [
      Stage(name: "install", deploy: "packages-install", before: ""),
      Stage(name: "again", deploy: "packages-install", before: ""),
      Stage(name: "drift", deploy: "packages-install", before: "apk del -q jq"),
      Stage(name: "remove", deploy: "packages-remove", before: ""),
    ]))
    "services" => Ok(Scenario(name:, reset: "rc-service xinfradiff stop >/dev/null 2>&1; rc-update del xinfradiff default >/dev/null 2>&1; rm -f /etc/init.d/xinfradiff /run/xinfradiff.pid; true", probe: services_probe, stages: [
      Stage(name: "up", deploy: "services-up", before: ""),
      Stage(name: "again", deploy: "services-up", before: ""),
      Stage(name: "drift", deploy: "services-up", before: "rc-service xinfradiff stop"),
      Stage(name: "down", deploy: "services-down", before: ""),
    ]))
    "commands" => Ok(Scenario(name:, reset: cleanup_pi, probe: commands_probe, stages: [
      Stage(name: "run", deploy: "commands-run", before: ""),
      Stage(name: "again", deploy: "commands-run", before: ""),
    ]))
    "failures" => Ok(Scenario(name:, reset: cleanup_pi, probe: failures_probe, stages: [
      Stage(name: "broken", deploy: "failures-broken", before: ""),
      Stage(name: "fixed", deploy: "failures-fixed", before: ""),
      Stage(name: "again", deploy: "failures-fixed", before: ""),
    ]))
    else => fail f"unknown scenario {name}"
  }
}

proc docker_text(...argv: List[Str]) [process, error] -> Result[Str] {
  let out = run.text docker @argv
  Ok(out.trim())
}

proc address_of(container: Str) [process, error] -> Result[Str] {
  docker_text("inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", container)
}

pure count_of(output: Str, needle: Str) -> Int {
  output.lines() |> where { |line| needle in line } |> count()
}

proc pyinfra_run(address: Str, work: Path, deploy: Str, key: Str = "client", port: Int = 22) [process, error] -> Result[Run] {
  let mount = f"{work}:/work"
  let script = f"/work/{deploy}.py"
  let keyfile = f"/work/{key}"
  let out = run.capture --text docker run --rm -v $mount $image pyinfra $address $script --user root --port $port --key $keyfile --data ssh_known_hosts_file=/dev/null --data ssh_strict_host_key_checking=no -y
  let output = f"{out.stdout}\n{out.stderr}"
  Ok(Run(ok: out.status.ok, changed: count_of(output, "] Success") > 0))
}

proc xinfra_run(inventory: Path, deploy: Str, host: Str) [process, error] -> Result[Run] {
  let program = f"fixtures/pyinfra/{deploy}.xsh"
  let out = run.capture --text xsh bin/xinfra.xsh apply $inventory $program --limit $host
  let changed = out.stdout.lines() |> where { |line| line.starts_with("apply:") and ! (", 0 changed," in line) } |> count()
  Ok(Run(ok: out.status.ok, changed: changed > 0))
}

proc probe_of(container: Str, script: Str) [process, error] -> Result[Str] {
  let out = run.capture --text docker exec $container sh -c $script
  Ok(f"{out.stdout}")
}

proc fixture_container(inventory: Path, host: Str) [fs, error] -> Result[Str] {
  let state = json.read(fp"{inventory.parent()}/containers.json")?.require(State)?
  let index = host.replace("fx-", with: "").parse_int()? - 1
  Ok(state.containers[index])
}

proc compare_scenario(scenario: Scenario, inventory: Path, host: Str, work: Path, target: Str, address: Str, container: Str) [fs, process, error] -> Result[Bool] {
  var agreed = true
  let reset = scenario.reset
  run docker exec $target sh -c $reset
  run docker exec $container sh -c $reset
  for stage in scenario.stages {
    if stage.before != "" {
      let before = stage.before
      run docker exec $target sh -c $before
      run docker exec $container sh -c $before
    }

    let theirs = pyinfra_run(address, work, stage.deploy)?
    let ours = xinfra_run(inventory, stage.deploy, host)?
    let same = theirs == ours
    if ! same {
      agreed = false
    }

    print f"{scenario.name}/{stage.name}: pyinfra ok={theirs.ok} changed={theirs.changed}; xsh-infra ok={ours.ok} changed={ours.changed}{if same { "" } else { "  DIFFERENT" }}"
    let state_theirs = probe_of(target, scenario.probe)?
    let state_ours = probe_of(container, scenario.probe)?
    let comparable = state_ours.replace("pig:x:4401:piu", with: "pig:x:4401:")
    if state_theirs != comparable {
      agreed = false
      print f"{scenario.name}/{stage.name}: states differ\npyinfra:\n{state_theirs}\nxsh-infra:\n{state_ours}"
    }
  }

  Ok(agreed)
}

proc compare_unreachable(inventory: Path, host: Str, work: Path, target: Str, address: Str) [fs, process, error] -> Result[Bool] {
  let stranger = fp"{work}/stranger"
  stranger.remove(missing_ok: true)
  fp"{work}/stranger.pub".remove(missing_ok: true)
  run ssh-keygen -q -t ed25519 -N "" -f $stranger
  let theirs_refused = pyinfra_run("127.0.0.1", work, "failures-fixed", port: 1)?
  let theirs_denied = pyinfra_run(address, work, "failures-fixed", key: "stranger")?
  let table = f"[defaults]\nuser = \"root\"\nprivilege = \"root\"\nkey = \"stranger\"\ntimeout_ms = 3000\n[hosts.refused]\naddress = \"127.0.0.1\"\nport = 1\nhost_key = \"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"\n"
  let ours_inventory = fp"{work}/unreachable.toml"
  ours_inventory.write(table)
  let ours_refused = xinfra_run(ours_inventory, "failures-fixed", "refused")?
  let denied_inventory = fp"{work}/denied.toml"
  let pub = fp"{work}/host_ed25519.pub"
  let pin = run.text ssh-keygen -lf $pub
  denied_inventory.write(f"[defaults]\nuser = \"root\"\nprivilege = \"root\"\nkey = \"stranger\"\ntimeout_ms = 3000\n[hosts.denied]\naddress = \"{address}\"\nhost_key = \"{pin.fields()[1]}\"\n")
  let ours_denied = xinfra_run(denied_inventory, "failures-fixed", "denied")?
  print f"unreachable: pyinfra ok={theirs_refused.ok}; xsh-infra ok={ours_refused.ok}"
  print f"auth failure: pyinfra ok={theirs_denied.ok}; xsh-infra ok={ours_denied.ok}"
  Ok(! theirs_refused.ok and ! ours_refused.ok and ! theirs_denied.ok and ! ours_denied.ok)
}

## Build the pyinfra image.
cli main build() [process, error] {
  run docker build -q -t $image fixtures/pyinfra
}

## Compare pyinfra's results with xsh-infra's for SCENARIO on fixture host HOST.
cli main diff(scenario: Str = "all", inventory: Path = p".work/fixtures/inventory.toml", host: Str = "fx-2", dir: Path = p".work/pyinfra") [fs, process, time, error] {
  let names = if scenario == "all" { ["files", "packages", "services", "commands", "failures"] } else { [scenario] }
  var chosen: List[Scenario] = []
  for name in names {
    chosen += [scenario_of(name)?]
  }

  dir.mkdir(parents: true)
  let client = fp"{inventory.parent()}/client"
  let work = dir.resolve()?
  fp"{work}/client".write(client.read_bytes()?)
  fp"{work}/client".chmod(0o600)
  fp"{work}/motd".write("hello\n")
  for source in fs.children(p"fixtures/pyinfra")? {
    if source.name.ends_with(".py") or source.name == "xinfradiff" {
      fp"{work}/{source.name}".write(fp"fixtures/pyinfra/{source.name}".read_bytes()?)
    }
  }

  let host_key = fp"{work}/host_ed25519"
  host_key.remove(missing_ok: true)
  fp"{work}/host_ed25519.pub".remove(missing_ok: true)
  run ssh-keygen -q -t ed25519 -N "" -f $host_key -C pyinfra-target
  let target = docker_text(
    "run", "-d", "--rm", "--label", "xinfra-fixture=pyinfra",
    "-v", f"{work}/host_ed25519:/fixture/host_ed25519:ro",
    "-v", f"{client.resolve()?}.pub:/fixture/client.pub:ro",
    "xinfra-fixture:alpine-3.22",
  )?
  defer { run.status docker rm -f $target }
  time.sleep(2s)
  run docker exec $target sh -c "apk add -q openssh-sftp-server; echo 'Subsystem sftp /usr/lib/ssh/sftp-server' >> /etc/ssh/sshd_config; kill -HUP 1"
  time.sleep(1s)
  let address = address_of(target)?
  let container = fixture_container(inventory, host)?
  var agreed = true
  for item in chosen {
    if ! compare_scenario(item, inventory, host, work, target, address, container)? {
      agreed = false
    }

    if item.name == "failures" and ! compare_unreachable(inventory, host, work, target, address)? {
      agreed = false
    }
  }

  if agreed {
    print "pyinfra and xsh-infra agree"
  } else {
    fail "pyinfra and xsh-infra disagree"
  }
}

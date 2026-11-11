##! Disposable Alpine hosts behind a real OpenSSH server, one container each.
##! `up` writes an inventory and `down` removes exactly the containers `up`
##! started. Containers are reached on their bridge address; nothing is
##! published on the host network.

const image = "xinfra-fixture:alpine-3.22"
const label = "xinfra-fixture"

type State = {containers: List[Str]}

proc docker_text(...argv: List[Str]) [process, error] -> Result[Str] {
  let out = run.text docker @argv
  Ok(out.trim())
}

proc fingerprint(pub: Path) [process, error] -> Result[Str] {
  let line = run.text ssh-keygen -lf $pub
  Ok(line.fields()[1])
}

proc wait_for_sshd(container: Str) [process, time, error] -> Result[Unit] {
  for _ in range(50) {
    let status = run.status docker exec $container nc -z 127.0.0.1 22
    if status.ok {
      return
    }

    time.sleep(200ms)
  }

  fail f"sshd in {container} did not start"
}

proc keygen(file: Path) [process, error] {
  run ssh-keygen -q -t ed25519 -N "" -f $file
}

## Build the fixture image.
cli main build() [process, error] {
  run docker build -t $image fixtures/alpine
}

## Start COUNT hosts and write DIR/inventory.toml.
cli main up(count: UInt = 2, dir: Path = p".work/fixtures") [fs, process, time, error] {
  guard count >= 1 and count <= 8 else {
    fail "count must be 1..8"
  }

  let run_id = f"{time.now()}"
  fp"{dir}".mkdir(parents: true)
  let client = fp"{dir}/client"
  if ! fp"{client}".exists()? {
    keygen(client)?
  }

  var lines = [
    "[defaults]",
    "user = \"deploy\"",
    "privilege = \"doas\"",
    "key = \"client\"",
    "timeout_ms = 10000",
    "",
  ]
  var ids: List[Str] = []
  for index in range(1, count + 1) {
    let host_key = fp"{dir}/host-{run_id}-{index}"
    keygen(host_key)?
    let pin = fingerprint(fp"{host_key}.pub")?
    let name = f"xinfra-fx-{run_id}-{index}"
    let container = docker_text(
      "run", "-d", "--rm", "--name", name, "--label", f"{label}={run_id}",
      "-v", f"{host_key.resolve()?}:/fixture/host_ed25519:ro",
      "-v", f"{client.resolve()?}.pub:/fixture/client.pub:ro",
      image,
    )?
    ids += [container]
    wait_for_sshd(container)?
    let address = docker_text("inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", container)?
    lines += [
      f"[hosts.fx-{index}]",
      f"address = \"{address}\"",
      f"host_key = \"{pin}\"",
      "",
      f"[hosts.fx-{index}-root]",
      f"address = \"{address}\"",
      "user = \"root\"",
      "privilege = \"root\"",
      f"host_key = \"{pin}\"",
      "",
      f"[hosts.fx-{index}-plain]",
      f"address = \"{address}\"",
      "user = \"plain\"",
      "privilege = \"doas\"",
      f"host_key = \"{pin}\"",
      "",
    ]
  }

  fp"{dir}/inventory.toml".write(lines.join("\n") + "\n")
  json.write(fp"{dir}/containers.json", {containers: ids})?
  print f"started {ids.len()} host(s); inventory at {dir}/inventory.toml"
}

## Remove the containers recorded in DIR/containers.json.
cli main down(dir: Path = p".work/fixtures") [fs, process, error] {
  let record = fp"{dir}/containers.json"
  if ! record.exists()? {
    return
  }

  let state = json.read(record)?.require(State)?
  for container in state.containers {
    run.status docker rm -f $container
  }

  record.remove()
  print f"removed {state.containers.len()} host(s)"
}

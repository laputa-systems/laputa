proc fixture(name: Str) -> Path {
  fp"tests/pm/fixtures/trust-update/{name}"
}

proc wait_for_port(port_file: Path, attempts: Int) [fs, time, error] -> Result[Int, Error] {
  var tries = 0
  while tries < attempts {
    if port_file.exists()? {
      let text = port_file.read_text()?.trim()
      if text != "" {
        return text.parse_int_decimal()
      }
    }

    time.sleep(100ms)?
    tries += 1
  }

  test.fail("fixture server did not publish its port")
  0
}

type ConsumerServer = {port: Int, pid: Int, handle: ProcessHandle}

proc serve_chain(ctx: TestContext, name: Str, python: Str, chain: Str, key: Str) [fs, process, env, time, error] -> Result[ConsumerServer, Error] {
  let dir = test.temp_dir(ctx, name:)?
  let routes = fp"{dir}/routes"
  routes.mkdir()
  fp"{routes}/hello".write(bytes.from_text("hello\n"))?
  let port_file = fp"{dir}/port"
  let script = fixture("tls_server.py")
  let child = spawn run $python $script $chain $key $port_file $routes ?
  {port: wait_for_port(port_file, 100)?, pid: child.pid, handle: child}
}

proc stop_server(server: ConsumerServer) [process, error] {
  match process.kill(server.pid, signal: "KILL") {
    Ok(_) => {},
    Err(_) => {}
  }

  match process.wait_any([server.handle]) {
    Ok(_) => {},
    Err(_) => {}
  }
}

proc python_or_skip() [process, error] -> Result[Str, Error] {
  match process.which("python3") {
    Ok(found) => found.display(),
    Err(_) => {
      test.skip("python3 is unavailable for the fixture TLS server")
      ""
    }
  }
}

proc run_client(ctx: TestContext, name: Str, port: Int, root: Str, verify: Str, expected: Str, with_policy: Bool) [fs, process, env, error] {
  let xsh = (e"XSH_HOST" ?? "").trim()
  assert xsh != "", "XSH_HOST must name the shipped static XSH binary"
  let binary = path.absolute(fp"{xsh}")?
  let fixtures = path.absolute(fixture(""))?
  let script = path.absolute(p"guest/trust-policy-client.xsh")?
  let policy = path.absolute(fixture("release-c/trust-policy"))?
  let output = test.temp_path(ctx, name: f"trust-policy-{name}.log")
  var argv = [
    "docker", "run", "--rm", "--pull=never", "--network", "host",
    "--mount", f"type=bind,src={binary.display()},dst=/xsh,readonly",
    "--mount", f"type=bind,src={fixtures.display()},dst=/fixtures,readonly",
    "--mount", f"type=bind,src={script.display()},dst=/client.xsh,readonly",
  ]
  if with_policy {
    argv += ["--mount", f"type=bind,src={policy.display()},dst=/etc/laputa/trust-policy,readonly"]
  }
  argv += [
    "--entrypoint", "/xsh", "debian:stable-slim", "/client.xsh", "--",
    f"https://127.0.0.1:{port}/hello", root, verify, expected,
  ]
  let command = process.command_argv("docker", argv, p".", {PATH: "/usr/bin:/bin"}, stdout: output, stderr: output, timeout: 30s)
  let status = process.run(command)?
  assert status.ok, output.read_text()?
}

test xsh_enforces_intermediate_policy_across_cross_signed_chains [fs, process, env, time, error] { |ctx|
  let python = python_or_skip()?
  let control = serve_chain(ctx, "xsh-policy-control", python, fixture("tls/chain-control.pem").display(), fixture("tls/ee-control.key").display())?
  defer stop_server(control)
  run_client(ctx, "control", control.port, "cross-r1", "verify", "accept", true)?
  for entry in [["cross-r1", "cross-r1"], ["cross-r2", "cross-r2"]] {
    let server = serve_chain(ctx, f"xsh-policy-{entry[0]}", python, fixture(f"tls/chain-{entry[0]}.pem").display(), fixture("tls/ee-cross.key").display())?
    defer stop_server(server)
    run_client(ctx, f"{entry[0]}-baseline", server.port, entry[1], "verify", "accept", false)?
    run_client(ctx, entry[0], server.port, entry[1], "verify", "reject", true)?
    run_client(ctx, f"{entry[0]}-disabled", server.port, entry[1], "disabled", "reject", true)?
  }
}

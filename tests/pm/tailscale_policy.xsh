proc fixture(name: Str) -> Path {
  fp"tests/pm/fixtures/trust-update/{name}"
}

proc wait_for_port(port_file: Path) [fs, time, error] -> Result[Int, Error] {
  var attempts = 0
  while attempts < 100 {
    if port_file.exists()? {
      let text = port_file.read_text()?.trim()
      if text != "" { return text.parse_int_decimal() }
    }
    time.sleep(100ms)?
    attempts += 1
  }
  test.fail("fixture server did not publish its port")
  0
}

proc stop_server(child: ProcessHandle) [process, error] {
  child.cancel(signal: "TERM", kill_after: 5s)
}

proc verify_connection(ctx: TestContext, root: Path, chain: Str, key: Str, trust: Str, expected: Str) [fs, process, env, time, error] {
  let dir = test.temp_dir(ctx, name: f"tailscale-policy-{chain}-{trust}")?
  let port_file = fp"{dir}/port"
  let routes = fp"{dir}/routes"
  routes.mkdir()?
  let server = spawn run "python3" fixture("tls_server.py") fixture(f"tls/chain-{chain}.pem") fixture(f"tls/{key}.key") $port_file $routes ?
  defer stop_server(server)
  let port = wait_for_port(port_file)?
  let fixtures = path.absolute(fixture(""))?
  let xsh = path.absolute(fp"{e"XSH_HOST" ?? ""}")?
  let policy = fp"{fixtures}/release-c/trust-policy"
  let work = fp"{dir}/container"
  work.mkdir()?
  let out = fp"{dir}/client.log"
  let argv = [
    "docker", "run", "--rm", "--pull=never", "--network", "host",
    "--mount", f"type=bind,src={xsh},dst=/xsh,readonly",
    "--mount", f"type=bind,src={root},dst=/package,readonly",
    "--mount", f"type=bind,src={fixtures},dst=/fixtures,readonly",
    "--mount", f"type=bind,src={policy},dst=/etc/laputa/trust-policy,readonly",
    "--mount", f"type=bind,src={work},dst=/work",
    "--entrypoint", "/xsh", "debian:stable-slim", "/fixtures/tailscale-policy-client.xsh", "--", f"{port}", trust, expected,
  ]
  let result = process.run(process.command_argv("docker", argv, p".", {PATH: "/usr/bin:/bin"}, stdout: out, stderr: out, timeout: 30s))?
  assert result.ok, out.read_text()?
}

test tailscaled_enforces_intermediate_policy [fs, process, env, time, error] { |ctx|
  let configured = (e"LAPUTA_TAILSCALE_ROOT" ?? "").trim()
  if configured == "" { test.skip("LAPUTA_TAILSCALE_ROOT is not set") }
  let root = path.absolute(fp"{configured}")?
  verify_connection(ctx, root, "control", "ee-control", "cross-r1", "fetch control key: 404 Not Found")?
  verify_connection(ctx, root, "cross-r1", "ee-cross", "cross-r1", "certificate blocked by Laputa trust policy")?
  verify_connection(ctx, root, "cross-r2", "ee-cross", "cross-r2", "certificate blocked by Laputa trust policy")?
  verify_connection(ctx, root, "control", "ee-control", "cross-r2", "certificate signed by unknown authority")?
}

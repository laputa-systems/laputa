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

proc root_bundle(ctx: TestContext) [fs, error] -> Result[Path, Error] {
  let bundle = test.temp_path(ctx, name: "consumer-bundle.pem")
  bundle.write(fixture("tls/cross-r1.crt").read_bytes()?)
  bundle
}

proc uv_reaches_http(ctx: TestContext, uv: Path, bundle: Path, port: Int, label: Str) [fs, process, error] -> Result[Bool, Error] {
  let dir = test.temp_dir(ctx, name: f"uv-{label}")?
  let requirements = fp"{dir}/requirements.in"
  requirements.write(bytes.from_text("trust-consumer-fixture-package\n"))?
  let stderr = fp"{dir}/stderr"
  let command = process.command_argv(
    uv,
    [uv.display(), "pip", "compile", requirements.display(), "--no-cache", "--index-url", f"https://127.0.0.1:{port}/simple/"],
    dir,
    {SSL_CERT_FILE: bundle.display(), UV_NO_CONFIG: "1", HOME: dir.display(), PATH: "/usr/bin:/bin"},
    stderr:,
    timeout: 60s,
  )
  let _ = process.run(command)?
  let text = stderr.read_text()?
  if "invalid peer certificate" in text {
    return false
  }

  assert "unsatisfiable" in text, text
  true
}

proc packaged_root() [env, error] -> Result[Str, Error] {
  (e"LAPUTA_TRUST_CONSUMER_ROOT" ?? "").trim()
}

proc uv_or_skip() [env, process, error] -> Result[Path, Error] {
  let root = packaged_root()?
  return fp"{root}/usr/bin/uv" when root != ""

  match process.which("uv") {
    Ok(found) => found,
    Err(_) => {
      test.skip("uv is unavailable")
      p"/nonexistent"
    }
  }
}

test uv_accepts_control_and_blocked_intermediate_but_rejects_omitted_root [fs, process, env, time, error] { |ctx|
  let python = python_or_skip()?
  let uv = uv_or_skip()?
  let bundle = root_bundle(ctx)?
  var outcomes: List[Bool] = []

  for entry in [["control", "ee-control"], ["cross-r1", "ee-cross"], ["cross-r2", "ee-cross"]] {
    let server = serve_chain(ctx, f"uv-server-{entry[0]}", python, fixture(f"tls/chain-{entry[0]}.pem").display(), fixture(f"tls/{entry[1]}.key").display())?
    defer stop_server(server)
    outcomes += [uv_reaches_http(ctx, uv, bundle, server.port, entry[0])?]
  }

  assert outcomes == [true, true, false]
}

##! Outbound HTTPS behavior against fixture TLS servers with controlled trust.
##! The XSH client pins its trust snapshot per agent and fails closed on any
##! change until the client is recreated. Custom CA bundles are selected per
##! request; the host trust policy file is never touched by these tests.
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

type TrustFixtureServer = {port: Int, pid: Int, handle: ProcessHandle}

proc serve_fixture_tls(
  ctx: TestContext,
  name: Str,
  python: Str,
  chain: Str,
  key: Str,
  routes: Path,
  drip: Str,
  delay_ms: Str,
) [fs, process, env, time, error] -> Result[TrustFixtureServer, Error] {
  let dir = test.temp_dir(ctx, name: name)?
  let port_file = fp"{dir}/port"
  let script = fixture("tls_server.py")
  if drip != "" {
    let child = spawn run $python $script $chain $key $port_file $routes --drip $drip --delay-ms $delay_ms ?
    return {port: wait_for_port(port_file, 100)?, pid: child.pid, handle: child}
  }

  let child = spawn run $python $script $chain $key $port_file $routes ?
  {port: wait_for_port(port_file, 100)?, pid: child.pid, handle: child}
}

proc stop_fixture(server: TrustFixtureServer) [process, error] {
  match process.kill(server.pid, signal: "KILL") {
    Ok(_) => {},
    Err(_) => {}
  }

  match process.wait_any([server.handle]) {
    Ok(_) => {},
    Err(_) => {}
  }
}

proc fixture_routes(ctx: TestContext, name: Str, body: Str) [fs, error] -> Result[Path, Error] {
  let dir = test.temp_dir(ctx, name: name)?
  fp"{dir}/hello".write(bytes.from_text(body))?
  dir
}

type TrustTlsReply = {status: Int, body: Bytes}

proc https_get(url: Str, bundle: Path, pool: Str) [fs, net, time, error] -> Result[TrustTlsReply, Error] {
  let response = net.request({
    method: "GET",
    url,
    ca_certificate: bundle,
    pool,
    connect_timeout: 10s,
    timeout: 30s,
  })?
  {status: response.status.require(Int)?, body: response.body.require(Bytes)?}
}

test trust_tls_accepts_trusted_chain [fs, process, env, time, net, error] { |ctx|
  let python = match process.which("python3") {
    Ok(found) => found.display(),
    Err(_) => {
      test.skip("python3 is unavailable for the fixture TLS server")
      return
    },
  }

  let bundle = test.temp_path(ctx, name: "trust-tls-bundle.pem")
  bundle.write(fixture("tls/ca-a.crt").read_bytes()?)
  let _ = net.pool("trust-tls-accept", 4, 1s)?
  let routes = fixture_routes(ctx, "trust-tls-accept-routes", "hello fixture\n")?
  let server = serve_fixture_tls(ctx, "trust-tls-accept", python, fixture("tls/server-a.crt").display(), fixture("tls/server-a.key").display(), routes, "", "")?
  defer stop_fixture(server)?

  let url = f"https://127.0.0.1:{server.port}/hello"
  let response = https_get(url, bundle, "trust-tls-accept")?
  assert response.status == 200
  assert response.body.utf8()? == "hello fixture\n"
  net.close_pool("trust-tls-accept")?
}

test trust_tls_rejects_untrusted_chain [fs, process, env, time, net, error] { |ctx|
  let python = match process.which("python3") {
    Ok(found) => found.display(),
    Err(_) => {
      test.skip("python3 is unavailable for the fixture TLS server")
      return
    },
  }

  let bundle = test.temp_path(ctx, name: "trust-tls-reject-bundle.pem")
  bundle.write(fixture("tls/ca-b.crt").read_bytes()?)
  let _ = net.pool("trust-tls-reject", 4, 1s)?
  let routes = fixture_routes(ctx, "trust-tls-reject-routes", "hello fixture\n")?
  let server = serve_fixture_tls(ctx, "trust-tls-reject", python, fixture("tls/server-a.crt").display(), fixture("tls/server-a.key").display(), routes, "", "")?
  defer stop_fixture(server)?

  let url = f"https://127.0.0.1:{server.port}/hello"
  match https_get(url, bundle, "trust-tls-reject") {
    Ok(_) => test.fail("untrusted certificate chain was accepted"),
    Err(problem) => assert "certificate" in problem.message
  }

  net.close_pool("trust-tls-reject")?
}

test trust_tls_poisoned_client_requires_recreation [fs, process, env, time, net, error] { |ctx|
  let python = match process.which("python3") {
    Ok(found) => found.display(),
    Err(_) => {
      test.skip("python3 is unavailable for the fixture TLS server")
      return
    },
  }

  let bundle = test.temp_path(ctx, name: "trust-tls-poison-bundle.pem")
  bundle.write(fixture("tls/ca-a.crt").read_bytes()?)
  let _ = net.pool("trust-tls-poison", 4, 1s)?
  let routes = fixture_routes(ctx, "trust-tls-poison-routes", "hello fixture\n")?
  let server = serve_fixture_tls(ctx, "trust-tls-poison", python, fixture("tls/server-a.crt").display(), fixture("tls/server-a.key").display(), routes, "", "")?
  defer stop_fixture(server)?

  let url = f"https://127.0.0.1:{server.port}/hello"
  let first = https_get(url, bundle, "trust-tls-poison")?
  assert first.status == 200

  bundle.write(bytes.from_text(fixture("tls/ca-a.crt").read_text()? + fixture("tls/ca-b.crt").read_text()?))
  match https_get(url, bundle, "trust-tls-poison") {
    Ok(_) => test.fail("changed CA bundle was accepted without recreating the client"),
    Err(problem) => assert "changed" in problem.message
  }

  let _ = net.pool("trust-tls-poison-new", 4, 1s)?
  let second = https_get(url, bundle, "trust-tls-poison-new")?
  assert second.status == 200
  net.close_pool("trust-tls-poison")?
  net.close_pool("trust-tls-poison-new")?
}
test trust_tls_unrelated_chains_keep_working [fs, process, env, time, net, error] { |ctx|
  let python = match process.which("python3") {
    Ok(found) => found.display(),
    Err(_) => {
      test.skip("python3 is unavailable for the fixture TLS server")
      return
    },
  }

  let bundle = test.temp_path(ctx, name: "trust-tls-control-bundle.pem")
  bundle.write(fixture("tls/cross-r1.crt").read_bytes()?)
  let _ = net.pool("trust-tls-control", 4, 1s)?
  let routes = fixture_routes(ctx, "trust-tls-control-routes", "hello fixture\n")?
  let server = serve_fixture_tls(ctx, "trust-tls-control", python, fixture("tls/chain-control.pem").display(), fixture("tls/ee-control.key").display(), routes, "", "")?
  defer stop_fixture(server)?

  let url = f"https://127.0.0.1:{server.port}/hello"
  let response = https_get(url, bundle, "trust-tls-control")?
  assert response.status == 200
  net.close_pool("trust-tls-control")?
}

test trust_tls_long_lived_service_recovers_by_recreating_pool [fs, process, env, time, net, error] { |ctx|
  let python = match process.which("python3") {
    Ok(found) => found.display(),
    Err(_) => {
      test.skip("python3 is unavailable for the fixture TLS server")
      return
    },
  }

  let routes = fixture_routes(ctx, "trust-tls-service-routes", "service payload\n")?
  let service_bundle = test.temp_path(ctx, name: "trust-tls-service-bundle.pem")
  service_bundle.write(fixture("tls/ca-a.crt").read_bytes()?)
  let first = serve_fixture_tls(ctx, "trust-tls-service-first", python, fixture("tls/server-a.crt").display(), fixture("tls/server-a.key").display(), routes, "", "")?
  defer stop_fixture(first)?

  var served = 0
  let _ = net.pool("trust-tls-service", 4, 1s)?
  let first_url = f"https://127.0.0.1:{first.port}/hello"
  let ready = https_get(first_url, service_bundle, "trust-tls-service")?
  assert ready.status == 200
  served += 1

  stop_fixture(first)?
  service_bundle.write(bytes.from_text(fixture("tls/ca-a.crt").read_text()? + fixture("tls/ca-b.crt").read_text()?))?
  let second = serve_fixture_tls(ctx, "trust-tls-service-second", python, fixture("tls/server-b.crt").display(), fixture("tls/server-b.key").display(), routes, "", "")?
  defer stop_fixture(second)?

  let second_url = f"https://127.0.0.1:{second.port}/hello"
  match https_get(second_url, service_bundle, "trust-tls-service") {
    Ok(_) => test.fail("rotated server chain was accepted without recreating the client"),
    Err(_) => {},
  }

  net.close_pool("trust-tls-service")?
  let _ = net.pool("trust-tls-service-next", 4, 1s)?
  let recovered = https_get(second_url, service_bundle, "trust-tls-service-next")?
  assert recovered.status == 200
  assert recovered.body.utf8()? == "service payload\n"
  served += 1
  assert served == 2
  net.close_pool("trust-tls-service-next")?
}

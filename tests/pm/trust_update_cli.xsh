##! Trust command entrypoint, usage errors, and process-lifecycle tests.
##! Subprocess tests run trust.xsh in a child XSH with isolated environments.

proc runner() -> Result[Path] {
  let configured = e"XSH_HOST" ?? ""
  return fp"{configured}" when configured != ""
  process.which("xsh")
}

proc module_root() [fs, env, error] -> Result[Path] {
  path.absolute(p".")
}

type TrustCliResult = {ok: Bool, code: Int, err: Str, out: Str}

proc trust_run(args: List[Str], err: Path, out: Path) [fs, process, env, error] -> Result[TrustCliResult, Error] {
  let xsh = runner()?
  let modules = module_root()?
  let command = process.command_argv(
    xsh.display(),
    [xsh.display(), p"trust.xsh".display(), "--"].extend(args),
    modules,
    {XSH_MODULE_PATH: modules.display(), XSH_HOST: xsh.display()},
    stdout: out,
    stderr: err,
  )
  let status = process.run(command)?
  {ok: status.ok, code: status.exit_code()?, err: err.read_text()?, out: out.read_text()?}
}

test trust_cli_help_lists_commands [fs, process, env, error] { |ctx|
  let err = test.temp_path(ctx, name: "trust-help.err")
  let out = test.temp_path(ctx, name: "trust-help.out")
  let status = trust_run(["--help"], err, out)?
  assert status.ok
}

test trust_cli_rejects_unknown_command [fs, process, env, error] { |ctx|
  let err = test.temp_path(ctx, name: "trust-unknown.err")
  let out = test.temp_path(ctx, name: "trust-unknown.out")
  let status = trust_run(["frobnicate"], err, out)?
  assert ! status.ok
  assert "unknown trust command" in status.err
}

test trust_cli_update_requires_a_source [fs, process, env, error] { |ctx|
  let err = test.temp_path(ctx, name: "trust-no-source.err")
  let out = test.temp_path(ctx, name: "trust-no-source.out")
  let root = test.temp_dir(ctx, name: "trust-cli-no-source")?
  let status = trust_run(["update", "--root", root.display()], err, out)?
  assert ! status.ok
  assert "requires --from DIR or --url URL" in status.err
}

test trust_cli_rejects_conflicting_sources [fs, process, env, error] { |ctx|
  let err = test.temp_path(ctx, name: "trust-both-sources.err")
  let out = test.temp_path(ctx, name: "trust-both-sources.out")
  let root = test.temp_dir(ctx, name: "trust-cli-both-sources")?
  let status = trust_run(["update", "--from", "a", "--url", "https://example.invalid/r", "--root", root.display()], err, out)?
  assert ! status.ok
  assert "exactly one of --from and --url" in status.err
}

test trust_cli_status_reports_uninitialized_root [fs, process, env, error] { |ctx|
  let err = test.temp_path(ctx, name: "trust-status.err")
  let out = test.temp_path(ctx, name: "trust-status.out")
  let root = test.temp_dir(ctx, name: "trust-cli-status")?
  let status = trust_run(["status", "--root", root.display()], err, out)?
  assert status.ok
}
use trust.store as trust_store
use trust.update as trust_update

proc fixture(name: Str) -> Path {
  fp"tests/pm/fixtures/trust-update/{name}"
}

proc stage_system(ctx: TestContext, name: Str, key: Str) -> Result[Path, Error] {
  let root = test.temp_dir(ctx, name: name)?
  let seed_bundle = fp"{root}/usr/share/laputa/trust/seed/ca-certificates.crt"
  let seed_policy = fp"{root}/usr/share/laputa/trust/seed/trust-policy"
  let key_path = fp"{root}/etc/laputa/trust-update-key"
  for parent in [seed_bundle.parent, key_path.parent, fp"{root}/etc/ssl/certs", fp"{root}/var/lib/xsh-pm/packages/ca-certificates"] {
    parent.mkdir(parents: true)
  }

  seed_bundle.write(p"packages/ca-certificates/files/cacert.pem".read_bytes()?)
  seed_policy.write(p"packages/ca-certificates/files/trust-policy".read_bytes()?)
  key_path.write(fixture(f"keys/{key}.public.base64").read_text()?.trim().base64_decode()?)
  fp"{root}/etc/ssl/certs/ca-certificates.crt".symlink(to: p"../../../var/lib/laputa/trust/active/ca-certificates.crt")
  fp"{root}/etc/laputa/trust-policy".symlink(to: p"../../var/lib/laputa/trust/active/trust-policy")
  fp"{root}/etc/ssl/cert.pem".symlink(to: p"certs/ca-certificates.crt")
  root
}

proc stage_release(ctx: TestContext, name: Str, which: Str) -> Result[Path, Error] {
  let out = fp"{test.temp_dir(ctx, name: name)?}/release"
  out.mkdir(parents: true)
  for file in ["metadata", "metadata.sig", "ca-certificates.crt", "trust-policy"] {
    fp"{fixture(which)}/{file}".copy(to: fp"{out}/{file}")
  }

  out
}

proc active_bundle(root: Path) [fs, error] -> Result[Bytes, Error] {
  fp"{root}/var/lib/laputa/trust/active/ca-certificates.crt".read_bytes()
}

proc wait_for_port_file(port_file: Path, attempts: Int) [fs, time, error] -> Result[Int, Error] {
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

proc spawn_fixture_server(
  ctx: TestContext,
  python: Str,
  name: Str,
  chain: Str,
  key: Str,
  docroot: Path,
  drip: Str,
  delay_ms: Str,
) [fs, process, env, time, error] -> Result[TrustFixtureServer, Error] {
  let dir = test.temp_dir(ctx, name: name)?
  let port_file = fp"{dir}/port"
  let script = fp"tests/pm/fixtures/trust-update/tls_server.py"
  if drip != "" {
    let child = spawn run $python $script $chain $key $port_file $docroot --drip $drip --delay-ms $delay_ms ?
    return {port: wait_for_port_file(port_file, 100)?, pid: child.pid, handle: child}
  }

  let child = spawn run $python $script $chain $key $port_file $docroot ?
  {port: wait_for_port_file(port_file, 100)?, pid: child.pid, handle: child}
}

proc kill_child(pid: Int, handle: ProcessHandle) [process, error] {
  match process.kill(pid, signal: "KILL") {
    Ok(_) => {},
    Err(_) => {},
  }

  match process.wait_any([handle]) {
    Ok(_) => {},
    Err(_) => {},
  }
}

test trust_update_url_converges_with_from [fs, process, env, time, error] { |ctx|
  let python = match process.which("python3") {
    Ok(found) => found.display(),
    Err(_) => {
      test.skip("python3 is unavailable for the fixture TLS server")
      return
    },
  }

  let root = stage_system(ctx, "trust-update-url", "signing-key")?
  let bundle = fp"{root}/transport-bundle.pem"
  bundle.write(fixture("release-b/ca-certificates.crt").read_bytes()?)
  let server = spawn_fixture_server(
    ctx,
    python,
    "trust-update-url-server",
    fixture("tls/server-a.crt").display(),
    fixture("tls/server-a.key").display(),
    fixture("release-b"),
    "",
    "",
  )?
  defer kill_child(server.pid, server.handle)?

  let url = f"https://127.0.0.1:{server.port}/"
  let out = test.temp_path(ctx, name: "trust-update-url.out")
  let err = test.temp_path(ctx, name: "trust-update-url.err")
  let xsh = runner()?
  let modules = module_root()?
  let fetch = process.command_argv(
    xsh.display(),
    [xsh.display(), fp"{modules}/trust.xsh".display(), "--", "update", "--url", url, "--root", root.display()],
    modules,
    {XSH_MODULE_PATH: modules.display(), XSH_HOST: xsh.display(), SSL_CERT_FILE: bundle.display()},
    stdout: out,
    stderr: err,
  )
  let status = process.run(fetch)?
  assert status.ok, err.read_text()?
  assert trust_update.trust_status(root)?.generation == "2"
}

test trust_update_interrupted_download_leaves_no_store_mutation [fs, process, env, time, error] { |ctx|
  let python = match process.which("python3") {
    Ok(found) => found.display(),
    Err(_) => {
      test.skip("python3 is unavailable for the fixture TLS server")
      return
    },
  }

  let root = stage_system(ctx, "trust-update-trickle", "signing-key")?
  let bundle = fp"{root}/transport-bundle.pem"
  bundle.write(fixture("release-b/ca-certificates.crt").read_bytes()?)
  let server = spawn_fixture_server(
    ctx,
    python,
    "trust-update-trickle-server",
    fixture("tls/server-a.crt").display(),
    fixture("tls/server-a.key").display(),
    fixture("release-b"),
    "2048",
    "100",
  )?
  defer kill_child(server.pid, server.handle)?

  let xsh = runner()?
  let modules = module_root()?
  let url = f"https://127.0.0.1:{server.port}/"
  let child = spawn run XSH_MODULE_PATH=$modules XSH_HOST=$xsh SSL_CERT_FILE=$bundle $xsh trust.xsh -- update --url $url --root $root ?
  time.sleep(2s)?
  process.kill(child.pid, signal: "KILL")?
  let _ = wait [child]?

  assert ! fp"{root}/var/lib/laputa/trust/generations".exists()?
  assert ! fp"{root}/var/lib/laputa/trust/journal.json".exists()?

  let out = test.temp_path(ctx, name: "trust-update-resume.out")
  let err = test.temp_path(ctx, name: "trust-update-resume.err")
  let resume_command = process.command_argv(
    xsh.display(),
    [xsh.display(), fp"{modules}/trust.xsh".display(), "--", "update", "--url", url, "--root", root.display()],
    modules,
    {XSH_MODULE_PATH: modules.display(), XSH_HOST: xsh.display(), SSL_CERT_FILE: bundle.display()},
    stdout: out,
    stderr: err,
  )
  let second_try = process.run(resume_command)?
  assert second_try.ok, err.read_text()?
  assert trust_update.trust_status(root)?.generation == "2"
}

test trust_update_killed_mid_transaction_recovers_cleanly [fs, process, env, time, error] { |ctx|
  for delay_ms in [5, 15, 30, 60, 120, 250] {
    let root = stage_system(ctx, f"trust-update-kill-{delay_ms}", "signing-key")?
    let source = stage_release(ctx, f"trust-update-kill-source-{delay_ms}", "release-b")?
    let xsh = runner()?
    let modules = module_root()?
    let child = spawn run XSH_MODULE_PATH=$modules XSH_HOST=$xsh $xsh trust.xsh -- update --from $source --root $root ?
    time.sleep(time.millis(delay_ms))?
    process.kill(child.pid, signal: "KILL")?
    let _ = wait [child]?

    let active = match trust_store.trust_store_read_active(trust_store.trust_store_paths(root)) {
      Ok(generation) => generation,
      Err(_) => "none",
    }
    if active == "none" {
      assert ! fp"{root}/var/lib/laputa/trust/generations/2".exists()?
    } else {
      assert active == "1" or active == "2"
      if active == "1" {
        assert active_bundle(root)? == fixture("release-a-stale/ca-certificates.crt").read_bytes()?
      } else {
        assert active_bundle(root)? == fixture("release-b/ca-certificates.crt").read_bytes()?
      }
    }

    let resumed = trust_update.trust_update_from_dir(root, source)?
    assert resumed.generation == "2"
    assert trust_store.trust_store_read_journal(trust_store.trust_store_paths(root))?.present == false
  }
}

proc store_snapshot(root: Path) [fs, error] -> Result[Str, Error] {
  var entries: List[Str] = []
  for entry in fs.walk(fp"{root}/var/lib/laputa/trust", hidden: true)? {
    let rel = entry.path.strip_prefix(root)?
    entries += [f"{rel.display()} {entry.kind} {entry.size}"]
  }

  entries.join("\n")
}

test trust_cli_status_is_read_only_under_concurrency [fs, process, env, time, error] { |ctx|
  let root = stage_system(ctx, "trust-cli-status-race", "signing-key")?
  let source = stage_release(ctx, "trust-cli-status-race-source", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, source)?

  fp"{root}/var/lib/laputa/trust/sentinel-keep".write("keep\n")?
  fp"{root}/var/lib/laputa/trust/generations/2/sentinel-keep".write("keep\n")?
  let before = store_snapshot(root)?

  let xsh = runner()?
  let modules = module_root()?
  let iodir = test.temp_dir(ctx, name: "trust-status-race-io")?
  let script = fp"{modules}/trust.xsh"
  var outputs: List[Path] = []
  var handles: List[ProcessHandle] = []
  for index in range(8) {
    let err = fp"{iodir}/status-{index}.err"
    let out = fp"{iodir}/status-{index}.out"
    outputs += [out]
    handles += [spawn run XSH_MODULE_PATH=$modules XSH_HOST=$xsh $xsh $script -- status --root $root > $out 2> $err ?]
  }

  for _ in range(20) {
    let status = trust_update.trust_status(root)?
    assert status.generation == "2"
  }

  for handle in handles {
    let _ = process.wait_any([handle])?
  }

  for out in outputs {
    assert "generation 2" in out.read_text()?
  }

  assert store_snapshot(root)? == before
  assert fp"{root}/var/lib/laputa/trust/sentinel-keep".read_text()? == "keep\n"
  assert fp"{root}/var/lib/laputa/trust/generations/2/sentinel-keep".read_text()? == "keep\n"
  assert ! fp"{root}/var/lib/laputa/trust/.probe-target".exists()?
  assert trust_store.trust_store_read_active(trust_store.trust_store_paths(root))? == "2"
}

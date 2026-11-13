##! Drive the remote administration library against one headless guest and print
##! one RESULT line per proven behavior. The harness owns the guest and its keys.
use system.remote

proc check(label: Str, ok: Bool) [io, error] {
  guard ok else { fail f"FAILED: {label}" }
  print f"RESULT {label}"
}

proc main(...argv: List[Str]) [fs, process, net, env, time, error, io] {
  let repo = Path(argv[0])
  let port = argv[1].parse_int()?
  let key = Path(argv[2])
  let host_key = argv[3]
  let operator = argv[4]
  let candidate = Path(argv[5])
  let program = remote.remote_program(repo)?
  let target: remote.RemoteTarget = {host: "127.0.0.1", port: port, user: operator, key: key, host_key: host_key, timeout_ms: 20000}

  let wrong = {...target, host_key: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}
  match remote.remote_connect(wrong) {
    Ok(_) => fail "FAILED: a wrong host key was accepted"
    Err(SshError.HostKeyMismatch {..}) => print "RESULT wrong host key refused before authentication"
    Err(other) => fail f"FAILED: unexpected {other.message}"
  }

  with session = remote.remote_connect(target)? {
    let info = ssh.info(session)?
    check("host key verified against the provisioned fingerprint", info.host_key == host_key)?
    print f"INFO kex={info.kex} cipher={info.cipher_client_to_server}"

    let inspection = remote.remote_inspect(session, program)?
    check("running generation reported", json.get(inspection.generation, ["profile"], "").require(Str)? == "qemu-maintained")?
    check("guest identifies itself", inspection.hostname == "laputa-admin")?
    let oxish = inspection.services |> where .name == "oxish" |> collect
    check("xinit services listed with oxish running", oxish.len() == 1 and oxish[0].state == "running")?

    let hostname = remote.remote_run(session, program, ["/usr/bin/xinit", "status", "oxish"])?
    check("explicit argv ran with exact status", hostname.exit_code == 0 and ! hostname.signaled)?
    let failing = remote.remote_run(session, program, ["/usr/bin/xinit", "check", "/nonexistent/service.xsh"])?
    check("a failing command reports its status and stderr as data", failing.exit_code != 0 and ! failing.stderr.is_empty())?
    match remote.remote_run(session, program, ["/nonexistent/binary"]) {
      Ok(_) => fail "FAILED: a missing executable ran"
      Err(remote.RemoteError.Refused {..}) => print "RESULT a missing executable is a refusal with its reason"
      Err(other) => fail f"FAILED: unexpected {other.message}"
    }

    let digest = remote.remote_digest(candidate)?
    let staged = remote.remote_stage(session, program, candidate, "candidate.bin", digest)?
    check("candidate staged and verified", staged.outcome == "staged")?
    let again = remote.remote_stage(session, program, candidate, "candidate.bin", digest)?
    check("repeating the stage reports present, not a second write", again.outcome == "present")?
    let state = remote.remote_staged(session, program, "candidate.bin")?
    check("guest digest equals the local digest", state.sha256 == digest)?

    let bad = "0000000000000000000000000000000000000000000000000000000000000000"
    match remote.remote_stage(session, program, candidate, "mismatch.bin", bad) {
      Ok(_) => fail "FAILED: a wrong digest was accepted"
      Err(remote.RemoteError.Refused {..}) => print "RESULT a wrong digest is refused"
      Err(other) => fail f"FAILED: unexpected {other.message}"
    }
    let leftover = remote.remote_staged(session, program, "mismatch.bin")?
    check("a refused transfer leaves nothing behind", ! leftover.present and leftover.incoming.is_empty())?
  }

  let big = Path(argv[6])
  let big_digest = remote.remote_digest(big)?
  var interrupted = false
  with session = remote.remote_connect(target)? {
    match remote.remote_stage(session, program, big, "interrupted.bin", big_digest, timeout_ms: 120) {
      Ok(_) => print "INFO the transfer finished inside the deadline"
      Err(SshError.Timeout {certainty, ..}) => {
        check("a deadline mid-transfer reports a possibly-executed mutation", certainty == .Submitted)?
        interrupted = true
      }
      Err(other) => fail f"FAILED: unexpected {other.message}"
    }
  }
  check("the interrupting deadline fired", interrupted)?
  with session = remote.remote_connect(target)? {
    let after = remote.remote_staged(session, program, "interrupted.bin")?
    check("reconciliation shows the interrupted stage was not published", ! after.present)?
    check("an interrupted transfer cleans its scratch file", after.incoming.is_empty())?
  }

  let diagnostics = remote.remote_diagnose_afresh(target, program)?
  let dead = diagnostics.unhealthy |> where .name == "wpa_supplicant" |> collect
  check("diagnostics name the dead service", dead.len() == 1)?
  for log in diagnostics.logs {
    print f"INFO log {log.path}: readable={log.readable} lines={log.lines.len()}"
  }
}

main(@args)?

##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

error ScriptError = Failed(kind: Str, message: Str)

proc main(rootfs: Path = /rootfs) [fs, process, env, time, error] {
  proof.target_elf(rootfs, p"usr/bin/dropbear", "dropbear")
  proof.target_elf(rootfs, p"usr/bin/dropbearkey", "dropbear")
  proof.target_elf(rootfs, p"usr/bin/dbclient", "dropbear")
  let build_arch = pm_util.build_arch()?
  let target_arch = pm_util.target_arch()?

  if build_arch != target_arch {
    print f"dropbear ok: cross-built {target_arch}"
    return
  }

  let os = system.uname()?
  let arch = os.machine
  let dynlinker = fp"{rootfs}/usr/lib/ld-musl-{arch}.so.1"
  let dropbearkey = fp"{rootfs}/usr/bin/dropbearkey"
  let tmp = /tmp/dropbear-proof
  tmp.mkdir()

  # RSA: exercises libtommath (big-integer arithmetic) + libtomcrypt (RSA ops).
  let rsa_key = fp"{tmp}/host_rsa"
  run $dynlinker $dropbearkey "-t" "rsa" "-s" "2048" "-f" $rsa_key ?
  let rsa_out = run.text $dynlinker $dropbearkey "-y" "-f" $rsa_key ?

  if "ssh-rsa" not in rsa_out {
    Err(ScriptError.Failed(kind: "dropbear-proof", message: f"rsa: unexpected output: {rsa_out.trim()}"))?
  }

  print "dropbear ok: rsa 2048 key generated"

  # ed25519: exercises curve25519 (ECC) in libtomcrypt.
  let ed_key = fp"{tmp}/host_ed25519"
  run $dynlinker $dropbearkey "-t" "ed25519" "-f" $ed_key ?
  let ed_out = run.text $dynlinker $dropbearkey "-y" "-f" $ed_key ?

  if "ssh-ed25519" not in ed_out {
    Err(ScriptError.Failed(kind: "dropbear-proof", message: f"ed25519: unexpected output: {ed_out.trim()}"))?
  }

  print "dropbear ok: ed25519 key generated"

  # ecdsa-256: exercises ECDSA / prime256v1 in libtomcrypt.
  let ec_key = fp"{tmp}/host_ecdsa"
  run $dynlinker $dropbearkey "-t" "ecdsa" "-s" "256" "-f" $ec_key ?
  let ec_out = run.text $dynlinker $dropbearkey "-y" "-f" $ec_key ?

  if "ecdsa-sha2-nistp256" not in ec_out {
    Err(ScriptError.Failed(kind: "dropbear-proof", message: f"ecdsa: unexpected output: {ec_out.trim()}"))?
  }

  print "dropbear ok: ecdsa-256 key generated"
  ssh_session(dynlinker, rootfs, tmp, ed_key)
}

proc public_key_line(body: Str) [error] -> Result[Str] {
  for line in body.lines() {
    let trimmed = line.trim()

    return trimmed when trimmed.starts_with("ssh-")
  }

  Err(ScriptError.Failed(kind: "dropbear-proof", message: "dropbearkey did not print an SSH public key"))
}


# Runs one command over SSH as `login` on loopback and returns its output, or
# "" when the login fails. `-y -y` skips host key checking entirely, so the
# client writes no known_hosts; BatchMode keeps it from prompting; HOME keeps
# it away from the user's own ~/.ssh. Output goes to a file, not a pipe, so a
# descendant that outlives the client cannot hold the read open.
proc ssh_echo(dynlinker: Path, rootfs: Path, home: Path, login: Str, key: Path, port: Int) -> Result[Str] {
  let dbclient = fp"{rootfs}/usr/bin/dbclient"
  let out = fp"{home}/ssh.out"
  var ok = false

  env ({
    HOME: home.display(),
  }) {
    ok = (run.status --timeout=10s $dynlinker $dbclient "-y" "-y" "-o" "BatchMode=yes" "-i" $key "-p" f"{port}" f"{login}@127.0.0.1" "echo laputa-ssh-ok" > $out 2> /dev/null).ok
  }

  return "" unless ok

  out.read_text()?.trim()
}

# The installer's QEMU proof logs in over SSH with an ed25519 host key and
# public-key authentication; this runs the same exchange on loopback: the
# server with an ed25519 host key and no password logins, a client with an
# authorized key that runs a command, and one with an unknown key that dropbear
# must refuse.
proc ssh_session(dynlinker: Path, rootfs: Path, tmp: Path, host_key: Path) {
  let dropbearkey = fp"{rootfs}/usr/bin/dropbearkey"
  let dropbear = fp"{rootfs}/usr/bin/dropbear"
  let me = user.current()?
  let client_key = fp"{tmp}/client_ed25519"
  let stranger_key = fp"{tmp}/stranger_ed25519"
  client_key.remove(missing_ok: true)
  stranger_key.remove(missing_ok: true)
  run $dynlinker $dropbearkey "-t" "ed25519" "-f" $client_key ?
  run $dynlinker $dropbearkey "-t" "ed25519" "-f" $stranger_key ?
  let client_public = public_key_line(run.text $dynlinker $dropbearkey "-y" "-f" $client_key ?)?

  # dropbear accepts authorized_keys only when every directory up to the
  # user's home (or /) is owned by the user or root and not group or world
  # writable, which rules out /tmp; a private directory under the home passes.
  let pid = process.current_pid()?
  let auth_dir = fp"{me.home}/.laputa-proof-dropbear-{pid}"
  auth_dir.remove(missing_ok: true)
  auth_dir.mkdir()
  defer auth_dir.remove(missing_ok: true)?
  auth_dir.chmod(0o700)
  fp"{auth_dir}/authorized_keys".write(f"{client_public}\n", mode: 0o600)
  let client_home = fp"{tmp}/client-home"
  client_home.mkdir()
  let log_path = fp"{tmp}/dropbear.log"
  let port = 22000 + pid % 20000
  let listen = f"127.0.0.1:{port}"
  let server = spawn run $dynlinker $dropbear "-F" "-E" "-s" "-r" $host_key "-D" $auth_dir "-p" $listen > /dev/null 2> $log_path ?

  var output = ""
  var tries = 50

  # Retry while the server comes up.
  while tries > 0 and output == "" {
    output = ssh_echo(dynlinker, rootfs, client_home, me.name, client_key, port)?

    if output == "" {
      time.sleep(100ms)
      tries -= 1
    }
  }

  let stranger = ssh_echo(dynlinker, rootfs, client_home, me.name, stranger_key, port)?
  process.kill(server.pid, "TERM")
  let _ = wait server
  let log = log_path.read_text()?
  proof.ensure(output == "laputa-ssh-ok", "dropbear-ssh", f"authorized client did not run its command: {output}; server log: {log}")
  proof.ensure("Pubkey auth succeeded" in log, "dropbear-ssh", f"server did not log public-key auth: {log}")
  proof.ensure(stranger == "", "dropbear-ssh", "dropbear accepted a client key missing from authorized_keys")
  print "dropbear ok: ed25519 host key, public-key login runs a command, unknown key refused"
}
main(@args)

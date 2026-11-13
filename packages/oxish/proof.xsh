##! Artifact proof for the oxish package: target ELF checks, key generation, and a
##! login-mode public-key session against a loopback server.
use pm.proof
use pm.util as pm_util

const tools = ["oxish", "oxish-keygen", "oxish-scp", "oxish-server", "oxish-session", "oxish-sftp"]

proc fingerprint(keygen: Path, key: Path) [fs, process, env, error] -> Result[Str] {
  let line = run.text $keygen "-l" "-f" $key
  let words = line.words()

  proof.ensure(words.len() >= 2 and words[1].starts_with("SHA256:"), "proof-oxish", f"unexpected fingerprint line: {line.trim()}")
  words[1]
}

proc public_key(keygen: Path, key: Path) [fs, process, env, error] -> Result[Str] {
  let line = run.text $keygen "-y" "-f" $key

  proof.ensure(line.trim().starts_with("ssh-ed25519 "), "proof-oxish", f"unexpected public key: {line.trim()}")
  line.trim()
}

proc ssh_echo(client: Path, key: Path, host_key: Str, login: Str, port: Int) [fs, process, env, error] -> Result[Str] {
  let status = run.capture --text --timeout=10s $client "-p" $port "-i" $key "--host-key" $host_key "-T" f"{login}@127.0.0.1" "laputa-ssh-ok"

  return "" unless status.status.ok

  status.stdout.trim()
}

proc main(rootfs = p"/rootfs") [fs, process, env, time, error] {
  for tool in tools {
    proof.target_elf(rootfs, fp"usr/bin/{tool}", "oxish")
  }

  let build_arch = pm_util.build_arch()?
  let target_arch = pm_util.target_arch()?

  if build_arch != target_arch {
    print f"oxish ok: cross-built {target_arch}"
    return
  }

  let keygen = fp"{rootfs}/usr/bin/oxish-keygen"
  let server = fp"{rootfs}/usr/bin/oxish-server"
  let client = fp"{rootfs}/usr/bin/oxish"
  let tmp = fp"{rootfs}/tmp/oxish-proof-{process.current_pid()?}"
  tmp.mkdir()
  tmp.chmod(0o700)
  defer tmp.remove()

  let host_key = fp"{tmp}/host"
  let client_key = fp"{tmp}/client"
  let stranger_key = fp"{tmp}/stranger"
  run $keygen "-f" $host_key "-C" "proof-host"
  run $keygen "-f" $client_key "-C" "proof-client"
  run $keygen "-f" $stranger_key "-C" "proof-stranger"
  proof.ensure(host_key.metadata()?.mode.bit_and(0o777) == 0o600, "proof-oxish", "host key is not mode 0600")
  let again = run.status $keygen "-f" $host_key > /dev/null 2> /dev/null
  proof.ensure(! again.ok, "proof-oxish", "oxish-keygen replaced an existing key")
  let host_fingerprint = fingerprint(keygen, host_key)?
  proof.ensure(fingerprint(keygen, fp"{host_key}.pub")? == host_fingerprint, "proof-oxish", "public and private fingerprints differ")
  print "oxish ok: ed25519 host and client keys generated, existing key kept"

  let me = user.current()?

  if me.uid == 0 {
    print "oxish ok: login session proof skipped (root refuses account uid 0)"
    return
  }

  # oxish-server serves only its own account when unprivileged. Its login shell is a
  # script that prints its `-c` command, so the proof needs no system shell.
  let runner = process.which("xsh")?
  let shell = fp"{tmp}/shell.xsh"
  shell.write(f"#!{runner}\nproc main(...argv: List[Str]) [io, error] {{\n  print argv[1]\n}}\n\nmain(@args)?\n", mode: 0o755)
  let passwd = fp"{tmp}/passwd"
  passwd.write(f"{me.name}:x:{me.uid}:{me.gid}::{tmp}:{shell}\n")
  let group_file = fp"{tmp}/group"
  group_file.write(f"{me.name}:x:{me.gid}:\n")
  let accounts = fp"{tmp}/accounts"
  accounts.write(f"{me.name} {public_key(keygen, client_key)?}\n", mode: 0o600)
  let log_path = fp"{tmp}/server.log"
  let port = 22000 + process.current_pid()? % 20000
  let service = spawn run $server "--mode" "login" "--bind" "127.0.0.1" "--port" $port "--host-key-file" $host_key "--accounts" $accounts \
    "--passwd-file" $passwd "--group-file" $group_file > /dev/null 2> $log_path ?

  var output = ""
  var tries = 50

  while tries > 0 and output == "" {
    output = ssh_echo(client, client_key, host_fingerprint, me.name, port)?

    if output == "" {
      time.sleep(100ms)
      tries -= 1
    }
  }

  let scp = fp"{rootfs}/usr/bin/oxish-scp"
  let upload = fp"{tmp}/upload"
  upload.write("laputa-scp-ok\n", mode: 0o600)
  let download = fp"{tmp}/download"
  let put = run.status --timeout=10s $scp "-P" $port "-i" $client_key "--host-key" $host_fingerprint $upload f"{me.name}@127.0.0.1:copied" > /dev/null 2> /dev/null
  let get = run.status --timeout=10s $scp "-P" $port "-i" $client_key "--host-key" $host_fingerprint f"{me.name}@127.0.0.1:copied" $download > /dev/null 2> /dev/null
  let stranger = ssh_echo(client, stranger_key, host_fingerprint, me.name, port)?
  let wrong_host = ssh_echo(client, client_key, "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", me.name, port)?
  process.kill(service.pid, "TERM")
  let _ = wait service
  let log = log_path.read_text()?
  proof.ensure(output == "laputa-ssh-ok", "proof-oxish", f"authorized client did not run its command: {output}; server log: {log}")
  proof.ensure(stranger == "", "proof-oxish", "oxish-server accepted a client key missing from the accounts file")
  proof.ensure(wrong_host == "", "proof-oxish", "the client accepted a host key that does not match the pin")
  proof.ensure(put.ok and get.ok, "proof-oxish", f"oxish-scp round trip failed; server log: {log}")
  proof.ensure(fp"{tmp}/copied".read_text()? == "laputa-scp-ok\n" and download.read_text()? == "laputa-scp-ok\n", "proof-oxish", "oxish-scp copies differ from the source")
  print "oxish ok: pinned host key, public-key login runs a command, unknown key refused, scp round trip"
}

##! The one transport boundary. Everything that reaches a host goes through
##! `exec`: a catalogue operation plus positional arguments, rendered by
##! `shell` into the command string the remote login shell receives. A `Posix`
##! target receives `/bin/sh -c '<script>'`; an `Xsh` target receives XSH
##! source for `xsh-login -c`. Remote hosts use the native `ssh` module; the
##! `Local` kind runs the same command string through a local `sh` or `xsh` for
##! tests and development.

use infra.model
use infra.scripts
use infra.shell

## The opaque handle `ssh.connect` returns.
export type Session = SshSession

## An authenticated session, or none for a local host, with the authority
## policy and login-shell dialect of the host it belongs to.
export type Connection = {
  host: Str,
  kind: model.TransportKind,
  dialect: model.Dialect,
  session: Session?,
  privilege: model.Privilege,
  escalate_reads: Bool,
  timeout_ms: Int,
  transfer_timeout_ms: Int,
}

## What a script printed and the status it exited with.
export type Execution = {code: Int, stdout: Bytes, stderr: Bytes}

## Why a request produced no execution.
export error TransportError =
  Unreachable(message: Str) |
  Refused(message: Str) |
  NotSubmitted(message: Str) |
  Interrupted(message: Str) |
  Abnormal(message: Str)

## Whether a failed request may have reached the host, as the native client
## reports it in every `SshError` variant.
export pure certainty_of(error: SshError) -> ssh.Certainty {
  ssh.certainty(error)
}

pure transport_error(error: SshError) -> TransportError {
  match certainty_of(error) {
    ssh.Certainty.NotSubmitted => TransportError.NotSubmitted(error.message)
    ssh.Certainty.Submitted => TransportError.Interrupted(error.message)
  }
}

pure ssh_options(host: model.Host, key: Path, host_key: Str) -> Record {
  {
    host: host.address,
    port: host.port,
    user: host.user,
    key: key,
    host_key: host_key,
    timeout_ms: host.timeout_ms,
  }
}

pure local_connection(host: model.Host) -> Connection {
  Connection(
    host: host.name,
    kind: .Local,
    dialect: host.dialect,
    session: null,
    privilege: host.privilege,
    escalate_reads: host.escalate_reads,
    timeout_ms: host.timeout_ms,
    transfer_timeout_ms: host.transfer_timeout_ms,
  )
}

pure ssh_connection(host: model.Host, session: Session) -> Connection {
  Connection(
    host: host.name,
    kind: .Ssh,
    dialect: host.dialect,
    session: session,
    privilege: host.privilege,
    escalate_reads: host.escalate_reads,
    timeout_ms: host.timeout_ms,
    transfer_timeout_ms: host.transfer_timeout_ms,
  )
}

pure ssh_target(host: model.Host) -> Result[Record, TransportError] {
  guard let key = host.key else {
    return Err(TransportError.Refused(f"{host.name}: an ssh host needs a key"))
  }

  guard let host_key = host.host_key else {
    return Err(TransportError.Refused(f"{host.name}: an ssh host needs a pinned host_key"))
  }

  Ok(ssh_options(host, key, host_key))
}

## Open the authenticated session for a host. A local host needs none.
export proc connect(host: model.Host) [error] -> Result[Connection, TransportError] {
  match host.transport {
    model.Local => Ok(local_connection(host))
    model.Ssh => {
      let options = ssh_target(host)?
      match ssh.connect(options) {
        Ok(session) => Ok(ssh_connection(host, session))
        Err(error) => Err(TransportError.Unreachable(f"{host.name}: {error.message}"))
      }
    }
  }
}

## Open every host, at most `jobs` at a time, and answer one result per host in
## order. The sessions belong to the calling scope. A host that stalls or fails
## fails only itself.
export proc connect_all(hosts: List[model.Host], jobs: Int) [error] -> List[Result[Connection, TransportError]] {
  var targets: List[Record] = []
  var refusals: Map[Str, TransportError] = {}
  for host in hosts {
    if host.transport == model.Ssh {
      match ssh_target(host) {
        Ok(options) => targets += [options]
        Err(error) => refusals[host.name] = error
      }
    }
  }

  var opened: List[Result[SshSession, SshError]] = []
  if ! targets.is_empty() {
    match ssh.connect_all({targets: targets, jobs: jobs}) {
      Ok(found) => opened = found
      Err(error) => opened = targets |> map { |_| Err(error) } |> collect()
    }
  }

  var results: List[Result[Connection, TransportError]] = []
  var next = 0
  for host in hosts {
    if host.transport == model.Local {
      results += [Ok(local_connection(host))]
      continue
    }

    match refusals.get(host.name) {
      Ok(refusal) => {
        results += [Err(refusal)]
        continue
      }
      Err(_) => {}
    }

    match opened[next] {
      Ok(session) => results += [Ok(ssh_connection(host, session))]
      Err(error) => results += [Err(TransportError.Unreachable(f"{host.name}: {error.message}"))]
    }
    next += 1
  }

  results
}

## Whether a connection can still carry a request. A failed command leaves an
## ssh session unusable; a caller that needs one reconnects instead of guessing.
export proc usable(connection: Connection) [error] -> Bool {
  guard let session = connection.session else {
    return true
  }

  match ssh.info(session) {
    Ok(info) => info.usable
    Err(_) => false
  }
}

## Close a session early. Closing a local connection does nothing.
export proc disconnect(connection: Connection) [error] -> Result[Unit, Error] {
  guard let session = connection.session else {
    return
  }

  ssh.close(session)
}

pure render(connection: Connection, script: Str, args: List[Str], privileged: Bool) -> Result[Str, TransportError] {
  match connection.dialect {
    model.Posix => {
      let escalate = privileged and connection.privilege == .Doas
      let rendered = if escalate { shell.escalated_command(script, args) } else { shell.command(script, args) }
      match rendered {
        Ok(text) => Ok(text)
        Err(error) => Err(TransportError.Refused(error.message), cause: error)
      }
    }
    model.Xsh => {
      guard ! (privileged and connection.privilege == .Doas) else {
        return Err(TransportError.Refused("the xsh dialect has no doas escalation; use privilege plain or root"))
      }

      match shell.xsh_command(script, args) {
        Ok(text) => Ok(text)
        Err(error) => Err(TransportError.Refused(error.message), cause: error)
      }
    }
  }
}

type Captured = {status: Status, stdout: Bytes, stderr: Bytes}

pure capture_result(captured: Result[Captured, ProcessError]) -> Result[Execution, TransportError] {
  match captured {
    Err(ProcessError.Timeout {message}) => Err(TransportError.Interrupted(message))
    Err(error) => Err(TransportError.NotSubmitted(error.message), cause: error)
    Ok(out) => {
      if out.status.signaled() {
        Err(TransportError.Abnormal(f"the command was killed by a signal"))
      } else {
        Ok(Execution(code: out.status.exit_code() ?? 255, stdout: out.stdout, stderr: out.stderr))
      }
    }
  }
}

proc exec_local_xsh(command: Str, stdin: Bytes?, stdin_path: Path?, timeout_ms: Int) [fs, process, error] -> Result[Execution, TransportError] {
  let interpreter = match process.which("xsh") {
    Ok(found) => found
    Err(error) => {
      return Err(TransportError.Refused(f"a local xsh target needs an xsh interpreter on PATH: {error.message}"))
    }
  }
  let source = match fs.tempfile() {
    Ok(found) => found
    Err(error) => {
      return Err(TransportError.NotSubmitted(error.message), cause: error)
    }
  }
  let root_path = match source.root.host_path() {
    Ok(found) => found
    Err(error) => {
      return Err(TransportError.NotSubmitted(error.message), cause: error)
    }
  }
  let source_path = fp"{root_path}/{source.path.display()}"
  match source_path.write(command) {
    Ok(_) => {}
    Err(error) => {
      return Err(TransportError.NotSubmitted(error.message), cause: error)
    }
  }

  let limit = timeout_ms * 1ms
  let empty = b""
  let captured = if stdin_path != null {
    try run.capture --bytes --timeout=limit $interpreter $source_path < $stdin_path
  } else if stdin != null {
    try run.capture --bytes --timeout=limit $interpreter $source_path < $stdin
  } else {
    try run.capture --bytes --timeout=limit $interpreter $source_path < $empty
  }

  capture_result(captured)
}

proc exec_local(command: Str, dialect: model.Dialect, stdin: Bytes?, stdin_path: Path?, timeout_ms: Int) [fs, process, error] -> Result[Execution, TransportError] {
  match dialect {
    model.Xsh => exec_local_xsh(command, stdin, stdin_path, timeout_ms)
    model.Posix => {
      let limit = timeout_ms * 1ms
      let empty = b""
      let captured = if stdin_path != null {
        try run.capture --bytes --timeout=limit sh -c $command < $stdin_path
      } else if stdin != null {
        try run.capture --bytes --timeout=limit sh -c $command < $stdin
      } else {
        try run.capture --bytes --timeout=limit sh -c $command < $empty
      }

      capture_result(captured)
    }
  }
}

proc exec_ssh(session: Session, command: Str, stdin: Bytes?, stdin_path: Path?, timeout_ms: Int) [error] -> Result[Execution, TransportError] {
  let outcome = if stdin_path != null {
    ssh.exec(session, command, {timeout_ms: timeout_ms, stdin_path: stdin_path})
  } else if stdin != null {
    ssh.exec(session, command, {timeout_ms: timeout_ms, stdin: stdin})
  } else {
    ssh.exec(session, command, {timeout_ms: timeout_ms})
  }

  match outcome {
    Err(error) => Err(transport_error(error), cause: error)
    Ok(result) => {
      if result.signal != "" {
        Err(TransportError.Abnormal(f"the command was killed by signal {result.signal}"))
      } else if result.missing {
        Err(TransportError.Abnormal("the channel closed without an exit status"))
      } else {
        Ok(Execution(code: result.exit_code, stdout: result.stdout, stderr: result.stderr))
      }
    }
  }
}

proc exec_rendered(
  connection: Connection,
  script: Str,
  args: List[Str],
  privileged: Bool,
  stdin: Bytes?,
  stdin_path: Path?,
  timeout_ms: Int?,
) [fs, process, error] -> Result[Execution, TransportError] {
  let command = render(connection, script, args, privileged)?
  let limit = timeout_ms ?? connection.timeout_ms
  match connection.kind {
    model.Local => exec_local(command, connection.dialect, stdin, stdin_path, limit)
    model.Ssh => {
      guard let session = connection.session else {
        return Err(TransportError.Refused("an ssh connection has no session"))
      }

      exec_ssh(session, command, stdin, stdin_path, limit)
    }
  }
}

## Run one catalogue operation with positional arguments on a host. The source
## belongs to the connection's dialect. `privileged` applies the host's
## authority policy. A nonzero exit is an `Execution`, not an error. A request
## that may have reached the host and failed is `Interrupted`; the caller must
## not replay it.
export proc exec(
  connection: Connection,
  operation: scripts.Operation,
  args: List[Str] = [],
  privileged: Bool = false,
  stdin: Bytes? = null,
  stdin_path: Path? = null,
  timeout_ms: Int? = null,
) [fs, process, error] -> Result[Execution, TransportError] {
  let script = match scripts.source(connection.dialect, operation) {
    Ok(found) => found
    Err(error) => {
      return Err(TransportError.Refused(error.message), cause: error)
    }
  }
  exec_rendered(connection, script, args, privileged, stdin, stdin_path, timeout_ms)
}

## Run one raw POSIX script with positional arguments. This is for the Alpine
## fixtures and transport tests, which inspect a host with their own scripts;
## an xsh target has no POSIX shell to run it in, so it is refused there.
export proc exec_script(
  connection: Connection,
  script: Str,
  args: List[Str] = [],
  privileged: Bool = false,
  stdin: Bytes? = null,
  stdin_path: Path? = null,
  timeout_ms: Int? = null,
) [fs, process, error] -> Result[Execution, TransportError] {
  guard connection.dialect == .Posix else {
    return Err(TransportError.Refused("a raw POSIX script cannot run on an xsh target"))
  }
  exec_rendered(connection, script, args, privileged, stdin, stdin_path, timeout_ms)
}

##! Native SSH transport adapter and shell contract.

use shlex
use xinfra.inventory as inventory

## The fixed remote command search path.
export const REMOTE_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

## An authenticated native SSH session capability.
export type Session = {token: Str}

## A captured remote command result.
export type ExecResult = {
  exit_code: Int,
  signal: Str,
  missing: Bool,
  stdout: Bytes,
  stderr: Bytes,
  certainty: Str,
}

## Whether a transport failure may have followed submission.
export pure after_submission(message: Str) -> Bool {
  "after submission" in message
}

## Connect to one inventory host and authenticate with its Ed25519 key.
export proc connect(host: inventory.Host, timeout_ms: Int = 10000) -> Result[Session, Str] {
  match ssh.connect({
    host: host.address,
    port: host.port,
    user: host.user,
    key: host.key,
    host_key: host.host_key,
    timeout_ms: timeout_ms,
  }) {
    Ok(session) => Ok(session),
    Err(error) => Err(error.message),
  }
}

## Connect to an explicit endpoint with a pinned host key.
export proc connect_endpoint(
  host: Str,
  port: Int,
  username: Str,
  key: Path,
  host_key: Str,
  timeout_ms: Int = 10000,
) -> Result[Session, Str] {
  match ssh.connect({
    host: host,
    port: port,
    user: username,
    key: key,
    host_key: host_key,
    timeout_ms: timeout_ms,
  }) {
    Ok(session) => Ok(session),
    Err(error) => Err(error.message),
  }
}

## Render one remote `/bin/sh -c` script with the required environment prefix.
export pure shell_command(body: Str) -> Str {
  let script = f"LC_ALL=C\nPATH={REMOTE_PATH}\nexport LC_ALL PATH\n{body}"
  f"/bin/sh -c {shlex.quote(script)}"
}

## Run one argv command through `/bin/sh -c`.
export proc exec(
  session: Session,
  argv: List[Str],
  timeout_ms: Int? = null,
) -> Result[ExecResult, Str] {
  if argv.is_empty() {
    return Err("empty argv")
  }

  for argument in argv {
    if "\0" in argument {
      return Err("argument contains NUL")
    }
  }

  let command = shell_command(shlex.join(argv))
  let result = if timeout_ms == null {
    ssh.exec(session, command, {})
  } else {
    ssh.exec(session, command, {timeout_ms: timeout_ms ?? 0})
  }
  match result {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

## Run a fixed script through `/bin/sh -c`.
export proc run_script(
  session: Session,
  script: Str,
  timeout_ms: Int? = null,
) -> Result[ExecResult, Str] {
  if "\0" in script {
    return Err("script contains NUL")
  }

  let command = shell_command(script)
  let result = if timeout_ms == null {
    ssh.exec(session, command, {})
  } else {
    ssh.exec(session, command, {timeout_ms: timeout_ms ?? 0})
  }
  match result {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

pure elevated_body(elevate: List[Str], body: Str) -> Str {
  if elevate.is_empty() {
    return body
  }
  f"{shlex.join(elevate)} sh -c {shlex.quote(body)}"
}

## Stream a local file to one remote path.
export proc upload_file(
  session: Session,
  destination: Path,
  source: Path,
  timeout_ms: Int? = null,
  elevate: List[Str] = [],
) -> Result[ExecResult, Str] {
  let command = shell_command(elevated_body(elevate, f"cat > {shlex.quote(destination.display())}"))
  let result = if timeout_ms == null {
    ssh.exec(session, command, {stdin_path: source})
  } else {
    ssh.exec(session, command, {stdin_path: source, timeout_ms: timeout_ms ?? 0})
  }
  match result {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

## Write bytes to one remote path.
export proc write_bytes(
  session: Session,
  destination: Path,
  data: Bytes,
  timeout_ms: Int? = null,
  elevate: List[Str] = [],
) -> Result[ExecResult, Str] {
  let command = shell_command(elevated_body(elevate, f"cat > {shlex.quote(destination.display())}"))
  let result = if timeout_ms == null {
    ssh.exec(session, command, {stdin: data})
  } else {
    ssh.exec(session, command, {stdin: data, timeout_ms: timeout_ms ?? 0})
  }
  match result {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

## Run one argv command with secret bytes on stdin.
export proc exec_stdin(
  session: Session,
  argv: List[Str],
  data: Bytes,
  timeout_ms: Int? = null,
  elevate: List[Str] = [],
) -> Result[ExecResult, Str] {
  if argv.is_empty() {
    return Err("empty argv")
  }
  for argument in argv {
    if "\0" in argument {
      return Err("argument contains NUL")
    }
  }
  let command = shell_command(shlex.join(elevate + argv))
  let result = if timeout_ms == null {
    ssh.exec(session, command, {stdin: data})
  } else {
    ssh.exec(session, command, {stdin: data, timeout_ms: timeout_ms ?? 0})
  }
  match result {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

## Close a transport session.
export proc close(session: Session) -> Result[Unit, Str] {
  match ssh.close(session) {
    Ok(_) => Ok(),
    Err(error) => Err(error.message),
  }
}

##! Administer one Laputa machine over XSH's native SSH client. Every request runs the
##! fixed program in system/remote_guest.xsh; request values travel as bounded JSON on
##! stdin and never become shell or XSH source. Reads work without elevated authority.

## The remote program refused a request or could not complete it.
export error RemoteError = Refused(kind: Str, message: Str) | Malformed(message: Str) | Failed(exit_code: Int, message: Str)

## The SSH session capability returned by `ssh.connect`.
export type RemoteSession = {token: Str}

## How to reach one machine. `host_key` is the fingerprint provisioned out of band.
export type RemoteTarget = {
  host: Str,
  port: Int,
  user: Str,
  key: Path,
  host_key: Str,
  timeout_ms: Int,
}

## The remote protocol version the guest program speaks.
export const REMOTE_PROTOCOL = "laputa-remote-1"
## The largest remote reply the client accepts.
export const REMOTE_REPLY_LIMIT = 4194304

## Reads the reviewed remote program from a Laputa checkout.
export proc remote_program(root: Path) [fs, error] -> Result[Str, Error] {
  fp"{root}/system/remote_guest.xsh".read_text()?
}

## Opens one session to the machine; its scope closes it.
export proc remote_connect(target: RemoteTarget) [net, error] -> Result[RemoteSession, Error] {
  ssh.connect(target)?
}

type ExecResult = {
  exit_code: Int,
  signal: Str,
  missing: Bool,
  stdout: Bytes,
  stderr: Bytes,
  certainty: Str,
}

proc decode_reply(result: ExecResult) [error] -> Result[Record, Error] {
  guard ! result.missing else {
    return Err(RemoteError.Malformed(message: "the remote program ended without a completion status"))
  }
  guard result.exit_code == 0 else {
    return Err(RemoteError.Failed(exit_code: result.exit_code, message: result.stderr.utf8()?.trim()))
  }
  let text = result.stdout.utf8()?.trim()
  guard ! text.is_empty() and "\n" not in text else {
    return Err(RemoteError.Malformed(message: "the remote program must answer with exactly one line"))
  }
  let reply = json.decode(text)?.require(Record)?
  guard json.get(reply, ["protocol"], "") == REMOTE_PROTOCOL else {
    return Err(RemoteError.Malformed(message: "the remote program speaks another protocol"))
  }
  if json.get(reply, ["ok"], false).require(Bool)? {
    return json.get(reply, ["result"], {}).require(Record)?
  }
  let failure = json.get(reply, ["error"], {}).require(Record)?
  Err(RemoteError.Refused(kind: json.get(failure, ["kind"], "").require(Str)?, message: json.get(failure, ["message"], "").require(Str)?))
}

proc call(session: RemoteSession, program: Str, request: Any, payload: Path?, timeout_ms: Int) [fs, net, error] -> Result[Record, Error] {
  let line = bytes.from_text(json.encode(request)? + "\n")
  let result = if payload == null {
    ssh.exec(session, program, {stdin: line, timeout_ms: timeout_ms})?
  } else {
    ssh.exec(session, program, {stdin: line, stdin_path: payload, timeout_ms: timeout_ms})?
  }
  decode_reply(result)?
}

## One xinit service as the guest supervisor reports it.
export type RemoteService = {name: Str, state: Str, restarts: Int}
## The machine's running generation, health report and service states.
export type RemoteInspection = {generation: Any, health: Any, services: List[RemoteService], kernel: Str, hostname: Str}
## The result of an explicit argv run.
export type RemoteRun = {exit_code: Int, signaled: Bool, stdout: Bytes, stderr: Bytes, truncated: Bool}
## The result of staging a file.
export type RemoteStage = {outcome: Str, path: Str, size: Int, sha256: Str}
## What is staged under a name, and which scratch files a failed transfer left.
export type RemoteStaged = {present: Bool, size: Int, sha256: Str, incoming: List[Str]}
## The tail of one log; `readable` is false when the operator lacks authority to read it.
export type RemoteLog = {path: Str, readable: Bool, lines: List[Str]}
## Bounded evidence for a failure.
export type RemoteDiagnosis = {services: List[RemoteService], unhealthy: List[RemoteService], logs: List[RemoteLog]}

proc services_of(value: Any) [error] -> Result[List[RemoteService], Error] {
  var found: List[RemoteService] = []
  for item in value.require(List[Record])? {
    found += [{
      name: json.get(item, ["name"], "").require(Str)?,
      state: json.get(item, ["state"], "").require(Str)?,
      restarts: json.get(item, ["restarts"], 0).require(Int)?,
    }]
  }
  found
}

proc logs_of(value: Any) [error] -> Result[List[RemoteLog], Error] {
  var found: List[RemoteLog] = []
  for item in value.require(List[Record])? {
    found += [{
      path: json.get(item, ["path"], "").require(Str)?,
      readable: json.get(item, ["readable"], false).require(Bool)?,
      lines: json.get(item, ["lines"], []).require(List[Str])?,
    }]
  }
  found
}

## Reads the running generation receipt, health report and xinit service states.
export proc remote_inspect(session: RemoteSession, program: Str) [fs, net, error] -> Result[RemoteInspection, Error] {
  let reply = call(session, program, {protocol: REMOTE_PROTOCOL, op: "inspect"}, null, 30000)?
  {
    generation: json.get(reply, ["generation"], null),
    health: json.get(reply, ["health"], null),
    services: services_of(json.get(reply, ["services"], []))?,
    kernel: json.get(reply, ["kernel"], "").require(Str)?,
    hostname: json.get(reply, ["hostname"], "").require(Str)?,
  }
}

## Runs an explicit argv, without a shell, with the operator's authority.
export proc remote_run(session: RemoteSession, program: Str, argv: List[Str], timeout_ms: Int = 30000) [fs, net, error] -> Result[RemoteRun, Error] {
  let reply = call(session, program, {protocol: REMOTE_PROTOCOL, op: "run", argv: argv, timeout_ms: timeout_ms}, null, timeout_ms + 15000)?
  {
    exit_code: json.get(reply, ["exit_code"], -1).require(Int)?,
    signaled: json.get(reply, ["signaled"], false).require(Bool)?,
    stdout: json.get(reply, ["stdout_b64"], "").require(Str)?.base64_decode()?,
    stderr: json.get(reply, ["stderr_b64"], "").require(Str)?.base64_decode()?,
    truncated: json.get(reply, ["truncated"], false).require(Bool)?,
  }
}

## Computes the SHA-256 the guest must see for a local file.
export proc remote_digest(source: Path) [fs, error] -> Result[Str, Error] {
  hash.sha256(source)?.hex()
}

## Streams a local file into the operator's staging directory under `name`. The guest
## verifies the size and the caller's `sha256` (from a trusted receipt, not from the
## file just sent), publishes without replacing, and reports whether the file was
## staged now or was already present with the same digest. A different file already
## named `name` is refused, and a refused or interrupted transfer leaves no file.
## A failure after the request left is never retried here; reconcile with `remote_staged`.
## Verified staging is not an authenticity claim.
export proc remote_stage(session: RemoteSession, program: Str, source: Path, name: Str, sha256: Str, timeout_ms: Int = 600000) [fs, net, error] -> Result[RemoteStage, Error] {
  let size = source.metadata()?.size
  let reply = call(session, program, {protocol: REMOTE_PROTOCOL, op: "stage", name: name, size: size, sha256: sha256}, source, timeout_ms)?
  {
    outcome: json.get(reply, ["outcome"], "").require(Str)?,
    path: json.get(reply, ["path"], "").require(Str)?,
    size: json.get(reply, ["size"], 0).require(Int)?,
    sha256: json.get(reply, ["sha256"], "").require(Str)?,
  }
}

## Reports whether `name` is staged and with which digest, for reconciling an unknown outcome.
export proc remote_staged(session: RemoteSession, program: Str, name: Str) [fs, net, error] -> Result[RemoteStaged, Error] {
  let reply = call(session, program, {protocol: REMOTE_PROTOCOL, op: "staged", name: name}, null, 30000)?
  {
    present: json.get(reply, ["present"], false).require(Bool)?,
    size: json.get(reply, ["size"], 0).require(Int)?,
    sha256: json.get(reply, ["sha256"], "").require(Str)?,
    incoming: json.get(reply, ["incoming"], []).require(List[Str])?,
  }
}

## Collects bounded logs and unhealthy services.
export proc remote_diagnose(session: RemoteSession, program: Str) [fs, net, error] -> Result[RemoteDiagnosis, Error] {
  let reply = call(session, program, {protocol: REMOTE_PROTOCOL, op: "diagnose"}, null, 30000)?
  {
    services: services_of(json.get(reply, ["services"], []))?,
    unhealthy: services_of(json.get(reply, ["unhealthy"], []))?,
    logs: logs_of(json.get(reply, ["logs"], []))?,
  }
}

## Opens a fresh session and collects diagnostics, for use after a failure that left the earlier session unusable.
export proc remote_diagnose_afresh(target: RemoteTarget, program: Str) [fs, net, error] -> Result[RemoteDiagnosis, Error] {
  with session = remote_connect(target)? {
    return remote_diagnose(session, program)?
  }
  Err(RemoteError.Malformed(message: "unreachable"))
}

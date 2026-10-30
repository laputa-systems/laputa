##! Bounded QMP exchanges over a connected Unix stream.
## Whether a lost response may hide a completed mutation.
export enum QmpRequestKind { QmpReadOnly, QmpMutation }
## A command or a pause in milliseconds between commands in one QMP session.
export enum QmpStep { QmpExecute(Str, Str, QmpRequestKind), QmpDelay(Int) }
## Protocol failures, command rejections, and uncertain mutation outcomes.
export error QmpError = Protocol(message: Str) | Rejected(message: Str) | Indeterminate(operation: Str)

proc qmp_wait(fd: Int, event: Str, deadline: Int) -> Result[Unit, Error] {
  let remaining = deadline - time.monotonic()?
  if remaining <= 0 { return Err(QmpError.Protocol("QMP deadline expired")) }
  let ready = unix.poll_fd(fd, [event], timeout_ms: (remaining + 999999) / 1000000)?
  if !(event in ready) { return Err(QmpError.Protocol("QMP socket unavailable or timed out")) }
}

type QmpFrame = {message: Any, pending: Bytes}
type QmpReply = {value: Any, pending: Bytes}

proc qmp_frame(fd: Int, pending: Bytes, deadline: Int) -> Result[QmpFrame, Error] {
  var buffer = pending
  loop {
    if time.monotonic()? >= deadline { return Err(QmpError.Protocol("QMP deadline expired")) }
    let endings = regex.find_bytes("\n", buffer)?
    if !endings.is_empty() {
      let end = endings[0].start
      if end > 1048576 { return Err(QmpError.Protocol("QMP frame exceeds 1 MiB")) }
      let message = json.decode(buffer.slice(0, end).utf8()?)?
      if time.monotonic()? >= deadline { return Err(QmpError.Protocol("QMP deadline expired")) }
      return {message, pending: buffer.slice(end + 1)}
    }
    if buffer.len() > 1048576 { return Err(QmpError.Protocol("QMP frame exceeds 1 MiB")) }
    qmp_wait(fd, "readable", deadline)?
    let part = unix.read_fd(fd, 4096)?
    if part.len() == 0 { return Err(QmpError.Protocol("QMP socket closed")) }
    buffer = bytes.concat([buffer, part])
  }
}

proc qmp_send(fd: Int, payload: Bytes, deadline: Int) -> Result[Unit, Error] {
  var offset = 0
  while offset < payload.len() {
    qmp_wait(fd, "writable", deadline)?
    let written = unix.write_fd(fd, payload.slice(offset))?
    if written == 0 { return Err(QmpError.Protocol("QMP socket closed while writing")) }
    offset += written
  }
}

proc qmp_response(fd: Int, pending: Bytes, id: Int, deadline: Int) -> Result[QmpReply, Error] {
  var buffer = pending
  loop {
    let frame = qmp_frame(fd, buffer, deadline)?
    buffer = frame.pending
    let message = frame.message
    if json.get(message, ["event"], null) != null { continue }
    if json.get(message, ["id"], null) != id { return Err(QmpError.Protocol("unexpected QMP response id")) }
    let failure = json.get(message, ["error"], null)
    if failure != null { return Err(QmpError.Rejected(json.encode(failure)?)) }
    return {value: json.get(message, ["return"])?, pending: buffer}
  }
}

proc qmp_command(fd: Int, pending: Bytes, execute: Str, arguments: Any, id: Int, deadline: Int) -> Result[QmpReply, Error] {
  let request = json.encode({execute, arguments, id})? + "\n"
  qmp_send(fd, bytes.from_text(request), deadline)?
  qmp_response(fd, pending, id, deadline)?
}

## Execute ordered steps on one Linux connection with a session deadline.
export proc qmp_linux_run(socket: Path, steps: List[QmpStep], timeout_ms: Int) -> Result[Unit, Error] {
  if timeout_ms <= 0 { return Err(QmpError.Protocol("QMP timeout must be positive")) }
  let deadline = time.monotonic()? + timeout_ms * 1000000
  let constants = linux.net_constants()
  let fd = linux.socket(constants.AF_UNIX, constants.SOCK_STREAM + constants.SOCK_NONBLOCK)?
  defer unix.close_fd(fd)
  linux.connect(fd, {family: "unix", address: socket.display()})?
  let greeting = qmp_frame(fd, b"", deadline)?
  let _ = json.get(greeting.message, ["QMP"])?.require(Record)?
  let capabilities = qmp_command(fd, greeting.pending, "qmp_capabilities", {}, 1, deadline)?
  var pending = capabilities.pending
  var id = 2
  for step in steps {
    match step {
      QmpDelay(milliseconds) => {
        if milliseconds < 0 or milliseconds * 1000000 > deadline - time.monotonic()? {
          return Err(QmpError.Protocol("QMP delay exceeds deadline"))
        }
        time.sleep(time.millis(milliseconds))?
      },
      QmpExecute(execute, arguments, kind) => {
        let decoded = json.decode(arguments)?
        let result = qmp_command(fd, pending, execute, decoded, id, deadline)
        match result {
          Ok(reply) => {
            pending = reply.pending
            id += 1
          },
          Err(QmpError.Rejected {message}) => return Err(QmpError.Rejected(message)),
          Err(failure) => {
            if kind == QmpMutation { return Err(QmpError.Indeterminate(execute)) }
            return Err(failure)
          },
        }
      },
    }
  }
  Ok()
}

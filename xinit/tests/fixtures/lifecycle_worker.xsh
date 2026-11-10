#!/bin/xsh --
proc boot_ms() -> Result[Int] {
  time.boottime()? / 1000000
}

proc main(...argv: List[Str]) [fs, process, env, time, net, error] -> Result[Unit] {
  guard argv.len() >= 2 else {
    return Err(error.failure("lifecycle worker needs a name and a mode"))
  }

  let name = argv[0]
  let mode = argv[1]
  let events = p"/run/r1/events"
  let locks = p"/run/r1/locks"
  events.mkdir(parents: true)?
  locks.mkdir(parents: true)?
  let pid = process.current_pid()?
  let started = boot_ms()?
  let lock = match fs.lock(fp"{locks}/{name}.lock", nonblocking: true) {
    Ok(held) => held,
    Err(failure) => {
      fp"{events}/duplicate.{name}.{started}.{pid}".write(f"{failure.message}\n")?
      return Err(error.failure(f"duplicate {name}"))
    },
  }
  defer fs.unlock(lock)
  fp"{events}/start.{name}.{started}.{pid}".write(f"{started}\n")?

  var notify = ""
  if let Ok(value) = env.get("NOTIFY_FD") {
    notify = value
  }
  if ! notify.is_empty() {
    let fd = notify.parse_int() ?? -1
    if fd >= 0 {
      if mode != "slow" {
        let _ = unix.write_fd(fd, b"1")
      }
      let _ = unix.close_fd(fd)
    }
  }

  while true {
    time.sleep(500ms)?
  }

  Ok()
}

main(@args)?

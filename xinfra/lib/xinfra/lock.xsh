##! Per-host apply locks with boot-id stale proof.

use xinfra.transport as transport

## One lock owner record.
export type Owner = {
  token: Str,
  pid: Int,
  boot: Str,
  start: Int,
  host: Str,
}

pure owner_text(owner: Owner) -> Str {
  f"token={owner.token}\npid={owner.pid}\nboot={owner.boot}\nstart={owner.start}\nhost={owner.host}\n"
}

proc text(value: Bytes) -> Str {
  value.utf8() ?? ""
}

proc execute(session: transport.Session, argv: List[Str], elevate: List[Str] = []) -> Result[transport.ExecResult, Str] {
  transport.exec(session, elevate + argv)
}

proc boot_id(session: transport.Session) -> Result[Str, Str] {
  let result = execute(session, ["cat", "/proc/sys/kernel/random/boot_id"])?
  if result.exit_code != 0 {
    return Err(text(result.stderr).trim())
  }
  Ok(text(result.stdout).trim())
}

proc read_owner(session: transport.Session, lock_path: Path, elevate: List[Str] = []) -> Result[Owner?, Str] {
  let result = execute(session, ["cat", f"{lock_path.display()}/owner"], elevate)?
  if result.exit_code != 0 {
    return Ok(null)
  }
  var token = ""
  var pid = 0
  var boot = ""
  var start = 0
  var host = ""
  for line in text(result.stdout).lines() {
    let parts = line.split("=", maxsplit: 1)
    if parts.len() != 2 {
      continue
    }
    if parts[0] == "token" { token = parts[1] }
    if parts[0] == "pid" { pid = parts[1].parse_int() ?? 0 }
    if parts[0] == "boot" { boot = parts[1] }
    if parts[0] == "start" { start = parts[1].parse_int() ?? 0 }
    if parts[0] == "host" { host = parts[1] }
  }
  Ok(Owner(token: token, pid: pid, boot: boot, start: start, host: host))
}

proc write_owner(session: transport.Session, lock_path: Path, owner: Owner, elevate: List[Str] = []) -> Result[Unit, Str] {
  let result = transport.write_bytes(session, fp"{lock_path}/owner", bytes.from_text(owner_text(owner)), null, elevate)?
  if result.exit_code != 0 {
    return Err(text(result.stderr).trim())
  }
  Ok()
}

## Acquire one lock, optionally stealing a lock from an earlier boot.
export proc acquire(
  session: transport.Session,
  lock_path: Path,
  token: Str,
  host_name: Str,
  steal: Bool = false,
  elevate: List[Str] = [],
) -> Result[Str, Str] {
  let current_boot = boot_id(session)?
  let claimed = execute(session, ["mkdir", lock_path.display()], elevate)?
  if claimed.exit_code == 0 {
    let owner = Owner(
      token: token,
      pid: match process.current_pid() { Ok(value) => value, Err(_) => 0 },
      boot: current_boot,
      start: time.now(),
      host: host_name,
    )
    write_owner(session, lock_path, owner, elevate)?
    return Ok(token)
  }

  let owner = read_owner(session, lock_path, elevate)?
  if owner == null {
    return Err(f"lock {lock_path.display()} exists without an owner")
  }
  let current = owner ?? Owner(token: "", pid: 0, boot: "", start: 0, host: "")
  if steal and current.boot != current_boot {
    let _ = execute(session, ["rm", "-rf", lock_path.display()], elevate)?
    let reclaimed = execute(session, ["mkdir", lock_path.display()], elevate)?
    if reclaimed.exit_code == 0 {
      let replacement = Owner(
        token: token,
        pid: match process.current_pid() { Ok(value) => value, Err(_) => 0 },
        boot: current_boot,
        start: time.now(),
        host: host_name,
      )
      write_owner(session, lock_path, replacement, elevate)?
      return Ok(token)
    }
  }
  Err(f"locked by token {current.token} pid {current.pid} host {current.host} boot {current.boot}")
}

## Release a lock only when the caller still owns it.
export proc release(session: transport.Session, lock_path: Path, token: Str, elevate: List[Str] = []) -> Result[Unit, Str] {
  let owner = read_owner(session, lock_path, elevate)?
  if owner == null {
    return Err("lock is not held")
  }
  if (owner ?? Owner(token: "", pid: 0, boot: "", start: 0, host: "")).token != token {
    return Err("lock owner token differs")
  }
  let removed = execute(session, ["rm", "-rf", lock_path.display()], elevate)?
  if removed.exit_code != 0 {
    return Err(text(removed.stderr).trim())
  }
  Ok()
}

## Remove a lock regardless of its owner.
export proc unlock_force(session: transport.Session, lock_path: Path, elevate: List[Str] = []) -> Result[Unit, Str] {
  let removed = execute(session, ["rm", "-rf", lock_path.display()], elevate)?
  if removed.exit_code != 0 {
    return Err(text(removed.stderr).trim())
  }
  Ok()
}

## Read the current lock owner, if any.
export proc owner(session: transport.Session, lock_path: Path, elevate: List[Str] = []) -> Result[Owner?, Str] {
  read_owner(session, lock_path, elevate)
}

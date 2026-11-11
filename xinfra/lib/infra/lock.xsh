##! The remote apply lock: one directory per host, created atomically, holding
##! an ownership token the holder must present to release it. A lock is never
##! taken over because it looks old or its holder looks gone; an operator
##! releases a stale lock by naming the token it holds.

use infra.probe
use infra.scripts
use infra.transport

## A lock this controller holds: where it is and the token that proves it.
export type Held = {path: Str, token: Str}

## Why the lock was not taken.
export error LockError =
  Contended(holder: Str) |
  Failed(message: Str)

pure holder_text(controller: Str, pid: Int, now: Int) -> Str {
  f"xinfra controller {controller} pid {pid} at {now}"
}

pure hex_or_raw(text: Str) -> Str {
  probe.decode_hex(text.trim()) ?? text.trim()
}

## Take the lock on a host, or fail with the holder's own description.
export proc acquire(connection: transport.Connection, lock_path: Str) [env, process, time, error] -> Result[Held, LockError] {
  let controller = system.hostname() ?? "unknown"
  let pid = process.current_pid() ?? 0
  let holder = holder_text(controller, pid, time.now())
  match transport.exec(connection, scripts.acquire_lock, [lock_path, holder], privileged: true) {
    Err(error) => Err(LockError.Failed(error.message), cause: error)
    Ok(execution) => {
      let text = execution.stdout.utf8() ?? ""
      if execution.code == 0 and text.starts_with("acquired ") {
        Ok(Held(path: lock_path, token: text.byte_slice(9).trim()))
      } else if execution.code == 75 and text.starts_with("held ") {
        Err(LockError.Contended(hex_or_raw(text.byte_slice(5))))
      } else {
        Err(LockError.Failed(execution.stderr.utf8() ?? f"exit {execution.code}"))
      }
    }
  }
}

## Release a lock this controller holds. A lock held under another token is
## left alone and reported.
export proc release(connection: transport.Connection, held: Held) [process, error] -> Result[Unit, LockError] {
  match transport.exec(connection, scripts.release_lock, [held.path, held.token], privileged: true) {
    Err(error) => Err(LockError.Failed(error.message), cause: error)
    Ok(execution) => {
      guard execution.code == 0 else {
        return Err(LockError.Failed((execution.stderr.utf8() ?? "").trim()))
      }
    }
  }
}

## Describe the holder of a host's lock, or null when it is free.
export proc inspect(connection: transport.Connection, lock_path: Str) [process, error] -> Result[Str?, LockError] {
  let execution = match transport.exec(connection, scripts.inspect_lock, [lock_path], privileged: true) {
    Err(error) => {
      return Err(LockError.Failed(error.message), cause: error)
    }
    Ok(found) => found
  }

  if execution.code != 0 {
    return Err(LockError.Failed((execution.stderr.utf8() ?? f"exit {execution.code}").trim()))
  }

  let text = execution.stdout.utf8() ?? ""
  if text.starts_with("state free") {
    return Ok(null)
  }

  let table = text.lines() |> where { |line| line.starts_with("holder ") } |> collect()
  Ok(if table.is_empty() { "(unknown holder)" } else { hex_or_raw(table[0].byte_slice(7)) })
}

## Remove a lock after an operator has confirmed its token, for example after a
## controller crash. The token must match the one on the host.
export proc break_lock(connection: transport.Connection, lock_path: Str, token: Str) [process, error] -> Result[Unit, LockError] {
  release(connection, Held(path: lock_path, token:))
}

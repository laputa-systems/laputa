##! Per-host lock matrix.

use xinfra.lock as lock
use xinfra.transport as transport

type Fixture = {host: Str, port: Int, username: Str, key: Path, host_key: Str}

proc required(name: Str) [env, error] -> Result[Str, Str] {
  match env.get(name) {
    Ok(value) => Ok(value),
    Err(error) => Err(f"missing {name}: {error.message}"),
  }
}

proc fixture(suffix: Str) [env, error] -> Result[Fixture, Str] {
  let host = required(f"XINFRA_FIXTURE_{suffix}_HOST")?
  let port_text = required(f"XINFRA_FIXTURE_{suffix}_PORT")?
  let port = match port_text.parse_int() {
    Ok(value) => value,
    Err(error) => { return Err(error.message) },
  }
  let username = required("XINFRA_FIXTURE_USER")?
  let key_text = required("XINFRA_FIXTURE_KEY")?
  let host_key = required(f"XINFRA_FIXTURE_{suffix}_HOST_KEY")?
  Ok({host: host, port: port, username: username, key: fp"{key_text}", host_key: host_key})
}

proc require(condition: Bool, message: Str) -> Result[Unit, Str] {
  if condition { Ok() } else { Err(message) }
}

proc connect(fixture: Fixture) [error] -> Result[transport.Session, Str] {
  transport.connect_endpoint(fixture.host, fixture.port, fixture.username, fixture.key, fixture.host_key)
}

pure test_case(label: Str) -> Str {
  f"ok {label}"
}

## Executes the lock matrix.
export proc check_lock() [fs, process, env, time, error, io] -> Result[Unit, Str] {
  let a = fixture("A")?
  let lock_path = p"/home/xinfra/xinfra-r6-lock"
  let first = connect(a)?
  let second = connect(a)?

  let _ = lock.unlock_force(first, lock_path)?
  let _ = lock.acquire(first, lock_path, "one", "xinfra-a")?
  let contender = match lock.acquire(second, lock_path, "two", "xinfra-a") {
    Ok(_) => false,
    Err(_) => true,
  }
  require(contender, "two holders acquired the same lock")?
  let current = lock.owner(second, lock_path)?
  require(current != null, "lock owner is missing")?
  require((current?.token ?? "") == "one", "lock owner token is wrong")?
  let _ = lock.release(first, lock_path, "one")?
  let _ = lock.acquire(second, lock_path, "two", "xinfra-a")?
  let _ = lock.release(second, lock_path, "two")?
  print test_case("one lock holder")

  let _ = lock.acquire(first, lock_path, "stale", "xinfra-a")?
  let stale = "token=dead\npid=1\nboot=different-boot\nstart=1\nhost=xinfra-a\n"
  let _ = transport.write_bytes(second, fp"{lock_path}/owner", bytes.from_text(stale))?
  let refused = match lock.acquire(second, lock_path, "next", "xinfra-a", false) {
    Ok(_) => false,
    Err(_) => true,
  }
  require(refused, "same-boot stale lock was stolen without proof")?
  let stolen = lock.acquire(second, lock_path, "next", "xinfra-a", true)?
  require(stolen == "next", "boot-id stale proof did not reclaim the lock")?
  let _ = lock.release(second, lock_path, "next")?
  print test_case("boot-id stale proof")

  let _ = lock.acquire(first, lock_path, "forced", "xinfra-a")?
  let _ = lock.unlock_force(second, lock_path)?
  let _ = lock.acquire(second, lock_path, "after", "xinfra-a")?
  let _ = lock.release(second, lock_path, "after")?
  print test_case("explicit unlock")

  Ok()
}

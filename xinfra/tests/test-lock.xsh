use infra.lock
use infra.testing
use infra.transport

test only_one_controller_holds_the_lock_at_a_time { |ctx|
  let dir = test.temp_dir(ctx)?
  let lock_dir = f"{dir}/xinfra.lock"
  let connection = transport.connect(testing.local_host())?
  let held = lock.acquire(connection, lock_dir)?
  assert held.token != ""
  match lock.acquire(connection, lock_dir) {
    Err(lock.LockError.Contended {holder}) => {
      assert held.token in holder
      assert "xinfra controller" in holder
    }
    else => assert false, "a second controller took the lock"
  }
  lock.release(connection, held)?
  let again = lock.acquire(connection, lock_dir)?
  assert again.token != held.token
}

test a_lock_is_released_only_with_its_own_token { |ctx|
  let dir = test.temp_dir(ctx)?
  let lock_dir = f"{dir}/xinfra.lock"
  let connection = transport.connect(testing.local_host())?
  let held = lock.acquire(connection, lock_dir)?
  assert lock.release(connection, lock.Held(path: lock_dir, token: "not-the-token")) is Err(_)
  assert lock.inspect(connection, lock_dir)? != null
  lock.release(connection, held)?
  assert lock.inspect(connection, lock_dir)? == null
}

test an_operator_can_break_a_stale_lock_by_naming_its_token { |ctx|
  let dir = test.temp_dir(ctx)?
  let lock_dir = f"{dir}/xinfra.lock"
  let connection = transport.connect(testing.local_host())?
  let held = lock.acquire(connection, lock_dir)?
  let holder = lock.inspect(connection, lock_dir)? ?? ""
  let token = holder.fields()[0]
  assert token == held.token
  lock.break_lock(connection, lock_dir, token)?
  assert lock.inspect(connection, lock_dir)? == null
}

test an_old_lock_is_never_taken_over { |ctx|
  let dir = test.temp_dir(ctx)?
  let lock_dir = f"{dir}/xinfra.lock"
  let connection = transport.connect(testing.local_host())?
  let held = lock.acquire(connection, lock_dir)?
  run touch -d "2001-01-01" $lock_dir
  assert lock.acquire(connection, lock_dir) is Err(_)
  lock.release(connection, held)?
}

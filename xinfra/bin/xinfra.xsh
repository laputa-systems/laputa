#!/usr/bin/env -S xsh --
##! xinfra: reconcile Alpine/Laputa-style hosts over native SSH.
##!
##!   xinfra doctor INVENTORY
##!   xinfra plan INVENTORY DEPLOYMENT
##!   xinfra check INVENTORY DEPLOYMENT
##!   xinfra apply INVENTORY DEPLOYMENT
##!   xinfra unlock INVENTORY HOST [--token TOKEN]
##!
##! Exit status: 0 success, 1 drift found by `check`, 2 invalid input before any
##! host was touched, 3 a host failed or an outcome needs attention.

use infra.app
use infra.engine

proc options(limit: List[Str], jobs: Int, format: Str, verbose: Bool, failure: Str, lock_path: Str) -> Result[app.Options, Error] {
  guard jobs >= 1 and jobs <= 64 else {
    fail "--jobs must be 1..64"
  }

  Ok(app.Options(
    limit:,
    jobs:,
    format: app.format_of(format)?,
    verbose:,
    failure: app.policy_of(failure)?,
    lock_path:,
  ))
}

proc finish(status: Result[Int, Error]) [io] {
  match status {
    Ok(code) => exit code
    Err(error) => {
      eprint f"xinfra: {error.message}"
      exit 2
    }
  }
}

## Validate configuration and remote capabilities of the selected hosts.
cli main doctor(
  inventory: Path,
  limit: List[Str] = [],
  jobs: Int = 4,
  format: Str = "text",
  verbose: Bool = false,
  lock_path: Str = "/run/xinfra.lock",
) [fs, env, process, io, error] {
  let chosen = options(limit, jobs, format, verbose, "host", lock_path)
  finish(match chosen {
    Ok(value) => app.doctor_command(inventory, value)
    Err(error) => Err(error)
  })
}

## Read each host's facts and report the changes apply would make.
cli main plan(
  inventory: Path,
  deploy: Path,
  limit: List[Str] = [],
  jobs: Int = 4,
  format: Str = "text",
  verbose: Bool = false,
  lock_path: Str = "/run/xinfra.lock",
) [fs, env, process, io, error] {
  let chosen = options(limit, jobs, format, verbose, "host", lock_path)
  finish(match chosen {
    Ok(value) => app.survey_command(engine.Plan, inventory, deploy, value)
    Err(error) => Err(error)
  })
}

## Report whether each host complies with the deployment; exit 1 on drift.
cli main check(
  inventory: Path,
  deploy: Path,
  limit: List[Str] = [],
  jobs: Int = 4,
  format: Str = "text",
  verbose: Bool = false,
  lock_path: Str = "/run/xinfra.lock",
) [fs, env, process, io, error] {
  let chosen = options(limit, jobs, format, verbose, "host", lock_path)
  finish(match chosen {
    Ok(value) => app.survey_command(engine.Check, inventory, deploy, value)
    Err(error) => Err(error)
  })
}

## Reconcile each host with the deployment, then verify.
cli main apply(
  inventory: Path,
  deploy: Path,
  limit: List[Str] = [],
  jobs: Int = 4,
  format: Str = "text",
  verbose: Bool = false,
  failure: Str = "host",
  lock_path: Str = "/run/xinfra.lock",
) [fs, env, process, time, io, error] {
  let chosen = options(limit, jobs, format, verbose, failure, lock_path)
  finish(match chosen {
    Ok(value) => app.apply_command(inventory, deploy, value)
    Err(error) => Err(error)
  })
}

## Show a host's lock holder, or release it when --token names the token on the host.
cli main unlock(
  inventory: Path,
  host: Str,
  token: Str = "",
  lock_path: Str = "/run/xinfra.lock",
) [fs, env, process, io, error] {
  let named: Str? = if token == "" { null } else { token }
  finish(app.unlock_command(inventory, host, named, lock_path))
}

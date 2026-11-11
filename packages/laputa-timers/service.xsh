##! xinit service for the supervised timer scheduler.
##!
##! One foreground process owns every job; PID 1 supervises only this process.
##! Readiness is notify: the scheduler writes the byte once the state file, the
##! cancellation markers and the job definitions are loaded and the live
##! snapshot is published. Readiness means armed, not that any job has run.

## The exact scheduler invocation for the maintained profile.
export pure timers_argv() -> List[Str] {
  ["xsh", "/usr/lib/laputa/timers-run.xsh", "run"]
}

## The xinit service record. Nothing takes `need` on the scheduler: a broken
## timer definition must not hold back boot, rescue or login.
export let service = {
  name: "laputa-timers",
  kind: "longrun",
  command: process.command_argv(p"/usr/bin/xsh", timers_argv(), env: {XSH_MODULE_PATH: "/usr/lib/xsh/core"}),
  targets: [
    "boot",
  ],
  readiness: "notify",
  ready_timeout_ms: 5000,
  stop_timeout_ms: 5000,
  restart: {
    mode: "always",
    delay_ms: 1000,
    max_delay_ms: 30000,
    stable_after_ms: 10000,
  },
  logging: "append",
}

## Reports how many jobs are armed and due from the live snapshot.
export proc status() [fs, process, env, error] -> Result[Str, Error] {
  let snapshot = fp"/run/laputa-timers/status.json"
  return Ok("jobs=unknown") unless snapshot.exists()
  match json.read(snapshot) {
    Ok(value) => {
      let jobs = json.get(value, ["jobs"], []).require(List[Any]) ?? []
      let invalid = json.get(value, ["invalid"], []).require(List[Any]) ?? []
      var due = 0
      var running = 0
      for job in jobs {
        let state = json.get(job, ["state"], "").require(Str) ?? ""
        if state == "due" {
          due += 1
        }
        if state == "running" {
          running += 1
        }
      }
      Ok(f"jobs={jobs.len()} due={due} running={running} invalid={invalid.len()}")
    }
    Err(_) => Ok("jobs=unknown"),
  }
}

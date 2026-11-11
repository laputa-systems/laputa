##! The command-line application: load, validate, run, render. `bin/xinfra.xsh`
##! only parses options and calls these.

use infra.deployment
use infra.doctor
use infra.engine
use infra.inventory
use infra.lock
use infra.model
use infra.report
use infra.transport
use infra.workload

## How a report is written.
export enum Format: Str { Text = "text", Json = "json", Jsonl = "jsonl" }

## Options every run command shares.
export type Options = {
  limit: List[Str],
  jobs: Int,
  format: Format,
  verbose: Bool,
  failure: engine.FailurePolicy,
  lock_path: Str,
}

## Read a `--format` value.
export pure format_of(text: Str) -> Result[Format, Error] {
  match text {
    "text" => Ok(Text)
    "json" => Ok(Json)
    "jsonl" => Ok(Jsonl)
    else => {
      fail f"--format must be text, json or jsonl, not {text}"
    }
  }
}

## Read a `--failure` value.
export pure policy_of(text: Str) -> Result[engine.FailurePolicy, Error] {
  match text {
    "host" => Ok(engine.Host)
    "abort" => Ok(engine.Abort)
    "continue" => Ok(engine.Continue)
    else => {
      fail f"--failure must be host, abort or continue, not {text}"
    }
  }
}

## Render a report in the chosen format.
export pure render(result: report.Report, options: Options) -> Result[Str, Error] {
  match options.format {
    Text => Ok(report.text(result, options.verbose))
    Json => report.json_document(result)
    Jsonl => report.json_lines(result)
  }
}

proc declare_all(hosts: List[model.Host], deployed: deployment.Deployment) [fs, env, error] -> Result[List[workload.Workload], Error] {
  var declared: List[workload.Workload] = []
  for host in hosts {
    let resources = ctx f"host {host.name}" { deployed.resources(host)? }
    declared += [workload.Workload(host:, resources:)]
  }

  Ok(declared)
}

proc prepare(inventory_file: Path, deploy_file: Path, options: Options) [fs, env, error] -> Result[workload.Prepared, Error] {
  let loaded = inventory.load(inventory_file)?
  let hosts = inventory.select(loaded, options.limit)?
  let deployed = deployment.load(deploy_file)?
  workload.prepare(declare_all(hosts, deployed)?)?
}

pure settings_of(options: Options) -> engine.Settings {
  engine.Settings(jobs: options.jobs, policy: options.failure, lock_path: options.lock_path)
}

## Validate configuration and remote capabilities of the selected hosts.
export proc doctor_command(inventory_file: Path, options: Options) [fs, env, process, error] -> Result[Int, Error] {
  let loaded = inventory.load(inventory_file)?
  let hosts = inventory.select(loaded, options.limit)?
  let result = doctor.inspect(hosts, options.lock_path, options.jobs)
  print (render(result, options)?)
  Ok(report.exit_status(result))
}

## Run `plan` or `check`: validate, observe and report. Nothing is mutated.
export proc survey_command(mode: engine.Mode, inventory_file: Path, deploy_file: Path, options: Options) [fs, env, process, error] -> Result[Int, Error] {
  let prepared = prepare(inventory_file, deploy_file, options)?
  let result = engine.survey(mode, prepared, settings_of(options))
  print (render(result, options)?)
  Ok(report.exit_status(result))
}

## Run `apply`: validate, lock, reconcile and verify.
export proc apply_command(inventory_file: Path, deploy_file: Path, options: Options) [fs, env, process, time, io, error] -> Result[Int, Error] {
  let prepared = prepare(inventory_file, deploy_file, options)?
  let result = engine.apply(prepared, settings_of(options))
  print (render(result, options)?)
  Ok(report.exit_status(result))
}

## Show a host's lock holder, or release it when `token` is the one on the host.
export proc unlock_command(inventory_file: Path, host_name: Str, token: Str?, lock_path: Str) [fs, env, process, error] -> Result[Int, Error] {
  let loaded = inventory.load(inventory_file)?
  let hosts = inventory.select(loaded, [host_name])?
  guard hosts.len() == 1 else {
    fail f"{host_name} names a group; name one host"
  }

  let target = lock_path.replace("{host}", with: host_name)
  let connection = match transport.connect(hosts[0]) {
    Ok(opened) => opened
    Err(error) => {
      fail error.message
    }
  }

  let holder = match lock.inspect(connection, target) {
    Ok(found) => found
    Err(error) => {
      fail error.message
    }
  }

  if token == null {
    print (if holder == null { f"{host_name}: lock {target} is free" } else { f"{host_name}: lock {target} is held: {report.sanitize(holder)}" })
    return Ok(0)
  }

  guard holder != null else {
    print f"{host_name}: lock {target} is already free"
    return Ok(0)
  }

  match lock.break_lock(connection, target, token) {
    Ok(_) => {
      print f"{host_name}: released {target}"
      Ok(0)
    }
    Err(error) => {
      fail error.message
    }
  }
}

##! Reading host state. Every observation is a fresh read through the
##! transport; nothing is cached, so no read can outlive a mutation. An
##! observation never mutates.

use infra.fact
use infra.model
use infra.probe
use infra.scripts
use infra.transport

pure unreadable(cause: fact.Cause, detail: Str) -> fact.Unreadable {
  fact.Unreadable(cause:, detail:)
}

pure report(execution: transport.Execution) -> Result[Str, fact.Unreadable] {
  if execution.code != 0 {
    let stderr = execution.stderr.utf8() ?? "(stderr is not text)"
    return Err(unreadable(.Unavailable, f"exit {execution.code}: {stderr.trim()}"))
  }

  match execution.stdout.utf8() {
    Ok(text) => Ok(text)
    Err(_) => Err(unreadable(.Malformed, "the report is not valid UTF-8"))
  }
}

proc read(connection: transport.Connection, script: Str, args: List[Str]) [process, error] -> Result[transport.Execution, transport.TransportError] {
  transport.exec(connection, script, args, privileged: connection.escalate_reads)
}

## The state of one path as the host reports it.
export proc path_state(connection: transport.Connection, target: Str) [process, error] -> Result[fact.PathState, transport.TransportError] {
  let execution = read(connection, scripts.path_state, [target])?
  match report(execution) {
    Ok(text) => Ok(probe.path_fact(text))
    Err(reason) => Ok(fact.Unseen(reason))
  }
}

proc package_state(connection: transport.Connection, spec: model.PackageSpec) [process, error] -> Result[fact.PackageState, transport.TransportError] {
  let wanted = if spec.constraint == null { "" } else { spec.constraint.version }
  let execution = read(connection, scripts.package_state, [spec.name, wanted])?
  match report(execution) {
    Ok(text) => Ok(probe.package_fact(text))
    Err(reason) => Ok(fact.PackageUnseen(reason))
  }
}

proc accounts(connection: transport.Connection) [process, error] -> Result[probe.AccountsState, transport.TransportError] {
  let execution = read(connection, scripts.accounts_state, [])?
  match report(execution) {
    Ok(text) => Ok(probe.accounts(text))
    Err(reason) => Ok(probe.AccountsUnseen(reason))
  }
}

proc service_state(connection: transport.Connection, spec: model.ServiceSpec) [process, error] -> Result[fact.ServiceState, transport.TransportError] {
  let execution = read(connection, scripts.service_state, [spec.name, spec.runlevel])?
  match report(execution) {
    Ok(text) => Ok(probe.service_fact(text))
    Err(reason) => Ok(fact.ServiceUnseen(reason))
  }
}

proc guard_state(connection: transport.Connection, invocation: model.Invocation) [process, error] -> Result[fact.GuardState, transport.TransportError] {
  let execution = match invocation {
    model.Argv(argv) => read(connection, scripts.run_argv, argv)?
    model.Shell(text) => read(connection, scripts.run_shell, [text])?
  }
  Ok(fact.Exited(execution.code))
}

## Read the fact a resource's spec is compared with.
export proc observe(connection: transport.Connection, spec: model.Spec) [process, error] -> Result[fact.Fact, transport.TransportError] {
  match spec {
    model.Directory(directory) => Ok(fact.OnPath(path_state(connection, directory.path)?))
    model.File(file) => Ok(fact.OnPath(path_state(connection, file.path)?))
    model.Link(link) => Ok(fact.OnPath(path_state(connection, link.path)?))
    model.Package(package) => Ok(fact.OnPackage(package_state(connection, package)?))
    model.PackageIndex(_) => Ok(fact.Nothing)
    model.GroupAccount(account_group) => {
      match accounts(connection)? {
        probe.AccountsFound(found) => Ok(fact.OnGroup(probe.group_fact(found, account_group.name)))
        probe.AccountsUnseen(reason) => Ok(fact.OnGroup(fact.GroupUnseen(reason)))
      }
    }
    model.UserAccount(account) => {
      match accounts(connection)? {
        probe.AccountsFound(found) => Ok(fact.OnUser(probe.user_fact(found, account.name)))
        probe.AccountsUnseen(reason) => Ok(fact.OnUser(fact.UserUnseen(reason)))
      }
    }
    model.Service(service) => Ok(fact.OnService(service_state(connection, service)?))
    model.Exec(command) => {
      match command.guard {
        model.Creates(target) => Ok(fact.OnPath(path_state(connection, target)?))
        model.SkipIf(invocation) => Ok(fact.OnGuard(guard_state(connection, invocation)?))
        model.OnlyIf(invocation) => Ok(fact.OnGuard(guard_state(connection, invocation)?))
        model.Always => Ok(fact.Nothing)
        model.OnChange => Ok(fact.Nothing)
      }
    }
  }
}

## The tools a host has and the authority it runs as, for `doctor`.
export proc capabilities(connection: transport.Connection) [process, error] -> Result[probe.Capabilities, transport.TransportError] {
  let execution = transport.exec(connection, scripts.capabilities)?
  guard execution.code == 0 else {
    return Err(transport.TransportError.Abnormal(f"the capability probe exited {execution.code}"))
  }

  match execution.stdout.utf8() {
    Err(_) => Err(transport.TransportError.Abnormal("the capability report is not valid UTF-8"))
    Ok(text) => {
      match probe.capabilities(text) {
        Ok(found) => Ok(found)
        Err(error) => Err(transport.TransportError.Abnormal(error.message))
      }
    }
  }
}

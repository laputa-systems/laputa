##! Reconciliation across hosts. Plan and check observe and compare; apply
##! walks one shared operation sequence, each operation a barrier: it
##! finishes or fails on every participating host before the next starts,
##! and hosts inside an operation run concurrently up to the job bound. A
##! failed host is data, not a fleet-wide abort.

use infra.compare
use infra.content
use infra.fact
use infra.lock
use infra.model
use infra.mutate
use infra.observe
use infra.outcome
use infra.report
use infra.transport
use infra.workload

## Which command is being run.
export enum Mode: Str { Plan = "plan", Check = "check", Apply = "apply" }

## What a failure stops: the failed host's later resources (`Host`, the
## default), every host's later operations (`Abort`), or only resources that
## depend on the failed one (`Continue`).
export enum FailurePolicy: Str { Host = "host", Abort = "abort", Continue = "continue" }

## Run-wide knobs. `lock_path` may contain `{host}`, replaced by the host name,
## for hosts that share a filesystem.
export type Settings = {jobs: Int, policy: FailurePolicy, lock_path: Str}

pure clean(text: Str, secrets: List[Str]) -> Str {
  report.sanitize(report.redact(text, secrets))
}

pure find_resource(resources: List[model.Resource], id: Str) -> model.Resource? {
  let found = resources |> where { |resource| resource.id == id } |> collect()
  if found.is_empty() { null } else { found[0] }
}

pure intersects(left: List[Str], right: List[Str]) -> Bool {
  left |> any { |id| id in right }
}

pure verdict_entry(host: Str, resource: model.Resource, verdict: compare.Verdict, conditional: Bool, secrets: List[Str]) -> report.Entry {
  let kind = model.kind(resource.spec)
  match verdict {
    compare.Satisfied => report.Entry(host:, id: resource.id, kind:, status: "satisfied", act: null, changes: [], conditional:, phase: null, detail: null, verified: null)
    compare.Drifted(drift) => report.Entry(host:, id: resource.id, kind:, status: "drift", act: f"{drift.act}", changes: drift.changes, conditional:, phase: null, detail: null, verified: null)
    compare.Conflicting(reason) => report.Entry(host:, id: resource.id, kind:, status: "conflict", act: null, changes: [], conditional:, phase: null, detail: clean(reason, secrets), verified: null)
    compare.Uncertain(reason) => report.Entry(host:, id: resource.id, kind:, status: "uncertain", act: null, changes: [], conditional:, phase: "observe", detail: clean(f"{reason.cause}: {reason.detail}", secrets), verified: null)
    compare.Unevaluated(reason) => report.Entry(host:, id: resource.id, kind:, status: "not-evaluated", act: null, changes: [], conditional:, phase: null, detail: reason, verified: null)
  }
}

pure planned_change(mode: Mode, verdict: compare.Verdict) -> Bool {
  match verdict {
    compare.Drifted(_) => true
    compare.Unevaluated(_) => mode == .Plan
    else => false
  }
}

pure material_for(prepared: workload.Prepared, host: Str, resource: model.Resource) -> compare.Material? {
  let found = prepared.materials.get(workload.material_key(host, resource.id))
  match found {
    Ok(material) => material
    Err(_) => null
  }
}

proc survey_host(mode: Mode, entry: workload.Workload, prepared: workload.Prepared) [fs, env, process, error] -> report.HostReport {
  let name = entry.host.name
  let secrets = prepared.secrets
  let connection = match transport.connect(entry.host) {
    Ok(opened) => opened
    Err(error) => {
      return report.HostReport(host: name, ok: false, phase: "connect", detail: clean(error.message, secrets), entries: [])
    }
  }

  var entries: List[report.Entry] = []
  var planned: List[Str] = []
  for resource in entry.resources {
    let state = match observe.observe(connection, resource.spec) {
      Ok(found) => found
      Err(error) => {
        let _ = transport.disconnect(connection)
        return report.HostReport(host: name, ok: false, phase: "observe", detail: clean(f"{resource.id}: {error.message}", secrets), entries:)
      }
    }

    let verdict = compare.verdict(resource.spec, state, material_for(prepared, name, resource), planned)
    let conditional = intersects(model.dependencies(resource), planned)
    entries += [verdict_entry(name, resource, verdict, conditional, secrets)]
    if planned_change(mode, verdict) {
      planned += [resource.id]
    }
  }

  let _ = transport.disconnect(connection)
  report.HostReport(host: name, ok: true, phase: null, detail: null, entries:)
}

## Observe every selected host and report what apply would change. Nothing is
## mutated, no lock is taken, and each host is connected only for the read.
export proc survey(mode: Mode, prepared: workload.Prepared, settings: Settings) [fs, env, process, error] -> report.Report {
  let hosts = prepared.workloads |> par-map(jobs: settings.jobs) { |entry| survey_host(mode, entry, prepared) } |> collect()
  report.Report(mode: f"{mode}", hosts:)
}

type HostState = {
  workload: workload.Workload,
  connection: transport.Connection?,
  held: lock.Held?,
  fatal: Str?,
  fatal_phase: Str?,
  stopped: Str?,
  active: Str?,
  changed: List[Str],
  unsettled: List[Str],
  entries: List[report.Entry],
}

type Step = {state: HostState, resource: model.Resource}

type Reconciled = {host: Str, id: Str, outcome: outcome.Outcome, entry: report.Entry}

pure outcome_entry(host: Str, resource: model.Resource, result: outcome.Outcome, secrets: List[Str]) -> report.Entry {
  let kind = model.kind(resource.spec)
  match result {
    outcome.Unchanged => report.Entry(host:, id: resource.id, kind:, status: "unchanged", act: null, changes: [], conditional: false, phase: null, detail: null, verified: null)
    outcome.Changed(applied) => report.Entry(host:, id: resource.id, kind:, status: "changed", act: null, changes: applied.changes, conditional: false, phase: null, detail: null, verified: applied.verified)
    outcome.Skipped(reason) => report.Entry(host:, id: resource.id, kind:, status: "skipped", act: null, changes: [], conditional: false, phase: null, detail: clean(reason, secrets), verified: null)
    outcome.Blocked(reason) => report.Entry(host:, id: resource.id, kind:, status: "blocked", act: null, changes: [], conditional: false, phase: null, detail: clean(reason, secrets), verified: null)
    outcome.Failed(failure) => report.Entry(host:, id: resource.id, kind:, status: "failed", act: null, changes: [], conditional: false, phase: f"{failure.phase}", detail: clean(failure.message, secrets), verified: null)
    outcome.PartiallyApplied(failure) => report.Entry(host:, id: resource.id, kind:, status: "partial", act: null, changes: [], conditional: false, phase: f"{failure.phase}", detail: clean(failure.message, secrets), verified: null)
    outcome.OutcomeUnknown(failure) => report.Entry(host:, id: resource.id, kind:, status: "unknown", act: null, changes: [], conditional: false, phase: f"{failure.phase}", detail: clean(failure.message, secrets), verified: null)
  }
}

pure failed_at(phase: outcome.Phase, message: Str) -> outcome.Outcome {
  outcome.Failed(outcome.Failure(phase:, message:))
}

pure unknown_at(phase: outcome.Phase, message: Str) -> outcome.Outcome {
  outcome.OutcomeUnknown(outcome.Failure(phase:, message:))
}

pure skip_reason(spec: model.Spec) -> Str {
  match spec {
    model.Exec(command) => {
      match command.guard {
        model.Creates(target) => f"{target} already exists"
        model.SkipIf(_) => "the skip guard succeeded"
        model.OnlyIf(_) => "the only-if guard failed"
        model.OnChange => "no triggering resource changed"
        model.Always => "always runs"
      }
    }
    else => "condition not met"
  }
}

pure verifiable(spec: model.Spec) -> Bool {
  match spec {
    model.PackageIndex(_) => false
    model.Exec(command) => {
      match command.guard {
        model.Creates(_) => true
        model.SkipIf(_) => true
        else => false
      }
    }
    else => true
  }
}

proc verify(
  connection: transport.Connection,
  resource: model.Resource,
  applied: compare.Drift,
  material: compare.Material?,
) [fs, env, process, error] -> outcome.Outcome {
  let confirmed = outcome.Changed(outcome.Applied(changes: applied.changes, verified: true))
  match observe.observe(connection, resource.spec) {
    Err(error) => unknown_at(.Verify, f"the change was applied but could not be checked: {error.message}")
    Ok(state) => {
      match compare.verdict(resource.spec, state, material, []) {
        compare.Satisfied => confirmed
        compare.Unevaluated(_) => confirmed
        compare.Uncertain(reason) => unknown_at(.Verify, f"the change was applied but the result could not be read: {reason.detail}")
        compare.Drifted(drift) => failed_at(.Verify, f"after the change the host still differs in {changed_fields(drift)}")
        compare.Conflicting(reason) => failed_at(.Verify, f"after the change the host conflicts: {reason}")
      }
    }
  }
}

pure changed_fields(drift: compare.Drift) -> Str {
  let fields = drift.changes |> map { |change| change.field } |> collect()
  fields.join(", ")
}

proc confirm(
  connection: transport.Connection,
  resource: model.Resource,
  drift: compare.Drift,
  material: compare.Material?,
) [fs, env, process, error] -> outcome.Outcome {
  if ! verifiable(resource.spec) {
    return outcome.Changed(outcome.Applied(changes: drift.changes, verified: false))
  }

  verify(connection, resource, drift, material)
}

proc run_drift(
  connection: transport.Connection,
  resource: model.Resource,
  state: fact.Fact,
  drift: compare.Drift,
  material: compare.Material?,
) [fs, env, process, error] -> outcome.Outcome {
  match mutate.apply(connection, resource, state, drift, declared_content(resource), material) {
    Err(failure) => outcome.of_error(failure)
    Ok(_) => confirm(connection, resource, drift, material)
  }
}

pure declared_content(resource: model.Resource) -> model.Content? {
  match resource.spec {
    model.File(spec) => spec.content
    else => null
  }
}

pure file_spec(resource: model.Resource) -> model.FileSpec? {
  match resource.spec {
    model.File(spec) => spec
    else => null
  }
}

proc fresh_material(resource: model.Resource) [fs, env, error] -> Result[compare.Material?, Error] {
  guard let spec = file_spec(resource) else {
    return Ok(null)
  }

  guard let source = spec.content else {
    return Ok(null)
  }

  if spec.presence == .Absent {
    return Ok(null)
  }

  let measured = content.measure(source)?
  Ok(measured)
}

proc settle(
  connection: transport.Connection,
  resource: model.Resource,
  state: fact.Fact,
  material: compare.Material?,
  changed: List[Str],
) [fs, env, process, error] -> outcome.Outcome {
  match compare.verdict(resource.spec, state, material, changed) {
    compare.Satisfied => {
      match resource.spec {
        model.Exec(_) => outcome.Skipped(skip_reason(resource.spec))
        else => outcome.Unchanged
      }
    }
    compare.Conflicting(reason) => failed_at(.Apply, f"refusing to change: {reason}")
    compare.Uncertain(reason) => failed_at(.Observe, f"cannot establish the current state ({reason.cause}): {reason.detail}")
    compare.Unevaluated(reason) => {
      let drift = compare.Drift(act: .Run, changes: [compare.Change(field: "run", from: "-", to: reason)])
      run_drift(connection, resource, state, drift, material)
    }
    compare.Drifted(drift) => run_drift(connection, resource, state, drift, material)
  }
}

proc reconcile_one(connection: transport.Connection, resource: model.Resource, changed: List[Str]) [fs, env, process, error] -> outcome.Outcome {
  match fresh_material(resource) {
    Err(error) => failed_at(.Stage, error.message)
    Ok(material) => {
      match observe.observe(connection, resource.spec) {
        Err(error) => failed_at(.Observe, error.message)
        Ok(state) => settle(connection, resource, state, material, changed)
      }
    }
  }
}

proc attempt(step: Step) [fs, env, process, error] -> outcome.Outcome {
  guard let connection = step.state.connection else {
    return failed_at(.Connect, "the host has no connection")
  }

  reconcile_one(connection, step.resource, step.state.changed)
}

proc run_step(step: Step, secrets: List[Str]) [fs, env, process, error] -> Reconciled {
  let name = step.state.workload.host.name
  let result = attempt(step)
  Reconciled(host: name, id: step.resource.id, outcome: result, entry: outcome_entry(name, step.resource, result, secrets))
}

type Locked = {host: Str, held: lock.Held?, failure: Str?}

proc take_lock(state: HostState, lock_path: Str, secrets: List[Str]) [env, process, time, error] -> Locked {
  let host = state.workload.host.name
  guard let connection = state.connection else {
    return Locked(host:, held: null, failure: "the host has no connection")
  }

  let target = lock_path.replace("{host}", with: host)
  match lock.acquire(connection, target) {
    Ok(held) => Locked(host:, held:, failure: null)
    Err(lock.LockError.Contended {holder}) => Locked(host:, held: null, failure: clean(f"another apply holds {target}: {holder}", secrets))
    Err(other) => Locked(host:, held: null, failure: clean(other.message, secrets))
  }
}

pure initial_state(entry: workload.Workload) -> HostState {
  HostState(
    workload: entry,
    connection: null,
    held: null,
    fatal: null,
    fatal_phase: null,
    stopped: null,
    active: null,
    changed: [],
    unsettled: [],
    entries: [],
  )
}

pure with_fatal(state: HostState, phase: Str, message: Str) -> HostState {
  {...state, fatal: message, fatal_phase: phase}
}

pure blocked_reason(state: HostState, resource: model.Resource, aborted: Str?) -> Str? {
  if aborted != null {
    return aborted
  }

  if state.stopped != null {
    return state.stopped
  }

  let waiting = model.dependencies(resource) |> where { |id| id in state.unsettled } |> collect()
  if waiting.is_empty() { null } else { f"{waiting[0]} did not complete on this host" }
}

pure absorb(state: HostState, done: Reconciled, policy: FailurePolicy) -> HostState {
  let settled = outcome.settled(done.outcome)
  let changed = match done.outcome {
    outcome.Changed(_) => state.changed + [done.id]
    else => state.changed
  }
  let unsettled = if settled { state.unsettled } else { state.unsettled + [done.id] }
  let stopped = if outcome.bad(done.outcome) and policy == .Host and state.stopped == null {
    f"{done.id} failed earlier on this host"
  } else {
    state.stopped
  }
  {...state, changed: changed, unsettled: unsettled, stopped: stopped, entries: state.entries + [done.entry]}
}

pure blocked_state(state: HostState, resource: model.Resource, reason: Str, secrets: List[Str]) -> HostState {
  let entry = outcome_entry(state.workload.host.name, resource, outcome.Blocked(reason), secrets)
  {...state, unsettled: state.unsettled + [resource.id], entries: state.entries + [entry]}
}

proc release_all(states: Map[Str, HostState]) [env, process, error] {
  for state in states.values() {
    if state.connection != null {
      if state.held != null {
        let released = transport.usable(state.connection) and release_on(state.connection, state.held)
        if ! released {
          let _ = release_fresh(state.workload.host, state.held)
        }
      }

      let _ = transport.disconnect(state.connection)
    }
  }
}

proc release_on(connection: transport.Connection, held: lock.Held) [process, error] -> Bool {
  lock.release(connection, held) is Ok(_)
}

proc release_fresh(host: model.Host, held: lock.Held) [env, process, error] -> Bool {
  match transport.connect(host) {
    Err(_) => false
    Ok(connection) => {
      let released = release_on(connection, held)
      let _ = transport.disconnect(connection)
      released
    }
  }
}

proc settle_lock(state: HostState, secrets: List[Str]) [env, process, error] -> HostState {
  guard let held = state.held else {
    return state
  }

  let released = if let connection = state.connection { transport.usable(connection) and release_on(connection, held) } else { false }
  if released or release_fresh(state.workload.host, held) {
    return {...state, held: null}
  }

  let note = f"the lock {held.path} is still held with token {held.token}; release it with: xinfra unlock INVENTORY {state.workload.host.name} --token {held.token}"
  {...state, held: null, fatal: clean(note, secrets), fatal_phase: "release"}
}

pure host_report(state: HostState, secrets: List[Str]) -> report.HostReport {
  report.HostReport(
    host: state.workload.host.name,
    ok: state.fatal == null,
    phase: state.fatal_phase,
    detail: state.fatal,
    entries: state.entries,
  )
}

pure cancelled_entry(host: Str, resource: model.Resource, status: Str, detail: Str, secrets: List[Str]) -> report.Entry {
  report.Entry(
    host:,
    id: resource.id,
    kind: model.kind(resource.spec),
    status:,
    act: null,
    changes: [],
    conditional: false,
    phase: "cancelled",
    detail: clean(detail, secrets),
    verified: null,
  )
}

pure recorded_ids(entries: List[report.Entry]) -> List[Str] {
  entries |> map { |entry| entry.id } |> collect()
}

pure cancelled_host(state: HostState, secrets: List[Str]) -> report.HostReport {
  var entries = state.entries
  let known = recorded_ids(entries)
  for resource in state.workload.resources {
    if resource.id in known {
      continue
    }

    var status = "blocked"
    var detail = "the apply was cancelled before this resource ran"
    if let active = state.active {
      if active == resource.id {
        status = "unknown"
        detail = "the apply was cancelled while this resource was being reconciled; it may or may not have taken effect"
      }
    }

    entries += [cancelled_entry(state.workload.host.name, resource, status, detail, secrets)]
  }

  let phase = state.fatal_phase ?? "cancelled"
  let detail = state.fatal ?? "the apply was cancelled; this is what was observed"
  report.HostReport(host: state.workload.host.name, ok: false, phase:, detail:, entries:)
}

pure cancelled_report(states: Map[Str, HostState], secrets: List[Str]) -> report.Report {
  let hosts = states.values() |> map { |state| cancelled_host(state, secrets) } |> collect()
  report.Report(mode: "apply", hosts:)
}

## Reconcile every selected host. Connections open and locks are taken first;
## a host that cannot be reached or locked gets no mutations and is reported
## failed. Operations then run one at a time across hosts. Locks and sessions
## are released however the run ends.
export proc apply(prepared: workload.Prepared, settings: Settings) [fs, env, process, time, io, error] -> report.Report {
  let secrets = prepared.secrets
  var states: Map[Str, HostState] = {}
  for entry in prepared.workloads {
    states[entry.host.name] = initial_state(entry)
  }

  var completed = false
  defer {
    release_all(states)
    if ! completed {
      eprint (report.text(cancelled_report(states, secrets), true))
    }
  }

  let opened = transport.connect_all(prepared.workloads |> map { |entry| entry.host } |> collect(), settings.jobs)
  var position = 0
  for entry in prepared.workloads {
    let name = entry.host.name
    let state = states.get(name) ?? initial_state(entry)
    match opened[position] {
      Ok(connection) => states[name] = {...state, connection: connection}
      Err(error) => states[name] = with_fatal(state, "connect", clean(error.message, secrets))
    }
    position += 1
  }

  let lockable = states.values() |> where { |state| state.fatal == null } |> collect()
  let locked = lockable |> par-map(jobs: settings.jobs) { |state| take_lock(state, settings.lock_path, secrets) } |> collect()
  for item in locked {
    let state = states.get(item.host) ?? initial_state(prepared.workloads[0])
    if item.failure != null {
      states[item.host] = with_fatal(state, "lock", item.failure)
    } else {
      states[item.host] = {...state, held: item.held}
    }
  }

  var aborted: Str? = null
  for id in prepared.operations {
    var steps: List[Step] = []
    for state in states.values() {
      if state.fatal != null {
        continue
      }

      let resource = find_resource(state.workload.resources, id)
      if resource == null {
        continue
      }

      let reason = blocked_reason(state, resource, aborted)
      if reason == null {
        steps += [Step(state:, resource:)]
      } else {
        states[state.workload.host.name] = blocked_state(state, resource, reason, secrets)
      }
    }

    for step in steps {
      let name = step.state.workload.host.name
      let state = states.get(name) ?? step.state
      states[name] = {...state, active: id}
    }

    let results = steps |> par-map(jobs: settings.jobs) { |step| run_step(step, secrets) } |> collect()
    for done in results {
      let state = states.get(done.host) ?? initial_state(prepared.workloads[0])
      states[done.host] = {...absorb(state, done, settings.policy), active: null}
      if outcome.bad(done.outcome) and settings.policy == .Abort and aborted == null {
        aborted = f"apply aborted after {done.id} failed on {done.host}"
      }
    }
  }

  for name in states.keys() {
    states[name] = settle_lock(states.get(name) ?? initial_state(prepared.workloads[0]), secrets)
  }

  let hosts = prepared.workloads |> map { |entry| host_report(states.get(entry.host.name) ?? initial_state(entry), secrets) } |> collect()
  completed = true
  report.Report(mode: "apply", hosts:)
}

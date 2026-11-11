##! Pure comparison of desired state against observed facts. No function here
##! reads a host: given the same spec and fact it always returns the same
##! verdict, which is what makes plan, check and apply agree.

use infra.fact
use infra.model

const numeric = rx"^[0-9]+$"

## The kind of mutation a drifted resource needs.
export enum Act: Str { Create = "create", Update = "update", Remove = "remove", Run = "run" }

## One field that differs: what the host has, and what is declared. Values of a
## sensitive resource are already redacted.
export type Change = {field: Str, from: Str, to: Str}

## What has to happen to reach the declared state.
export type Drift = {act: Act, changes: List[Change]}

## The bytes a file is declared to hold, reduced to what comparison needs.
export type Material = {digest: Str, size: Int}

## The result of comparing one resource with its fact.
export enum Verdict {
  Satisfied,
  Drifted(Drift),
  Conflicting(Str),
  Uncertain(fact.Unreadable),
  Unevaluated(Str),
}

const redacted = "(redacted)"

pure drift(act: Act, changes: List[Change]) -> Verdict {
  Drifted(Drift(act:, changes:))
}

pure change(field: Str, from: Str, to: Str) -> Change {
  Change(field:, from:, to:)
}

pure reading(cause: fact.Cause, detail: Str) -> fact.Unreadable {
  fact.Unreadable(cause:, detail:)
}

pure mismatch(what: Str) -> Verdict {
  Uncertain(reading(.Malformed, f"internal: {what} was compared with a fact of another kind"))
}

## Render a mode as four octal digits.
export pure octal(mode: Int) -> Str {
  var rest = mode
  var digits: List[Str] = []
  while rest > 0 {
    digits = [f"{rest % 8}"] + digits
    rest = rest / 8
  }

  while digits.len() < 4 {
    digits = ["0"] + digits
  }

  digits.join("")
}

pure principal_matches(wanted: Str, name: Str, id: Int) -> Bool {
  if numeric.matches(wanted) {
    f"{id}" == wanted
  } else {
    name == wanted
  }
}

pure attribute_changes(owner: Str?, group_name: Str?, mode: Int?, info: fact.PathInfo) -> List[Change] {
  var changes: List[Change] = []
  if mode != null and info.mode != mode {
    changes += [change("mode", octal(info.mode), octal(mode))]
  }

  if owner != null and ! principal_matches(owner, info.owner, info.uid) {
    changes += [change("owner", info.owner, owner)]
  }

  if group_name != null and ! principal_matches(group_name, info.group, info.gid) {
    changes += [change("group", info.group, group_name)]
  }

  changes
}

pure wanted_attributes(owner: Str?, group_name: Str?, mode: Int?) -> List[Change] {
  var changes: List[Change] = []
  if mode != null {
    changes += [change("mode", "(none)", octal(mode))]
  }

  if owner != null {
    changes += [change("owner", "(none)", owner)]
  }

  if group_name != null {
    changes += [change("group", "(none)", group_name)]
  }

  changes
}

pure kind_name(kind: fact.PathKind) -> Str {
  match kind {
    fact.Directory => "directory"
    fact.Regular => "regular file"
    fact.Symlink => "symlink"
    fact.Other => "special file"
  }
}

pure compare_directory(spec: model.DirectorySpec, state: fact.PathState) -> Verdict {
  match state {
    fact.Unseen(unreadable) => Uncertain(unreadable)
    fact.Blocked(unreadable) => {
      if spec.presence == .Absent { Satisfied } else { Conflicting(f"a parent of {spec.path} is not a directory") }
    }
    fact.Missing => {
      if spec.presence == .Absent {
        Satisfied
      } else {
        drift(.Create, [change("presence", "absent", "directory")] + wanted_attributes(spec.owner, spec.group, spec.mode))
      }
    }
    fact.Found(info) => {
      if info.kind != .Directory {
        Conflicting(f"{spec.path} is a {kind_name(info.kind)}, not a directory")
      } else if spec.presence == .Absent {
        drift(.Remove, [change("presence", "directory", "absent")])
      } else {
        let changes = attribute_changes(spec.owner, spec.group, spec.mode, info)
        if changes.is_empty() { Satisfied } else { drift(.Update, changes) }
      }
    }
  }
}

pure short(digest: Str) -> Str {
  f"sha256:{digest.byte_slice(0, 12)}"
}

pure compare_file(spec: model.FileSpec, material: Material?, state: fact.PathState) -> Verdict {
  match state {
    fact.Unseen(unreadable) => Uncertain(unreadable)
    fact.Blocked(unreadable) => {
      if spec.presence == .Absent { Satisfied } else { Conflicting(f"a parent of {spec.path} is not a directory") }
    }
    fact.Missing => {
      if spec.presence == .Absent {
        Satisfied
      } else {
        let wanted = if spec.sensitive { redacted } else { short(material?.digest ?? "") }
        drift(.Create, [change("content", "(absent)", wanted)] + wanted_attributes(spec.owner, spec.group, spec.mode))
      }
    }
    fact.Found(info) => {
      if info.kind != .Regular {
        Conflicting(f"{spec.path} is a {kind_name(info.kind)}, not a regular file")
      } else if spec.presence == .Absent {
        drift(.Remove, [change("presence", "file", "absent")])
      } else if info.digest == null {
        Uncertain(reading(.Denied, f"cannot read the content of {spec.path} to compare it"))
      } else {
        var changes: List[Change] = []
        let wanted = material?.digest ?? ""
        if info.digest != wanted {
          let from = if spec.sensitive { redacted } else { short(info.digest ?? "") }
          let to = if spec.sensitive { redacted } else { short(wanted) }
          changes += [change("content", from, to)]
        }

        let all = changes + attribute_changes(spec.owner, spec.group, spec.mode, info)
        if all.is_empty() { Satisfied } else { drift(.Update, all) }
      }
    }
  }
}

pure compare_symlink(spec: model.SymlinkSpec, state: fact.PathState) -> Verdict {
  match state {
    fact.Unseen(unreadable) => Uncertain(unreadable)
    fact.Blocked(unreadable) => {
      if spec.presence == .Absent { Satisfied } else { Conflicting(f"a parent of {spec.path} is not a directory") }
    }
    fact.Missing => {
      if spec.presence == .Absent { Satisfied } else { drift(.Create, [change("target", "(absent)", spec.target)]) }
    }
    fact.Found(info) => {
      if info.kind != .Symlink {
        Conflicting(f"{spec.path} is a {kind_name(info.kind)}, not a symlink")
      } else if spec.presence == .Absent {
        drift(.Remove, [change("presence", "symlink", "absent")])
      } else if info.link_target == spec.target {
        Satisfied
      } else if spec.replacement == .ReplaceLink {
        drift(.Update, [change("target", info.link_target ?? "", spec.target)])
      } else {
        Conflicting(f"{spec.path} points to {info.link_target ?? ""} and replace is not allowed")
      }
    }
  }
}

pure constraint_text(constraint: model.Constraint?) -> Str {
  if constraint == null { "installed" } else { f"{constraint.op}{constraint.version}" }
}

pure ordering_holds(op: model.VersionOp, ordering: fact.Ordering) -> Bool {
  match op {
    model.Eq => ordering == .Same
    model.Ge => ordering != .Older
    model.Le => ordering != .Newer
    model.Gt => ordering == .Newer
    model.Lt => ordering == .Older
  }
}

pure compare_package(spec: model.PackageSpec, state: fact.PackageState) -> Verdict {
  match state {
    fact.PackageUnseen(unreadable) => Uncertain(unreadable)
    fact.NotInstalled => {
      if spec.presence == .Absent {
        Satisfied
      } else {
        drift(.Create, [change("package", "not installed", f"{spec.name} {constraint_text(spec.constraint)}")])
      }
    }
    fact.Installed(installed) => {
      if spec.presence == .Absent {
        drift(.Remove, [change("package", installed.version, "not installed")])
      } else if spec.constraint == null {
        Satisfied
      } else if installed.ordering == null {
        Uncertain(reading(.Malformed, f"no version ordering was reported for {spec.name}"))
      } else if ordering_holds(spec.constraint.op, installed.ordering) {
        Satisfied
      } else {
        drift(.Update, [change("version", installed.version, constraint_text(spec.constraint))])
      }
    }
  }
}

pure compare_group(spec: model.GroupSpec, state: fact.GroupState) -> Verdict {
  match state {
    fact.GroupUnseen(unreadable) => Uncertain(unreadable)
    fact.NoGroup => {
      if spec.presence == .Absent { Satisfied } else { drift(.Create, [change("group", "absent", spec.name)]) }
    }
    fact.GroupFound(info) => {
      if spec.presence == .Absent {
        drift(.Remove, [change("group", spec.name, "absent")])
      } else if spec.gid != null and info.gid != spec.gid {
        Conflicting(f"group {spec.name} has gid {info.gid}, not {spec.gid}; gids are never changed")
      } else {
        Satisfied
      }
    }
  }
}

pure compare_user(spec: model.UserSpec, state: fact.UserState) -> Verdict {
  match state {
    fact.UserUnseen(unreadable) => Uncertain(unreadable)
    fact.NoUser => {
      if spec.presence == .Absent { Satisfied } else { drift(.Create, [change("user", "absent", spec.name)]) }
    }
    fact.UserFound(info) => {
      if spec.presence == .Absent {
        drift(.Remove, [change("user", spec.name, "absent")])
      } else if spec.uid != null and info.uid != spec.uid {
        Conflicting(f"user {spec.name} has uid {info.uid}, not {spec.uid}; uids are never changed")
      } else {
        var changes: List[Change] = []
        if spec.group != null and info.group != spec.group {
          changes += [change("group", info.group ?? f"{info.gid}", spec.group)]
        }

        for member in spec.groups {
          if member not in info.memberships and member != info.group {
            changes += [change("membership", "not a member", member)]
          }
        }

        if spec.home != null and info.home != spec.home {
          changes += [change("home", info.home, spec.home)]
        }

        if spec.shell != null and info.shell != spec.shell {
          changes += [change("shell", info.shell, spec.shell)]
        }

        if changes.is_empty() { Satisfied } else { drift(.Update, changes) }
      }
    }
  }
}

pure any_changed(triggers: List[Str], changed: List[Str]) -> Bool {
  triggers |> any { |id| id in changed }
}

pure compare_service(spec: model.ServiceSpec, state: fact.ServiceState, changed: List[Str]) -> Verdict {
  match state {
    fact.ServiceUnseen(unreadable) => Uncertain(unreadable)
    fact.NoService => {
      let missing = match spec.adapter {
        model.OpenRc => f"no init script for service {spec.name}"
        model.Xinit => f"no xinit service file for {spec.name}"
      }
      Uncertain(reading(.Unavailable, missing))
    }
    fact.ServiceFound(info) => {
      var changes: List[Change] = []
      if spec.enabled != null {
        guard let enabled = info.enabled else {
          return Conflicting(f"the {spec.adapter} adapter has no enable or disable")
        }
        if enabled != spec.enabled {
          let from = if enabled { "enabled" } else { "disabled" }
          let to = if spec.enabled { "enabled" } else { "disabled" }
          changes += [change("enabled", from, to)]
        }
      }

      let restart = any_changed(spec.restart_on, changed)
      let reload = any_changed(spec.reload_on, changed)
      if spec.running == true and info.running != .Started {
        changes += [change("running", f"{info.running}", "started")]
      } else if spec.running == false and info.running != .Stopped {
        changes += [change("running", f"{info.running}", "stopped")]
      } else if restart and spec.running != false {
        changes += [change("notify", "running", "restart")]
      } else if reload and spec.running != false and info.running == .Started {
        changes += [change("notify", "running", "reload")]
      }

      if changes.is_empty() { Satisfied } else { drift(.Update, changes) }
    }
  }
}

pure guard_unreadable(code: Int) -> Bool {
  code >= 126
}

pure compare_command(spec: model.CommandSpec, state: fact.Fact, changed: List[Str]) -> Verdict {
  match spec.guard {
    model.Always => Unevaluated("runs on every apply")
    model.OnChange => {
      if any_changed(spec.triggers, changed) {
        drift(.Run, [change("trigger", "unchanged", "changed")])
      } else {
        Satisfied
      }
    }
    model.Creates(target) => {
      match state {
        fact.OnPath(fact.Found(_)) => Satisfied
        fact.OnPath(fact.Missing) => drift(.Run, [change("creates", "(absent)", target)])
        fact.OnPath(fact.Blocked(_)) => drift(.Run, [change("creates", "(absent)", target)])
        fact.OnPath(fact.Unseen(unreadable)) => Uncertain(unreadable)
        else => mismatch("command")
      }
    }
    model.SkipIf(_) => {
      match state {
        fact.OnGuard(fact.Exited(0)) => Satisfied
        fact.OnGuard(fact.Exited(code)) => {
          if guard_unreadable(code) {
            Uncertain(reading(.Unavailable, f"the guard could not run (exit {code})"))
          } else {
            drift(.Run, [change("guard", f"exit {code}", "exit 0")])
          }
        }
        fact.OnGuard(fact.GuardUnseen(unreadable)) => Uncertain(unreadable)
        else => mismatch("command")
      }
    }
    model.OnlyIf(_) => {
      match state {
        fact.OnGuard(fact.Exited(0)) => drift(.Run, [change("guard", "exit 0", "run")])
        fact.OnGuard(fact.Exited(code)) => {
          if guard_unreadable(code) {
            Uncertain(reading(.Unavailable, f"the guard could not run (exit {code})"))
          } else {
            Satisfied
          }
        }
        fact.OnGuard(fact.GuardUnseen(unreadable)) => Uncertain(unreadable)
        else => mismatch("command")
      }
    }
  }
}

## Compare one resource's spec with the fact observed for it. `changed` lists
## the identifiers of resources that have changed, or are planned to, before
## this one; triggers read it. `material` is the declared content of a file.
export pure verdict(spec: model.Spec, state: fact.Fact, material: Material?, changed: List[Str]) -> Verdict {
  match spec {
    model.Directory(directory) => {
      match state {
        fact.OnPath(path_state) => compare_directory(directory, path_state)
        else => mismatch("directory")
      }
    }
    model.File(file) => {
      match state {
        fact.OnPath(path_state) => compare_file(file, material, path_state)
        else => mismatch("file")
      }
    }
    model.Link(link) => {
      match state {
        fact.OnPath(path_state) => compare_symlink(link, path_state)
        else => mismatch("symlink")
      }
    }
    model.Package(package) => {
      match state {
        fact.OnPackage(package_state) => compare_package(package, package_state)
        else => mismatch("package")
      }
    }
    model.PackageIndex(_) => Unevaluated("the package index is refreshed only at apply")
    model.GroupAccount(account_group) => {
      match state {
        fact.OnGroup(group_state) => compare_group(account_group, group_state)
        else => mismatch("group")
      }
    }
    model.UserAccount(account) => {
      match state {
        fact.OnUser(user_state) => compare_user(account, user_state)
        else => mismatch("user")
      }
    }
    model.Exec(command) => compare_command(command, state, changed)
    model.Service(service) => {
      match state {
        fact.OnService(service_state) => compare_service(service, service_state, changed)
        else => mismatch("service")
      }
    }
  }
}


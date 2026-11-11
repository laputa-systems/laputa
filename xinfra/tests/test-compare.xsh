use infra.compare
use infra.declare
use infra.fact
use infra.model

pure info(
  kind: fact.PathKind,
  mode: Int = 0o644,
  owner: Str = "root",
  group_name: Str = "root",
  digest: Str? = null,
  target: Str? = null,
) -> fact.PathInfo {
  fact.PathInfo(kind:, mode:, uid: 0, gid: 0, owner:, group: group_name, size: 1, digest:, link_target: target)
}

pure found(value: fact.PathInfo) -> fact.Fact {
  fact.OnPath(fact.Found(value))
}

pure gone() -> fact.Fact {
  fact.OnPath(fact.Missing)
}

pure denied() -> fact.Fact {
  fact.OnPath(fact.Unseen(fact.Unreadable(cause: .Denied, detail: "no")))
}

const none: List[Str] = []

pure fields(verdict: compare.Verdict) -> List[Str] {
  match verdict {
    compare.Drifted(drift) => drift.changes |> map { |change| change.field } |> collect()
    else => []
  }
}

pure act(verdict: compare.Verdict) -> compare.Act? {
  match verdict {
    compare.Drifted(drift) => drift.act
    else => null
  }
}

pure sha(character: Str) -> Str {
  [character, character, character, character, character, character, character, character, character, character, character, character, character, character].join("")
}

test a_matching_directory_is_satisfied {
  let resource = declare.directory(id: "d", at: "/srv", owner: "root", mode: 0o755)?
  assert compare.verdict(resource.spec, found(info(.Directory, mode: 0o755)), null, none) is compare.Satisfied
}

test a_missing_directory_is_created_with_its_attributes {
  let resource = declare.directory(id: "d", at: "/srv", owner: "app", group_name: "app", mode: 0o750)?
  let verdict = compare.verdict(resource.spec, gone(), null, none)
  assert act(verdict) == .Create
  assert fields(verdict) == ["presence", "mode", "owner", "group"]
}

test directory_drift_lists_only_the_differing_attributes {
  let resource = declare.directory(id: "d", at: "/srv", owner: "app", mode: 0o750)?
  let verdict = compare.verdict(resource.spec, found(info(.Directory, mode: 0o755)), null, none)
  assert act(verdict) == .Update
  assert fields(verdict) == ["mode", "owner"]
}

test a_numeric_owner_matches_by_id {
  let resource = declare.directory(id: "d", at: "/srv", owner: "0", group_name: "0")?
  assert compare.verdict(resource.spec, found(info(.Directory)), null, none) is compare.Satisfied
}

test the_wrong_kind_of_object_is_a_conflict_not_drift {
  let resource = declare.directory(id: "d", at: "/srv")?
  for kind in [fact.Regular, fact.Symlink, fact.Other] {
    assert compare.verdict(resource.spec, found(info(kind)), null, none) is compare.Conflicting(_)
  }
  let absent = declare.directory(id: "d", at: "/srv", presence: .Absent)?
  assert compare.verdict(absent.spec, found(info(.Regular)), null, none) is compare.Conflicting(_)
  assert act(compare.verdict(absent.spec, found(info(.Directory)), null, none)) == .Remove
}

test an_unreadable_path_is_uncertain_never_unchanged_or_absent {
  let present = declare.directory(id: "d", at: "/srv")?
  let absent = declare.directory(id: "d", at: "/srv", presence: .Absent)?
  assert compare.verdict(present.spec, denied(), null, none) is compare.Uncertain(_)
  assert compare.verdict(absent.spec, denied(), null, none) is compare.Uncertain(_)
}

test a_blocked_parent_makes_an_absent_resource_satisfied_and_a_present_one_a_conflict {
  let blocked = fact.OnPath(fact.Blocked(fact.Unreadable(cause: .Conflict, detail: "not a directory")))
  let present = declare.directory(id: "d", at: "/srv/x")?
  let absent = declare.directory(id: "d", at: "/srv/x", presence: .Absent)?
  assert compare.verdict(present.spec, blocked, null, none) is compare.Conflicting(_)
  assert compare.verdict(absent.spec, blocked, null, none) is compare.Satisfied
}

test file_content_is_compared_by_digest_and_attributes {
  let resource = declare.file(id: "f", at: "/etc/f", text: "x", mode: 0o600)?
  let material = compare.Material(digest: sha("a"), size: 1)
  let same = found(info(.Regular, mode: 0o600, digest: sha("a")))
  assert compare.verdict(resource.spec, same, material, none) is compare.Satisfied
  let other = found(info(.Regular, mode: 0o600, digest: sha("b")))
  assert fields(compare.verdict(resource.spec, other, material, none)) == ["content"]
  let loose = found(info(.Regular, mode: 0o644, digest: sha("a")))
  assert fields(compare.verdict(resource.spec, loose, material, none)) == ["mode"]
  assert act(compare.verdict(resource.spec, other, material, none)) == .Update
}

test an_unreadable_file_digest_is_uncertain {
  let resource = declare.file(id: "f", at: "/etc/f", text: "x")?
  let material = compare.Material(digest: sha("a"), size: 1)
  let verdict = compare.verdict(resource.spec, found(info(.Regular, digest: null)), material, none)
  assert verdict is compare.Uncertain(_)
}

test a_sensitive_file_never_shows_its_digests {
  let resource = declare.file(id: "f", at: "/etc/f", secret_env: "TOKEN")?
  let material = compare.Material(digest: sha("a"), size: 1)
  let verdict = compare.verdict(resource.spec, found(info(.Regular, digest: sha("b"))), material, none)
  match verdict {
    compare.Drifted(drift) => {
      for change in drift.changes {
        assert change.from == "(redacted)" and change.to == "(redacted)"
      }
    }
    else => assert false, "no drift"
  }
  let created = compare.verdict(resource.spec, gone(), material, none)
  match created {
    compare.Drifted(drift) => assert drift.changes[0].to == "(redacted)"
    else => assert false, "no drift"
  }
}

test an_absent_file_is_removed_only_when_it_is_a_regular_file {
  let resource = declare.file(id: "f", at: "/etc/f", presence: .Absent)?
  assert act(compare.verdict(resource.spec, found(info(.Regular, digest: sha("a"))), null, none)) == .Remove
  assert compare.verdict(resource.spec, gone(), null, none) is compare.Satisfied
  assert compare.verdict(resource.spec, found(info(.Directory)), null, none) is compare.Conflicting(_)
}

test symlinks_are_replaced_only_when_the_policy_says_so {
  let keep = declare.symlink(id: "l", at: "/etc/l", target: "/a")?
  let replace = declare.symlink(id: "l", at: "/etc/l", target: "/a", replace: true)?
  let right = found(info(.Symlink, target: "/a"))
  let wrong = found(info(.Symlink, target: "/b"))
  assert compare.verdict(keep.spec, right, null, none) is compare.Satisfied
  assert compare.verdict(keep.spec, wrong, null, none) is compare.Conflicting(_)
  assert act(compare.verdict(replace.spec, wrong, null, none)) == .Update
  assert act(compare.verdict(keep.spec, gone(), null, none)) == .Create
  assert compare.verdict(keep.spec, found(info(.Directory)), null, none) is compare.Conflicting(_)
  assert compare.verdict(replace.spec, found(info(.Regular)), null, none) is compare.Conflicting(_)
}

pure installed(version: Str, ordering: fact.Ordering?) -> fact.Fact {
  fact.OnPackage(fact.Installed(fact.InstalledPackage(version:, ordering:)))
}

test package_constraints_follow_the_reported_ordering {
  let exact = declare.package(id: "p", name: "curl", version: "=8.0")?
  let at_least = declare.package(id: "p", name: "curl", version: ">=8.0")?
  let below = declare.package(id: "p", name: "curl", version: "<8.0")?
  let plain = declare.package(id: "p", name: "curl")?
  assert compare.verdict(exact.spec, installed("8.0", .Same), null, none) is compare.Satisfied
  assert act(compare.verdict(exact.spec, installed("8.1", .Newer), null, none)) == .Update
  assert compare.verdict(at_least.spec, installed("8.1", .Newer), null, none) is compare.Satisfied
  assert act(compare.verdict(at_least.spec, installed("7.9", .Older), null, none)) == .Update
  assert compare.verdict(below.spec, installed("7.9", .Older), null, none) is compare.Satisfied
  assert act(compare.verdict(below.spec, installed("8.0", .Same), null, none)) == .Update
  assert compare.verdict(plain.spec, installed("7.9", null), null, none) is compare.Satisfied
  assert compare.verdict(at_least.spec, installed("7.9", null), null, none) is compare.Uncertain(_)
}

test packages_are_installed_or_removed {
  let present = declare.package(id: "p", name: "curl")?
  let absent = declare.package(id: "p", name: "curl", presence: .Absent)?
  assert act(compare.verdict(present.spec, fact.OnPackage(fact.NotInstalled), null, none)) == .Create
  assert compare.verdict(absent.spec, fact.OnPackage(fact.NotInstalled), null, none) is compare.Satisfied
  assert act(compare.verdict(absent.spec, installed("1", null), null, none)) == .Remove
  let broken = fact.OnPackage(fact.PackageUnseen(fact.Unreadable(cause: .Unavailable, detail: "no apk")))
  assert compare.verdict(present.spec, broken, null, none) is compare.Uncertain(_)
  assert compare.verdict(absent.spec, broken, null, none) is compare.Uncertain(_)
}

test the_package_index_is_never_evaluated {
  let resource = declare.package_index(id: "index")?
  assert compare.verdict(resource.spec, fact.Nothing, null, none) is compare.Unevaluated(_)
}

pure account_fact(uid: Int = 1000, group_name: Str? = "app", memberships: List[Str] = [], home: Str = "/home/app", shell: Str = "/bin/ash") -> fact.Fact {
  fact.OnUser(fact.UserFound(fact.UserInfo(name: "app", uid:, gid: 1000, group: group_name, home:, shell:, memberships:)))
}

test users_never_change_ids_and_report_membership_gaps {
  let resource = declare.user_account(id: "u", name: "app", uid: 1000, primary_group: "app", groups: ["wheel", "audio"], shell: "/bin/ash")?
  let partial = account_fact(memberships: ["wheel"])
  let verdict = compare.verdict(resource.spec, partial, null, none)
  assert fields(verdict) == ["membership"]
  let complete = account_fact(memberships: ["wheel", "audio"])
  assert compare.verdict(resource.spec, complete, null, none) is compare.Satisfied
  assert compare.verdict(resource.spec, account_fact(uid: 2000, memberships: ["wheel", "audio"]), null, none) is compare.Conflicting(_)
  let moved = account_fact(memberships: ["wheel", "audio"], shell: "/bin/sh")
  assert fields(compare.verdict(resource.spec, moved, null, none)) == ["shell"]
  assert act(compare.verdict(resource.spec, fact.OnUser(fact.NoUser), null, none)) == .Create
}

test a_primary_group_counts_as_a_membership {
  let resource = declare.user_account(id: "u", name: "app", groups: ["app"])?
  assert compare.verdict(resource.spec, account_fact(), null, none) is compare.Satisfied
}

test users_and_groups_are_removed_without_touching_ids {
  let account = declare.user_account(id: "u", name: "app", presence: .Absent)?
  let team = declare.group_account(id: "g", name: "app", presence: .Absent)?
  assert act(compare.verdict(account.spec, account_fact(), null, none)) == .Remove
  assert compare.verdict(account.spec, fact.OnUser(fact.NoUser), null, none) is compare.Satisfied
  let present = fact.OnGroup(fact.GroupFound(fact.GroupInfo(name: "app", gid: 1000, members: [])))
  assert act(compare.verdict(team.spec, present, null, none)) == .Remove
  let wanted = declare.group_account(id: "g", name: "app", gid: 1001)?
  assert compare.verdict(wanted.spec, present, null, none) is compare.Conflicting(_)
  assert act(compare.verdict(wanted.spec, fact.OnGroup(fact.NoGroup), null, none)) == .Create
}

pure guard_fact(code: Int) -> fact.Fact {
  fact.OnGuard(fact.Exited(code))
}

test command_guards_decide_whether_a_command_runs {
  let creates = declare.command(id: "c", argv: ["touch", "/x"], creates: "/x")?
  assert compare.verdict(creates.spec, found(info(.Regular)), null, none) is compare.Satisfied
  assert act(compare.verdict(creates.spec, gone(), null, none)) == .Run
  assert compare.verdict(creates.spec, denied(), null, none) is compare.Uncertain(_)

  let skip = declare.command(id: "c", argv: ["x"], skip_if: ["test", "-e", "/x"])?
  assert compare.verdict(skip.spec, guard_fact(0), null, none) is compare.Satisfied
  assert act(compare.verdict(skip.spec, guard_fact(1), null, none)) == .Run
  assert compare.verdict(skip.spec, guard_fact(127), null, none) is compare.Uncertain(_)

  let only = declare.command(id: "c", argv: ["x"], only_if: ["test", "-e", "/x"])?
  assert act(compare.verdict(only.spec, guard_fact(0), null, none)) == .Run
  assert compare.verdict(only.spec, guard_fact(1), null, none) is compare.Satisfied
  assert compare.verdict(only.spec, guard_fact(126), null, none) is compare.Uncertain(_)

  let always = declare.command(id: "c", argv: ["x"], always: true)?
  assert compare.verdict(always.spec, fact.Nothing, null, none) is compare.Unevaluated(_)
}

test a_triggered_command_runs_only_after_a_listed_resource_changed {
  let resource = declare.command(id: "c", argv: ["x"], run_on: ["a", "b"])?
  assert compare.verdict(resource.spec, fact.Nothing, null, none) is compare.Satisfied
  assert compare.verdict(resource.spec, fact.Nothing, null, ["z"]) is compare.Satisfied
  assert act(compare.verdict(resource.spec, fact.Nothing, null, ["b"])) == .Run
}

pure service_fact(enabled: Bool, running: fact.Running) -> fact.Fact {
  fact.OnService(fact.ServiceFound(fact.ServiceInfo(enabled:, running:, ready: null)))
}

pure xinit_fact(running: fact.Running, ready: Bool) -> fact.Fact {
  fact.OnService(fact.ServiceFound(fact.ServiceInfo(enabled: null, running:, ready:)))
}

test services_converge_enablement_and_running_state {
  let resource = declare.service(id: "s", name: "sshd", enabled: true, running: true)?
  assert compare.verdict(resource.spec, service_fact(true, .Started), null, none) is compare.Satisfied
  assert fields(compare.verdict(resource.spec, service_fact(false, .Stopped), null, none)) == ["enabled", "running"]
  assert fields(compare.verdict(resource.spec, service_fact(true, .Crashed), null, none)) == ["running"]
  let stopped = declare.service(id: "s", name: "sshd", running: false)?
  assert fields(compare.verdict(stopped.spec, service_fact(true, .Started), null, none)) == ["running"]
  assert compare.verdict(resource.spec, fact.OnService(fact.NoService), null, none) is compare.Uncertain(_)
}

test restart_supersedes_reload_and_each_is_one_notification {
  let resource = declare.service(id: "s", name: "sshd", running: true, reload_on: ["a", "b"], restart_on: ["c"])?
  let up = service_fact(true, .Started)
  assert compare.verdict(resource.spec, up, null, none) is compare.Satisfied
  let reloaded = compare.verdict(resource.spec, up, null, ["a", "b"])
  assert fields(reloaded) == ["notify"]
  let both = compare.verdict(resource.spec, up, null, ["a", "b", "c"])
  match both {
    compare.Drifted(drift) => {
      assert drift.changes.len() == 1
      assert drift.changes[0].to == "restart"
    }
    else => assert false, "no drift"
  }
}

test a_stopped_service_is_not_reloaded_by_a_trigger {
  let resource = declare.service(id: "s", name: "sshd", reload_on: ["a"])?
  assert compare.verdict(resource.spec, service_fact(true, .Stopped), null, ["a"]) is compare.Satisfied
}

test an_xinit_service_plans_from_its_status_not_from_enablement {
  let resource = declare.xinit_service(id: "s", name: "logger", running: true)?
  assert compare.verdict(resource.spec, xinit_fact(.Started, true), null, none) is compare.Satisfied
  assert act(compare.verdict(resource.spec, xinit_fact(.Stopped, false), null, none)) == .Update
  assert fields(compare.verdict(resource.spec, xinit_fact(.Stopped, false), null, none)) == ["running"]
  assert fields(compare.verdict(resource.spec, xinit_fact(.Crashed, false), null, none)) == ["running"]
  assert compare.verdict(resource.spec, fact.OnService(fact.NoService), null, none) is compare.Uncertain(_)
  match compare.verdict(resource.spec, fact.OnService(fact.ServiceUnseen(fact.Unreadable(cause: .Denied, detail: "no"))), null, none) {
    compare.Uncertain(unreadable) => assert unreadable.cause == .Denied
    else => assert false, "an unreadable status was not uncertain"
  }

  let stopped = declare.xinit_service(id: "s", name: "logger", running: false)?
  assert fields(compare.verdict(stopped.spec, xinit_fact(.Started, true), null, none)) == ["running"]
  assert compare.verdict(stopped.spec, xinit_fact(.Stopped, false), null, none) is compare.Satisfied
}

test an_xinit_trigger_restarts_or_reloads_once_per_apply {
  let resource = declare.xinit_service(id: "s", name: "logger", reload_on: ["a"], restart_on: ["b"])?
  assert compare.verdict(resource.spec, xinit_fact(.Started, true), null, none) is compare.Satisfied
  assert fields(compare.verdict(resource.spec, xinit_fact(.Started, true), null, ["a"])) == ["notify"]
  let both = compare.verdict(resource.spec, xinit_fact(.Started, true), null, ["a", "b"])
  match both {
    compare.Drifted(drift) => {
      assert drift.changes.len() == 1
      assert drift.changes[0].to == "restart"
    }
    else => assert false, "no drift"
  }
  assert compare.verdict(resource.spec, xinit_fact(.Stopped, false), null, ["a"]) is compare.Satisfied
}

test modes_render_as_four_octal_digits {
  assert compare.octal(0o644) == "0644"
  assert compare.octal(0o7777) == "7777"
  assert compare.octal(0) == "0000"
  assert compare.octal(0o4755) == "4755"
}

test comparing_a_spec_with_the_wrong_kind_of_fact_is_uncertain_not_satisfied {
  let resource = declare.directory(id: "d", at: "/srv")?
  assert compare.verdict(resource.spec, fact.Nothing, null, none) is compare.Uncertain(_)
}

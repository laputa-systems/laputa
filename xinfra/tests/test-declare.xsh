use infra.declare
use infra.model

pure refused(result: Result[model.Resource, Error], needle: Str) -> Bool {
  match result {
    Ok(_) => false
    Err(error) => needle in error.message
  }
}

test paths_must_be_absolute_and_canonical {
  assert refused(declare.directory(id: "d", at: "relative/dir"), "absolute")
  assert refused(declare.directory(id: "d", at: "/a/../b"), "component")
  assert refused(declare.directory(id: "d", at: "/a//b"), "component")
  assert refused(declare.directory(id: "d", at: "/a/./b"), "component")
  assert refused(declare.directory(id: "d", at: "/a/"), "slash")
  assert refused(declare.directory(id: "d", at: "/"), "root")
  assert refused(declare.directory(id: "d", at: "/a\0b"), "NUL")
  assert declare.directory(id: "d", at: "/opt/it's a\nname -x") is Ok(_)
}

test ids_and_dependencies_are_validated_where_declared {
  assert refused(declare.directory(id: "", at: "/a"), "invalid resource id")
  assert refused(declare.directory(id: "has space", at: "/a"), "invalid resource id")
  assert refused(declare.directory(id: "ok", at: "/a", needs: ["bad id"]), "invalid resource id")
  assert declare.directory(id: "ok.1_2-3", at: "/a", needs: ["x"]) is Ok(_)
}

test modes_owners_and_groups_are_validated {
  assert refused(declare.directory(id: "d", at: "/a", mode: 0o10000), "mode out of range")
  assert refused(declare.directory(id: "d", at: "/a", mode: -1), "mode out of range")
  assert refused(declare.directory(id: "d", at: "/a", owner: "bad name"), "invalid owner")
  assert refused(declare.directory(id: "d", at: "/a", group_name: "-x"), "invalid group")
  assert declare.directory(id: "d", at: "/a", owner: "root", group_name: "0", mode: 0o2755) is Ok(_)
}

test a_file_needs_exactly_one_content_source {
  assert refused(declare.file(id: "f", at: "/etc/f"), "exactly one")
  assert refused(declare.file(id: "f", at: "/etc/f", text: "a", data: b"b"), "exactly one")
  assert refused(declare.file(id: "f", at: "/etc/f", presence: .Absent, text: "a"), "absent file takes no content")
  assert refused(declare.file(id: "f", at: "/etc/f", secret_env: "bad name"), "environment variable")
  assert declare.file(id: "f", at: "/etc/f", text: "a") is Ok(_)
  assert declare.file(id: "f", at: "/etc/f", presence: .Absent) is Ok(_)
}

test secret_content_marks_the_file_sensitive {
  let resource = declare.file(id: "f", at: "/etc/f", secret_env: "TOKEN")?
  match resource.spec {
    model.File(spec) => assert spec.sensitive
    else => assert false, "not a file"
  }
}

test a_validator_needs_one_staged_path_placeholder {
  assert refused(declare.file(id: "f", at: "/etc/f", text: "a", validate: ["sshd", "-t"]), "exactly one")
  assert refused(declare.file(id: "f", at: "/etc/f", text: "a", validate: ["x", "{}", "{}"]), "exactly one")
  assert declare.file(id: "f", at: "/etc/f", text: "a", validate: ["sshd", "-t", "-f", "{}"]) is Ok(_)
}

test a_present_symlink_needs_a_target {
  assert refused(declare.symlink(id: "l", at: "/etc/l"), "target")
  assert declare.symlink(id: "l", at: "/etc/l", target: "../x") is Ok(_)
  assert declare.symlink(id: "l", at: "/etc/l", presence: .Absent) is Ok(_)
}

test package_versions_follow_apk_syntax {
  let bound = declare.package(id: "p", name: "curl", version: ">=8.0.1-r0")?
  match bound.spec {
    model.Package(spec) => {
      guard let constraint = spec.constraint else {
        assert false, "no constraint"
        return
      }

      assert constraint.op == .Ge
      assert constraint.version == "8.0.1-r0"
    }
    else => assert false, "not a package"
  }
  assert refused(declare.package(id: "p", name: "Bad Name"), "invalid package name")
  assert refused(declare.package(id: "p", name: "curl", version: ">=x"), "invalid package version")
  assert refused(declare.package(id: "p", name: "curl", presence: .Absent, version: "1.0"), "absent package takes no version")
}

test a_command_needs_exactly_one_idempotence_condition {
  assert refused(declare.command(id: "c", argv: ["true"]), "exactly one")
  assert refused(declare.command(id: "c", argv: ["true"], creates: "/x", always: true), "exactly one")
  assert refused(declare.command(id: "c", argv: ["true"], shell: "true", always: true), "exactly one of argv and shell")
  assert refused(declare.command(id: "c", always: true), "exactly one of argv and shell")
  assert refused(declare.command(id: "c", argv: [], always: true), "at least one word")
  assert refused(declare.command(id: "c", argv: ["true"], always: true, accept: [256]), "out of range")
  assert declare.command(id: "c", argv: ["true"], creates: "/x") is Ok(_)
  assert declare.command(id: "c", shell: "test -e /x", skip_if_shell: "test -e /y") is Ok(_)
  assert declare.command(id: "c", argv: ["true"], run_on: ["f"]) is Ok(_)
  assert declare.command(id: "c", argv: ["true"], always: true) is Ok(_)
}

test a_service_must_declare_something {
  assert refused(declare.service(id: "s", name: "sshd"), "declare enabled")
  assert declare.service(id: "s", name: "sshd", running: true) is Ok(_)
  assert declare.service(id: "s", name: "sshd", restart_on: ["conf"]) is Ok(_)
}

test an_xinit_service_declares_no_enablement_or_runlevel {
  assert refused(declare.xinit_service(id: "s", name: "logger", enabled: true), "no enable or disable")
  assert refused(declare.xinit_service(id: "s", name: "logger"), "declare running")
  assert refused(declare.xinit_service(id: "s", name: "bad name", running: true), "invalid service name")
  let resource = declare.xinit_service(id: "s", name: "logger", running: true, restart_on: ["conf"])?
  match resource.spec {
    model.Service(spec) => {
      assert spec.adapter == .Xinit
      assert spec.enabled == null
      assert spec.running == true
      assert spec.runlevel == ""
    }
    else => assert false, "not a service"
  }
  assert model.dependencies(resource) == ["conf"]
}

test dependencies_include_declared_triggers {
  let service = declare.service(id: "s", name: "sshd", reload_on: ["a"], restart_on: ["b"], needs: ["c"])?
  assert model.dependencies(service) == ["c", "a", "b"]
}

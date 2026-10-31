use xinfra.model

proc expect_problem(result: Result[Unit, model.Problem], kind: Str, field: Str = "") [error] {
  match result {
    Ok(_) => test.fail(f"expected {kind} failure")?,
    Err(problem) => {
      test.eq(problem.kind, kind)?
      if ! field.is_empty() {
        test.eq(problem.field ?? "", field)?
      }
    },
  }
}

proc directory(id: Str, target: Path) -> model.Resource {
  model.Directory(model.DirectorySpec(id: id, path: target))
}

proc expect_ok(result: Result[Unit, model.Problem]) [error] {
  match result {
    Ok(_) => {}
    Err(problem) => test.fail(problem.message)?,
  }
}

test test_directory_defaults_and_privilege { |ctx|
  let directory = model.Directory(model.DirectorySpec(id: "etc-app", path: p"/etc/app"))
  test.eq(model.identity(directory), "etc-app")?
  test.eq(directory, model.Directory(model.DirectorySpec(id: "etc-app", path: p"/etc/app")))?
  match directory {
    model.Directory(spec) => {
      test.eq(spec.state, model.Present)?
      test.eq(spec.mode, 0o755)?
      test.eq(spec.owner, null)?
      test.eq(spec.group, null)?
      test.eq(spec.notify, [])?
      test.eq(spec.requires, [])?
      test.eq(spec.hosts, [])?
      test.eq(spec.privilege, null)?
    }
    _ => test.fail("directory did not match its variant")?,
  }

  test.eq(model.privilege(directory), model.AsUser)?
  expect_ok(model.validate(directory))
}

test test_file_defaults_and_variants { |ctx|
  let content = model.File(
    model.FileSpec(id: "motd", path: p"/etc/motd", source: model.Content("hello\n")),
  )
  match content {
    model.File(spec) => {
      test.eq(spec.state, model.Present)?
      test.eq(spec.mode, 0o644)?
      test.eq(spec.source, model.Content("hello\n"))?
    }
    _ => test.fail("file did not match its variant")?,
  }

  let rendered_file = model.File(
    model.FileSpec(
      id: "nginx-conf",
      path: p"/etc/nginx/nginx.conf",
      source: model.Templated(model.Template(path: p"templates/nginx.conf", vars: {"name": "web"})),
      validate: model.Validation(argv: ["nginx", "-t", "-c"]),
    ),
  )
  expect_ok(model.validate(rendered_file))

  let secret = model.File(
    model.FileSpec(id: "token", path: p"/etc/token", source: model.Secret(model.FromEnv("TOKEN"))),
  )
  expect_ok(model.validate(secret))
}

test test_package_user_group_and_service_default_to_root { |ctx|
  test.eq(
    model.privilege(model.Package(model.PackageSpec(id: "nginx", name: "nginx"))),
    model.AsRoot,
  )?
  test.eq(
    model.privilege(model.UserResource(model.UserSpec(id: "web", name: "web"))),
    model.AsRoot,
  )?
  test.eq(
    model.privilege(model.GroupResource(model.GroupSpec(id: "web", name: "web"))),
    model.AsRoot,
  )?
  test.eq(
    model.privilege(model.ServiceResource(model.ServiceSpec(id: "nginx", name: "nginx"))),
    model.AsRoot,
  )?
  test.eq(
    model.privilege(
      model.Package(model.PackageSpec(id: "nginx", name: "nginx", privilege: model.AsUser)),
    ),
    model.AsUser,
  )?
}

test test_host_selection { |ctx|
  let everywhere = directory("all", p"/etc/all")
  test.ok(model.applies_to(everywhere, "web-1", ["web"]))?
  test.ok(model.applies_to(everywhere, "db-1", []))?

  let selected = model.Directory(
    model.DirectorySpec(id: "web-only", path: p"/etc/web", hosts: ["web"]),
  )
  test.ok(model.applies_to(selected, "web-1", ["web"]))?
  test.ok(! model.applies_to(selected, "db-1", []))?
}

test test_rejects_empty_and_invalid_ids { |ctx|
  expect_problem(model.validate(directory("", p"/etc/app")), "empty-id")
  expect_problem(model.validate(directory("bad id", p"/etc/app")), "invalid-id")
  expect_problem(model.validate(directory("-leading", p"/etc/app")), "invalid-id")
}

test test_rejects_relative_and_parent_managed_paths { |ctx|
  expect_problem(model.validate(directory("relative", p"etc/app")), "invalid-field", "path")
  expect_problem(model.validate(directory("parent", p"/etc/../app")), "invalid-field", "path")
}

test test_rejects_non_utf8_paths { |ctx|
  let bad = Path.parse_bytes(bytes.from_ints([47, 101, 116, 99, 47, 255])?)?
  expect_problem(model.validate(directory("bad-bytes", bad)), "non-utf8-path", "path")

  let bad_source = Path.parse_bytes(bytes.from_ints([115, 114, 99, 255])?)?
  let file = model.File(
    model.FileSpec(id: "bad-source", path: p"/etc/app", source: model.Source(bad_source)),
  )
  expect_problem(model.validate(file), "non-utf8-path", "source")
}

test test_rejects_invalid_accounts_and_root_without_privilege { |ctx|
  let bad_owner = model.Directory(
    model.DirectorySpec(id: "bad-owner", path: p"/etc/app", owner: "bad owner"),
  )
  expect_problem(model.validate(bad_owner), "invalid-field", "owner")

  let root_owner = model.Directory(
    model.DirectorySpec(id: "root-owner", path: p"/etc/app", owner: "root"),
  )
  expect_problem(model.validate(root_owner), "invalid-field", "privilege")

  expect_ok(
    model.validate(
      model.Directory(
        model.DirectorySpec(id: "root-owner", path: p"/etc/app", owner: "root", privilege: model.AsRoot),
      ),
    ),
  )
}

test test_rejects_bad_modes { |ctx|
  for mode in [-1, 0o10000] {
    expect_problem(
      model.validate(model.Directory(model.DirectorySpec(id: "mode", path: p"/etc/app", mode: mode))),
      "invalid-field",
      "mode",
    )
  }
}

test test_rejects_invalid_file_source_combinations { |ctx|
  let absent_with_source = model.File(
    model.FileSpec(
      id: "absent-source",
      path: p"/etc/app",
      state: model.Absent,
      source: model.Content("x"),
    ),
  )
  expect_problem(model.validate(absent_with_source), "invalid-field", "source")

  let present_without_source = model.File(model.FileSpec(id: "missing-source", path: p"/etc/app"))
  expect_problem(model.validate(present_without_source), "invalid-field", "source")

  let absolute_source = model.File(
    model.FileSpec(id: "absolute-source", path: p"/etc/app", source: model.Source(p"/etc/passwd")),
  )
  expect_problem(model.validate(absolute_source), "invalid-field", "source")

  let empty_validation = model.File(
    model.FileSpec(
      id: "empty-validation",
      path: p"/etc/app",
      source: model.Content("x"),
      validate: model.Validation(argv: []),
    ),
  )
  expect_problem(model.validate(empty_validation), "invalid-field", "validate.argv")

  let absolute_template = model.File(
    model.FileSpec(
      id: "absolute-template",
      path: p"/etc/app",
      source: model.Templated(model.Template(path: p"/etc/template")),
    ),
  )
  expect_problem(model.validate(absolute_template), "invalid-field", "template.path")
}

test test_rejects_invalid_symlinks { |ctx|
  let empty_target = model.Symlink(
    model.SymlinkSpec(id: "link", path: p"/etc/link", target: p""),
  )
  expect_problem(model.validate(empty_target), "invalid-field", "target")

  let relative_path = model.Symlink(
    model.SymlinkSpec(id: "link", path: p"etc/link", target: p"/etc/target"),
  )
  expect_problem(model.validate(relative_path), "invalid-field", "path")
}

test test_accepts_alpine_package_names_and_relative_symlink_targets { |ctx|
  expect_ok(model.validate(model.Package(model.PackageSpec(id: "stdcpp", name: "libstdc++"))))
  expect_ok(model.validate(model.Package(model.PackageSpec(id: "edge", name: "nginx@edge"))))
  expect_ok(
    model.validate(
      model.Symlink(model.SymlinkSpec(id: "current", path: p"/etc/current", target: p"../current")),
    ),
  )
  expect_ok(
    model.validate(
      model.Symlink(model.SymlinkSpec(id: "dash", path: p"/etc/dash", target: p"-dash")),
    ),
  )
}

test test_rejects_invalid_package_specs { |ctx|
  let absent_constraint = model.Package(
    model.PackageSpec(id: "nginx", name: "nginx", state: model.Absent, constraint: ">=1.2"),
  )
  expect_problem(model.validate(absent_constraint), "invalid-field", "constraint")

  let bad_name = model.Package(model.PackageSpec(id: "nginx", name: "nginx extra"))
  expect_problem(model.validate(bad_name), "invalid-field", "name")
}

test test_rejects_invalid_user_and_group_specs { |ctx|
  expect_problem(
    model.validate(
      model.UserResource(model.UserSpec(id: "web", name: "bad name")),
    ),
    "invalid-field",
    "name",
  )
  expect_problem(
    model.validate(
      model.UserResource(model.UserSpec(id: "web", name: "web", uid: -1)),
    ),
    "invalid-field",
    "uid",
  )
  expect_problem(
    model.validate(
      model.UserResource(model.UserSpec(id: "web", name: "web", state: model.Absent, update: true)),
    ),
    "invalid-field",
    "update",
  )
  expect_problem(
    model.validate(
      model.UserResource(model.UserSpec(id: "web", name: "web", state: model.Absent, create_home: true)),
    ),
    "invalid-field",
    "create_home",
  )
  expect_problem(
    model.validate(
      model.GroupResource(model.GroupSpec(id: "web", name: "web", gid: -1)),
    ),
    "invalid-field",
    "gid",
  )
}

test test_rejects_invalid_commands { |ctx|
  let neither = model.CommandResource(
    model.CommandSpec(id: "run", creates: p"/tmp/done"),
  )
  expect_problem(model.validate(neither), "invalid-field", "argv")

  let both = model.CommandResource(
    model.CommandSpec(
      id: "run",
      argv: ["true"],
      shell: "true",
      creates: p"/tmp/done",
    ),
  )
  expect_problem(model.validate(both), "invalid-field", "argv")

  let unguarded = model.CommandResource(model.CommandSpec(id: "run", argv: ["true"]))
  expect_problem(model.validate(unguarded), "invalid-field", "always_run")

  let conflicting = model.CommandResource(
    model.CommandSpec(
      id: "run",
      argv: ["true"],
      creates: p"/tmp/done",
      always_run: true,
    ),
  )
  expect_problem(model.validate(conflicting), "invalid-field", "always_run")

  let empty: List[Str] = []
  let empty_argv = model.CommandResource(
    model.CommandSpec(id: "run", argv: empty, creates: p"/tmp/done"),
  )
  expect_problem(model.validate(empty_argv), "invalid-field", "argv")

  let empty_unless = model.CommandResource(
    model.CommandSpec(id: "run", argv: ["true"], unless_argv: empty),
  )
  expect_problem(model.validate(empty_unless), "invalid-field", "unless")

  let bad_timeout = model.CommandResource(
    model.CommandSpec(id: "run", argv: ["true"], creates: p"/tmp/done", timeout: 0s),
  )
  expect_problem(model.validate(bad_timeout), "invalid-field", "timeout")

  expect_ok(
    model.validate(
      model.CommandResource(
        model.CommandSpec(
          id: "run",
          argv: ["true"],
          unless_argv: ["test", "-e", "/tmp/done"],
          env: {"MODE": "test"},
          stdin_secret: model.FromEnv("TOKEN"),
          timeout: 5s,
        ),
      ),
    ),
  )
}

test test_rejects_invalid_service_and_selectors { |ctx|
  expect_problem(
    model.validate(model.ServiceResource(model.ServiceSpec(id: "svc", name: "bad service"))),
    "invalid-field",
    "name",
  )
  expect_problem(
    model.validate(
      model.Directory(model.DirectorySpec(id: "dir", path: p"/etc/app", hosts: ["bad group"])),
    ),
    "invalid-field",
    "hosts",
  )
  expect_problem(
    model.validate(
      model.File(
        model.FileSpec(
          id: "file",
          path: p"/etc/app",
          source: model.Content("x"),
          notify: ["not a service"],
        ),
      ),
    ),
    "invalid-field",
    "notify",
  )
}

test test_validates_every_resource_variant { |ctx|
  let resources = [
    directory("dir", p"/etc/app"),
    model.File(model.FileSpec(id: "file", path: p"/etc/file", source: model.Content("x"))),
    model.Symlink(model.SymlinkSpec(id: "link", path: p"/etc/link", target: p"/etc/file")),
    model.Package(model.PackageSpec(id: "pkg", name: "nginx")),
    model.UserResource(model.UserSpec(id: "user", name: "web")),
    model.GroupResource(model.GroupSpec(id: "group", name: "web")),
    model.CommandResource(
      model.CommandSpec(id: "run", argv: ["true"], creates: p"/tmp/done"),
    ),
    model.ServiceResource(model.ServiceSpec(id: "svc", name: "nginx")),
  ]
  expect_ok(model.validate_all(resources))
}

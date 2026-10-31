use support.fake_host as fake
use xinfra.host
use xinfra.model
use xinfra.resources.file
use xinfra.validate

proc host_path(root: Path, managed: Path) [error] -> Result[Path] {
  let relative = managed.strip_prefix(p"/")?
  Ok(fp"{root}/{relative}")
}

proc tree(root: Path) [fs, error] -> Result[List[Str]] {
  var names: List[Str] = []
  for entry in fs.walk(root, hidden: true)?.collect() {
    names += [entry.path.relative_to(root).display()]
  }

  Ok(names)
}

proc has_staging(names: List[Str]) -> Bool {
  for name in names {
    if name.find(".tmp") != null {
      return true
    }
  }

  false
}

proc expect_status(result: host.ApplyResult, expected: host.ApplyStatus) [error] {
  test.ok(
    result.status == expected,
    f"status {json.encode(result.status)?} expected {json.encode(expected)?}",
  )?
}

proc source(text: Str) -> validate.PreparedSource {
  validate.Content(validate.ContentSource(text: text, digest: hash.sha256(bytes.from_text(text)).hex()))
}

proc file_spec(id: Str, target: Path, text: Str) -> model.FileSpec {
  model.FileSpec(id: id, path: target, source: model.Content(text))
}

test test_first_apply_then_unchanged_and_content { |ctx|
  let root = test.temp_dir(ctx, "file-first")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    host_path(root, p"/etc")?.mkdir()?
    let spec = file_spec("motd", p"/etc/motd", "hello\n")

    let first = file.apply(ops, spec, source("hello\n"))
    expect_status(first, host.Changed)
    test.eq(first.verified, true)?
    test.eq(host_path(root, p"/etc/motd")?.read_text()?, "hello\n")?

    let second = file.apply(ops, spec, source("hello\n"))
    expect_status(second, host.Unchanged)
    test.eq(second.verified, true)?
    test.ok(! has_staging(tree(root)?))?
  }
}

test test_noop_leaves_mtime_alone { |ctx|
  let root = test.temp_dir(ctx, "file-mtime")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    host_path(root, p"/etc")?.mkdir()?
    let spec = file_spec("motd", p"/etc/motd", "hello\n")
    expect_status(file.apply(ops, spec, source("hello\n")), host.Changed)
    let before = fake.mtime(p"/etc/motd")?
    expect_status(file.apply(ops, spec, source("hello\n")), host.Unchanged)
    test.eq(fake.mtime(p"/etc/motd")?, before)?
  }
}

test test_drift_is_detected_and_repaired { |ctx|
  let root = test.temp_dir(ctx, "file-drift")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    host_path(root, p"/etc")?.mkdir()?
    let spec = file_spec("motd", p"/etc/motd", "hello\n")
    expect_status(file.apply(ops, spec, source("hello\n")), host.Changed)

    host_path(root, p"/etc/motd")?.write("drift\n")?
    expect_status(file.apply(ops, spec, source("hello\n")), host.Changed)
    test.eq(host_path(root, p"/etc/motd")?.read_text()?, "hello\n")?
    expect_status(file.apply(ops, spec, source("hello\n")), host.Unchanged)
  }
}

test test_validation_failure_preserves_the_live_object { |ctx|
  let root = test.temp_dir(ctx, "file-validation")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    host_path(root, p"/etc")?.mkdir()?
    host_path(root, p"/etc/motd")?.write("old\n")?

    let spec = model.FileSpec(
      id: "motd",
      path: p"/etc/motd",
      source: model.Content("new\n"),
      validate: model.Validation(argv: ["nginx", "-t", "-c"]),
    )
    env XINFRA_FAKE_VALIDATION_FAILURE="1" {
      let result = file.apply(ops, spec, source("new\n"))
      expect_status(result, host.Failed)
      test.eq(result.verified, false)?
    }
    test.eq(host_path(root, p"/etc/motd")?.read_text()?, "old\n")?
    test.ok(! has_staging(tree(root)?))?
  }
}

test test_partial_transfer_preserves_the_destination_and_cleans_staging { |ctx|
  let root = test.temp_dir(ctx, "file-partial")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    host_path(root, p"/etc")?.mkdir()?
    host_path(root, p"/etc/motd")?.write("old\n")?
    let spec = file_spec("motd", p"/etc/motd", "new content\n")

    env XINFRA_FAKE_STAGE_FAILURE="1" {
      let result = file.apply(ops, spec, source("new content\n"))
      expect_status(result, host.Partial)
      test.eq(result.verified, false)?
    }
    test.eq(host_path(root, p"/etc/motd")?.read_text()?, "old\n")?
    test.ok(! has_staging(tree(root)?))?
  }
}

test test_secret_content_is_resolved_only_at_apply_and_is_idempotent { |ctx|
  let root = test.temp_dir(ctx, "file-secret")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    host_path(root, p"/etc")?.mkdir()?
    let spec = model.FileSpec(
      id: "token",
      path: p"/etc/token",
      source: model.Secret(model.FromEnv("TOKEN")),
      mode: 0o600,
    )
    let prepared = validate.Secret(model.FromEnv("TOKEN"))
    env TOKEN="canary-value" {
      expect_status(file.apply(ops, spec, prepared), host.Changed)
      test.eq(host_path(root, p"/etc/token")?.read_text()?, "canary-value")?
      expect_status(file.apply(ops, spec, prepared), host.Unchanged)
    }
  }
}

test test_absence_removes_only_files { |ctx|
  let root = test.temp_dir(ctx, "file-absent")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    host_path(root, p"/etc")?.mkdir()?
    let present = file_spec("motd", p"/etc/motd", "hello\n")
    expect_status(file.apply(ops, present, source("hello\n")), host.Changed)

    let absent = model.FileSpec(id: "motd", path: p"/etc/motd", state: model.Absent)
    expect_status(file.apply(ops, absent, null), host.Changed)
    test.ok(! host_path(root, p"/etc/motd")?.exists()?)?
    expect_status(file.apply(ops, absent, null), host.Unchanged)

    host_path(root, p"/etc/dir")?.mkdir()?
    let conflict = model.FileSpec(id: "dir", path: p"/etc/dir", state: model.Absent)
    expect_status(file.apply(ops, conflict, null), host.Blocked)
  }
}

test test_type_conflicts_and_untrusted_parents_are_explicit { |ctx|
  let root = test.temp_dir(ctx, "file-conflict")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    host_path(root, p"/etc")?.mkdir()?
    host_path(root, p"/etc/motd")?.mkdir()?
    let spec = file_spec("motd", p"/etc/motd", "hello\n")
    expect_status(file.apply(ops, spec, source("hello\n")), host.Blocked)
    test.ok(host_path(root, p"/etc/motd")?.is_dir()?)?

    host_path(root, p"/etc/motd")?.remove_dir()?
    env XINFRA_FAKE_INSECURE_PARENT="1" {
      expect_status(file.apply(ops, spec, source("hello\n")), host.Blocked)
    }
    test.ok(! host_path(root, p"/etc/motd")?.exists()?)?
  }
}

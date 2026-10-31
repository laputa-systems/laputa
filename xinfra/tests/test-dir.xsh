use support.fake_host as fake
use xinfra.host
use xinfra.model
use xinfra.plan
use xinfra.resources.dir

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

proc directory(id: Str, target: Path) -> model.Resource {
  model.Directory(model.DirectorySpec(id: id, path: target))
}

test test_first_apply_then_unchanged { |ctx|
  let root = test.temp_dir(ctx, "dir-first")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    expect_status(dir.apply(ops, model.DirectorySpec(id: "srv", path: p"/srv")), host.Changed)
    let target = p"/srv/app"
    let spec = model.DirectorySpec(id: "app", path: target)

    let first = dir.apply(ops, spec)
    expect_status(first, host.Changed)
    test.eq(first.verified, true)?
    test.eq(first.host, "fake")?
    test.ok((host_path(root, target)?).is_dir()?)?

    let second = dir.apply(ops, spec)
    expect_status(second, host.Unchanged)
    test.eq(second.verified, true)?
  }
}

test test_drift_is_detected_and_repaired { |ctx|
  let root = test.temp_dir(ctx, "dir-drift")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    expect_status(dir.apply(ops, model.DirectorySpec(id: "srv", path: p"/srv")), host.Changed)
    let target = p"/srv/app"
    let spec = model.DirectorySpec(id: "app", path: target)
    expect_status(dir.apply(ops, spec), host.Changed)

    let real = host_path(root, target)?
    real.chmod(0o700)?
    expect_status(dir.apply(ops, spec), host.Changed)
    let mode = match real.metadata() {
      Ok(value) => value.mode,
      Err(_) => 0,
    }
    test.eq(mode.bit_and(0o777), 0o755)?
    expect_status(dir.apply(ops, spec), host.Unchanged)
  }
}

test test_plan_and_check_perform_no_write { |ctx|
  let root = test.temp_dir(ctx, "dir-plan")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    expect_status(dir.apply(ops, model.DirectorySpec(id: "srv", path: p"/srv")), host.Changed)
    let spec = model.DirectorySpec(id: "app", path: p"/srv/app")
    expect_status(dir.apply(ops, spec), host.Changed)

    let before = tree(root)?
    let inspection = ops.inspect_path(p"/srv/app")?
    let assessment = plan.assess(directory("app", p"/srv/app"), null, host.observed(inspection))
    test.eq(assessment.prediction, plan.Unchanged)?
    test.eq(tree(root)?, before)?
    test.ok(! has_staging(tree(root)?))?
  }
}

test test_noop_leaves_mtime_alone { |ctx|
  let root = test.temp_dir(ctx, "dir-mtime")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    expect_status(dir.apply(ops, model.DirectorySpec(id: "srv", path: p"/srv")), host.Changed)
    let spec = model.DirectorySpec(id: "app", path: p"/srv/app")
    expect_status(dir.apply(ops, spec), host.Changed)
    let before = fake.mtime(p"/srv/app")?
    expect_status(dir.apply(ops, spec), host.Unchanged)
    test.eq(fake.mtime(p"/srv/app")?, before)?
  }
}

test test_absence_is_one_level { |ctx|
  let root = test.temp_dir(ctx, "dir-absent")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    expect_status(dir.apply(ops, model.DirectorySpec(id: "srv", path: p"/srv")), host.Changed)
    expect_status(dir.apply(ops, model.DirectorySpec(id: "app", path: p"/srv/app")), host.Changed)

    let absent_parent = model.DirectorySpec(id: "srv", path: p"/srv", state: model.Absent)
    let blocked = dir.apply(ops, absent_parent)
    expect_status(blocked, host.Blocked)
    test.ok(host_path(root, p"/srv/app")?.is_dir()?)?

    let absent_child = model.DirectorySpec(id: "app", path: p"/srv/app", state: model.Absent)
    expect_status(dir.apply(ops, absent_child), host.Changed)
    test.ok(! host_path(root, p"/srv/app")?.exists()?)?
    expect_status(dir.apply(ops, absent_child), host.Unchanged)
  }
}

test test_file_and_directory_conflicts_are_explicit { |ctx|
  let root = test.temp_dir(ctx, "dir-conflict")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    host_path(root, p"/etc")?.mkdir()?
    host_path(root, p"/etc/conflict")?.write("not a directory")?

    let present = dir.apply(ops, model.DirectorySpec(id: "conflict", path: p"/etc/conflict"))
    expect_status(present, host.Blocked)
    test.ok(host_path(root, p"/etc/conflict")?.is_file()?)?

    let absent = dir.apply(ops, model.DirectorySpec(id: "conflict", path: p"/etc/conflict", state: model.Absent))
    expect_status(absent, host.Blocked)
  }
}

test test_untrusted_parent_is_blocked { |ctx|
  let root = test.temp_dir(ctx, "dir-parent")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    env XINFRA_FAKE_INSECURE_PARENT="1" {
      let result = dir.apply(ops, model.DirectorySpec(id: "app", path: p"/srv/app"))
      expect_status(result, host.Blocked)
      test.ok(! host_path(root, p"/srv/app")?.exists()?)?
    }
  }
}

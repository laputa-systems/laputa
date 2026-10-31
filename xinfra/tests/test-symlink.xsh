use support.fake_host as fake
use xinfra.host
use xinfra.model
use xinfra.resources.symlink

proc host_path(root: Path, managed: Path) [error] -> Result[Path] {
  let relative = managed.strip_prefix(p"/")?
  Ok(fp"{root}/{relative}")
}

proc expect_status(result: host.ApplyResult, expected: host.ApplyStatus) [error] {
  test.ok(
    result.status == expected,
    f"status {json.encode(result.status)?} expected {json.encode(expected)?}",
  )?
}

proc link_spec(id: Str, target: Path, destination: Path, replace: Bool = false) -> model.SymlinkSpec {
  model.SymlinkSpec(id: id, path: destination, target: target, replace: replace)
}

test test_first_apply_then_unchanged { |ctx|
  let root = test.temp_dir(ctx, "link-first")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    host_path(root, p"/etc")?.mkdir()?
    let spec = link_spec("motd-link", p"/etc/motd", p"/etc/link")

    expect_status(symlink.apply(ops, spec), host.Changed)
    test.eq(host_path(root, p"/etc/link")?.readlink()?, p"/etc/motd")?

    let second = symlink.apply(ops, spec)
    expect_status(second, host.Unchanged)
    test.eq(second.verified, true)?
  }
}

test test_target_drift_requires_explicit_replacement { |ctx|
  let root = test.temp_dir(ctx, "link-drift")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    host_path(root, p"/etc")?.mkdir()?
    host_path(root, p"/etc/motd")?.write("old\n")?
    host_path(root, p"/etc/link")?.symlink(to: p"/etc/other")?

    let blocked = symlink.apply(ops, link_spec("motd-link", p"/etc/motd", p"/etc/link"))
    expect_status(blocked, host.Blocked)
    test.eq(host_path(root, p"/etc/link")?.readlink()?, p"/etc/other")?

    let replace = link_spec("motd-link", p"/etc/motd", p"/etc/link", replace: true)
    expect_status(symlink.apply(ops, replace), host.Changed)
    test.eq(host_path(root, p"/etc/link")?.readlink()?, p"/etc/motd")?
    expect_status(symlink.apply(ops, replace), host.Unchanged)
  }
}

test test_file_conflicts_are_explicit { |ctx|
  let root = test.temp_dir(ctx, "link-file")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    host_path(root, p"/etc")?.mkdir()?
    host_path(root, p"/etc/link")?.write("a file")?

    expect_status(symlink.apply(ops, link_spec("motd-link", p"/etc/motd", p"/etc/link")), host.Blocked)
    test.ok(host_path(root, p"/etc/link")?.is_file()?)?

    let replace = link_spec("motd-link", p"/etc/motd", p"/etc/link", replace: true)
    expect_status(symlink.apply(ops, replace), host.Changed)
    test.ok(host_path(root, p"/etc/link")?.is_symlink()?)?
    test.eq(host_path(root, p"/etc/link")?.readlink()?, p"/etc/motd")?
  }
}

test test_directory_conflicts_are_explicit { |ctx|
  let root = test.temp_dir(ctx, "link-dir")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    host_path(root, p"/etc")?.mkdir()?
    host_path(root, p"/etc/link")?.mkdir()?

    expect_status(symlink.apply(ops, link_spec("motd-link", p"/etc/motd", p"/etc/link")), host.Blocked)
    test.ok(host_path(root, p"/etc/link")?.is_dir()?)?
  }
}

test test_absence_removes_only_symlinks { |ctx|
  let root = test.temp_dir(ctx, "link-absent")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    host_path(root, p"/etc")?.mkdir()?
    let present = link_spec("motd-link", p"/etc/motd", p"/etc/link")
    expect_status(symlink.apply(ops, present), host.Changed)

    let absent = model.SymlinkSpec(
      id: "motd-link",
      path: p"/etc/link",
      target: p"/etc/motd",
      state: model.Absent,
    )
    expect_status(symlink.apply(ops, absent), host.Changed)
    test.ok(! host_path(root, p"/etc/link")?.exists()?)?
    expect_status(symlink.apply(ops, absent), host.Unchanged)

    host_path(root, p"/etc/file")?.write("file")?
    let conflict = model.SymlinkSpec(
      id: "file",
      path: p"/etc/file",
      target: p"/etc/motd",
      state: model.Absent,
    )
    expect_status(symlink.apply(ops, conflict), host.Blocked)
    test.ok(host_path(root, p"/etc/file")?.is_file()?)?
  }
}

test test_untrusted_parent_is_blocked { |ctx|
  let root = test.temp_dir(ctx, "link-parent")?
  env XINFRA_FAKE_ROOT=f"{root}" {
    fake.reset()?
    let ops = fake.host()
    host_path(root, p"/etc")?.mkdir()?
    env XINFRA_FAKE_INSECURE_PARENT="1" {
      expect_status(symlink.apply(ops, link_spec("motd-link", p"/etc/motd", p"/etc/link")), host.Blocked)
    }
    test.ok(! host_path(root, p"/etc/link")?.exists()?)?
  }
}

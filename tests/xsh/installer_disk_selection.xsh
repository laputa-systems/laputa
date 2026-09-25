##! CI disk selection ignores unrelated sysfs nodes and reads partition metadata.
use installer.disk_selection

proc test_ci_target_installed_skips_non_partition_sysfs_entries(ctx: TestContext) [fs, error] {
  let root = test.temp_dir(ctx, name: "installer-sys-block")?
  let block = fp"${root}/vda"
  fs.mkdir(block)?
  fs.write(fp"${block}/device", "not a partition\n")?
  fs.mkdir(fp"${block}/vda1")?
  fs.write(fp"${block}/vda1/partition", "1\n")?
  fs.write(fp"${block}/vda1/uevent", "PARTUUID=33333333-3333-3333-3333-333333333333\n")?

  test.eq(
    disk_selection.ci_target_installed(root, [p"/dev/vda"], "33333333-3333-3333-3333-333333333333")?,
    true,
  )?
  test.eq(
    disk_selection.ci_target_installed(root, [p"/dev/vda"], "44444444-4444-4444-4444-444444444444")?,
    false,
  )?
}

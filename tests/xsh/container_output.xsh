##! Behavior coverage for publishing final container artifacts without exposing partial host outputs.
use laputa.container_output as container_output

proc test_publish_final_file_replaces_only_after_the_verified_copy(ctx: TestContext) [fs, error] {
  let root = test.temp_dir(ctx, name: "container-output")?
  let source = fp"${root}/workspace/disk.img"
  let output = fp"${root}/host-output/disk.img"
  fs.mkdir(source.parent)?
  fs.mkdir(output.parent)?
  fs.write(source, "verified disk image")?
  fs.write(output, "previous disk image")?

  container_output.publish_final_file(source, output)?
  test.eq(fs.read_text(output)?, "verified disk image")?

  fs.remove(source)?

  match container_output.publish_final_file(source, output) {
    Ok(_) => test.fail("missing local source unexpectedly replaced host output")?
    Err(problem) => test.contains(problem.message, "source is missing or empty")?,
  }

  test.eq(fs.read_text(output)?, "verified disk image")?
}

proc test_publish_bundle_switches_current_only_after_a_complete_verified_directory(ctx: TestContext) [fs, error] {
  let root = test.temp_dir(ctx, name: "container-bundle")?
  let workspace = fp"${root}/workspace"
  fs.mkdir(workspace)?
  let plan = fp"${workspace}/build-plan.json"
  let generation = fp"${workspace}/generation.json"
  let kernel = fp"${workspace}/vmlinuz"
  let rootfs = fp"${workspace}/rootfs.ext4"
  let disk = fp"${workspace}/disk.img"
  for item in [plan, generation, kernel, rootfs, disk] { fs.write(item, f"${item.name}\n")? }
  let key = bytes.from_text("system bundle").sha256().hex()
  let files: List[container_output.BundleFile] = [
    {name: "build-plan.json", source: plan},
    {name: "generation.json", source: generation},
    {name: "vmlinuz", source: kernel},
    {name: "rootfs.ext4", source: rootfs},
    {name: "disk.img", source: disk},
  ]
  container_output.publish_bundle(root, key, files)?
  test.eq(fp"${root}/current".readlink()?.display(), f"builds/${key}")?
  test.eq(fs.read_text(fp"${root}/current/disk.img")?, "disk.img\n")?
  test.eq(fs.exists(fp"${root}/builds/.${key}.tmp")?, false)?

  fs.write(disk, "changed disk\n")?
  match container_output.publish_bundle(root, key, files) {
    Ok(_) => test.fail("completed system bundle unexpectedly changed")?
    Err(problem) => test.contains(problem.message, "bundle output does not match")?,
  }
  test.eq(fs.read_text(fp"${root}/current/disk.img")?, "disk.img\n")?
}

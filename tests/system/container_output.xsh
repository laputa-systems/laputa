##! Behavior coverage for publishing final container artifacts without exposing partial host outputs.
use system.container_output

test test_publish_final_file_replaces_only_after_the_verified_copy [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "container-output")?
  let source = fp"{root}/workspace/disk.img"
  let output = fp"{root}/host-output/disk.img"
  source.parent.mkdir()
  output.parent.mkdir()
  source.write("verified disk image")
  output.write("previous disk image")

  container_output.publish_final_file(source, output)
  assert output.read_text()? == "verified disk image"

  source.remove(missing_ok: false)

  match container_output.publish_final_file(source, output) {
    Ok(_) => test.fail("missing local source unexpectedly replaced host output")
    Err(problem) => assert "source is missing or empty" in problem.message
  }

  assert output.read_text()? == "verified disk image"
}

test test_publish_bundle_switches_current_only_after_a_complete_verified_directory [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "container-bundle")?
  let workspace = fp"{root}/workspace"
  workspace.mkdir()
  let plan = fp"{workspace}/build-plan.json"
  let generation = fp"{workspace}/generation.json"
  let kernel = fp"{workspace}/vmlinuz"
  let rootfs = fp"{workspace}/rootfs.ext4"
  let disk = fp"{workspace}/disk.img"
  for item in [plan, generation, kernel, rootfs, disk] {
    item.write(
      f"""{item.name}
""",
    )
  }

  let key = bytes.from_text("system bundle").sha256().hex()
  let files = [
    {
      name: "build-plan.json",
      source: plan,
    },
    {
      name: "generation.json",
      source: generation,
    },
    {
      name: "vmlinuz",
      source: kernel,
    },
    {
      name: "rootfs.ext4",
      source: rootfs,
    },
    {
      name: "disk.img",
      source: disk,
    },
  ]
  container_output.publish_bundle(root, key, files)
  assert fp"{root}/current".readlink()?.display() == f"builds/{key}"
  assert fp"{root}/current/disk.img".read_text()? == """disk.img
"""
  assert fp"{root}/builds/.{key}.tmp".exists()? == false

  disk.write(
    """changed disk
""",
  )
  match container_output.publish_bundle(root, key, files) {
    Ok(_) => test.fail("completed system bundle unexpectedly changed")
    Err(problem) => assert "bundle output does not match" in problem.message
  }

  assert fp"{root}/current/disk.img".read_text()? == """disk.img
"""
}

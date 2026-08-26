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

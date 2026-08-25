##! Unit coverage for deterministic rootfs sizing and GPT disk output.
use laputa.image as image
use laputa.qemu as qemu
use laputa.types as types

proc test_rootfs_size_has_expected_margin_rounding_and_floor() [error] {
  test.eq(image.rootfs_size_bytes(0), 256 * 1024 * 1024)?
  test.eq(image.rootfs_size_bytes(256 * 1024 * 1024), 384 * 1024 * 1024)?
  test.eq(image.rootfs_size_bytes(257 * 1024 * 1024), 386 * 1024 * 1024)?
}

proc test_protective_mbr_has_signature_and_protective_partition() [error] {
  let mbr = image.protective_mbr(1024)?
  test.eq(bytes.unpack_le(mbr, 1, offset: 450)?, 238)?
  test.eq(bytes.unpack_le(mbr, 2, offset: 510)?, 43605)?
}

proc test_gpt_disk_is_written_atomically_with_expected_root_partition(ctx: TestContext) [fs, error] {
  let root = test.temp_dir(ctx, name: "image")?
  let rootfs = fp"${root}/rootfs.ext4"
  let disk = fp"${root}/disk.img"
  fs.write(rootfs, bytes.zero(4096)?)?
  fs.write(disk, "old")?
  image.write_disk(rootfs, disk)?
  image.verify_disk(disk, 4096)?
  test.ok(fs.metadata(disk)?.size > 4096)?
  test.eq(image.image_root_partuuid(), "33333333-3333-3333-3333-333333333333")?
}

proc test_kernel_manifest_path_is_relative_existing_and_nonempty(ctx: TestContext) [fs, error] {
  let root = test.temp_dir(ctx, name: "kernel-source")?
  fs.mkdir(fp"${root}/boot")?
  fs.write(fp"${root}/boot/vmlinuz", "kernel")?
  test.eq(image.image_kernel_source(root, p"boot/vmlinuz")?, fp"${root}/boot/vmlinuz")?

  for path_value in [p"boot/missing", p"/boot/vmlinuz", p"../boot/vmlinuz"] {
    match image.image_kernel_source(root, path_value) {
      Ok(_) => test.ok(false)?
      Err(_) => {}
    }
  }
}

proc test_gpt_partuuid_matches_the_qemu_kernel_command_line() [error] {
  test.ok(qemu.kernel_cmdline(types.Test).contains(f"root=PARTUUID=${image.image_root_partuuid()}"))?
}

proc test_generation_size_counts_payload_and_incomplete_disk_preserves_final(ctx: TestContext) [fs, error] {
  let root = test.temp_dir(ctx, name: "generation-size")?
  fs.mkdir(fp"${root}/usr")?
  fs.write(fp"${root}/usr/payload", "payload")?
  test.eq(image.image_generation_used_bytes(root)?, 7)?

  let rootfs = fp"${root}/invalid.ext4"
  let disk = fp"${root}/disk.img"
  fs.write(rootfs, "not-sector-aligned")?
  fs.write(disk, "previous-final")?
  match image.write_disk(rootfs, disk) {
    Ok(_) => test.ok(false)?
    Err(_) => {}
  }
  test.eq(fs.read_text(disk)?, "previous-final")?
}

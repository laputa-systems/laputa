##! Unit coverage for deterministic rootfs sizing and GPT disk output.
use system.image as image
use system.qemu as qemu
use system.types as types

test test_rootfs_size_has_expected_margin_rounding_and_floor [error] {
  assert image.rootfs_size_bytes(0) == 256 * 1024 * 1024
  assert image.rootfs_size_bytes(256 * 1024 * 1024) == 384 * 1024 * 1024
  assert image.rootfs_size_bytes(257 * 1024 * 1024) == 386 * 1024 * 1024
}

test test_protective_mbr_has_signature_and_protective_partition [error] {
  let mbr = image.protective_mbr(1024)?
  assert bytes.unpack_le(mbr, 1, offset: 450)? == 238
  assert bytes.unpack_le(mbr, 2, offset: 510)? == 43605
}

test test_gpt_disk_is_written_atomically_with_expected_root_partition [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "image")?
  let rootfs = fp"${root}/rootfs.ext4"
  let disk = fp"${root}/disk.img"
  fs.write(rootfs, bytes.zero(4096)?)?
  fs.write(disk, "old")?
  image.write_disk(rootfs, disk)?
  image.verify_disk(disk, 4096)?
  assert fs.metadata(disk)?.size > 4096
  assert image.image_root_partuuid() == "33333333-3333-3333-3333-333333333333"
}

test test_kernel_manifest_path_is_relative_existing_and_nonempty [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "kernel-source")?
  fs.mkdir(fp"${root}/boot")?
  fs.write(fp"${root}/boot/vmlinuz", "kernel")?
  assert image.image_kernel_source(root, p"boot/vmlinuz")? == fp"${root}/boot/vmlinuz"

  for path_value in [p"boot/missing", /boot/vmlinuz, ../boot/vmlinuz] {
    match image.image_kernel_source(root, path_value) {
      Ok(_) => assert false
      Err(_) => {}
    }
  }
}

test test_gpt_partuuid_matches_the_qemu_kernel_command_line [error] {
  assert f"root=PARTUUID=${image.image_root_partuuid()}" in qemu.kernel_cmdline(types.Test)
}

test test_generation_size_counts_payload_and_incomplete_disk_preserves_final [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "generation-size")?
  fs.mkdir(fp"${root}/usr")?
  fs.write(fp"${root}/usr/payload", "payload")?
  assert image.image_generation_used_bytes(root)? == 7

  let rootfs = fp"${root}/invalid.ext4"
  let disk = fp"${root}/disk.img"
  fs.write(rootfs, "not-sector-aligned")?
  fs.write(disk, "previous-final")?
  match image.write_disk(rootfs, disk) {
    Ok(_) => assert false
    Err(_) => {}
  }

  assert fs.read_text(disk)? == "previous-final"
}

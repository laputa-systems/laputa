##! Unit coverage for deterministic rootfs sizing and GPT disk output.
use system.image
use system.qemu
use system.types

test test_rootfs_size_has_expected_margin_rounding_and_floor [error] {
  assert image.rootfs_size_bytes(0) == 256MiB
  assert image.rootfs_size_bytes(256MiB) == 384MiB
  assert image.rootfs_size_bytes(257MiB) == 386MiB
}

test test_protective_mbr_has_signature_and_protective_partition [error] {
  let mbr = image.protective_mbr(1024)?
  assert bytes.unpack_le(mbr, 1, offset: 450)? == 238
  assert bytes.unpack_le(mbr, 2, offset: 510)? == 43605
}

test test_gpt_disk_is_written_atomically_with_expected_root_partition [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "image")?
  let rootfs = fp"{root}/rootfs.ext4"
  let disk = fp"{root}/disk.img"
  rootfs.write(bytes.zero(4096)?)
  disk.write("old")
  image.write_disk(rootfs, disk)
  image.verify_disk(disk, 4096)
  assert disk.metadata()?.size > 4096
  assert image.image_root_partuuid() == "33333333-3333-3333-3333-333333333333"
}

test test_kernel_manifest_path_is_relative_existing_and_nonempty [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "kernel-source")?
  fp"{root}/boot".mkdir()
  fp"{root}/boot/vmlinuz".write("kernel")
  assert image.image_kernel_source(root, p"boot/vmlinuz")? == fp"{root}/boot/vmlinuz"

  for path_value in [p"boot/missing", /boot/vmlinuz, ../boot/vmlinuz] {
    match image.image_kernel_source(root, path_value) {
      Ok(_) => assert false
      Err(_) => {}
    }
  }
}

test test_gpt_partuuid_matches_the_qemu_kernel_command_line [error] {
  assert f"root=PARTUUID={image.image_root_partuuid()}" in qemu.kernel_cmdline(
    qemu.qemu_target("Linux", "x86_64")?,
    types.Test,
  )
}

test test_generation_size_counts_payload_and_incomplete_disk_preserves_final [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "generation-size")?
  fp"{root}/usr".mkdir()
  fp"{root}/usr/payload".write("payload")
  assert image.image_generation_used_bytes(root)? == 7

  let rootfs = fp"{root}/invalid.ext4"
  let disk = fp"{root}/disk.img"
  rootfs.write("not-sector-aligned")
  disk.write("previous-final")
  match image.write_disk(rootfs, disk) {
    Ok(_) => assert false
    Err(_) => {}
  }

  assert disk.read_text()? == "previous-final"
}

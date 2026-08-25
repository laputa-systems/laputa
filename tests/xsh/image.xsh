##! Unit coverage for deterministic rootfs sizing and GPT disk output.
use laputa.image as image

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

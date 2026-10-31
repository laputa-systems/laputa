##! Boundary regression for the deterministic ext4 formatter shipped by laputa-fs.
const block_size = 4096
const inode_size = 256
const inode_table_block = 4

proc runner() -> Result[Path] {
  let configured = e"XSH_HOST" ?? ""
  return fp"{configured}" when configured != ""

  process.which("xsh")?
}

proc inode_offset(inode: Int) -> Int {
  inode_table_block * block_size + (inode - 1) * inode_size
}

test test_ext4_uses_inline_storage_only_below_sixty_byte_symlink_boundary [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "laputa-fs-symlink-boundary")?
  let source = fp"{root}/source"
  let image = fp"{root}/rootfs.ext4"
  let fast_target = "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  let block_target = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  assert fast_target.byte_len() == 59
  assert block_target.byte_len() == 60
  source.mkdir()
  fp"{source}/fast".symlink(to: fp"{fast_target}")
  fp"{source}/block".symlink(to: fp"{block_target}")
  image.write(b"")
  image.truncate(8MiB)

  let xsh = runner()?
  let status = process.run(
    process.command_argv(
      xsh,
      [
        xsh,
        "packages/laputa-fs/files/mkfs.ext4.xsh",
        "--",
        "-d",
        source,
        image,
      ],
    ),
  )?
  assert status.ok

  let block_inode = inode_offset(11)
  let fast_inode = inode_offset(12)
  assert bytes.unpack_le(bytes.read_at(image, block_inode + 28, 4)?, 4)? == 8
  assert bytes.unpack_le(bytes.read_at(image, fast_inode + 28, 4)?, 4)? == 0
  assert bytes.read_at(image, fast_inode + 40, 59)? == bytes.from_text(fast_target)

  let block = bytes.unpack_le(bytes.read_at(image, block_inode + 40, 4)?, 4)?
  assert block > 0
  assert bytes.read_at(image, block * block_size, 60)? == bytes.from_text(block_target)
}

test test_ext4_rejects_a_final_group_too_small_for_metadata [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "laputa-fs-short-final-group")?
  let source = fp"{root}/source"
  let image = fp"{root}/rootfs.ext4"
  let stderr = fp"{root}/mkfs.stderr"
  source.mkdir()
  image.write(b"")
  image.truncate(129MiB)

  let xsh = runner()?
  let status = process.run(
    process.command_argv(
      xsh,
      [
        xsh,
        "packages/laputa-fs/files/mkfs.ext4.xsh",
        "--",
        "-d",
        source,
        image,
      ],
      stderr:,
    ),
  )?
  assert ! status.ok
  assert "last ext4 block group is too small for its metadata" in stderr.read_text()?
}

test test_ext4_applies_explicit_inode_owners_and_rejects_invalid_paths [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "laputa-fs-owners")?
  let source = fp"{root}/source"
  let image = fp"{root}/state.ext4"
  let owners = fp"{root}/owners.json"
  source.mkdir()?
  fp"{source}/a".write("private")?
  fp"{source}/a".chmod(0o600)?
  fp"{source}/b".write("root")?
  image.write(b"")?
  image.truncate(8MiB)?
  json.write(owners, [{path: "a", uid: 1001, gid: 1002}])?
  let xsh = runner()?
  let args = [xsh.display(), "packages/laputa-fs/files/mkfs.ext4.xsh", "--", "-d", source.display(), "--inode-owners", owners.display(), image.display()]
  assert process.run(process.command_argv(xsh, args))?.ok
  let a = inode_offset(11)
  let b = inode_offset(12)
  assert bytes.unpack_le(bytes.read_at(image, a, 2)?, 2)?.bit_and(0o777) == 0o600
  assert bytes.unpack_le(bytes.read_at(image, a + 2, 2)?, 2)? == 1001
  assert bytes.unpack_le(bytes.read_at(image, a + 24, 2)?, 2)? == 1002
  assert bytes.unpack_le(bytes.read_at(image, b + 2, 2)?, 2)? == 0
  assert bytes.unpack_le(bytes.read_at(image, b + 24, 2)?, 2)? == 0
  let before = hash.sha256(image)?.hex()
  for bad in [
    [{path: "a", uid: 1001, gid: 1002}, {path: "a", uid: 1001, gid: 1002}],
    [{path: "missing", uid: 1001, gid: 1002}],
    [{path: "../escape", uid: 1001, gid: 1002}],
    [{path: "/a", uid: 1001, gid: 1002}],
    [{path: "a", uid: 65536, gid: 1002}],
  ] {
    json.write(owners, bad)?
    assert !process.run(process.command_argv(xsh, args))?.ok
    assert hash.sha256(image)?.hex() == before
  }
  fp"{source}/link".symlink(to: p"a")?
  json.write(owners, [{path: "link", uid: 1001, gid: 1002}])?
  assert !process.run(process.command_argv(xsh, args))?.ok
  assert hash.sha256(image)?.hex() == before
}

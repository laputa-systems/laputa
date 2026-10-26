##! Local successor bundle validation for disposable self-hosting guests.
use pm.generation
use system.image

## Validate the local successor identity, selected kernel, actual root receipt, and disk payload before boot.
export proc self_hosting_verify_bundle(bundle: Path, expected_generation: Str, selected_kernel: Path, tools_image: Str) [fs, process, env, error] -> Result[Unit, Error] {
  let receipt = generation.read_generation_receipt_file(fp"{bundle}/generation.json")?
  fail "successor generation differs from the expected generation" unless receipt.generation_sha256 == expected_generation
  let handle = fs.tempdir()?
  let extracted = handle.host_path()?
  let docker = process.which("docker")?
  let extraction = process.run(process.command_argv(docker, [
    docker.display(), "run", "--rm", "--network", "none", "--memory", "128m",
    "--mount", f"type=bind,src={bundle}/rootfs.ext4,dst=/rootfs.ext4,readonly",
    "--mount", f"type=bind,src={extracted},dst=/extract",
    tools_image, "/usr/sbin/debugfs", "-R", "dump /var/lib/laputa/generation.json /extract/embedded.json", "/rootfs.ext4",
  ], timeout: 10s))?
  fail "cannot read successor root receipt" unless extraction.ok
  fail "successor root receipt differs from its bundle" unless generation.read_generation_receipt_file(fp"{extracted}/embedded.json")? == receipt
  fail "successor kernel differs from the selected PM kernel" unless hash.sha256(fp"{bundle}/vmlinuz")? == hash.sha256(selected_kernel)?
  let rootfs = fp"{bundle}/rootfs.ext4"
  let disk = fp"{bundle}/disk.img"
  let size = rootfs.metadata()?.size
  image.verify_disk(disk, size)?
  let sector_bytes = 512
  let partition = bytes.read_at(disk, 2 * sector_bytes, 128)?
  let start = bytes.unpack_le(partition, 8, offset: 32)? * sector_bytes
  var offset = 0
  while offset < size {
    let count = if size - offset < 1024 * 1024 { size - offset } else { 1024 * 1024 }
    fail "successor disk root payload differs from its root filesystem" unless bytes.read_at(disk, start + offset, count)? == bytes.read_at(rootfs, offset, count)?
    offset += count
  }
}

proc main(bundle: Path, expected_generation: Str, selected_kernel: Path, tools_image: Str) [fs, process, env, error] -> Result[Unit, Error] {
  self_hosting_verify_bundle(bundle, expected_generation, selected_kernel, tools_image)?
}

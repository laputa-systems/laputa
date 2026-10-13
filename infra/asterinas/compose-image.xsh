##! Run PM generation and ext2 image construction in Laputa's offline package-tools image.
use seed.images
use seed.world
use seed.xsh_seed


proc main(arch: Str, profile_overlay_path: Str) [fs, env, process, error] {
  let laputa_root = fs.cwd()?
  let value = xsh_seed.xsh_seed_arch(arch)?
  let docker = images.docker_program()?
  let seed = xsh_seed.xsh_seed_require(laputa_root, arch)?
  let tag = images.ensure_package_tools(docker, laputa_root, value)?
  let output = fp"{laputa_root}/.out/asterinas-firecracker"
  let store = world.world_store(laputa_root, arch)
  let _ = output.mkdir()?
  fp"{output}/package-tools-image".write(f"{tag}\n")
  let _ = store.mkdir()?
  let _ = world.world_kbuild_cache(laputa_root).mkdir()?
  let id = unix.id()?
  let owner: world.WorldOwner = world.WorldOwner(uid: id.uid, gid: id.gid)
  let inner = ["/bin/xsh", "/src/laputa/infra/asterinas/build-image.xsh", "--", arch, tag, profile_overlay_path]
  let argv = world.world_container_argv(
    docker,
    laputa_root,
    seed,
    value,
    tag,
    output,
    store,
    owner,
    inner,
  )
  let status = process.run(process.command_argv(docker, argv, laputa_root))?

  if ! status.ok {
    fail "Asterinas PM generation and ext2 image build failed"
  }
}

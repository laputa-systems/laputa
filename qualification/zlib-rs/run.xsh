##! Host entry for the zlib-rs census gate: build the packages, compose a root, and run check.xsh in the package-tools container.
use seed.images
use seed.world
use seed.xsh_seed

const gate_packages = ["zlib", "zlib-rs", "llvm-toolchain"]

proc main(...argv: List[Str]) [fs, net, process, env, time, error] {
  guard argv.len() == 1 else {
    return Err(xsh_seed.SeedError.Usage("usage: xsh qualification/zlib-rs/run.xsh -- ARCH"))
  }

  let arch = argv[0]
  let laputa_root = fs.cwd()?
  let value = xsh_seed.xsh_seed_arch(arch)?
  var build_args = ["build", "--arch", arch]

  for name in gate_packages {
    build_args = build_args.extend(["--package", name])
  }

  world.world_command(laputa_root, world.parse_world_args(build_args)?)

  let gate_dir = fp"{laputa_root}/.out/zlib-rs-gate/{arch}"
  let plan = fp"{gate_dir}/plan.json"
  let gate_root = fp"{gate_dir}/root"
  gate_root.remove()
  gate_dir.mkdir()
  let store = world.world_store(laputa_root, arch)
  world.host_pm_plan("", laputa_root, gate_packages, f"{arch}-linux-musl", plan)
  world.host_pm_compose("", plan, store, gate_packages, gate_root)

  let docker = images.docker_program()?
  let seed = xsh_seed.xsh_seed_require(laputa_root, arch)?
  let tag = images.ensure_package_tools(docker, laputa_root, value)?
  let id = unix.id()?
  world.world_kbuild_cache(laputa_root).mkdir()
  let command = world.world_container_argv(
    docker,
    laputa_root,
    seed,
    value,
    tag,
    gate_root,
    store,
    {uid: id.uid, gid: id.gid},
    ["/bin/xsh", "/src/laputa/qualification/zlib-rs/check.xsh", "--", "/output"],
  )
  let status = process.run(process.command_argv(docker, command, laputa_root))?

  guard status.ok else {
    return Err(xsh_seed.SeedError.Failed(f"zlib-rs qualification failed in {tag}"))
  }
}

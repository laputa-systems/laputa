##! Seed entrypoint behind `make fetch`, `make seed`, and `make seed-smoke`.
#!/bin/xsh
use seed.images
use seed.xsh_seed

pure seed_usage() -> Str {
  """usage: seed.xsh <fetch|build|smoke> --arch ARCH --xsh-root PATH [--jobs N] [SUITE...]

  fetch   networked: the xsh-test image, XSH's crates, and the saved host-tools base
  build   offline: the XSH seed under .out/seed/ARCH and the package-tools image
  smoke   offline: run the package-tools image with the seed and prove it works;
          SUITE replaces the default PM test subset
"""
}

type SeedArgs = {command: Str, arch: Str, xsh_root: Str, jobs: Int, suites: List[Str]}

proc parse_seed_args(argv: List[Str]) [error] -> Result[SeedArgs] {
  if argv.len() == 0 or argv[0] not in ["fetch", "build", "smoke"] {
    return Err(xsh_seed.SeedError.Usage(seed_usage()))
  }

  var parsed: SeedArgs = SeedArgs(command: argv[0], arch: "", xsh_root: "", jobs: 4, suites: [])
  var index = 1

  while index < argv.len() {
    guard argv[index].starts_with("--") else {
      parsed = {...parsed, suites: parsed.suites.push(argv[index])}
      index += 1
      continue
    }

    if index + 1 >= argv.len() {
      return Err(xsh_seed.SeedError.Usage(f"{argv[index]} needs a value\n\n{seed_usage()}"))
    }

    let value = argv[index + 1]
    match argv[index] {
      "--arch" => parsed = {...parsed, arch: value}
      "--xsh-root" => parsed = {...parsed, xsh_root: value}
      "--jobs" => parsed = {...parsed, jobs: value.parse_int()?}
      _ => return Err(xsh_seed.SeedError.Usage(f"unknown option {argv[index]}\n\n{seed_usage()}"))
    }

    index += 2
  }

  if parsed.arch == "" or parsed.xsh_root == "" or (parsed.command != "smoke" and parsed.suites.len() > 0) {
    return Err(xsh_seed.SeedError.Usage(seed_usage()))
  }

  parsed
}

## Construct the offline smoke run: package-tools with the seed and the checkout mounted read-only.
pure seed_smoke_argv(
  docker: Path,
  laputa_root: Path,
  seed: Path,
  value: xsh_seed.SeedArch,
  tag: Str,
  suites: List[Str],
) -> List[Str] {
  [
    docker.display(),
    "run",
    "--rm",
    "--platform",
    value.docker_platform,
    "--network",
    "none",
    "--mount",
    f"type=bind,src={laputa_root},dst=/src/laputa,readonly",
    @xsh_seed.xsh_seed_mount_argv(seed),
    "--workdir",
    "/src/laputa",
    "--env",
    "XSH_PM_OFFLINE=1",
    tag,
    "/bin/xsh",
    "/src/laputa/seed/smoke.xsh",
    "--",
    value.arch,
    @suites,
  ]
}

proc main(...argv: List[Str]) [fs, process, env, error] {
  let args = parse_seed_args(argv)?
  let laputa_root = fs.cwd()?

  if ! fs.exists(fp"{laputa_root}/pm.xsh")? or ! fs.exists(fp"{laputa_root}/packages")? {
    return Err(xsh_seed.SeedError.Usage(f"run seed.xsh from the Laputa checkout root, not {laputa_root}"))
  }

  let value = xsh_seed.xsh_seed_arch(args.arch)?
  let xsh_root = path.absolute(fp"{args.xsh_root}")?
  let docker = images.docker_program()?

  match args.command {
    "fetch" => {
      xsh_seed.xsh_seed_fetch(docker, laputa_root, xsh_root, value)?
      images.fetch_host_tools(docker, laputa_root, value)?
    }
    "build" => {
      xsh_seed.xsh_seed_build(docker, laputa_root, xsh_root, value, args.jobs)?
      let tag = images.ensure_package_tools(docker, laputa_root, value)?
      print f"seed {xsh_seed.xsh_seed_dir(laputa_root, value.arch)}"
      print f"image {tag}"
    }
    _ => {
      let seed = xsh_seed.xsh_seed_require(laputa_root, value.arch)?
      let tag = images.ensure_package_tools(docker, laputa_root, value)?
      let status = process.run(
        process.command_argv(docker, seed_smoke_argv(docker, laputa_root, seed, value, tag, args.suites), laputa_root),
      )?

      if ! status.ok {
        return Err(xsh_seed.SeedError.Failed(f"seed smoke test failed in {tag}"))
      }
    }
  }
}

main(@args)?

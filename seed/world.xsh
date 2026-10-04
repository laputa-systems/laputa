##! Package builds on the local seed behind `make plan`, `make build`, `make publish`, and `make root`.
# Containers never get a network. Planning and building run in package-tools
# with `--network none`, the seed mounted at /bin and /usr/lib/xsh/core, the
# checkout (and with it the source cache) read-only at /src/laputa, and the
# artifact store `.out/artifacts/ARCH` at /artifacts. The store is the build
# cache: plans are offline, so every node says `build`, and the executor skips
# each one whose artifact the store already holds.
#
# Only host processes talk to the loopback mirror. `publish` builds, then
# uploads that plan's verified store artifacts from the host; `root` imports
# a root's closure from the mirror into a fresh store on the host, then
# composes and inspects it in an offline container. Sources need no mirror inside a build: the read-only
# cache already holds every pinned upstream.
use pm.cli as pm_cli
use pm.plan_json as pm_plan_json
use pm.types as pm_types
use seed.images as images
use seed.xsh_seed as xsh_seed

pure world_usage() -> Str {
  """usage: world_cli.xsh COMMAND --arch ARCH [OPTIONS]

  plan    [--package NAME... | --stop LINE]   offline plan in package-tools
  build   [--package NAME... | --stop LINE] [--jobs N]
                                              plan, then build into the artifact store
  publish --repo URL [--package NAME... | --stop LINE] [--jobs N]
                                              build, then publish that plan's artifacts from the host
  root    --repo URL --package NAME... [--jobs N]
                                              import NAMEs from the mirror, compose and inspect a root offline

With neither --package nor --stop, plan and build select every package.
stop lines: pre-cmake (every package whose build closure needs neither cmake nor linux)
"""
}

## One parsed `world_cli.xsh` command.
export type WorldArgs = {command: Str, arch: Str, packages: List[Str], stop: Str, jobs: Int, repo: Str}

## Parse `world_cli.xsh` argv; selection, repository, and root rules fail here, before any Docker run.
export proc parse_world_args(argv: List[Str]) [error] -> Result[WorldArgs] {
  if argv.len() == 0 or argv[0] not in ["plan", "build", "publish", "root"] {
    return Err(xsh_seed.SeedError.Usage(world_usage()))
  }

  var parsed: WorldArgs = {command: argv[0], arch: "", packages: [], stop: "", jobs: 4, repo: ""}
  var index = 1

  while index < argv.len() {
    if index + 1 >= argv.len() {
      return Err(xsh_seed.SeedError.Usage(f"{argv[index]} needs a value\n\n{world_usage()}"))
    }

    let value = argv[index + 1]
    match argv[index] {
      "--arch" => parsed = {...parsed, arch: value}
      "--package" => parsed = {...parsed, packages: parsed.packages.push(value)}
      "--stop" => parsed = {...parsed, stop: value}
      "--jobs" => parsed = {...parsed, jobs: value.parse_int()?}
      "--repo" => parsed = {...parsed, repo: value}
      _ => return Err(xsh_seed.SeedError.Usage(f"unknown option {argv[index]}\n\n{world_usage()}"))
    }
    index += 2
  }

  if parsed.arch == "" or parsed.jobs < 1 {
    return Err(xsh_seed.SeedError.Usage(world_usage()))
  }

  if parsed.packages.len() > 0 and parsed.stop != "" {
    return Err(xsh_seed.SeedError.Usage("select packages with either --package (PKGS) or --stop (STOP), not both"))
  }

  if parsed.command in ["publish", "root"] and parsed.repo == "" {
    return Err(xsh_seed.SeedError.Usage(f"{parsed.command} needs --repo URL, the local mirror\n\n{world_usage()}"))
  }

  if parsed.command == "root" and (parsed.packages.len() == 0 or parsed.stop != "") {
    return Err(xsh_seed.SeedError.Usage(f"root needs one or more --package runtime roots\n\n{world_usage()}"))
  }

  parsed
}

## The packages a named stop line excludes, with every package whose build closure needs one.
export pure world_stop_line(name: Str) -> Result[List[Str]] {
  match name {
    "pre-cmake" => ["cmake", "linux"]
    _ => Err(xsh_seed.SeedError.Usage(f"unknown stop line {name}; the stop lines are: pre-cmake"))
  }
}

## The `pm repo plan` selection for explicit packages, a stop line, or (neither) every package.
export pure world_selection_argv(packages: List[Str], stop: Str) -> Result[List[Str]] {
  if packages.len() > 0 {
    var argv: List[Str] = []

    for name in packages {
      argv = argv.extend(["--root", name])
    }

    return argv
  }

  if stop == "" {
    return ["--all"]
  }

  var argv = ["--all"]

  for name in world_stop_line(stop)? {
    argv = argv.extend(["--without", name])
  }

  argv
}

## Derived state for one architecture's world: the last plan, and the `make root` tree.
export pure world_dir(laputa_root: Path, arch: Str) -> Path {
  fp"{laputa_root}/.out/world/{arch}"
}

## The PM artifact store for one architecture, shared with the profile builds.
export pure world_store(laputa_root: Path, arch: Str) -> Path {
  fp"{laputa_root}/.out/artifacts/{arch}"
}

## Construct one offline package-tools run: `output` at /output, `store` at /artifacts.
export pure world_container_argv(
  docker: Path,
  laputa_root: Path,
  seed: Path,
  value: xsh_seed.SeedArch,
  tag: Str,
  output: Path,
  store: Path,
  inner: List[Str],
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
  ].extend(xsh_seed.xsh_seed_mount_argv(seed)).extend([
    "--mount",
    f"type=bind,src={output},dst=/output",
    "--mount",
    f"type=bind,src={store},dst=/artifacts",
    "--workdir",
    "/src/laputa",
    tag,
  ]).extend(inner)
}

type WorldContainer = {docker: Path, laputa_root: Path, seed: Path, value: xsh_seed.SeedArch, tag: Str}

proc world_container(laputa_root: Path, value: xsh_seed.SeedArch) [fs, process, env, error] -> Result[WorldContainer] {
  let docker = images.docker_program()?
  let seed = xsh_seed.xsh_seed_require(laputa_root, value.arch)?
  let tag = images.ensure_package_tools(docker, laputa_root, value)?
  {docker, laputa_root, seed, value, tag}
}

proc world_run(container: WorldContainer, output: Path, store: Path, inner: List[Str], label: Str) [fs, process, error] {
  fs.mkdir(output)?
  fs.mkdir(store)?
  let argv = world_container_argv(container.docker, container.laputa_root, container.seed, container.value, container.tag, output, store, inner)
  let status = process.run(process.command_argv(container.docker, argv, container.laputa_root))?

  if ! status.ok {
    return Err(xsh_seed.SeedError.Failed(f"{label} failed in {container.tag}"))
  }
}

# PM names targets `ARCH-linux-musl`; the seed's `triple` is Rust's.
pure pm_target(value: xsh_seed.SeedArch) -> Str {
  f"{value.arch}-linux-musl"
}

pure pm_argv(args: List[Str]) -> List[Str] {
  ["/bin/xsh", "/src/laputa/pm.xsh", "--"].extend(args)
}

proc world_plan(container: WorldContainer, args: WorldArgs) [fs, process, error] {
  let laputa_root = container.laputa_root
  let selection = world_selection_argv(args.packages, args.stop)?
  world_run(
    container,
    world_dir(laputa_root, args.arch),
    world_store(laputa_root, args.arch),
    pm_argv(["repo", "plan", "--repo", "/src/laputa"].extend(selection).extend(["--target", pm_target(container.value), "--output", "/output/plan.json"])),
    "repo plan",
  )?
}

proc world_build(container: WorldContainer, args: WorldArgs) [fs, process, error] {
  world_plan(container, args)?
  world_run(
    container,
    world_dir(container.laputa_root, args.arch),
    world_store(container.laputa_root, args.arch),
    pm_argv(["repo", "build", "/output/plan.json", "--store", "/artifacts", "--jobs", f"{args.jobs}"]),
    "repo build",
  )?
}

# Runs PM in this host process against the loopback mirror.
proc host_pm(repo: Str, args: List[Str]) [fs, net, process, env, time, error] {
  env ({XSH_PM_REPO: repo}) {
    pm_cli.run_pm_cli(args)?
  } ?
}

# Publishing the last plan could upload a stale selection (a reverted rel
# bump, say) under tuples the checkout no longer declares, so publish first
# builds the current checkout's plan; an unchanged build is a no-op.
proc world_publish(container: WorldContainer, args: WorldArgs) [fs, net, process, env, time, error] {
  world_build(container, args)?
  let plan = fp"{world_dir(container.laputa_root, args.arch)}/plan.json"
  host_pm(args.repo, ["repo", "publish", plan.display(), "--store", world_store(container.laputa_root, args.arch).display()])?
}

## The `make root` tree: the mirror plan, the store imported from the mirror, and the composed receipt.
export pure world_root_dir(laputa_root: Path, arch: Str) -> Path {
  fp"{world_dir(laputa_root, arch)}/root"
}

# The root's whole closure must come from the mirror: a node the mirror lacks
# would build on the host, which is not a build environment.
proc require_mirror_plan(plan: Path, repo: Str) [fs, error] {
  let value = pm_plan_json.read(plan)?
  let missing = [node.name for node in value.nodes if pm_types.plan_action_is_build(node.action)]

  if missing.len() > 0 {
    return Err(xsh_seed.SeedError.Missing(f"{repo} lacks exact artifacts for {missing.join(", ")}; run `make publish` with a selection that includes them first"))
  }
}

proc world_root(container: WorldContainer, args: WorldArgs) [fs, net, process, env, time, error] {
  let laputa_root = container.laputa_root
  let root_dir = world_root_dir(laputa_root, args.arch)

  if fs.exists(root_dir)? {
    return Err(xsh_seed.SeedError.Failed(f"{root_dir} already exists; `make root` removes it first"))
  }

  let plan = fp"{root_dir}/plan.json"
  let store = fp"{root_dir}/store"
  fs.mkdir(store)?
  var selection: List[Str] = []

  for name in args.packages {
    selection = selection.extend(["--root", name])
  }

  host_pm(args.repo, ["repo", "plan", "--repo", laputa_root.display()].extend(selection).extend(["--target", pm_target(container.value), "--output", plan.display()]))?
  require_mirror_plan(plan, args.repo)?
  host_pm(args.repo, ["repo", "build", plan.display(), "--store", store.display(), "--jobs", f"{args.jobs}"])?
  world_run(
    container,
    root_dir,
    store,
    ["/bin/xsh", "/src/laputa/seed/world_root.xsh", "--", args.arch, "/output/plan.json", "/artifacts", "/output"].extend(args.packages),
    "root compose",
  )?
}

## Run one parsed command from the Laputa checkout root.
export proc world_command(laputa_root: Path, args: WorldArgs) [fs, net, process, env, time, error] {
  if ! fs.exists(fp"{laputa_root}/pm.xsh")? or ! fs.exists(fp"{laputa_root}/packages")? {
    return Err(xsh_seed.SeedError.Usage(f"run world_cli.xsh from the Laputa checkout root, not {laputa_root}"))
  }

  let value = xsh_seed.xsh_seed_arch(args.arch)?

  match args.command {
    "plan" => world_plan(world_container(laputa_root, value)?, args)?
    "build" => world_build(world_container(laputa_root, value)?, args)?
    "publish" => world_publish(world_container(laputa_root, value)?, args)?
    _ => world_root(world_container(laputa_root, value)?, args)?
  }
}

##! Package builds on the local seed behind `make plan`, `make build`, `make publish`, and `make root`.
use pm.cli as pm_cli
use pm.plan_json as pm_plan_json
use pm.types as pm_types
use seed.images
use seed.xsh_seed

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
export proc parse_world_args(argv: List[Str]) [error] -> Result[WorldArgs, Error] {
  if argv.is_empty() or argv[0] not in ["plan", "build", "publish", "root"] {
    return Err(xsh_seed.SeedError.Usage(world_usage()))
  }

  var parsed: WorldArgs = WorldArgs(command: argv[0], arch: "", packages: [], stop: "", jobs: 4, repo: "")
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
      "--jobs" => parsed = {...parsed, jobs: value as Int}
      "--repo" => parsed = {...parsed, repo: value}
      else => return Err(xsh_seed.SeedError.Usage(f"unknown option {argv[index]}\n\n{world_usage()}"))
    }

    index += 2
  }

  if parsed.arch == "" or parsed.jobs < 1 {
    return Err(xsh_seed.SeedError.Usage(world_usage()))
  }

  if ! parsed.packages.is_empty() and parsed.stop != "" {
    return Err(xsh_seed.SeedError.Usage("select packages with either --package (PKGS) or --stop (STOP), not both"))
  }

  if parsed.command in ["publish", "root"] and parsed.repo == "" {
    return Err(xsh_seed.SeedError.Usage(f"{parsed.command} needs --repo URL, the local mirror\n\n{world_usage()}"))
  }

  if parsed.command == "root" and (parsed.packages.is_empty() or parsed.stop != "") {
    return Err(xsh_seed.SeedError.Usage(f"root needs one or more --package runtime roots\n\n{world_usage()}"))
  }

  parsed
}

## The packages a named stop line excludes, with every package whose build closure needs one.
export pure world_stop_line(name: Str) -> Result[List[Str], Error] {
  match name {
    "pre-cmake" => ["cmake", "linux"]
    else => Err(xsh_seed.SeedError.Usage(f"unknown stop line {name}; the stop lines are: pre-cmake"))
  }
}

## The `pm repo plan` selection for explicit packages, a stop line, or (neither) every package.
export pure world_selection_argv(packages: List[Str], stop: Str) -> Result[List[Str], Error] {
  guard packages.is_empty() else {
    let argv: List[Str] = collect {
      for name in packages {
        yield @["--root", name]
      }
    }

    return argv
  }

  return ["--all"] when stop == ""

  var argv = ["--all"]

  for name in world_stop_line(stop)? {
    argv += ["--without", name]
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

## The linux recipe's Kbuild plan cache, kept across builds under `.out/`.
export pure world_kbuild_cache(laputa_root: Path) -> Path {
  fp"{laputa_root}/.out/cache/linux-kbuild"
}

## The container mount of `world_kbuild_cache` at the path the linux recipe uses.
export pure world_kbuild_cache_mount_argv(laputa_root: Path) -> List[Str] {
  ["--mount", f"type=bind,src={world_kbuild_cache(laputa_root)},dst=/var/cache/laputa/linux-kbuild"]
}

## The host user a container hands its writable mounts back to.
export type WorldOwner = {uid: Int, gid: Int}

## The container entry that runs `inner`, then gives `/output`, `/artifacts`, and the Kbuild cache to `owner`.
export pure world_owned_argv(owner: WorldOwner, inner: List[Str]) -> List[Str] {
  [
    "/bin/xsh",
    "/src/laputa/seed/container_entry.xsh",
    "--",
    f"{owner.uid}",
    f"{owner.gid}",
    "/output",
    "/artifacts",
    "/var/cache/laputa/linux-kbuild",
    "--",
    @inner,
  ]
}

## Construct one offline package-tools run: `output` at /output, `store` at /artifacts, owned by `owner` afterwards.
export pure world_container_argv(
  docker: Path,
  laputa_root: Path,
  seed: Path,
  value: xsh_seed.SeedArch,
  tag: Str,
  output: Path,
  store: Path,
  owner: WorldOwner,
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
    @xsh_seed.xsh_seed_mount_argv(seed),
    "--mount",
    f"type=bind,src={output},dst=/output",
    "--mount",
    f"type=bind,src={store},dst=/artifacts",
    @world_kbuild_cache_mount_argv(laputa_root),
    "--workdir",
    "/src/laputa",
    tag,
    @world_owned_argv(owner, inner),
  ]
}

type WorldContainer = {
  docker: Path,
  laputa_root: Path,
  seed: Path,
  value: xsh_seed.SeedArch,
  tag: Str,
  owner: WorldOwner,
}

proc world_container(laputa_root: Path, value: xsh_seed.SeedArch) -> Result[WorldContainer] {
  let docker = images.docker_program()?
  let seed = xsh_seed.xsh_seed_require(laputa_root, value.arch)?
  let tag = images.ensure_package_tools(docker, laputa_root, value)?
  let id = unix.id()?
  {docker, laputa_root, seed, value, tag, owner: {uid: id.uid, gid: id.gid}}
}

proc world_run(container: WorldContainer, output: Path, store: Path, inner: List[Str], label: Str) {
  output.mkdir()
  store.mkdir()
  world_kbuild_cache(container.laputa_root).mkdir()
  let argv = world_container_argv(
    container.docker,
    container.laputa_root,
    container.seed,
    container.value,
    container.tag,
    output,
    store,
    container.owner,
    inner,
  )
  let status = process.run(process.command_argv(container.docker, argv, container.laputa_root))?

  if ! status.ok {
    return Err(xsh_seed.SeedError.Failed(f"{label} failed in {container.tag}"))
  }
}

pure pm_target(value: xsh_seed.SeedArch) -> Str {
  f"{value.arch}-linux-musl"
}

pure pm_argv(args: List[Str]) -> List[Str] {
  ["/bin/xsh", "/src/laputa/pm.xsh", "--"].extend(args)
}

proc world_plan(container: WorldContainer, args: WorldArgs) {
  let laputa_root = container.laputa_root
  let selection = world_selection_argv(args.packages, args.stop)?
  world_run(
    container,
    world_dir(laputa_root, args.arch),
    world_store(laputa_root, args.arch),
    pm_argv(
      [
        "repo",
        "plan",
        "--repo",
        "/src/laputa",
        @selection,
        "--target",
        pm_target(container.value),
        "--output",
        "/output/plan.json",
      ],
    ),
    "repo plan",
  )
}

proc world_build(container: WorldContainer, args: WorldArgs) {
  world_plan(container, args)
  world_run(
    container,
    world_dir(container.laputa_root, args.arch),
    world_store(container.laputa_root, args.arch),
    pm_argv(
      ["repo", "build", "/output/plan.json", "--store", "/artifacts", "--jobs", f"{args.jobs}", "--logs", "/output/logs"],
    ),
    "repo build",
  )
}

## Plan explicit package roots in this host process against the mirror.
export proc host_pm_plan(repo_url: Str, repo_root: Path, roots: List[Str], target: Str, output: Path) [fs, net, process, env, time, error] {
  env ({XSH_PM_REPO: repo_url}) {
    pm_cli.pm_cli_repo_plan({repo: repo_root.display(), all: false, roots, without: [], target, output})
  }
}

## Import or build a saved plan in this host process against the mirror.
export proc host_pm_build(repo_url: Str, input: Path, store: Path, jobs: Int) [fs, net, process, env, time, error] {
  env ({XSH_PM_REPO: repo_url}) {
    pm_cli.pm_cli_repo_build({input, store, jobs, logs: p""})
  }
}

## Publish a saved plan's verified artifacts in this host process.
export proc host_pm_publish(repo_url: Str, input: Path, store: Path) [fs, net, process, env, time, error] {
  env ({XSH_PM_REPO: repo_url}) {
    pm_cli.pm_cli_repo_publish({input, store})
  }
}

## Compose a generation from a saved plan and store in this host process.
export proc host_pm_compose(repo_url: Str, input: Path, store: Path, runtime_roots: List[Str], output: Path) [fs, net, process, env, time, error] {
  env ({XSH_PM_REPO: repo_url}) {
    pm_cli.pm_cli_root_compose({input, store, runtime_roots, output})
  }
}

proc world_publish(container: WorldContainer, args: WorldArgs) {
  world_build(container, args)
  let plan = fp"{world_dir(container.laputa_root, args.arch)}/plan.json"
  host_pm_publish(args.repo, input: plan, store: world_store(container.laputa_root, args.arch))
}

## The `make root` tree: the mirror plan, the store imported from the mirror, and the composed receipt.
export pure world_root_dir(laputa_root: Path, arch: Str) -> Path {
  fp"{world_dir(laputa_root, arch)}/root"
}

## Require every node of a host plan to be an exact mirror artifact.
export proc require_mirror_plan(plan: Path, repo: Str) [fs, error] {
  let value = pm_plan_json.read(plan)?
  let missing = [node.name for node in value.nodes if pm_types.plan_action_is_build(node.action)]

  if ! missing.is_empty() {
    return Err(
      xsh_seed.SeedError.Missing(
        f"{repo} lacks exact artifacts for {missing.join(", ")}; run `make publish` with a selection that includes them first",
      ),
    )
  }
}

proc world_root(container: WorldContainer, args: WorldArgs) {
  let laputa_root = container.laputa_root
  let root_dir = world_root_dir(laputa_root, args.arch)

  if root_dir.exists() {
    return Err(xsh_seed.SeedError.Failed(f"{root_dir} already exists; `make root` removes it first"))
  }

  let plan = fp"{root_dir}/plan.json"
  let store = fp"{root_dir}/store"
  store.mkdir()
  host_pm_plan(
    args.repo,
    repo_root: laputa_root,
    roots: args.packages,
    target: pm_target(container.value),
    output: plan,
  )
  require_mirror_plan(plan, args.repo)
  host_pm_build(args.repo, input: plan, store:, jobs: args.jobs)
  world_run(
    container,
    root_dir,
    store,
    ["/bin/xsh", "/src/laputa/seed/world_root.xsh", "--", args.arch, "/output/plan.json", "/artifacts", "/output"].extend(
      args.packages,
    ),
    "root compose",
  )
}

## Run one parsed command from the Laputa checkout root.
export proc world_command(laputa_root: Path, args: WorldArgs) [fs, net, process, env, time, error] {
  if ! fp"{laputa_root}/pm.xsh".exists() or ! fp"{laputa_root}/packages".exists() {
    return Err(xsh_seed.SeedError.Usage(f"run world_cli.xsh from the Laputa checkout root, not {laputa_root}"))
  }

  let value = xsh_seed.xsh_seed_arch(args.arch)?

  match args.command {
    "plan" => world_plan(world_container(laputa_root, value)?, args)
    "build" => world_build(world_container(laputa_root, value)?, args)
    "publish" => world_publish(world_container(laputa_root, value)?, args)
    else => world_root(world_container(laputa_root, value)?, args)
  }
}

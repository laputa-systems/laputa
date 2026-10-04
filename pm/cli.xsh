##! Explicit typed command boundary for immutable package planning, execution, publication, and generation composition.
use catalog
use execute as pm_execute
use generation
use generation_adapter as pm_generation_adapter
use graph
use local
use plan as pm_plan
use plan_json as pm_plan_json
use policy
use recipe
use remote
use repo
use sources
use store
use types
use util

type RepoCheckArgs = {repo: Path}

type RepoPlanArgs = {repo: Path, all: Bool, roots: List[Str], without: List[Str], target: Str, output: Path}

type RepoShowArgs = {input: Path}

type RepoBuildArgs = {input: Path, store: Path, jobs: Int, logs: Path}

type RepoBuildNodeArgs = {input: Path, repo: Path, store: Path, node: Str}

type RepoPublishArgs = {input: Path, store: Path}

type RepoPackagesArgs = {repo: Path, packages: List[Str]}

type RootComposeArgs = {input: Path, store: Path, runtime_roots: List[Str], output: Path}

type RootInspectArgs = {input: Path}

type StoreVerifyArgs = {store: Path}

type StoreExtractArgs = {input: Path, store: Path, package: Str, path: Path, output: Path}

type SourcesFetchArgs = {repo: Path, all: Bool, packages: List[Str], targets: List[types.Target]}

enum PmCommand {
    Help(Str),
    RepoCheck(RepoCheckArgs),
    RepoPlan(RepoPlanArgs),
    RepoShow(RepoShowArgs),
    RepoBuild(RepoBuildArgs),
    RepoBuildNode(RepoBuildNodeArgs),
    RepoPublish(RepoPublishArgs),
    RepoChecksum(RepoPackagesArgs),
    RepoUpdateChecksums(RepoPackagesArgs),
    SourcesFetch(SourcesFetchArgs),
    RootCompose(RootComposeArgs),
    RootInspect(RootInspectArgs),
    StoreVerify(StoreVerifyArgs),
    StoreExtract(StoreExtractArgs),
}

type RepoCheckOptions = {repo: Str}

type RepoPlanOptions = {repo: Str, all: Bool, roots: List[Str], without: List[Str], target: Str, output: Path}

type RepoShowOptions = {input: Path}

type RepoBuildOptions = {input: Path, store: Path, jobs: Int, logs: Str}

type RepoBuildNodeOptions = {input: Path, repo: Str, store: Path, node: Str}

type RepoPublishOptions = {input: Path, store: Path}

type RepoPackagesOptions = {repo: Str, packages: List[Str]}

type RootComposeOptions = {input: Path, store: Path, runtime_roots: List[Str], output: Path}

type RootInspectOptions = {input: Path}

type StoreVerifyOptions = {store: Path}

type StoreExtractOptions = {input: Path, store: Path, package: Str, path: Path, output: Path}

type SourcesFetchOptions = {repo: Str, all: Bool, packages: List[Str], targets: List[Str]}

pure help_text() -> Str {
  """usage: pm COMMAND [OPTIONS]

repository commands:
  repo check [--repo PATH]
  repo plan [--repo PATH] (--all [--without PACKAGE...] | --root PACKAGE...) [--target TARGET] --output PLAN
  repo show PLAN
  repo build PLAN --store STORE [-j N|--jobs N] [--logs DIR]
  repo build-node PLAN --repo PATH --store STORE --node ARTIFACT_KEY
  repo publish PLAN --store STORE
  repo checksum [--repo PATH] PACKAGE...
  repo update-checksums [--repo PATH] PACKAGE...

source commands:
  sources fetch [--repo PATH] (--all | PACKAGE...) [--target TARGET]...

root commands:
  root compose PLAN --store STORE --runtime-root PACKAGE... --output GENERATION
  root inspect GENERATION_OR_RECEIPT

store commands:
  store verify --store STORE
  store extract PLAN --store STORE --package PACKAGE --path PATH --output FILE

targets: aarch64-linux-musl, x86_64-linux-musl (default: the host's)
"""
}

pure repo_help_text() -> Str {
  """usage: pm repo COMMAND [OPTIONS]

  check [--repo PATH]
  plan [--repo PATH] (--all [--without PACKAGE...] | --root PACKAGE...) [--target TARGET] --output PLAN
  show PLAN
  build PLAN --store STORE [-j N|--jobs N] [--logs DIR]
  build-node PLAN --repo PATH --store STORE --node ARTIFACT_KEY
  publish PLAN --store STORE
  checksum [--repo PATH] PACKAGE...
  update-checksums [--repo PATH] PACKAGE...

targets: aarch64-linux-musl, x86_64-linux-musl (default: the host's)
"""
}

pure repo_plan_help_text() -> Str {
  """usage: pm repo plan [--repo PATH] (--all [--without PACKAGE...] | --root PACKAGE...) [--target TARGET] --output PLAN

--without PACKAGE drops from --all every package whose build closure needs
PACKAGE (and PACKAGE itself): `--all --without cmake --without linux` plans
everything that builds before cmake and linux exist.

targets: aarch64-linux-musl, x86_64-linux-musl (default: the host's)
"""
}

pure sources_help_text() -> Str {
  """usage: pm sources fetch [--repo PATH] (--all | PACKAGE...) [--target TARGET]...

Downloads every pinned upstream source the selected packages use on each
target into the content-addressed source cache (LAPUTA_SOURCE_CACHE, default
REPO/.cache/sources) and verifies its sha256. This is the only PM command that
contacts upstream hosts; builds read the cache or the local mirror named by
LAPUTA_MIRROR.

targets: aarch64-linux-musl, x86_64-linux-musl (default: the host's)
"""
}

pure root_help_text() -> Str {
  """usage: pm root COMMAND [OPTIONS]

  compose PLAN --store STORE --runtime-root PACKAGE... --output GENERATION
  inspect GENERATION_OR_RECEIPT
"""
}

pure store_help_text() -> Str {
  """usage: pm store COMMAND [OPTIONS]

  verify --store STORE
  extract PLAN --store STORE --package PACKAGE --path PATH --output FILE
"""
}

pure tail_after(argv: List[Str], start: Int) -> List[Str] {
  var result: List[Str] = []
  var index = start

  while index < argv.len() {
    result = result.push(argv[index])
    index += 1
  }

  result
}

# Parent discovery is intentionally restricted to a complete package repository.
proc current_pm_repo_root() [fs, error] -> Result[Path] {
  var dir = fs.cwd()?

  while true {
    return dir when fs.exists(fp"{dir}/pm.xsh")? and fs.exists(fp"{dir}/packages")?

    let parent = dir.parent

    return p"" when parent.display() == dir.display()

    dir = parent
  }

  p""
}

proc repo_default_root() [fs, error] -> Result[Path] {
  let root = current_pm_repo_root()?

  if root.display() == "" {
    return Err(types.PmError.Usage("pm repo requires --repo outside a package repository"))
  }

  root
}

proc execution_repo_root() [fs, error] -> Result[Path] {
  let root = current_pm_repo_root()?

  if root.display() == "" {
    return Err(types.PmError.Usage("pm repo build requires running inside a package repository"))
  }

  root
}

proc resolve_repo_root(raw: Str) [fs, error] -> Result[Path] {
  return repo_default_root()? when raw == ""

  path.absolute(fp"{raw}")?
}

proc parse_repo_packages(args: List[Str], command: Str) [fs, error] -> Result[RepoPackagesArgs] {
  var parsed: RepoPackagesOptions = RepoPackagesOptions(repo: "", packages: [])

  match cli.parse(
    args,
    {
      repo: {form: "--repo PATH", default: ""},
      packages: {form: "...PACKAGE"},
    },
    command,
  ) {
    Ok(value) => parsed = value
    Err(problem) => return Err(problem)
  }

  if parsed.packages.len() == 0 {
    return Err(types.PmError.Usage(f"{command} requires one-or-more PACKAGE arguments"))
  }

  {repo: resolve_repo_root(parsed.repo)?, packages: parsed.packages}
}

proc parse_repo_command(argv: List[Str]) [fs, env, error] -> Result[PmCommand] {
  if argv.len() == 1 or argv[1] in ["-h", "--help", "help"] {
    return Help(repo_help_text())
  }

  let action = argv[1]
  let args = tail_after(argv, 2)

  if action not in ["check", "plan", "show", "build", "build-node", "publish", "checksum", "update-checksums"] {
    return Err(types.PmError.Usage(f"unknown pm repo command {action}"))
  }

  if args.len() == 1 and args[0] in ["-h", "--help", "help"] {
    return Help(if action == "plan" { repo_plan_help_text() } else { repo_help_text() })
  }

  match action {
    "check" => {
      var parsed: RepoCheckOptions = RepoCheckOptions(repo: "")
      match cli.parse(args, {repo: {form: "--repo PATH", default: ""}}, "pm repo check") {
        Ok(value) => parsed = value
        Err(problem) => return Err(problem)
      }

      RepoCheck({repo: resolve_repo_root(parsed.repo)?})
    }
    "plan" => {
      var parsed: RepoPlanOptions = RepoPlanOptions(
        repo: "",
        all: false,
        roots: [],
        without: [],
        target: "",
        output: p"",
      )
      match cli.parse(
        args,
        {
          repo: {form: "--repo PATH", default: ""},
          all: {form: "--all", default: false},
          roots: {form: "--root PACKAGE", repeated: true},
          without: {form: "--without PACKAGE", repeated: true},
          target: {form: "--target TARGET", default: ""},
          output: {form: "--output PLAN", kind: "Path", required: true},
        },
        "pm repo plan",
      ) {
        Ok(value) => parsed = value
        Err(problem) => return Err(problem)
      }

      if parsed.all == (parsed.roots.len() > 0) {
        return Err(types.PmError.Usage("pm repo plan requires exactly one of --all or one-or-more --root"))
      }

      if parsed.without.len() > 0 and ! parsed.all {
        return Err(types.PmError.Usage("pm repo plan --without requires --all"))
      }

      # A plan targets the host's architecture unless it names one.
      let target = if parsed.target == "" { f"{util.host_arch()?}-linux-musl" } else { parsed.target }
      let _ = types.parse_target(target)?
      parsed = {...parsed, target}
      RepoPlan({
        repo: resolve_repo_root(parsed.repo)?,
        all: parsed.all,
        roots: parsed.roots,
        without: parsed.without,
        target: parsed.target,
        output: parsed.output,
      })
    }
    "show" => {
      var parsed: RepoShowOptions = RepoShowOptions(input: p"")
      match cli.parse(args, {input: {form: "PLAN", kind: "Path", required: true}}, "pm repo show") {
        Ok(value) => parsed = value
        Err(problem) => return Err(problem)
      }

      RepoShow({input: parsed.input})
    }
    "build" => {
      var parsed: RepoBuildOptions = RepoBuildOptions(input: p"", store: p"", jobs: cpu.count(), logs: "")
      match cli.parse(
        args,
        {
          input: {form: "PLAN", kind: "Path", required: true},
          store: {form: "--store STORE", kind: "Path", required: true},
          jobs: {form: "-j --jobs N", kind: "Int", default: cpu.count(), min: 1},
          logs: {form: "--logs DIR", default: ""},
        },
        "pm repo build",
      ) {
        Ok(value) => parsed = value.require(RepoBuildOptions)?
        Err(problem) => return Err(problem)
      }

      RepoBuild({input: parsed.input, store: parsed.store, jobs: parsed.jobs, logs: fp"{parsed.logs}"})
    }
    "build-node" => {
      var parsed: RepoBuildNodeOptions = RepoBuildNodeOptions(input: p"", repo: "", store: p"", node: "")
      match cli.parse(
        args,
        {
          input: {form: "PLAN", kind: "Path", required: true},
          repo: {form: "--repo PATH", required: true},
          store: {form: "--store STORE", kind: "Path", required: true},
          node: {form: "--node ARTIFACT_KEY", required: true},
        },
        "pm repo build-node",
      ) {
        Ok(value) => parsed = value.require(RepoBuildNodeOptions)?
        Err(problem) => return Err(problem)
      }

      RepoBuildNode({input: parsed.input, repo: fp"{parsed.repo}", store: parsed.store, node: parsed.node})
    }
    "publish" => {
      var parsed: RepoPublishOptions = RepoPublishOptions(input: p"", store: p"")
      match cli.parse(
        args,
        {
          input: {form: "PLAN", kind: "Path", required: true},
          store: {form: "--store STORE", kind: "Path", required: true},
        },
        "pm repo publish",
      ) {
        Ok(value) => parsed = value
        Err(problem) => return Err(problem)
      }

      RepoPublish({input: parsed.input, store: parsed.store})
    }
    "checksum" => RepoChecksum(parse_repo_packages(args, "pm repo checksum")?)
    "update-checksums" => RepoUpdateChecksums(parse_repo_packages(args, "pm repo update-checksums")?)
    _ => Err(types.PmError.Usage(f"unknown pm repo command {action}"))
  }
}

proc parse_sources_command(argv: List[Str]) [fs, env, error] -> Result[PmCommand] {
  if argv.len() == 1 or argv[1] in ["-h", "--help", "help"] {
    return Help(sources_help_text())
  }

  if argv[1] != "fetch" {
    return Err(types.PmError.Usage(f"unknown pm sources command {argv[1]}"))
  }

  let args = tail_after(argv, 2)

  if args.len() == 1 and args[0] in ["-h", "--help", "help"] {
    return Help(sources_help_text())
  }

  var parsed: SourcesFetchOptions = SourcesFetchOptions(repo: "", all: false, packages: [], targets: [])
  match cli.parse(
    args,
    {
      repo: {form: "--repo PATH", default: ""},
      all: {form: "--all", default: false},
      targets: {form: "--target TARGET", repeated: true},
      packages: {form: "...PACKAGE"},
    },
    "pm sources fetch",
  ) {
    Ok(value) => parsed = value
    Err(problem) => return Err(problem)
  }

  if parsed.all == (parsed.packages.len() > 0) {
    return Err(types.PmError.Usage("pm sources fetch requires exactly one of --all or one-or-more PACKAGE arguments"))
  }

  let names = if parsed.targets.len() == 0 { [f"{util.host_arch()?}-linux-musl"] } else { parsed.targets }
  var targets: List[types.Target] = []

  for name in names {
    let target = types.parse_target(name)?

    if target not in targets {
      targets += [target]
    }
  }

  SourcesFetch({repo: resolve_repo_root(parsed.repo)?, all: parsed.all, packages: parsed.packages, targets})
}

proc parse_root_command(argv: List[Str]) [error] -> Result[PmCommand] {
  if argv.len() == 1 or argv[1] in ["-h", "--help", "help"] {
    return Help(root_help_text())
  }

  let action = argv[1]
  let args = tail_after(argv, 2)

  if action not in ["compose", "inspect"] {
    return Err(types.PmError.Usage(f"unknown pm root command {action}"))
  }

  if args.len() == 1 and args[0] in ["-h", "--help", "help"] {
    return Help(root_help_text())
  }

  if action == "compose" {
    var parsed: RootComposeOptions = RootComposeOptions(input: p"", store: p"", runtime_roots: [], output: p"")
    match cli.parse(
      args,
      {
        input: {form: "PLAN", kind: "Path", required: true},
        store: {form: "--store STORE", kind: "Path", required: true},
        runtime_roots: {form: "--runtime-root PACKAGE", repeated: true},
        output: {form: "--output GENERATION", kind: "Path", required: true},
      },
      "pm root compose",
    ) {
      Ok(value) => parsed = value
      Err(problem) => return Err(problem)
    }

    if parsed.runtime_roots.len() == 0 {
      return Err(types.PmError.Usage("pm root compose requires one-or-more --runtime-root PACKAGE"))
    }

    return RootCompose(
      {input: parsed.input, store: parsed.store, runtime_roots: parsed.runtime_roots, output: parsed.output},
    )
  }

  var parsed: RootInspectOptions = RootInspectOptions(input: p"")
  match cli.parse(args, {input: {form: "GENERATION", kind: "Path", required: true}}, "pm root inspect") {
    Ok(value) => parsed = value
    Err(problem) => return Err(problem)
  }

  RootInspect({input: parsed.input})
}

proc parse_store_command(argv: List[Str]) [error] -> Result[PmCommand] {
  if argv.len() == 1 or argv[1] in ["-h", "--help", "help"] {
    return Help(store_help_text())
  }

  if argv[1] == "extract" {
    var extracted: StoreExtractOptions = StoreExtractOptions(
      input: p"",
      store: p"",
      package: "",
      path: p"",
      output: p"",
    )
    match cli.parse(
      tail_after(argv, 2),
      {
        input: {form: "PLAN", kind: "Path", required: true},
        store: {form: "--store STORE", kind: "Path", required: true},
        package: {form: "--package PACKAGE", required: true},
        path: {form: "--path PATH", kind: "Path", required: true},
        output: {form: "--output FILE", kind: "Path", required: true},
      },
      "pm store extract",
    ) {
      Ok(value) => extracted = value
      Err(problem) => return Err(problem)
    }

    return StoreExtract({
      input: extracted.input,
      store: extracted.store,
      package: extracted.package,
      path: extracted.path,
      output: extracted.output,
    })
  }

  if argv[1] != "verify" {
    return Err(types.PmError.Usage(f"unknown pm store command {argv[1]}"))
  }

  var parsed: StoreVerifyOptions = StoreVerifyOptions(store: p"")
  match cli.parse(
    tail_after(argv, 2),
    {store: {form: "--store STORE", kind: "Path", required: true}},
    "pm store verify",
  ) {
    Ok(value) => parsed = value
    Err(problem) => return Err(problem)
  }

  StoreVerify({store: parsed.store})
}

proc parse_command(argv: List[Str]) [fs, env, error] -> Result[PmCommand] {
  return Help(help_text()) when argv.len() == 0 or argv[0] in ["-h", "--help", "help"]

  match argv[0] {
    "repo" => parse_repo_command(argv)?
    "sources" => parse_sources_command(argv)?
    "root" => parse_root_command(argv)?
    "store" => parse_store_command(argv)?
    _ => Err(types.PmError.Usage(f"unknown pm command {argv[0]}"))
  }
}

# Planning is offline unless XSH_PM_REPO names a package repository; offline
# plans record the digest of an empty index.
proc remote_snapshot_for_plan(
  cache_root: Path,
  target: types.Target,
) [fs, net, env, time, error] -> Result[types.RemoteSnapshot] {
  var index: List[types.RemotePackage] = []
  let cache = util.remote_index_cache_path(cache_root)
  let repo_url = remote.repo_url()

  if repo_url != "" {
    for entry in remote.load_remote_index_from_repo(repo_url, cache_root)? {
      index = remote.upsert_remote_package(index, entry)?
    }

    remote.write_remote_index_cache(cache_root, index)?
  }

  let index_sha256 = if cache.exists()? { hash.sha256(cache)?.hex() } else { bytes.from_text("[]\n").sha256().hex() }
  var packages: List[types.RemotePlanArtifact] = []

  for entry in index {
    continue unless entry.arch == types.pm_target_arch(target)
    packages = packages.push(remote.plan_artifact_from_package_at_repo(entry, repo_url, cache_root)?)
  }

  {target, index_sha256, packages}
}

proc selected_packages(repo_root: Path, names: List[Str]) [fs, env, error] -> Result[List[types.Package]] {
  let value = catalog.load(repo_root)?
  let by_name = catalog.package_map(value)
  var selected: List[types.Package] = []
  var seen: Map[Bool] = {}

  for name in names {
    if name in seen {
      return Err(types.PmError.Usage(f"package {name} was selected more than once"))
    }

    if ! (name in by_name) {
      return Err(types.PmError.MissingDependency(f"package {name} is not in {repo_root}"))
    }

    let listed: types.Package = by_name.get(name)?
    selected = selected.push(recipe.load_package(fp"{repo_root}/{listed.dir}")?)
    seen[name] = true
  }

  selected
}

proc command_repo_check(args: RepoCheckArgs) [fs, env, error] {
  let value = catalog.load(args.repo)?
  let edges = graph.edges(value, policy.aarch64_docker())?
  print "repo" "check" value.packages.len() "packages" edges.len() "edges"
}

proc command_repo_plan(args: RepoPlanArgs) [fs, net, process, env, time, error] {
  let target = types.parse_target(args.target)?
  let policy_value = if target == types.target_aarch64() { policy.aarch64_docker() } else { policy.x86_64_docker() }

  let cache_handle = fs.tempdir()?
  defer cache_handle.close()?
  let cache_root = cache_handle.host_path()?
  let catalog_value = catalog.load_for_target(args.repo, target)?
  var roots = args.roots
  var all = args.all

  # `--all --without` plans an explicit root set: every package that builds
  # without the excluded ones, so the plan records exactly what it selected.
  if args.without.len() > 0 {
    roots = graph.packages_buildable_without(catalog_value, args.without, policy_value)?
    all = false

    if roots.len() == 0 {
      return Err(types.PmError.Usage(f"no package builds without {args.without.join(", ")}"))
    }
  }

  let value = pm_plan.resolve(
    catalog_value,
    remote_snapshot_for_plan(cache_root, target)?,
    policy_value,
    roots,
    all,
  )?

  # The durable DTO and atomic write are kept behind `write_plan` while the release
  # native-test runner cannot encode a direct reachable call to `plan_json.write`.
  pm_plan_json.write_plan(args.output, value)?
  print (pm_plan.render(value, false)?)
}

proc command_repo_show(args: RepoShowArgs) [fs, error] {
  print (pm_plan.render(pm_plan_json.read(args.input)?, false)?)
}

proc command_repo_build(args: RepoBuildArgs) [fs, net, process, env, time, error] {
  let value = pm_plan_json.read(args.input)?
  if value.target == types.target_x86_64() and (system.uname()?.sysname != "Linux" or util.host_arch()? != "x86_64") {
    return Err(types.PmError.PackageContract("repo build requires a native Linux x86_64 runner for x86_64-linux-musl"))
  }

  let result = pm_execute.build_plan(value, execution_repo_root()?, args.store, remote.repo_url(), args.jobs, args.logs)?
  print "repo" "build" $result.plan_sha256 result.artifacts.len() "artifacts"
}

proc command_repo_build_node(args: RepoBuildNodeArgs) [fs, net, process, env, time, error] {
  let value = pm_plan_json.read(args.input)?
  let receipt = pm_execute.build_plan_node(value, args.repo, args.store, remote.repo_url(), args.node)?
  print "repo" "build-node" $receipt.package_id $receipt.key
}

proc command_repo_publish(args: RepoPublishArgs) [fs, net, env, time, error] {
  let value = pm_plan_json.read(args.input)?
  let snapshot = repo.snapshot(value, args.store)?
  let repo_url = remote.repo_url()

  if repo_url == "" {
    return Err(
      types.PmError.RemoteRepo("pm repo publish needs XSH_PM_REPO, for example http://127.0.0.1:3000 for the local mirror"),
    )
  }

  let work_handle = fs.tempdir()?
  defer work_handle.close()?
  let token = (env.get("LAPUTA_TOKEN") ?? "").trim()
  repo.publish(snapshot, repo_url, token, work_handle.host_path()?)?
  print "repo" "publish" $value.plan_sha256 snapshot.packages.len() "artifacts"
}

proc command_repo_checksums(args: RepoPackagesArgs, update: Bool) [fs, net, process, env, time, error] {
  let cache_root = sources.source_cache_root(args.repo)?

  for pkg in selected_packages(args.repo, args.packages)? {
    if update {
      local.update_package_checksums(cache_root, pkg)?
    } else {
      local.print_package_checksums(cache_root, pkg)?
    }
  }
}

proc command_sources_fetch(args: SourcesFetchArgs) [fs, net, env, time, error] {
  let cache_root = sources.source_cache_root(args.repo)?
  var items: List[sources.SourceFetchItem] = []
  var seen: List[Str] = []

  for target in args.targets {
    let value = catalog.load_for_target(args.repo, target)?
    let by_name = catalog.package_map(value)
    var selected: List[types.Package] = []

    if args.all {
      selected = value.packages
    } else {
      for name in args.packages {
        guard name in by_name else {
          return Err(types.PmError.MissingDependency(f"package {name} is not in {args.repo}"))
        }

        selected = selected.push(by_name.get(name)?)
      }
    }

    for item in sources.source_fetch_items(selected, types.pm_target_arch(target))? {
      if item.sha256 not in seen {
        items += [item]
        seen = seen.push(item.sha256)
      }
    }
  }

  sources.fetch_sources(cache_root, items)?
}

proc command_root_compose(args: RootComposeArgs) [fs, error] {
  let value = pm_plan_json.read(args.input)?
  let overlay_handle = fs.tempdir()?
  defer overlay_handle.close()?
  let overlay = overlay_handle.host_path()?
  let generation_plan = generation.plan(value, args.runtime_roots, generation.overlay_digest(overlay)?)?
  let receipt = generation.compose(generation_plan, args.store, args.output, overlay)?
  print "root" "compose" $receipt.generation_sha256 $receipt.root_sha256
}

proc command_root_inspect(args: RootInspectArgs) [fs, error] {
  # Image builders retain the receipt JSON after atomically publishing their final
  # image and removing container-local generation staging. Accept that durable
  # boundary as well as an intact generation root.
  let receipt = if fs.metadata(args.input)?.kind == "file" {
    generation.read_generation_receipt_file(args.input)?
  } else {
    generation.read_generation_receipt(args.input)?
  }
  print "root" "inspect" $receipt.generation_sha256 $receipt.root_sha256
  print "runtime-roots" receipt.runtime_roots.join(" ")
  print "artifacts" receipt.artifacts.len()
}

proc command_store_verify(args: StoreVerifyArgs) [fs, error] {
  let receipts = store.verify_all(args.store)?
  print "store" "verify" receipts.len() "artifacts"
}

proc command_store_extract(args: StoreExtractArgs) [fs, error] {
  pm_generation_adapter.generation_adapter_copy_manifest_file(
    args.input,
    args.store,
    args.package,
    args.path,
    args.output,
  )?
  print f"store extract {args.package} {args.path}"
}

proc handle(command: PmCommand) [fs, net, process, env, time, error] {
  match command {
    Help(text) => print $text
    RepoCheck(args) => command_repo_check(args)?
    RepoPlan(args) => command_repo_plan(args)?
    RepoShow(args) => command_repo_show(args)?
    RepoBuild(args) => command_repo_build(args)?
    RepoBuildNode(args) => command_repo_build_node(args)?
    RepoPublish(args) => command_repo_publish(args)?
    RepoChecksum(args) => command_repo_checksums(args, false)?
    RepoUpdateChecksums(args) => command_repo_checksums(args, true)?
    SourcesFetch(args) => command_sources_fetch(args)?
    RootCompose(args) => command_root_compose(args)?
    RootInspect(args) => command_root_inspect(args)?
    StoreVerify(args) => command_store_verify(args)?
    StoreExtract(args) => command_store_extract(args)?
  }
}

## Parses only the final explicit PM command surface; there are no extension or legacy fallbacks.
export proc run_pm_cli(argv: List[Str]) [fs, net, process, env, time, error] {
  let args = if argv.len() > 0 and argv[0] == "--" { tail_after(argv, 1) } else { argv }
  handle(parse_command(args)?)?
}

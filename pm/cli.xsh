##! Explicit typed command boundary for immutable package planning, execution, publication, and generation composition.
use catalog
use execute as pm_execute
use generation
use generation_adapter as pm_generation_adapter
use graph
use local
use maintainer
use plan as pm_plan
use plan_json as pm_plan_json
use policy
use recipe
use remote
use repo
use repo_snapshot
use sources
use store
use types
use util

type PmRepoCheckArgs = {repo: Path}

type PmRepoPlanArgs = {repo: Str, all: Bool, roots: List[Str], without: List[Str], target: Str, output: Path}

type PmRepoShowArgs = {input: Path}

type PmRepoBuildArgs = {input: Path, store: Path, jobs: Int, logs: Path}

type PmRepoBuildNodeArgs = {input: Path, repo: Path, store: Path, node: Str}

type PmRepoPublishArgs = {input: Path, store: Path}

type PmRepoPublishSnapshotArgs = {snapshot_dir: Path}

type PmRepoPackagesArgs = {repo: Str, packages: List[Str]}

type PmRootComposeArgs = {input: Path, store: Path, runtime_roots: List[Str], output: Path}

type PmRootInspectArgs = {input: Path}

type PmStoreVerifyArgs = {store: Path}

type PmStoreGcArgs = {store: Path, keep: List[Str]}

type PmStoreExtractArgs = {input: Path, store: Path, package: Str, path: Path, output: Path}

type PmSourcesFetchArgs = {repo: Path, all: Bool, packages: List[Str], targets: List[types.Target]}

proc current_pm_repo_root() -> Result[Path] {
  var dir = fs.cwd()?

  while true {
    return dir when fp"{dir}/pm.xsh".exists() and fp"{dir}/packages".exists()

    let parent = dir.parent

    return p"" when parent.display() == dir.display()

    dir = parent
  }

  p""
}

proc repo_default_root() -> Result[Path] {
  let root = current_pm_repo_root()?

  if root == "" {
    return Err(types.PmError.Usage("pm repo requires --repo outside a package repository"))
  }

  root
}

proc execution_repo_root() -> Result[Path] {
  let root = current_pm_repo_root()?

  if root == "" {
    return Err(types.PmError.Usage("pm repo build requires running inside a package repository"))
  }

  root
}

## Resolve an explicit repository path or discover the enclosing complete repository.
export proc pm_cli_resolve_repo_root(raw: Str) -> Result[Path, Error] {
  return repo_default_root()? when raw == ""

  path.absolute(fp"{raw}")?
}

proc remote_snapshot_for_plan(cache_root: Path, target: types.Target) -> Result[types.RemoteSnapshot] {
  var index: List[types.RemotePackage] = []
  let cache = util.remote_index_cache_path(cache_root)
  let repo_url = remote.repo_url()

  if repo_url != "" and ! util.is_local_repo_url(repo_url) {
    let key_file = (e"XSH_PM_REPO_KEY_FILE" ?? "").trim()

    guard key_file != "" else {
      return Err(
        types.PmError.Auth("planning from a production repository needs XSH_PM_REPO_KEY_FILE naming the provisioned snapshot keys; refusing to use the unsigned index"),
      )
    }

    let keys = repo_snapshot.snapshot_load_keys(fp"{key_file}")?
    let now = time.now() / 1000
    let state_dir = (e"XSH_PM_REPO_STATE_DIR" ?? "").trim()
    index = remote.load_verified_remote_index(repo_url, cache_root, keys, now, state_dir)?
  } else if repo_url != "" {
    for entry in remote.load_remote_index_from_repo(repo_url, cache_root)? {
      index = remote.upsert_remote_package(index, entry)?
    }

    remote.write_remote_index_cache(cache_root, index)
  }

  let index_sha256 = if cache.exists() { hash.sha256(cache)?.hex() } else { bytes.from_text("[]\n").sha256().hex() }
  var packages: List[types.RemotePlanArtifact] = [
    remote.plan_artifact_from_package_at_repo(entry, repo_url, cache_root)?
    for entry in index
    if entry.arch == types.pm_target_arch(target)
  ]
  {target, index_sha256, packages}
}

proc selected_packages(repo_root: Path, names: List[Str]) -> Result[List[types.Package]] {
  let value = catalog.load(repo_root)?
  let by_name = catalog.package_map(value)
  var selected: List[types.Package] = []
  var seen: Set[Str] = set.empty()

  for name in names {
    if name in seen {
      return Err(types.PmError.Usage(f"package {name} was selected more than once"))
    }

    if ! (name in by_name) {
      return Err(types.PmError.MissingDependency(f"package {name} is not in {repo_root}"))
    }

    let listed: types.Package = by_name.get(name)?
    selected += [recipe.load_package(fp"{repo_root}/{listed.dir}")?]
    seen = seen.add(name)
  }

  selected
}

## Execute the typed repo check command.
export proc pm_cli_repo_check(args: PmRepoCheckArgs) {
  let value = catalog.load(args.repo)?
  let edges = graph.edges(value, policy.aarch64_docker())?
  print "repo" "check" value.packages.len() "packages" edges.len() "edges"
}

## Execute the typed repo plan command.
export proc pm_cli_repo_plan(args: PmRepoPlanArgs) [fs, net, process, env, time, error] {
  if args.all == ! args.roots.is_empty() {
    return Err(types.PmError.Usage("pm repo plan requires exactly one of --all or one-or-more --root"))
  }

  if ! args.without.is_empty() and ! args.all {
    return Err(types.PmError.Usage("pm repo plan --without requires --all"))
  }

  let target_name = if args.target == "" { f"{util.host_arch()?}-linux-musl" } else { args.target }
  let target = types.parse_target(target_name)?
  let repo_root = pm_cli_resolve_repo_root(args.repo)?
  let policy_value = if target == types.target_aarch64() { policy.aarch64_docker() } else { policy.x86_64_docker() }

  let cache_handle = fs.tempdir()?
  let cache_root = cache_handle.host_path()?
  let catalog_value = catalog.load_for_target(repo_root, target)?
  var roots = args.roots
  var all = args.all

  if ! args.without.is_empty() {
    roots = graph.packages_buildable_without(catalog_value, args.without, policy_value)?
    all = false

    if roots.is_empty() {
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

  pm_plan_json.write_plan(args.output, value)
  print (pm_plan.render(value, false)?)
}

## Execute the typed repo show command.
export proc pm_cli_repo_show(args: PmRepoShowArgs) {
  print (pm_plan.render(pm_plan_json.read(args.input)?, false)?)
}

## Execute the typed repo build command.
export proc pm_cli_repo_build(args: PmRepoBuildArgs) {
  let value = pm_plan_json.read(args.input)?
  if value.target == types.target_x86_64() and (system.uname()?.sysname != "Linux" or util.host_arch()? != "x86_64") {
    return Err(types.PmError.PackageContract("repo build requires a native Linux x86_64 runner for x86_64-linux-musl"))
  }

  let result = pm_execute.build_plan(value, execution_repo_root()?, args.store, remote.repo_url(), args.jobs, args.logs)?
  print "repo" "build" $result.plan_sha256 result.artifacts.len() "artifacts"
}

## Execute the typed repo build node command.
export proc pm_cli_repo_build_node(args: PmRepoBuildNodeArgs) {
  let value = pm_plan_json.read(args.input)?
  let receipt = pm_execute.build_plan_node(value, args.repo, args.store, remote.repo_url(), args.node)?
  print "repo" "build-node" $receipt.package_id $receipt.key
}

## Execute the typed repo publish command.
export proc pm_cli_repo_publish(args: PmRepoPublishArgs) {
  let value = pm_plan_json.read(args.input)?
  let snapshot = repo.snapshot(value, args.store)?
  let repo_url = remote.repo_url()

  if repo_url == "" {
    return Err(
      types.PmError.RemoteRepo("pm repo publish needs XSH_PM_REPO, for example http://127.0.0.1:3000 for the local mirror"),
    )
  }

  let work_handle = fs.tempdir()?
  let token = (e"LAPUTA_TOKEN" ?? "").trim()
  repo.publish(snapshot, repo_url, token, work_handle.host_path()?)
  print "repo" "publish" $value.plan_sha256 snapshot.packages.len() "artifacts"
}

## Execute the typed repo publish-snapshot command.
export proc pm_cli_repo_publish_snapshot(args: PmRepoPublishSnapshotArgs) {
  let repo_url = remote.repo_url()

  if repo_url == "" {
    return Err(
      types.PmError.RemoteRepo("pm repo publish-snapshot needs XSH_PM_REPO, for example http://127.0.0.1:3000 for the local mirror"),
    )
  }

  let key_file = (e"XSH_PM_REPO_KEY_FILE" ?? "").trim()

  guard key_file != "" else {
    return Err(
      types.PmError.Auth("repository snapshot publication needs XSH_PM_REPO_KEY_FILE naming the provisioned snapshot keys"),
    )
  }

  let work_handle = fs.tempdir()?
  let token = (e"LAPUTA_TOKEN" ?? "").trim()
  let keys = repo_snapshot.snapshot_load_keys(fp"{key_file}")?
  repo.publish_snapshot(repo_url, token, work_handle.host_path()?, args.snapshot_dir, keys)
  print "repo" "publish-snapshot" $args.snapshot_dir
}

proc command_repo_checksums(args: PmRepoPackagesArgs, update: Bool) [fs, net, process, env, time, error] {
  if args.packages.is_empty() {
    let command = if update { "pm repo update-checksums" } else { "pm repo checksum" }
    return Err(types.PmError.Usage(f"{command} requires one-or-more PACKAGE arguments"))
  }

  let repo_root = pm_cli_resolve_repo_root(args.repo)?
  let cache_root = sources.source_cache_root(repo_root)?

  for pkg in selected_packages(repo_root, args.packages)? {
    if update {
      local.update_package_checksums(cache_root, pkg)
    } else {
      local.print_package_checksums(cache_root, pkg)
    }
  }
}

type FetchSelection = {packages: List[types.Package], arch: Str}

## Fetch selected package sources for explicit or host targets.
export proc pm_cli_sources_fetch(repo: Str, all: Bool, packages: List[Str], target_names: List[Str]) {
  if all == ! packages.is_empty() {
    return Err(types.PmError.Usage("pm sources fetch requires exactly one of --all or one-or-more PACKAGE arguments"))
  }

  let names = if target_names.is_empty() { [f"{util.host_arch()?}-linux-musl"] } else { target_names }
  var targets: List[types.Target] = []

  for name in names {
    let target = types.parse_target(name)?
    if target not in targets { targets += [target] }
  }

  let args: PmSourcesFetchArgs = {repo: pm_cli_resolve_repo_root(repo)?, all, packages, targets}
  let cache_root = sources.source_cache_root(args.repo)?
  var items: List[sources.SourceFetchItem] = []
  var seen = []
  var selections: List[FetchSelection] = []

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

        selected += [by_name.get(name)?]
      }
    }

    for item in sources.source_fetch_items(selected, types.pm_target_arch(target))? {
      if item.sha256 not in seen {
        items += [item]
        seen += [item.sha256]
      }
    }

    selections += [{packages: selected, arch: types.pm_target_arch(target)}]
  }

  sources.fetch_sources(cache_root, items)

  var crate_items: List[sources.SourceFetchItem] = []

  for selection in selections {
    for item in sources.cargo_crate_fetch_items(cache_root, selection.packages, selection.arch)? {
      if item.sha256 not in seen {
        crate_items += [item]
        seen += [item.sha256]
      }
    }
  }

  if ! crate_items.is_empty() {
    sources.fetch_sources(cache_root, crate_items)
  }
}

## Execute the typed root compose command.
export proc pm_cli_root_compose(args: PmRootComposeArgs) {
  if args.runtime_roots.is_empty() {
    return Err(types.PmError.Usage("pm root compose requires one-or-more --runtime-root PACKAGE"))
  }

  let value = pm_plan_json.read(args.input)?
  let overlay_handle = fs.tempdir()?
  let overlay = overlay_handle.host_path()?
  let generation_plan = generation.plan(value, args.runtime_roots, generation.overlay_digest(overlay)?)?
  let receipt = generation.compose(generation_plan, args.store, args.output, overlay)?
  print "root" "compose" $receipt.generation_sha256 $receipt.root_sha256
}

## Execute the typed root inspect command.
export proc pm_cli_root_inspect(args: PmRootInspectArgs) {
  let receipt = if args.input.is_file() {
    generation.read_generation_receipt_file(args.input)?
  } else {
    generation.read_generation_receipt(args.input)?
  }
  print "root" "inspect" $receipt.generation_sha256 $receipt.root_sha256
  print "runtime-roots" receipt.runtime_roots.join(" ")
  print "artifacts" receipt.artifacts.len()
}

## Execute the typed store gc command.
export proc pm_cli_store_gc(args: PmStoreGcArgs) {
  return Err(types.PmError.Usage("pm store gc needs at least one --keep PLAN")) when args.keep.is_empty()

  var keep = []

  for plan_file in args.keep {
    keep += [node.artifact_key for node in pm_plan_json.read(fp"{plan_file}")?.nodes]
  }

  let result = store.gc(args.store, keep)?
  print "store" "gc" $result.artifacts "removed" $result.kept "kept"
}

## Execute the typed store verify command.
export proc pm_cli_store_verify(args: PmStoreVerifyArgs) {
  let receipts = store.verify_all(args.store)?
  print "store" "verify" receipts.len() "artifacts"
}

## Execute the typed store extract command.
export proc pm_cli_store_extract(args: PmStoreExtractArgs) {
  pm_generation_adapter.generation_adapter_copy_manifest_file(
    args.input,
    args.store,
    args.package,
    args.path,
    args.output,
  )
  print f"store extract {args.package} {args.path}"
}


## Calculate checksums for the selected repository packages.
export proc pm_cli_repo_checksum(args: PmRepoPackagesArgs) {
  command_repo_checksums(args, false)
}

## Update checksums for the selected repository packages.
export proc pm_cli_repo_update_checksums(args: PmRepoPackagesArgs) {
  command_repo_checksums(args, true)
}

## Report redundant recipe defaults without rewriting executable recipes.
export proc pm_cli_repo_lint(repo_root: Path) {
  let value = catalog.load(repo_root)?
  for pkg in value.packages {
    for field in recipe.redundant_defaults(fp"{repo_root}/{pkg.dir}")? {
      print f"{pkg.name}: redundant {field}"
    }
  }
}

## Report a selected recipe against an explicitly named GitHub release source.
export proc pm_cli_repo_outdated(repo: Str, package: Str, github_release: Str) {
  let repo_root = pm_cli_resolve_repo_root(repo)?
  let pkg = selected_packages(repo_root, [package])?[0]
  maintainer.maintainer_outdated(pkg, github_release)
}

## Print a reviewable filetree change from the selected saved build artifact.
export proc pm_cli_repo_update_filetree(repo: Str, package: Str, input: Path, store_root: Path) {
  let repo_root = pm_cli_resolve_repo_root(repo)?
  let value = pm_plan_json.read(input)?
  let packages = catalog.package_map(catalog.load_for_target(repo_root, value.target)?)
  guard package in packages else {
    return Err(types.PmError.MissingDependency(f"package {package} is not in {repo_root} for {types.target_text(value.target)}"))
  }
  let listed: types.Package = packages.get(package)?
  let pkg = recipe.load_package_for_target(fp"{repo_root}/{listed.dir}", value.target)?
  print (maintainer.maintainer_filetree_diff(pkg, repo_root, value, store_root)?)
}

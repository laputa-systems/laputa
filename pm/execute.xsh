##! Executes one immutable BuildPlan through Store receipts and isolated mutable work roots.
# Proof input is intentionally separate from artifact input: a changed proof writes a second immutable
# attestation under `store.reproof_receipt_path` after rechecking the unchanged payload.
#
# Each built payload is hashed once, when it is staged; its proof receipt and Store receipt reuse
# that digest. Store lookups trust the hashes recorded at commit, so reused artifacts are not
# re-read. Every dependency payload is extracted once per root, directly into that root.
use build as pm_build
use fingerprint
use local
use plan as build_plan
use plan_json
use proof as pm_proof
use recipe
use root as pm_root
use sources
use store
use types
use util

# State one node execution shares with its whole build. `executor` is computed
# once per build, and only when some node actually builds; `published` holds
# the receipts of completed levels by artifact key.
type ExecuteContext = {
  plan: types.BuildPlan,
  repo_root: Path,
  store_root: Path,
  remote_repo: Str,
  executor: types.ExecutorProvenance?,
  published: Map[types.ArtifactReceipt],
}

proc execute_load_package(
  plan_value: types.BuildPlan,
  node: types.PlanNode,
  repo_root: Path,
) -> Result[types.Package] {
  let relative = util.ensure_relative_path(node.recipe_dir, f"plan recipe directory for {node.name}")?
  let pkg = recipe.load_package_for_target(fp"{repo_root}/{relative}", plan_value.target)?

  if pkg.name != node.name or pkg.ver != node.ver or pkg.rel != node.rel or util.package_id(pkg.name, pkg.ver, pkg.rel) != node.package_id {
    return Err(types.PmError.PackageContract(f"recipe {node.recipe_dir} does not match plan node {node.package_id}"))
  }

  # A recipe edited after planning would be built under a key naming other
  # inputs. Re-fingerprinting the recipe costs milliseconds next to the
  # recipe load itself, so it is checked rather than trusted.
  if fingerprint.package_build_input(repo_root, pkg, plan_value.target)? != node.recipe_sha256 {
    return Err(types.PmError.PackageContract(f"recipe build input changed after plan creation for {node.package_id}"))
  }

  if fingerprint.package_proof_input(repo_root, pkg)? != node.proof_sha256 {
    return Err(types.PmError.PackageContract(f"recipe proof input changed after plan creation for {node.package_id}"))
  }

  pkg
}

proc execute_require_receipt(
  plan_value: types.BuildPlan,
  node: types.PlanNode,
  receipt: types.ArtifactReceipt,
) [error] {
  let expected_dependencies = store.receipt_dependency_keys(node)
  let expected_runtime_dependencies = store.receipt_runtime_dependency_keys(node)

  if receipt.target != plan_value.target or receipt.key != node.artifact_key or receipt.package_name != node.name or receipt.package_id != node.package_id or receipt.recipe_sha256 != node.recipe_sha256 or receipt.dependency_keys != expected_dependencies or receipt.runtime_dependency_keys != expected_runtime_dependencies {
    return Err(
      types.PmError.PackageContract(f"stored artifact {node.artifact_key} does not match plan node {node.package_id}"),
    )
  }
}

proc execute_receipt(context: ExecuteContext, key: Str) -> Result[types.ArtifactReceipt] {
  return context.published.get(key)? when key in context.published

  store.lookup(context.store_root, key)
}

proc execute_receipt_closure(
  context: ExecuteContext,
  keys: List[Str],
) -> Result[List[types.ArtifactReceipt]] {
  var pending = keys |> sort
  var index = 0
  var seen: Map[Bool] = {}
  var receipts: List[types.ArtifactReceipt] = []

  while index < pending.len() {
    let key = pending[index]
    index += 1

    continue when seen.get(key) ?? false

    let receipt = execute_receipt(context, key)?
    seen[key] = true
    receipts += [receipt]

    for runtime_key in receipt.runtime_dependency_keys |> sort {
      if ! (seen.get(runtime_key) ?? false) {
        pending += [runtime_key]
      }
    }
  }

  receipts |> sort-by .package_name
}

# Creates `root` holding exactly the payloads of `artifacts`. Store commit
# recorded these artifacts' hashes, and the trusted Root plan rejects path
# ownership conflicts from metadata, so each payload is extracted once,
# straight into the root. Payload archives share top-level directories such
# as `usr`, so extraction merges into what earlier payloads created.
proc execute_compose_root(target: types.Target, root: Path, artifacts: List[types.ArtifactReceipt]) {
  let root_plan = pm_root.trusted_preflight(target, artifacts)?
  let payload_keys = {artifact.artifact_key: true for artifact in root_plan.artifacts if artifact.payload}
  root.mkdir()

  for receipt in artifacts {
    if receipt.key in payload_keys {
      archive.tar_extract(fp"{receipt.artifact_dir}/payload.tar.gz", root, 0, "auto", true)
    }
  }
}

proc execute_stage_local(
  context: ExecuteContext,
  node: types.PlanNode,
  pkg: types.Package,
  build_root: Path,
  work: Path,
) -> Result[types.StagedArtifact] {
  let executor = context.executor

  if executor == null {
    return Err(types.PmError.PackageContract(f"build of {node.package_id} has no executor provenance"))
  }

  let target_arch = types.pm_target_arch(context.plan.target)
  let recipe_dir = fp"{work}/recipe"
  let source = fp"{work}/source"
  let dest = fp"{work}/dest"
  let payload = fp"{work}/payload.tar.gz"
  let metadata = fp"{work}/metadata.json"
  let proof = fp"{work}/proof.json"
  # build_prepared_package creates a traced dynamic runner beside its recipe. Keep that implementation
  # detail inside this node's work tree so execution never writes the checkout or another node's recipe.
  let _ = fs.copy_tree(pkg.dir, recipe_dir, parents: true, overwrite: true)?
  util.normalize_checkout_tree(recipe_dir)
  let isolated_pkg = {...pkg, dir: recipe_dir}
  source.mkdir()
  # Package recipes may explicitly name repository-owned inputs (for example
  # laputa-pm's PM entrypoint/tree). Resolve those against the plan repository
  # while the recipe itself remains isolated under `work/recipe`.
  env ({
    XSH_PM_REPOSITORY_ROOT: context.repo_root.display(),
    XSH_PM_TARGET_ARCH: target_arch,
  }) {
    sources.prepare_package_source_tree(isolated_pkg, source)
  }

  # Builds are native, so the composed build root is also the target root.
  # Recipes resolve target files through LAPUTA_ROOT and build tools through
  # XSH_PM_BUILD_ROOT.
  #
  # CC and CXX name the compiler PATH resolves first, the build root's. Build
  # tools that score every compiler they find instead of taking the first on
  # PATH (muon since 0.6) would otherwise prefer a host GCC behind it, such as
  # the package-tools image's, over the build root's clang.
  env ({
    LAPUTA_ROOT: build_root.display(),
    XSH_PM_BUILD_ROOT: build_root.display(),
    PATH: f"{build_root}/bin:{build_root}/usr/bin:{e"PATH" ?? ""}",
    CC: "cc",
    CXX: "c++",
    XSH_PM_TARGET_ARCH: target_arch,
  }) {
    pm_build.build_prepared_package(recipe_dir, source, dest, payload)
  }

  let built = local.load_built_package_from_dest(isolated_pkg, node.package_id, payload, dest)?
  local.write_package_metadata(metadata, target_arch, built, executor)
  {
    payload,
    payload_sha256: hash.sha256(payload)?.hex(),
    metadata,
    proof,
    executor_sha256: fingerprint.executor_provenance_sha256(executor)?,
  }
}

proc execute_publish_proof_cache(store_root: Path, node: types.PlanNode, payload_sha256: Str, proof: Path) {
  pm_proof.verify_artifact_receipt(proof, node, payload_sha256)
  let cached = store.reproof_receipt_path(store_root, node.artifact_key, node.proof_key)
  cached.parent.mkdir()
  let lock = fs.lock(fp"{cached.parent}/{node.proof_key}.lock")?
  defer fs.unlock(lock)?

  if cached.exists() {
    pm_proof.verify_artifact_receipt(cached, node, payload_sha256)
    return
  }

  let temporary = fp"{cached}.tmp"
  temporary.remove(missing_ok: true)
  defer temporary.remove(missing_ok: true)?
  proof.copy(temporary, overwrite: true)
  temporary.rename(cached)
}

# Runs the package proof against `payload` in a fresh root holding its runtime
# closure, then writes the proof receipt to `proof`. That closure follows
# `deps` edges only: a runtime-only dependency orders no build, so it may not
# exist yet when this node is proved. Generations compose it with the rest.
proc execute_run_proof(
  context: ExecuteContext,
  node: types.PlanNode,
  pkg: types.Package,
  payload: Path,
  payload_sha256: Str,
  proof: Path,
) {
  # Metapackages select an already-proved dependency closure. They own neither
  # a payload archive nor a proof program, but still receive an immutable proof
  # receipt that binds this exact selector node to its opaque Store marker.
  if pkg.kind == types.package_meta() {
    pm_proof.write_artifact_receipt(proof, node, payload_sha256)
    return
  }

  let runtime_keys = [
    dependency.artifact_key
    for dependency in node.dependencies
    if dependency.kind == types.dependency_runtime()
  ]
  let runtime_artifacts = execute_receipt_closure(context, runtime_keys)?
  let root_handle = fs.tempdir()?
  defer root_handle.close()?
  # A proof root is a target runtime closure only: no executor substrate, so
  # the proof cannot pass on files the runner happens to provide.
  let proof_root = fp"{root_handle.host_path()?}/proof-root"
  execute_compose_root(context.plan.target, proof_root, runtime_artifacts)
  archive.tar_extract(payload, proof_root, 0, "auto", true)
  env ({
    XSH_PM_TARGET_ARCH: types.pm_target_arch(context.plan.target),
  }) {
    pm_proof.run_artifact_proof(proof_root, pkg)
  }
  pm_proof.write_artifact_receipt(proof, node, payload_sha256)
}

proc execute_build_local(
  context: ExecuteContext,
  node: types.PlanNode,
) -> Result[types.ArtifactReceipt] {
  let pkg = execute_load_package(context.plan, node, context.repo_root)?
  let root_handle = fs.tempdir()?
  defer root_handle.close()?
  let work = root_handle.host_path()?
  let build_root = fp"{work}/build-root"

  if pkg.kind == types.package_meta() {
    # Selectors have no build sandbox; their declared dependencies are ordered
    # by the BuildPlan and proved independently before this node executes.
    build_root.mkdir()
  } else {
    let dependencies = execute_receipt_closure(context, store.receipt_dependency_keys(node))?
    execute_compose_root(context.plan.target, build_root, dependencies)
    # Only compilation receives the host executor substrate.  A proof root is a
    # target runtime closure; leaking /bin and /usr from the runner both masks
    # missing dependencies and conflicts with baselayout's owned symlinks.
    pm_build.seed_executor_substrate(build_root)
  }

  let staged = execute_stage_local(context, node, pkg, build_root, work)?
  # Keep the proof outcome as Result data through this build-node boundary.
  # The published runner otherwise propagates a failing Unit proc directly out
  # of a par-map worker before its node-status marker can be written.
  execute_run_proof(context, node, pkg, staged.payload, staged.payload_sha256, staged.proof)

  let receipt = store.commit(context.plan.target, context.store_root, node, staged)?
  execute_require_receipt(context.plan, node, receipt)
  receipt
}

proc execute_existing_local(
  context: ExecuteContext,
  node: types.PlanNode,
) -> Result[types.ArtifactReceipt] {
  let receipt = store.lookup(context.store_root, node.artifact_key)?
  execute_require_receipt(context.plan, node, receipt)

  # The proof key binds the package, the artifact key, and the proof input.
  return receipt when receipt.proof_key == node.proof_key

  let cached = store.reproof_receipt_path(context.store_root, node.artifact_key, node.proof_key)

  if cached.exists() {
    pm_proof.verify_artifact_receipt(cached, node, receipt.payload_sha256)
    return receipt
  }

  let pkg = execute_load_package(context.plan, node, context.repo_root)?
  let root_handle = fs.tempdir()?
  defer root_handle.close()?
  let proof = fp"{root_handle.host_path()?}/proof.json"
  execute_run_proof(context, node, pkg, fp"{receipt.artifact_dir}/payload.tar.gz", receipt.payload_sha256, proof)
  execute_publish_proof_cache(context.store_root, node, receipt.payload_sha256, proof)
  receipt
}

proc execute_remote_node(
  context: ExecuteContext,
  node: types.PlanNode,
) -> Result[types.ArtifactReceipt] {
  guard node.remote != null else {
    return Err(
      types.PmError.PackageContract(f"remote plan node {node.package_id} has no immutable retrieval coordinates"),
    )
  }

  let cache_handle = fs.tempdir()?
  defer cache_handle.close()?
  let cache = cache_handle.host_path()?
  let receipt = store.import_remote(context.plan.target, context.store_root, node, context.remote_repo, cache)?
  execute_require_receipt(context.plan, node, receipt)
  receipt
}

# Executes one node of a plan that `build_plan` already validated.
proc execute_node(
  context: ExecuteContext,
  node: types.PlanNode,
) -> Result[types.ArtifactReceipt] {
  if store.artifact_path(context.store_root, node.artifact_key).exists() {
    return execute_existing_local(context, node)
  }

  # Keep action dispatch out of a constructor-pattern boundary.  The pinned
  # published runner parses qualified tag patterns differently from the newer
  # host checker; the typed predicate is stable across both runners.
  return execute_build_local(context, node) when types.plan_action_is_build(node.action)

  execute_remote_node(context, node)
}

# The edges a node waits for before it starts: everything its build root or
# proof root composes. A runtime-only dependency orders no build, so it is
# not one of them.
pure execute_wait_keys(node: types.PlanNode) -> List[Str] {
  [dependency.artifact_key for dependency in node.dependencies if dependency.kind != types.dependency_runtime_only()]
}

# One node building in its own child process.
type RunningNode = {handle: ProcessHandle, node: types.PlanNode, log: Path, started: Int}

type FinishedNode = {name: Str, seconds: Int, log: Path}

# The last lines of a failed node's log: the cause, without the rest of a
# build that can run to tens of thousands of lines.
proc execute_log_tail(log: Path, count: Int) -> Result[Str] {
  return "" unless log.exists()

  let lines = log.read_lines()?
  let first = if lines.len() > count { lines.len() - count } else { 0 }
  lines[first..].join("\n")
}

# The `error:` lines of a failed node's log, which name the cause above the
# runtime traceback; the plain tail when there are none.
proc execute_log_errors(log: Path) -> Result[Str] {
  return "" unless log.exists()

  let errors = [line.trim() for line in log.read_lines()? if line.trim().starts_with("error:")]

  return execute_log_tail(log, 12)? when errors.len() == 0

  let first = if errors.len() > 6 { errors.len() - 6 } else { 0 }
  errors[first..].join("\n")
}

proc execute_report_slowest(finished: List[FinishedNode]) {
  return when finished.len() == 0

  let ascending = finished |> sort-by .seconds |> collect
  var index = ascending.len() - 1
  var shown = 0
  print "repo build slowest packages:"

  while index >= 0 and shown < 10 {
    print f"  {ascending[index].seconds}s {ascending[index].name}"
    index -= 1
    shown += 1
  }
}

# Schedules by dependency, not by plan level. A node starts as soon as every
# node it waits for is in the store, so one slow package delays only its own
# dependents. Each build runs as `pm repo build-node` in a child process
# writing logs/NAME.log, so parallel builds never interleave their output and a
# failure names its package and log. Store publication stays receipt-last: a
# dependent reads only receipts its children already published.
proc execute_scheduled(
  context: ExecuteContext,
  plan_path: Path,
  logs: Path,
  jobs: Int,
) -> Result[Map[types.ArtifactReceipt]] {
  let pm_root = pm_build.pm_source_root()?
  let xsh = process.which("xsh")?
  var done: Map[types.ArtifactReceipt] = {}
  var pending = context.plan.nodes
  var running: List[RunningNode] = []
  var finished: List[FinishedNode] = []
  var failure = ""
  logs.mkdir()

  while pending.len() > 0 or running.len() > 0 {
    var waiting: List[types.PlanNode] = []

    for node in pending {
      let ready = [key for key in execute_wait_keys(node) if key not in done].len() == 0

      if failure != "" or ! ready or running.len() >= jobs {
        waiting += [node]
        continue
      }

      # Stored artifacts and exact remote imports cost no build; they run here,
      # so the scheduler's slots go to real builds.
      let stored = store.artifact_path(context.store_root, node.artifact_key).exists()?

      if stored or ! types.plan_action_is_build(node.action) {
        let receipt = execute_node({...context, published: done}, node)?
        execute_require_receipt(context.plan, node, receipt)
        done[node.artifact_key] = receipt
        continue
      }

      let log = fp"{logs}/{node.name}.log"
      log.write("")
      print f"repo build start {node.name}"
      let command = process.command_argv(
        xsh,
        [
          "xsh",
          fp"{pm_root}/pm.xsh",
          "--",
          "repo",
          "build-node",
          plan_path,
          "--repo",
          context.repo_root,
          "--store",
          context.store_root,
          "--node",
          node.artifact_key,
        ],
        context.repo_root,
        stdout: log,
        stderr: log,
        stdout_append: true,
        stderr_append: true,
      )
      let handle = spawn command?
      running += [{handle, node, log, started: time.now()}]
    }

    pending = waiting

    if running.len() == 0 {
      # Nothing runs and nothing can start: a failure drained the running
      # builds, or no pending node has its dependencies (an invalid plan).
      return Err(types.PmError.ExtensionFailed(failure)) when failure != ""

      return Err(types.PmError.PackageContract(f"no plan node can start; {pending.len()} wait on missing dependencies")) when pending.len() > 0

      break
    }

    let next = process.wait_any([entry.handle for entry in running])?
    let entry = running[next.index]
    running = [other for other in running if other.node.artifact_key != entry.node.artifact_key]
    let seconds = (time.now() - entry.started) / 1000

    if next.status.ok {
      let receipt = store.lookup(context.store_root, entry.node.artifact_key)?
      execute_require_receipt(context.plan, entry.node, receipt)
      done[entry.node.artifact_key] = receipt
      finished += [{name: entry.node.name, seconds, log: entry.log}]
      print f"repo build done {entry.node.name} {seconds}s"
      continue
    }

    print f"repo build FAILED {entry.node.name} after {seconds}s; log {entry.log}:"
    let tail = execute_log_tail(entry.log, 40)?
    print $tail

    if failure == "" {
      failure = f"package build for {entry.node.package_id} failed (log {entry.log}):\n{execute_log_errors(entry.log)?}"

      # Stop the other builds: their results are not needed once the build has
      # failed, and the store never keeps a partial artifact.
      for other in running {
        print f"repo build cancel {other.node.name}"
        other.handle.cancel(signal: "TERM", kill_after: 5s)
      }

      running = []
    }
  }

  execute_report_slowest(finished)

  # The failed node may have been the last one, which ends the loop normally.
  return Err(types.PmError.ExtensionFailed(failure)) when failure != ""

  done
}

## Build the one plan node `key` names, in a `pm repo build-node` child of the scheduler: every node it waits for is already in the store.
export proc build_plan_node(
  plan_value: types.BuildPlan,
  repo_root: Path,
  store_root: Path,
  remote_repo: Str,
  key: Str,
) [fs, net, process, env, time, error] -> Result[types.ArtifactReceipt, Error] {
  build_plan.validate(plan_value)
  build_plan.require_current_build_epoch(plan_value)
  let matches = [node for node in plan_value.nodes if node.artifact_key == key]

  guard matches.len() == 1 else {
    return Err(types.PmError.Usage(f"plan has no node with artifact key {key}"))
  }

  let node = matches[0]
  let context: ExecuteContext = {
    plan: plan_value,
    repo_root,
    store_root,
    remote_repo,
    executor: if execute_plan_builds({...plan_value, nodes: [node]}, store_root) { pm_build.executor_provenance()? } else { null },
    published: {},
  }
  let receipt = execute_node(context, node)?
  execute_require_receipt(plan_value, node, receipt)
  receipt
}

# Executor provenance hashes the XSH runners and the PM tree, so compute it only
# when some node will actually build.
proc execute_plan_builds(plan_value: types.BuildPlan, store_root: Path) -> Result[Bool] {
  for node in plan_value.nodes {
    if types.plan_action_is_build(node.action) and ! store.artifact_path(store_root, node.artifact_key).exists() {
      return true
    }
  }

  false
}

## Executes a BuildPlan into `store_root`; `jobs` bounds concurrent package builds and `logs` holds one log per built package. Artifact-store receipts are the only resume state, and results come back in plan order.
export proc build_plan(
  plan_value: types.BuildPlan,
  repo_root: Path,
  store_root: Path,
  remote_repo: Str,
  jobs: Int,
  logs: Path = p"",
) [fs, net, process, env, time, error] -> Result[types.BuildResult, Error] {
  build_plan.validate(plan_value)
  build_plan.require_current_build_epoch(plan_value)

  return Err(types.PmError.Usage("build jobs must be at least one")) when jobs < 1

  let context: ExecuteContext = {
    plan: plan_value,
    repo_root,
    store_root,
    remote_repo,
    executor: if execute_plan_builds(plan_value, store_root) { pm_build.executor_provenance()? } else { null },
    published: {},
  }
  var done: Map[types.ArtifactReceipt] = {}

  if jobs == 1 {
    # One job builds in this process, in plan order, with output inline.
    for node in plan_value.nodes {
      let receipt = execute_node({...context, published: done}, node)?
      execute_require_receipt(plan_value, node, receipt)
      done[node.artifact_key] = receipt
    }
  } else {
    let handle = fs.tempdir()?
    defer handle.close()?
    let scratch = handle.host_path()?
    # Children read the plan from disk; write_plan seals it with its digest.
    let plan_path = fp"{scratch}/plan.json"
    plan_json.write_plan(plan_path, plan_value)
    let log_dir = if logs == "" { fp"{scratch}/logs" } else { logs }
    done = execute_scheduled(context, plan_path, log_dir, jobs)?
  }

  let artifacts = [done.get(node.artifact_key)? for node in plan_value.nodes]

  # Keep the receipt list concrete at the public executor boundary. The
  # generated profile adapter crosses this boundary in a separate module and
  # must never receive an unparameterized List from the published runner.
  let result: types.BuildResult = types.BuildResult(
    format: "laputa-build-result-1",
    plan_sha256: plan_value.plan_sha256,
    artifacts:,
  )
  result
}

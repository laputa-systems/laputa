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
) [fs, env, error] -> Result[types.Package] {
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

proc execute_receipt(context: ExecuteContext, key: Str) [fs, error] -> Result[types.ArtifactReceipt] {
  if key in context.published {
    return context.published.get(key)?
  }

  store.lookup(context.store_root, key)
}

proc execute_receipt_closure(
  context: ExecuteContext,
  keys: List[Str],
) [fs, error] -> Result[List[types.ArtifactReceipt]] {
  var pending = keys |> sort
  var index = 0
  var seen: Map[Bool] = {}
  var receipts: List[types.ArtifactReceipt] = []

  while index < pending.len() {
    let key = pending[index]
    index += 1

    if seen.get(key) ?? false {
      continue
    }

    let receipt = execute_receipt(context, key)?
    seen[key] = true
    receipts = receipts.push(receipt)

    for runtime_key in receipt.runtime_dependency_keys |> sort {
      if ! (seen.get(runtime_key) ?? false) {
        pending = pending.push(runtime_key)
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
proc execute_compose_root(target: types.Target, root: Path, artifacts: List[types.ArtifactReceipt]) [fs, error] {
  let root_plan = pm_root.trusted_preflight(target, artifacts)?
  let payload_keys: Map[Bool] = {artifact.artifact_key: true for artifact in root_plan.artifacts if artifact.payload}
  fs.mkdir(root)?

  for receipt in artifacts {
    if receipt.key in payload_keys {
      archive.tar_extract(fp"{receipt.artifact_dir}/payload.tar.gz", root, 0, "auto", true)?
    }
  }
}

proc execute_stage_local(
  context: ExecuteContext,
  node: types.PlanNode,
  pkg: types.Package,
  build_root: Path,
  work: Path,
) [fs, net, process, env, time, error] -> Result[types.StagedArtifact] {
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
  let isolated_pkg = {...pkg, dir: recipe_dir}
  fs.mkdir(source)?
  # Package recipes may explicitly name repository-owned inputs (for example
  # laputa-pm's PM entrypoint/tree). Resolve those against the plan repository
  # while the recipe itself remains isolated under `work/recipe`.
  env ({
    XSH_PM_REPOSITORY_ROOT: context.repo_root.display(),
    XSH_PM_TARGET_ARCH: target_arch,
  }) {
    sources.prepare_package_source_tree(isolated_pkg, source)?
  }?

  # Builds are native, so the composed build root is also the target root.
  # Recipes resolve target files through LAPUTA_ROOT and build tools through
  # XSH_PM_BUILD_ROOT.
  env ({
    LAPUTA_ROOT: build_root.display(),
    XSH_PM_BUILD_ROOT: build_root.display(),
    PATH: f"{build_root}/bin:{build_root}/usr/bin:{env.get("PATH") ?? ""}",
    XSH_PM_TARGET_ARCH: target_arch,
  }) {
    pm_build.build_prepared_package(recipe_dir, source, dest, payload)?
  }?

  let built = local.load_built_package_from_dest(isolated_pkg, node.package_id, payload, dest)?
  local.write_package_metadata(metadata, target_arch, built, executor)?
  {
    payload,
    payload_sha256: hash.sha256(payload)?.hex(),
    metadata,
    proof,
    executor_sha256: fingerprint.executor_provenance_sha256(executor)?,
  }
}

proc execute_publish_proof_cache(
  store_root: Path,
  node: types.PlanNode,
  payload_sha256: Str,
  proof: Path,
) [fs, error] -> Result[Unit] {
  pm_proof.verify_artifact_receipt(proof, node, payload_sha256)?
  let cached = store.reproof_receipt_path(store_root, node.artifact_key, node.proof_key)
  fs.mkdir(cached.parent)?
  let lock = fs.lock(fp"{cached.parent}/{node.proof_key}.lock")?
  defer fs.unlock(lock)?

  if fs.exists(cached)? {
    pm_proof.verify_artifact_receipt(cached, node, payload_sha256)?
    return Ok()
  }

  let temporary = fp"{cached}.tmp"
  fs.remove(temporary, missing_ok: true)?
  defer fs.remove(temporary, missing_ok: true)?
  fs.copy(proof, temporary, overwrite: true)?
  fs.rename(temporary, cached)?
  return Ok()
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
) [fs, process, env, error] -> Result[Unit] {
  # Metapackages select an already-proved dependency closure. They own neither
  # a payload archive nor a proof program, but still receive an immutable proof
  # receipt that binds this exact selector node to its opaque Store marker.
  if pkg.kind == types.package_meta() {
    pm_proof.write_artifact_receipt(proof, node, payload_sha256)?
    return Ok()
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
  execute_compose_root(context.plan.target, proof_root, runtime_artifacts)?
  archive.tar_extract(payload, proof_root, 0, "auto", true)?
  env ({
    XSH_PM_TARGET_ARCH: types.pm_target_arch(context.plan.target),
  }) {
    pm_proof.run_artifact_proof(proof_root, pkg)?
  }?
  pm_proof.write_artifact_receipt(proof, node, payload_sha256)?
  return Ok()
}

proc execute_build_local(
  context: ExecuteContext,
  node: types.PlanNode,
) [fs, net, process, env, time, error] -> Result[types.ArtifactReceipt] {
  let pkg = execute_load_package(context.plan, node, context.repo_root)?
  let root_handle = fs.tempdir()?
  defer root_handle.close()?
  let work = root_handle.host_path()?
  let build_root = fp"{work}/build-root"

  if pkg.kind == types.package_meta() {
    # Selectors have no build sandbox; their declared dependencies are ordered
    # by the BuildPlan and proved independently before this node executes.
    fs.mkdir(build_root)?
  } else {
    let dependencies = execute_receipt_closure(context, store.receipt_dependency_keys(node))?
    execute_compose_root(context.plan.target, build_root, dependencies)?
    # Only compilation receives the host executor substrate.  A proof root is a
    # target runtime closure; leaking /bin and /usr from the runner both masks
    # missing dependencies and conflicts with baselayout's owned symlinks.
    pm_build.seed_executor_substrate(build_root)?
  }

  let staged = execute_stage_local(context, node, pkg, build_root, work)?
  # Keep the proof outcome as Result data through this build-node boundary.
  # The published runner otherwise propagates a failing Unit proc directly out
  # of a par-map worker before its node-status marker can be written.
  match execute_run_proof(context, node, pkg, staged.payload, staged.payload_sha256, staged.proof) {
    Ok(_) => {}
    Err(problem) => return Err(problem)
  }

  let receipt = store.commit(context.plan.target, context.store_root, node, staged)?
  execute_require_receipt(context.plan, node, receipt)?
  receipt
}

proc execute_existing_local(
  context: ExecuteContext,
  node: types.PlanNode,
) [fs, process, env, error] -> Result[types.ArtifactReceipt] {
  let receipt = store.lookup(context.store_root, node.artifact_key)?
  execute_require_receipt(context.plan, node, receipt)?

  # The proof key binds the package, the artifact key, and the proof input.
  if receipt.proof_key == node.proof_key {
    return receipt
  }

  let cached = store.reproof_receipt_path(context.store_root, node.artifact_key, node.proof_key)

  if fs.exists(cached)? {
    pm_proof.verify_artifact_receipt(cached, node, receipt.payload_sha256)?
    return receipt
  }

  let pkg = execute_load_package(context.plan, node, context.repo_root)?
  let root_handle = fs.tempdir()?
  defer root_handle.close()?
  let proof = fp"{root_handle.host_path()?}/proof.json"
  execute_run_proof(context, node, pkg, fp"{receipt.artifact_dir}/payload.tar.gz", receipt.payload_sha256, proof)?
  execute_publish_proof_cache(context.store_root, node, receipt.payload_sha256, proof)?
  receipt
}

proc execute_remote_node(
  context: ExecuteContext,
  node: types.PlanNode,
) [fs, net, error] -> Result[types.ArtifactReceipt] {
  if node.remote == null {
    return Err(
      types.PmError.PackageContract(f"remote plan node {node.package_id} has no immutable retrieval coordinates"),
    )
  }

  let cache_handle = fs.tempdir()?
  defer cache_handle.close()?
  let cache = cache_handle.host_path()?
  let receipt = store.import_remote(context.plan.target, context.store_root, node, context.remote_repo, cache)?
  execute_require_receipt(context.plan, node, receipt)?
  receipt
}

# Executes one node of a plan that `build_plan` already validated.
proc execute_node(
  context: ExecuteContext,
  node: types.PlanNode,
) [fs, net, process, env, time, error] -> Result[types.ArtifactReceipt] {
  if fs.exists(store.artifact_path(context.store_root, node.artifact_key))? {
    return execute_existing_local(context, node)
  }

  # Keep action dispatch out of a constructor-pattern boundary.  The pinned
  # published runner parses qualified tag patterns differently from the newer
  # host checker; the typed predicate is stable across both runners.
  if types.plan_action_is_build(node.action) {
    return execute_build_local(context, node)
  }

  return execute_remote_node(context, node)
}

# The published runner erases `par-map`'s result element schema, including
# primitive `Str` values. Do not expose or type-bind that transient result.
# Each worker writes one unique transient outcome marker before its `?`
# propagation; after all workers stop, the parent converts that non-generic
# status back into the original node failure before it ever reads Store. This
# retains worker error propagation on runners that leave par-map errors
# in-band, while Store receipt-last publication remains the level boundary.
pure execute_parallel_level_ok_marker(status: Path, node: types.PlanNode) -> Path {
  fp"{status}/{node.artifact_key}.ok"
}

pure execute_parallel_level_error_marker(status: Path, node: types.PlanNode) -> Path {
  fp"{status}/{node.artifact_key}.error"
}

proc execute_parallel_level_worker(
  context: ExecuteContext,
  node: types.PlanNode,
  status: Path,
) [fs, net, process, env, time, error] -> Result[Unit] {
  # Keep the node Result as data until its failure marker is durable. The
  # caller reconstructs that marker after par-map completion; propagating it
  # here would make runner-specific erased par-map control flow observable.
  match execute_node(context, node) {
    Ok(_) => {
      fs.write(execute_parallel_level_ok_marker(status, node), "ok\n")?
      return Ok()
    }
    Err(problem) => {
      fs.write(execute_parallel_level_error_marker(status, node), problem.message + "\n")?
      # The parent reconstructs and propagates this failure only after every
      # worker has joined. Returning success here avoids an erased par-map
      # result becoming a runner-dependent control-flow boundary.
      return Ok()
    }
  }
}

proc execute_parallel_level_require_workers(nodes: List[types.PlanNode], status: Path) [fs, error] {
  for node in nodes {
    let error_marker = execute_parallel_level_error_marker(status, node)

    if fs.exists(error_marker)? {
      let message = fs.read_text(error_marker)?.trim()
      return Err(types.PmError.ExtensionFailed(f"parallel executor node {node.package_id} failed: {message}"))
    }

    if ! fs.exists(execute_parallel_level_ok_marker(status, node))? {
      return Err(types.PmError.PackageContract(f"parallel executor node {node.package_id} did not report completion"))
    }
  }
}

# Once the ephemeral completion barrier succeeds, derive immutable keys from
# the known plan nodes and read receipt-last Store objects in ordinal order.
# This makes Store publication, rather than an erased parallel result, the
# executor's typed boundary.
proc execute_parallel_level(
  context: ExecuteContext,
  nodes: List[types.PlanNode],
  jobs: Int,
) [fs, net, process, env, time, error] -> Result[List[types.ArtifactReceipt]] {
  let handle = fs.tempdir()?
  defer handle.close()?
  let status = fp"{handle.host_path()?}/parallel-level-status"
  fs.mkdir(status)?

  let _ = nodes
    |> par-map(jobs: jobs) { |node|
      execute_parallel_level_worker(context, node, status)?
      # The value is deliberately ignored: only its completion/error behavior
      # matters, and the published runner erases the par-map element schema.
      0
    }

  execute_parallel_level_require_workers(nodes, status)?
  [store.lookup(context.store_root, node.artifact_key)? for node in nodes]
}

# Executor provenance hashes the XSH runners and the PM tree, so compute it only
# when some node will actually build.
proc execute_plan_builds(plan_value: types.BuildPlan, store_root: Path) [fs, error] -> Result[Bool] {
  for node in plan_value.nodes {
    if types.plan_action_is_build(node.action) and ! fs.exists(store.artifact_path(store_root, node.artifact_key))? {
      return true
    }
  }

  false
}

## Executes each topological BuildPlan level with bounded, deterministic result ordering; artifact-store receipts are the only resume state.
export proc build_plan(
  plan_value: types.BuildPlan,
  repo_root: Path,
  store_root: Path,
  remote_repo: Str,
  jobs: Int,
) [fs, net, process, env, time, error] -> Result[types.BuildResult] {
  build_plan.validate(plan_value)?
  build_plan.require_current_build_epoch(plan_value)?

  if jobs < 1 {
    return Err(types.PmError.Usage("build jobs must be at least one"))
  }

  var context: ExecuteContext = {
    plan: plan_value,
    repo_root,
    store_root,
    remote_repo,
    executor: if execute_plan_builds(plan_value, store_root)? { pm_build.executor_provenance()? } else { null },
    published: {},
  }
  var artifacts: List[types.ArtifactReceipt] = []
  var index = 0

  while index < plan_value.nodes.len() {
    let level = plan_value.nodes[index].level
    var level_nodes: List[types.PlanNode] = []

    while index < plan_value.nodes.len() and plan_value.nodes[index].level == level {
      level_nodes = level_nodes.push(plan_value.nodes[index])
      index += 1
    }

    var completed: List[types.ArtifactReceipt] = []

    if jobs == 1 or level_nodes.len() == 1 {
      for node in level_nodes {
        completed = completed.push(execute_node(context, node)?)
      }
    } else {
      # The postfix `?` is the scheduling boundary: without it par-map keeps
      # a failed worker in-band and a later level can attempt to consume that
      # worker's absent receipt. The level barrier below makes completion
      # of receipt-last publication explicit before advancing the plan.
      completed = execute_parallel_level(context, level_nodes, jobs)?
    }

    # Every receipt here was read from its final Store directory. A dependent
    # level starts only after each one matches its plan node.
    if completed.len() != level_nodes.len() {
      return Err(types.PmError.PackageContract("executor level result count does not match its plan nodes"))
    }

    var published = context.published
    var position = 0

    while position < level_nodes.len() {
      let receipt = completed[position]
      execute_require_receipt(plan_value, level_nodes[position], receipt)?
      published[receipt.key] = receipt
      artifacts = artifacts.push(receipt)
      position += 1
    }

    context = {...context, published}
  }

  # Keep the receipt list concrete at the public executor boundary. The
  # generated profile adapter crosses this boundary in a separate module and
  # must never receive an unparameterized List from the published runner.
  let result: types.BuildResult = {
    format: "laputa-build-result-1",
    plan_sha256: plan_value.plan_sha256,
    artifacts,
  }
  return result
}

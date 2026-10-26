##! Read-only maintainer reports from explicit upstream sources and verified artifacts.
use fingerprint
use plan
use root as pm_root
use store
use types

type MaintainerRelease = {tag_name: Str, draft: Bool, prerelease: Bool}

proc maintainer_numeric_version(raw: Str) -> Result[Str, Error] {
  let value = if raw.starts_with("v") { raw.byte_slice(1) } else { raw }
  guard rx"^[0-9]+(\.[0-9]+)*$".matches(value) else {
    return Err(types.PmError.PackageContract(f"unsupported upstream version {raw}: expected dotted numbers"))
  }
  for component in value.split(".") {
    let _ = component.parse_int_decimal().context("upstream-version-component", raw)?
  }
  value
}

## Compare a stable GitHub release response with the current numeric recipe version.
export proc maintainer_release_report(pkg: types.Package, source: Str, body: Str) -> Result[Str, Error] {
  let release = json.decode(body)?.require(MaintainerRelease)?
  if release.draft or release.prerelease {
    return Err(types.PmError.PackageContract(f"{source} returned a draft or prerelease"))
  }
  let latest = maintainer_numeric_version(release.tag_name)?
  let current = maintainer_numeric_version(pkg.ver)?
  let state = if plan.plan_compare_version_release(current, "0", latest, "0") < 0 { "update available" } else { "current" }
  f"{pkg.name} {pkg.ver} -> {latest}: {state} ({source})"
}

## Fetch the explicitly selected upstream GitHub repository release and report its source.
export proc maintainer_outdated(pkg: types.Package, github_release: Str) {
  let parts = github_release.split("/")
  guard parts.len() == 2 and parts[0] != "" and parts[1] != "" else {
    return Err(types.PmError.Usage("--github-release requires OWNER/REPO"))
  }
  guard rx"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$".matches(github_release) else {
    return Err(types.PmError.Usage("--github-release requires OWNER/REPO"))
  }
  let source = f"https://api.github.com/repos/{github_release}/releases/latest"
  let response = net.request({
    method: "GET",
    url: source,
    headers: [{name: "Accept", value: "application/vnd.github+json"}, {name: "User-Agent", value: "laputa-pm"}],
    timeout: 15s,
    connect_timeout: 5s,
    max_body_bytes: 1048576,
  }).context("upstream-release", source)?
  if response.status != 200 {
    return Err(types.PmError.RemoteIndex(f"{pkg.name}: {source}: HTTP {response.status}"))
  }
  print (maintainer_release_report(pkg, source, response.body as Str).context("upstream-release", source)?)
}

## Render a target-specific replacement declaration only from a current plan and verified payload.
export proc maintainer_filetree_diff(pkg: types.Package, repo_root: Path, value: types.BuildPlan, store_root: Path) -> Result[Str, Error] {
  guard pkg.kind == types.package_payload() else {
    return Err(types.PmError.PackageContract(f"{pkg.name}: metapackage has no payload filetree"))
  }
  let selected = [node for node in value.nodes if node.name == pkg.name]
  guard selected.len() == 1 else {
    return Err(types.PmError.Usage(f"package {pkg.name} is not in the saved BuildPlan"))
  }
  let node = selected[0]
  if fingerprint.package_build_input(repo_root, pkg, value.target)? != node.recipe_sha256 {
    return Err(types.PmError.PackageContract(f"{pkg.name}: recipe has changed since the saved BuildPlan"))
  }
  let receipt = store.verify_artifact(store_root, node.artifact_key)?
  if receipt.package_name != pkg.name or receipt.package_id != node.package_id or receipt.recipe_sha256 != node.recipe_sha256 or receipt.target != value.target {
    return Err(types.PmError.PackageContract(f"{pkg.name}: artifact receipt does not match the saved BuildPlan"))
  }
  var receipts = [receipt]
  var keys = [receipt.key]
  var index = 0
  while index < receipts.len() {
    for key in receipts[index].runtime_dependency_keys {
      if key not in keys {
        receipts += [store.verify_artifact(store_root, key)?]
        keys += [key]
      }
    }
    index += 1
  }
  let inventory = pm_root.preflight(value.target, receipts)?
  let entries = [entry for entry in inventory.entries if entry.package_name == pkg.name] |> sort-by .path
  var lines = [f"--- {pkg.dir}/PKGBUILD.xsh filetree ({types.target_text(value.target)})", f"+++ verified artifact {receipt.key}"]
  let old = [f"{entry.path} {types.file_kind_text(entry.kind)}" for entry in pkg.filetree] |> sort
  let next = [f"{entry.path} {types.file_kind_text(entry.kind)}" for entry in entries] |> sort
  for line in old {
    if line not in next { lines += [f"- {line}"] }
  }
  for line in next {
    if line not in old { lines += [f"+ {line}"] }
  }
  lines += [f"export const filetree_{types.pm_target_arch(value.target)} = ["]
  for entry in entries {
    let quoted = json.encode(entry.path)?
    let kind = json.encode(types.file_kind_text(entry.kind))?
    lines += [f"  {{path: p{quoted}, kind: {kind}}},"]
  }
  lines += ["]"]
  lines.join("\n")
}

##! Native manual-index composition proof using an explicitly supplied musl mandoc tool root.
use pm.catalog
use pm.generation
use pm.plan
use pm.policy
use pm.store
use pm.types

test test_manual_index_queries_composed_pages_and_preserves_prior_generation_on_failure [fs, process, env, error] { |ctx|
  let tools = env.path("LAPUTA_MANUAL_INDEX_TOOL_ROOT")?
  let arch = system.uname()?.machine
  let target = types.parse_target(f"{arch}-linux-musl")?
  let build_policy = if arch == "x86_64" { policy.x86_64_docker() } else { policy.aarch64_docker() }
  let repo = test.temp_dir(ctx, name: "manual-index-repository")?
  fp"{repo}/pm".mkdir()
  p"../../pm/proof.xsh".copy(to: fp"{repo}/pm/proof.xsh")
  let recipe = fp"{repo}/packages/mandoc/PKGBUILD.xsh"
  recipe.parent.mkdir()
  recipe.write("""##! Manual index native fixture.
## Package identity.
export const name = "mandoc"
## Payload classification.
export const package_kind = "payload"
## Version.
export const ver = "1"
## Release.
export const rel = "1"
## Runtime dependencies.
export const deps: List[Str] = []
## Build dependencies.
export const mkdeps_host: List[Str] = []
## Fixture sources.
export let upstream_sources = []
## Fixture payload.
export const filetree = [{path: p"usr", kind: "tree"}]
## Fixture build boundary.
export proc build(dest: Path) [fs, process, env, error] {}
""")
  fp"{recipe.parent}/proof.xsh".write("print 1\n")
  let build_value = plan.resolve(catalog.load(repo)?, {target, index_sha256: "", packages: []}, build_policy, ["mandoc"], false)?
  let node = build_value.nodes[0]
  let stage = test.temp_dir(ctx, name: "manual-index-artifact")?
  let contents = fp"{stage}/contents"
  let _ = fs.copy_tree(tools, contents, parents: true)?
  let page = fp"{contents}/usr/share/man/man1/laputa-island.1"
  page.parent.mkdir()
  page.write(".TH LAPUTA-ISLAND 1\n.SH NAME\nlaputa-island \\- original description\n")
  var entries: List[Record] = []
  for entry in fs.walk(contents, hidden: true, gitignore: false) |> sort-by .path {
    let relative = entry.path.strip_prefix(contents)?.display()
    continue when relative == "."
    if entry.kind == "dir" {
      entry.path.chmod(0o755)
    }
    let metadata = entry.path.metadata()?
    entries += [{path: relative, kind: if entry.kind == "dir" { "tree" } else { entry.kind }, mode: metadata.mode % 4096, sha256: if entry.kind == "file" { hash.sha256(entry.path)?.hex() } else { "" }, target: if entry.kind == "symlink" { entry.path.readlink()?.display() } else { "" }}]
  }
  let payload = fp"{stage}/payload.tar.gz"
  archive.tar_create(payload, contents, [p"."], compression: "gz")
  let metadata = fp"{stage}/metadata.json"
  json.write(metadata, {name: "mandoc", ver: "1", rel: "1", package_kind: "payload", files: entries})
  let proof = fp"{stage}/proof.json"
  proof.write("native fixture")
  let store_root = test.temp_dir(ctx, name: "manual-index-store")?
  let _ = store.commit(target, store_root, node, {payload, payload_sha256: hash.sha256(payload)?.hex(), metadata, proof, executor_sha256: bytes.from_text("manual index native fixture").sha256().hex()})?
  let overlay = test.temp_dir(ctx, name: "manual-index-overlay")?
  let overlay_page = fp"{overlay}/usr/share/man/man7/laputa-overlay.7"
  overlay_page.parent.mkdir()
  overlay_page.write(".TH LAPUTA-OVERLAY 7\n.SH NAME\nlaputa-overlay \\- overlay description\n")
  let value = generation.plan(build_value, ["mandoc"], generation.overlay_digest(overlay)?)?
  let parent = test.temp_dir(ctx, name: "manual-index-generations")?
  let first = fp"{parent}/first"
  let second = fp"{parent}/second"
  let receipt = generation.compose(value, store_root, first, overlay)?
  let repeated = generation.compose(value, store_root, second, overlay)?
  assert receipt == repeated
  generation.verify_generation(first, receipt)
  let loader = fp"{first}/usr/lib/ld-musl-{arch}.so.1"
  let apropos = fp"{first}/usr/bin/apropos"
  let found = run.text $loader "--library-path" fp"{first}/usr/lib" $apropos "-M" fp"{first}/usr/share/man" "Nm=laputa-island"
  assert found == "laputa-island(1) - original description\n"
  let overlaid = run.text $loader "--library-path" fp"{first}/usr/lib" $apropos "-M" fp"{first}/usr/share/man" "Nm=laputa-overlay"
  assert overlaid == "laputa-overlay(7) - overlay description\n"
  let database = fp"{first}/usr/share/man/mandoc.db"
  let original = database.read_bytes()?
  assert original == fp"{second}/usr/share/man/mandoc.db".read_bytes()?
  let root_receipt = json.read(fp"{first}/var/lib/laputa/root.json")?.require(Record)?
  let generated = root_receipt.get("generated_entries")?.require(List[Record])?
  assert generated.len() == 1
  assert generated[0].get("sha256")?.require(Str)? == original.sha256().hex()
  database.write("corrupt index")
  match generation.verify_generation(first, receipt) {
    Ok(_) => test.fail("changed manual index was accepted")
    Err(problem) => assert "does not match metadata" in problem.message
  }
  database.write(original)
  generation.verify_generation(first, receipt)
  let failing_overlay = test.temp_dir(ctx, name: "manual-index-failing-overlay")?
  fp"{failing_overlay}/usr/share/man/mandoc.db~".mkdir()
  let failed_plan = generation.plan(build_value, ["mandoc"], generation.overlay_digest(failing_overlay)?)?
  let failed = fp"{parent}/failed"
  match generation.compose(failed_plan, store_root, failed, failing_overlay) {
    Ok(_) => test.fail("failed manual index generation was published")
    Err(problem) => assert "selected-root makewhatis failed" in problem.message
  }
  assert ! failed.exists()?
  assert database.read_bytes()? == original
  generation.verify_generation(first, receipt)
  database.remove()
  match generation.verify_generation(first, receipt) {
    Ok(_) => test.fail("missing manual index was accepted")
    Err(problem) => assert "absent or unreadable" in problem.message
  }
}

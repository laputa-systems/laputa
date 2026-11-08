##! Adversarial coverage for one confined artifact-to-generation path: hostile payload entries, replaced
##! ancestors and staged inputs, destination conflicts, interrupted composition and exhausted space must
##! leave outside sentinels and the prior committed generation untouched.
use pm.catalog
use pm.generation
use pm.plan
use pm.plan_json
use pm.policy
use pm.store
use pm.types

type TarMember = {name: Str, kind: Str, link: Str, data: Bytes}

type DeclaredFile = {path: Str, content: Str}

type Scene = {
  base: Path,
  outside: Path,
  gens: Path,
  prior: Path,
  prior_receipt: types.GenerationReceipt,
  overlay: Path,
  build: types.BuildPlan,
  value: types.GenerationPlan,
  store_root: Path,
}

pure digest(value: Str) -> Str {
  bytes.from_text(value).sha256().hex()
}

pure filler_text(size: Int) -> Str {
  var text = ""
  for _ in range(size) {
    text += "x"
  }

  text
}

pure benign_content(name: Str) -> Str {
  f"payload {name}\n"
}

pure tar_octal(value: Int, digits: Int) -> Str {
  var rest = value
  var text = ""
  for _ in range(digits) {
    text = f"{rest % 8}{text}"
    rest = rest / 8
  }

  f"{text}\0"
}

pure tar_blocks(length: Int) -> Int {
  (length + 511) / 512 * 512
}

proc put(file: Path, offset: Int, data: Bytes) {
  assert bytes.write_at(file, offset, data)? == data.len()
}

proc write_tar(tarball: Path, members: List[TarMember]) {
  var size = 1024
  for member in members {
    size += 512 + tar_blocks(member.data.len())
  }

  tarball.write(bytes.zero(size)?)
  var header = 0
  for member in members {
    let fields = [
      {at: 0, text: member.name},
      {at: 100, text: tar_octal(0o644, 7)},
      {at: 108, text: tar_octal(0, 7)},
      {at: 116, text: tar_octal(0, 7)},
      {at: 124, text: tar_octal(member.data.len(), 11)},
      {at: 136, text: tar_octal(0, 11)},
      {at: 148, text: "        "},
      {at: 156, text: member.kind},
      {at: 157, text: member.link},
      {at: 257, text: "ustar\0"},
      {at: 263, text: "00"},
    ]
    for field in fields {
      if field.text != "" {
        put(tarball, header + field.at, bytes.from_text(field.text))
      }
    }

    let written = bytes.read_at(tarball, header, 512)?
    var checksum = 0
    for index in range(512) {
      checksum += written.byte_at(index) ?? 0
    }

    put(tarball, header + 148, bytes.from_text(tar_octal(checksum, 7)))
    if ! member.data.is_empty() {
      put(tarball, header + 512, member.data)
    }

    header += 512 + tar_blocks(member.data.len())
  }
}

proc write_gzip_tar(payload: Path, members: List[TarMember]) {
  let tarball = fp"{payload.parent}/{payload.name}.raw"
  write_tar(tarball, members)
  compression.transform(tarball, payload, format: "gzip", metadata: false)
  tarball.remove()
}

pure benign_member(name: Str) -> TarMember {
  {name: f"usr/share/{name}", kind: "0", link: "", data: bytes.from_text(benign_content(name))}
}

proc copied_repository(ctx: TestContext, name: Str) [fs, env, error] -> Result[Path] {
  let root = test.temp_dir(ctx, name:)?
  let _ = fs.copy_tree(p"tests/pm/fixtures/graph-catalog/packages", fp"{root}/packages", parents: true, overwrite: true)?
  fp"{root}/pm".mkdir()
  p"pm/proof.xsh".copy(to: fp"{root}/pm/proof.xsh", overwrite: true)
  root
}

proc commit_payload(
  ctx: TestContext,
  value: types.BuildPlan,
  store_root: Path,
  node: types.PlanNode,
  members: List[TarMember],
  declared: List[DeclaredFile],
) {
  let stage = test.temp_dir(ctx, name: f"confined-stage-{node.name}")?
  let payload = fp"{stage}/payload.tar.gz"
  let metadata = fp"{stage}/metadata.json"
  let proof = fp"{stage}/proof.json"
  write_gzip_tar(payload, members)
  json.write(
    metadata,
    {
      arch: types.pm_target_arch(value.target),
      name: node.name,
      ver: node.ver,
      rel: node.rel,
      package_kind: "payload",
      files: [
        {path: file.path, kind: "file", mode: 0o644, sha256: digest(file.content), target: ""}
        for file in declared
      ],
    },
  )
  proof.write(f"proof {node.name}\n")
  let _ = store.commit(
    value.target,
    store_root,
    node,
    {
      payload,
      payload_sha256: hash.sha256(payload)?.hex(),
      metadata,
      proof,
      executor_sha256: digest("confined executor"),
    },
  )?
}

proc commit_store(
  ctx: TestContext,
  value: types.BuildPlan,
  store_root: Path,
  hostile: Str,
  members: List[TarMember],
  declared: List[DeclaredFile],
) {
  for node in value.nodes {
    if node.name == hostile {
      commit_payload(ctx, value, store_root, node, members, declared)
    } else {
      commit_payload(
        ctx,
        value,
        store_root,
        node,
        [benign_member(node.name)],
        [{path: f"usr/share/{node.name}", content: benign_content(node.name)}],
      )
    }
  }
}

proc scene(ctx: TestContext, name: Str) -> Result[Scene] {
  let repo_root = copied_repository(ctx, f"{name}-repo")?
  let build = plan.resolve(catalog.load(repo_root)?, {target: types.Aarch64LinuxMusl, index_sha256: "confined", packages: []}, policy.aarch64_docker(), ["app"], false)?
  let overlay = fp"{test.temp_dir(ctx, name: f"{name}-overlay")?}/overlay"
  overlay.mkdir()
  let value = generation.plan(build, ["app"], generation.overlay_digest(overlay)?)?
  let store_root = test.temp_dir(ctx, name: f"{name}-store")?
  commit_store(ctx, build, store_root, "", [], [])
  let base = test.temp_dir(ctx, name: f"{name}-base")?
  let outside = fp"{base}/outside"
  outside.mkdir()
  fp"{outside}/sentinel".write("outside sentinel\n")
  let gens = fp"{base}/gens"
  let prior = fp"{gens}/prior"
  let prior_receipt = generation.compose(value, store_root, prior, overlay)?
  {base, outside, gens, prior, prior_receipt, overlay, build, value, store_root}
}

proc listing(directory: Path) -> Result[List[Str]] {
  [entry.name for entry in fs.children(directory)?] |> sort
}

proc assert_untouched(value: Scene, gens: List[Str]) {
  assert listing(value.outside)? == ["sentinel"]
  assert fp"{value.outside}/sentinel".read_text()? == "outside sentinel\n"
  assert listing(value.gens)? == gens
  generation.verify_generation(value.prior, value.prior_receipt)
  assert fp"{value.prior}/usr/share/runtime-lib".read_text()? == benign_content("runtime-lib")
}

proc expect_failure(result: Result[types.GenerationReceipt], label: Str) -> Result[Str] {
  match result {
    Ok(_) => Err(types.PmError.PackageContract(f"{label}: composition unexpectedly succeeded"))
    Err(problem) => problem.message
  }
}

test test_hostile_payload_entries_fail_before_publication_and_touch_nothing_outside [fs, process, env, error] { |ctx|
  let value = scene(ctx, "confined-hostile")?
  let outside = value.outside.display()
  let declared = [{path: "usr/share/runtime-lib", content: benign_content("runtime-lib")}]
  let cases = [
    {label: "parent", members: [benign_member("runtime-lib"), {name: "../escape", kind: "0", link: "", data: b"escaped\n"}]},
    {label: "absolute", members: [benign_member("runtime-lib"), {name: f"{outside}/absolute", kind: "0", link: "", data: b"escaped\n"}]},
    {
      label: "absolute-symlink-write-through",
      members: [
        benign_member("runtime-lib"),
        {name: "usr/share/link", kind: "2", link: outside, data: b""},
        {name: "usr/share/link/sentinel", kind: "0", link: "", data: b"overwritten\n"},
      ],
    },
    {
      label: "climbing-symlink-write-through",
      members: [
        benign_member("runtime-lib"),
        {name: "usr/share/up", kind: "2", link: "../../..", data: b""},
        {name: "usr/share/up/escape", kind: "0", link: "", data: b"escaped\n"},
      ],
    },
    {label: "outside-hard-link", members: [benign_member("runtime-lib"), {name: "usr/share/hard", kind: "1", link: f"{outside}/sentinel", data: b""}]},
    {label: "climbing-hard-link", members: [benign_member("runtime-lib"), {name: "usr/share/hard", kind: "1", link: "../outside/sentinel", data: b""}]},
    {label: "fifo", members: [benign_member("runtime-lib"), {name: "usr/share/fifo", kind: "6", link: "", data: b""}]},
    {label: "character-device", members: [benign_member("runtime-lib"), {name: "usr/share/null", kind: "3", link: "", data: b""}]},
    {label: "undeclared-file", members: [benign_member("runtime-lib"), {name: "usr/share/extra", kind: "0", link: "", data: b"extra\n"}]},
    {label: "declared-file-as-symlink", members: [{name: "usr/share/runtime-lib", kind: "2", link: "../../etc/passwd", data: b""}]},
  ]

  for hostile in cases {
    let store_root = test.temp_dir(ctx, name: f"confined-hostile-store-{hostile.label}")?
    commit_store(ctx, value.build, store_root, "runtime-lib", hostile.members, declared)
    let output = fp"{value.gens}/{hostile.label}"
    let _ = expect_failure(generation.compose(value.value, store_root, output, value.overlay), hostile.label)?
    assert ! output.exists()?, hostile.label
    assert_untouched(value, ["prior"])
  }
}

test test_payload_hard_links_materialize_as_independent_copies [fs, process, env, error] { |ctx|
  let value = scene(ctx, "confined-hard-link")?
  let store_root = test.temp_dir(ctx, name: "confined-hard-link-store")?
  commit_store(
    ctx,
    value.build,
    store_root,
    "runtime-lib",
    [benign_member("runtime-lib"), {name: "usr/share/alias", kind: "1", link: "usr/share/runtime-lib", data: b""}],
    [
      {path: "usr/share/alias", content: benign_content("runtime-lib")},
      {path: "usr/share/runtime-lib", content: benign_content("runtime-lib")},
    ],
  )
  let output = fp"{value.gens}/linked"
  let receipt = generation.compose(value.value, store_root, output, value.overlay)?
  generation.verify_generation(output, receipt)
  let original = fs.stat(fp"{output}/usr/share/runtime-lib")?
  let alias = fs.stat(fp"{output}/usr/share/alias")?
  assert original.nlink == 1 and alias.nlink == 1
  assert original.ino != alias.ino
  assert_untouched(value, ["linked", "prior"])
}

test test_destination_conflicts_are_never_replaced [fs, process, env, error] { |ctx|
  let value = scene(ctx, "confined-conflicts")?
  let existing = expect_failure(generation.compose(value.value, value.store_root, value.prior, value.overlay), "prior")?
  assert "already exists" in existing
  assert_untouched(value, ["prior"])

  let dangling = fp"{value.gens}/dangling"
  dangling.symlink(to: fp"{value.outside}/created")
  let _ = expect_failure(generation.compose(value.value, value.store_root, dangling, value.overlay), "dangling")?
  assert dangling.readlink()? == fp"{value.outside}/created"
  assert_untouched(value, ["dangling", "prior"])

  let file = fp"{value.gens}/file"
  file.write("not a generation\n")
  let _ = expect_failure(generation.compose(value.value, value.store_root, file, value.overlay), "file")?
  assert file.read_text()? == "not a generation\n"
  assert_untouched(value, ["dangling", "file", "prior"])

  let publication = fs.open_root(value.gens)?
  let _ = expect_failure(generation.compose_beneath(value.value, value.store_root, publication, "../escape", value.overlay), "climbing name")?
  assert_untouched(value, ["dangling", "file", "prior"])
}

test test_replaced_publication_ancestor_cannot_redirect_a_retained_composition [fs, process, env, error] { |ctx|
  let value = scene(ctx, "confined-ancestor")?
  let publication = fs.open_root(value.gens)?
  let moved = fp"{value.base}/gens.moved"
  value.gens.rename(to: moved)
  value.gens.symlink(to: value.outside)

  let receipt = generation.compose_beneath(value.value, value.store_root, publication, "candidate", value.overlay)?
  generation.verify_generation(fp"{moved}/candidate", receipt)
  assert listing(value.outside)? == ["sentinel"]
  assert fp"{value.outside}/sentinel".read_text()? == "outside sentinel\n"
  assert listing(moved)? == ["candidate", "prior"]
  generation.verify_generation(fp"{moved}/prior", value.prior_receipt)
}

test test_store_ingests_staged_inputs_only_beneath_their_directory [fs, process, env, error] { |ctx|
  let value = scene(ctx, "confined-store-inputs")?
  let node = [node for node in value.build.nodes if node.name == "runtime-lib"][0]
  let store_root = test.temp_dir(ctx, name: "confined-store-inputs")?
  let stage = test.temp_dir(ctx, name: "confined-store-stage")?
  let payload = fp"{stage}/payload.tar.gz"
  write_gzip_tar(payload, [benign_member("runtime-lib")])
  let payload_sha256 = hash.sha256(payload)?.hex()
  payload.remove()
  payload.symlink(to: fp"{value.outside}/sentinel")
  fp"{stage}/metadata.json".write("{}\n")
  fp"{stage}/proof.json".write("proof\n")
  match store.commit(
    value.build.target,
    store_root,
    node,
    {
      payload,
      payload_sha256,
      metadata: fp"{stage}/metadata.json",
      proof: fp"{stage}/proof.json",
      executor_sha256: digest("confined executor"),
    },
  ) {
    Ok(_) => test.fail("store ingested a staged payload symlink that leaves its directory")
    Err(_) => {}
  }

  assert ! store.artifact_path(store_root, node.artifact_key).exists()?
  assert listing(fp"{store_root}/v2/tmp")? == []
  assert_untouched(value, ["prior"])
}

test test_store_reclaims_interrupted_staging_for_its_key_only [fs, process, env, error] { |ctx|
  let value = scene(ctx, "confined-store-reclaim")?
  let node = [node for node in value.build.nodes if node.name == "runtime-lib"][0]
  let store_root = test.temp_dir(ctx, name: "confined-store-reclaim")?
  let tmp = fp"{store_root}/v2/tmp"
  let interrupted = fp"{tmp}/.{node.artifact_key}.killed.tmp"
  fp"{interrupted}/nested".mkdir()
  fp"{interrupted}/nested/payload.tar.gz".write("interrupted")
  let foreign = fp"{tmp}/.{digest("uncommitted key")}.running.tmp"
  foreign.mkdir()
  fp"{foreign}/payload.tar.gz".write("another key")
  let link = fp"{tmp}/{node.artifact_key}"
  link.symlink(to: value.outside)

  commit_store(ctx, value.build, store_root, "", [], [])
  assert ! interrupted.exists()?
  assert fp"{foreign}/payload.tar.gz".read_text()? == "another key"
  assert link.readlink()? == value.outside
  assert_untouched(value, ["prior"])
}

proc staging_present(gens: Path, name: Str) -> Result[Bool] {
  for entry in listing(gens)? {
    return true when entry.starts_with(f".{name}.") and entry.ends_with(".tmp")
  }

  false
}

proc driver(value: Scene, name: Str) -> Result[Path] {
  let plan_path = fp"{value.base}/{name}-plan.json"
  plan_json.write_plan(plan_path, value.build)
  plan_path
}

proc runner() [env, process, error] -> Result[Path] {
  let configured = e"XSH_HOST" ?? ""
  return fp"{configured}" when configured != ""
  process.which("xsh")
}

proc commit_wide_store(ctx: TestContext, value: Scene, name: Str, files: Int, size: Int) -> Result[Path] {
  let store_root = test.temp_dir(ctx, name: f"{name}-store")?
  let filler = filler_text(size)
  let members = [benign_member("runtime-lib")] + [
    {name: f"usr/share/wide/{index}", kind: "0", link: "", data: bytes.from_text(filler)} for index in range(files)
  ]
  let declared = [{path: "usr/share/runtime-lib", content: benign_content("runtime-lib")}] + [
    {path: f"usr/share/wide/{index}", content: filler} for index in range(files)
  ]
  commit_store(ctx, value.build, store_root, "runtime-lib", members, declared)
  store_root
}

test test_killed_composition_publishes_nothing_partial [fs, process, env, time, error] { |ctx|
  let value = scene(ctx, "confined-kill")?
  let store_root = commit_wide_store(ctx, value, "confined-kill-wide", 400, 64)?
  let plan_path = driver(value, "confined-kill")?
  let xsh = runner()?
  let modules = path.absolute(p".")?

  var outcomes: Set[Str] = set.empty()

  for delay_ms in [0, 10, 40, 100, 250, 600, 1500, 4000, 10000, 30000] {
    let output = fp"{value.gens}/killed-{delay_ms}"
    let child = spawn run XSH_MODULE_PATH=$modules XSH_HOST=$xsh $xsh pm.xsh -- root compose $plan_path --store $store_root --runtime-root app --output $output ?
    var polls = 0
    while ! staging_present(value.gens, f"killed-{delay_ms}") and ! output.exists() {
      polls += 1
      assert polls < 30000, "composition never began staging"
      time.sleep(time.millis(2))?
    }

    time.sleep(time.millis(delay_ms))?
    process.kill(child.pid, signal: "KILL")?
    let _ = wait [child]?
    let staged = staging_present(value.gens, f"killed-{delay_ms}")?
    outcomes = outcomes.add(if output.exists()? { "published" } else if staged { "staged" } else { "absent" })

    if output.exists()? {
      generation.verify_generation(output, generation.read_generation_receipt(output)?)
      assert fp"{output}/usr/share/wide/399".read_text()? == filler_text(64)
    }

    for entry in listing(value.gens)? {
      assert entry == "prior" or entry.starts_with("killed-") or (entry.starts_with(".killed-") and entry.ends_with(".tmp")), entry
    }

    assert listing(value.outside)? == ["sentinel"]
    generation.verify_generation(value.prior, value.prior_receipt)
    break when "published" in outcomes
  }

  assert "staged" in outcomes and "published" in outcomes

  let retried = fp"{value.gens}/retried"
  let retried_run = run.capture --text XSH_MODULE_PATH=$modules XSH_HOST=$xsh $xsh pm.xsh -- root compose $plan_path --store $store_root --runtime-root app --output $retried ?
  assert retried_run.status.ok, retried_run.stderr
  generation.verify_generation(retried, generation.read_generation_receipt(retried)?)
}

test test_exhausted_space_fails_without_partial_generation_or_lost_prior [fs, process, env, error] { |ctx|
  let unshare = match process.which("unshare") {
    Ok(found) => found,
    Err(_) => {
      test.skip("unshare is unavailable for the tmpfs fixture")
      return
    },
  }
  let probe = run.capture --text $unshare -Urm true ?
  if ! probe.status.ok {
    test.skip("unprivileged user and mount namespaces are unavailable for the tmpfs fixture")
    return
  }

  let value = scene(ctx, "confined-full")?
  let store_root = commit_wide_store(ctx, value, "confined-full-wide", 64, 16384)?
  let plan_path = driver(value, "confined-full")?
  let mount = fp"{value.base}/full"
  mount.mkdir()
  let script = fp"{value.base}/full.sh"
  script.write("""set -u
mount -t tmpfs -o size=640k tmpfs "$1" || exit 90
"$2" pm.xsh -- root compose "$3" --store "$4" --runtime-root app --output "$1/prior" >/dev/null || exit 91
"$2" pm.xsh -- root compose "$3" --store "$5" --runtime-root app --output "$1/full" >/dev/null 2>"$1.err"
echo "full-status $?"
grep -c 'No space left on device' "$1.err" | sed 's/^/enospc /'
ls -A "$1" | tr '\\n' ' ' | sed 's/^/entries /'
echo
"$2" pm.xsh -- root inspect "$1/prior" | head -1 | sed 's/^/prior /'
cat "$1/prior/usr/share/runtime-lib" | sed 's/^/prior-file /'
""")
  let xsh = runner()?
  let modules = path.absolute(p".")?
  let result = run.capture --text XSH_MODULE_PATH=$modules XSH_HOST=$xsh $unshare -Urm sh $script $mount $xsh $plan_path $value.store_root $store_root ?
  assert result.status.ok, result.stderr
  let lines = result.stdout.trim().split("\n")
  assert "full-status 0" not in lines and lines[0].starts_with("full-status "), result.stdout
  assert "enospc 1" in lines, result.stdout
  assert "entries prior " in lines, result.stdout
  assert "prior-file payload runtime-lib" in lines, result.stdout
  assert listing(value.outside)? == ["sentinel"]
}

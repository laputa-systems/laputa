##! Coverage for GitHub prerelease discovery and recipe pin refresh.
use pm.recipe
use pm.types
use refresh.prereleases

const FEED = """<?xml version="1.0" encoding="UTF-8"?>
<feed>
<entry><updated>2026-11-09T08:57:29Z</updated><link href="https://github.com/o/r/releases/tag/release-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"/></entry>
<entry><updated>2026-11-23T07:33:52Z</updated><link href="https://github.com/o/r/releases/tag/release-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"/></entry>
<entry><updated>2026-11-20T01:00:00Z</updated><link href="https://github.com/o/r/releases/tag/v2.0.0"/></entry>
</feed>
"""

const SUMS = """1111111111111111111111111111111111111111111111111111111111111111  pkg-x86_64-linux-musl.tar.xz
2222222222222222222222222222222222222222222222222222222222222222  pkg-aarch64-linux-musl.tar.xz
3333333333333333333333333333333333333333333333333333333333333333  pkg-software-x86_64-linux-musl.tar.xz
"""

const RECIPE = """##! Test recipe with a GitHub release pin.
use pm.types

## Package name.
export let name = "refresh-fixture"
## Payload classification.
export let package_kind = "payload"
## Upstream version.
export let ver = "1.4.1"
## Package release.
export let rel = "5"
## Runtime dependencies.
export let deps = []
## Build-host dependencies.
export let mkdeps_host = []
## Build-target dependencies.
export let mkdeps_target = []
## Upstream inputs.
export let upstream_sources = [{
  source: p"https://github.com/o/r/releases/download/release-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/pkg-ARCH-linux-musl.tar.gz => pkg",
  kind: "file",
  architectures: ["all"],
  checksums: [
    {arch: "x86_64", sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    {arch: "aarch64", sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
  ],
}]
## Declared outputs.
export let filetree = [{path: p"usr/bin/pkg", kind: "binary"}]
## Built at commit aaaaaaaaaa with sha aaaaaaaa and bbbbbbbb.
export proc build(dest: Path) [fs, process, error] {
  let tars = fs.walk(p".", gitignore: false)? |> where .kind == "file" and .ext == "gz"
  guard tars.len() == 1 else { return Err(types.PmError.PackageContract("bad tar count")) }
  tempdir unpacked {
    archive.extract(tars[0].path, unpacked, .Tar, compression: .Gzip, collision: .Replace)
  }
}
"""

pure repeated(digit: Str, count: Int) -> Str {
  var out = ""
  var index = 0
  while index < count {
    out += digit
    index += 1
  }
  out
}

test test_feed_discovery_prefers_newest_prefixed_entry [error] {
  let entries = prereleases.feed_entries(FEED, "release-")
  assert entries.len() == 2
  let tag = prereleases.latest_tag(FEED, "release-")
  assert tag == "release-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  assert prereleases.latest_tag(FEED, "no-such-prefix-") == ""
  assert prereleases.feed_entries("not a feed", "release-").is_empty()
}

test test_sums_and_asset_resolution_follow_format_changes [error] {
  let sums = prereleases.sums_map(SUMS)
  assert (sums.get("pkg-x86_64-linux-musl.tar.xz") ?? "") == repeated("1", 64)
  assert sums.get("missing.tar.xz") is Err(_)
  let exact = prereleases.resolve_asset("pkg-x86_64-linux-musl.tar.xz", sums)?
  assert exact.name == "pkg-x86_64-linux-musl.tar.xz"
  let changed = prereleases.resolve_asset("pkg-x86_64-linux-musl.tar.gz", sums)?
  assert changed.name == "pkg-x86_64-linux-musl.tar.xz"
  assert changed.sha256 == repeated("1", 64)
  assert prereleases.resolve_asset("unknown.tar.gz", sums) is Err(_)
  let both: Map[Str, Str] = {"a.tar.gz": repeated("1", 64), "a.tar.xz": repeated("2", 64)}
  assert prereleases.resolve_asset("a.tar.bz2", both) is Err(_)
}

test test_pin_and_format_helpers [error] {
  let source = p"https://github.com/o/r/releases/download/release-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/pkg-ARCH-linux-musl.tar.xz => pkg"
  let pin = prereleases.parse_pin_text(source.display())?
  assert pin.owner == "o"
  assert pin.repository == "r"
  assert pin.tag == "release-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  assert prereleases.parse_pin_text("files/input.txt") is Err(_)
  assert prereleases.commit_sha(pin.tag) == repeated("a", 40)
  assert prereleases.commit_sha("v1.2.3") == ""
  assert prereleases.archive_ext("pkg.tar.gz") == ".tar.gz"
  assert prereleases.asset_stem("pkg.tar.gz") == "pkg"
  assert prereleases.format_tokens(".tar.gz").compression == ".Gzip"
  assert prereleases.format_tokens(".tar.xz").ext == "xz"
  assert prereleases.format_tokens(".unknown").ext == ""
}

test test_build_refresh_rewrites_pin_checksums_rel_and_build_hook [fs, env, error] { |ctx|
  let dir = test.temp_dir(ctx, name: "refresh-recipe")?
  fp"{dir}/PKGBUILD.xsh".write(RECIPE)
  fp"{dir}/proof.xsh".write("export proc main(root: Path) [fs, error] {\n}\n")
  let pkg = recipe.load_package(dir)?
  let pin = prereleases.current_pin(pkg)?
  let new_tag = "release-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  let plan = prereleases.build_refresh(pkg, pin, new_tag, prereleases.sums_map(SUMS))?

  assert plan.old_rel == "5"
  assert plan.new_rel == "6"
  assert plan.warning == ""
  assert f"download/{new_tag}/pkg-ARCH-linux-musl.tar.xz" in plan.after
  assert "download/release-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" not in plan.after
  assert repeated("1", 64) in plan.after
  assert repeated("2", 64) in plan.after
  assert repeated("a", 64) not in plan.after
  assert repeated("b", 64) not in plan.after
  assert ".ext == \"xz\"" in plan.after
  assert "compression: .Xz" in plan.after
  assert ".ext == \"gz\"" not in plan.after
  assert "compression: .Gzip" not in plan.after
  assert "commit bbbbbbbbbb" in plan.after
  assert "sha 11111111" in plan.after
  assert "sha bbbbbbbb" not in plan.after

  let missing = prereleases.sums_map("")
  assert prereleases.build_refresh(pkg, pin, new_tag, missing) is Err(_)
}

test test_build_refresh_interpolated_tag_constant [fs, env, error] { |ctx|
  let dir = test.temp_dir(ctx, name: "refresh-interpolated")?
  let old_tag = "release-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let new_tag = "release-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  let fixture = RECIPE.replace("use pm.types", with: f"use pm.types\nconst release_tag = \"{old_tag}\"").replace(f"p\"https://github.com/o/r/releases/download/{old_tag}/", with: "fp\"https://github.com/o/r/releases/download/{release_tag}/").replace(".tar.gz", with: ".tar.xz")
  fp"{dir}/PKGBUILD.xsh".write(fixture)
  fp"{dir}/proof.xsh".write("export proc main(root: Path) [fs, error] {\n}\n")
  let pkg = recipe.load_package(dir)?
  let plan = prereleases.build_refresh(pkg, prereleases.current_pin(pkg)?, new_tag, prereleases.sums_map(SUMS))?
  assert f"const release_tag = \"{new_tag}\"" in plan.after
  assert "download/{release_tag}/pkg-ARCH-linux-musl.tar.xz" in plan.after
  assert repeated("1", 64) in plan.after
  assert repeated("2", 64) in plan.after
  assert plan.new_rel == "6"
  let changed_sums = prereleases.sums_map(SUMS.replace(".tar.xz", with: ".tar.gz"))
  assert prereleases.build_refresh(pkg, prereleases.current_pin(pkg)?, new_tag, changed_sums) is Err(_)
}

test test_all_skips_non_github_recipe_but_explicit_selection_errors [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "refresh-catalog")?
  let dir = fp"{root}/packages/refresh-fixture"
  dir.mkdir(parents: true)
  let fixture = RECIPE.replace("https://github.com/o/r/releases/download/", with: "https://example.com/download/")
  fp"{dir}/PKGBUILD.xsh".write(fixture)
  fp"{dir}/proof.xsh".write("export proc main(root: Path) [fs, error] {\n}\n")
  let xsh = process.which("xsh")?
  let modules = path.absolute(p".")?
  let all_result = run.capture --text XSH_MODULE_PATH=$modules $xsh refresh-prereleases.xsh -- --repo $root --all
  assert all_result.status.exited_with(0)
  assert "refresh-fixture: skipped (no GitHub release source)" in all_result.stdout
  let named = run.capture --text XSH_MODULE_PATH=$modules $xsh refresh-prereleases.xsh -- --repo $root refresh-fixture
  assert ! named.status.exited_with(0)
  assert "refresh-fixture: no GitHub release source to refresh" in named.stderr
}

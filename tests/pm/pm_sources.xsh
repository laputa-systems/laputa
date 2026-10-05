##! Behavior coverage for content-addressed URL sources, local-mirror resolution, and `pm sources fetch`.
use pm.sources
use pm.types
use pm.util

# No test reaches an upstream host: URL sources name `.invalid` hosts or
# `file://` paths (expanded like any URL), and the HTTP mirror case targets a
# closed loopback port.
const sha256_of_empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

proc runner() [fs, process, env, error] -> Result[Path] {
  let configured = (e"XSH_HOST" ?? "").trim()

  return path.absolute(fp"{configured}")? when configured != ""

  process.which("xsh")?
}

pure url_package(url: Str, sha256: Str) -> types.Package {
  {
    dir: p"packages/demo",
    name: "demo",
    ver: "1.0",
    rel: "1",
    kind: types.Meta,
    deps: [],
    runtime_only_deps: [],
    mkdeps_host: [],
    mkdeps_target: [],
    upstream_sources: [
      {
        source: fp"{url}",
        kind: types.Auto,
        architectures: [
          "all",
        ],
        checksums: [
          {
            arch: "all",
            sha256,
          },
        ],
      },
    ],
    filetree: [],
    nostrip: false,
    source_mirror: false,
    architectures: ["aarch64", "x86_64"],
  }
}

type DemoTarball = {path: Path, sha256: Str}

# A one-file source tarball and its sha256.
proc demo_tarball(
  ctx: TestContext,
  name: Str,
  text: Str = "hello from the cache\n",
) [fs, error] -> Result[DemoTarball] {
  let tree = test.temp_dir(ctx, name: f"{name}-tree")?
  fs.mkdir(fp"{tree}/demo-1.0")?
  fs.write(fp"{tree}/demo-1.0/hello.txt", text)?
  let tarball = test.temp_path(ctx, name: f"{name}.tar.gz")
  archive.tar_create(tarball, tree, [p"demo-1.0"])?
  {path: tarball, sha256: hash.sha256(tarball)?.hex()}
}

proc expect_stage_error(pkg: types.Package, src: Path, expected: List[Str]) [fs, net, env, error] {
  match sources.stage_package_sources(pkg, src) {
    Ok(_) => test.fail("staging unexpectedly succeeded")?
    Err(problem) => {
      for text in expected {
        assert text in problem.message
      }
    }
  }
}

test test_url_source_stages_from_a_cache_hit_without_network [fs, net, env, error] { |ctx|
  let tarball = demo_tarball(ctx, "cache-hit")?
  let cache = test.temp_dir(ctx, name: "cache-hit-cache")?
  let entry = sources.source_cache_entry(cache, tarball.sha256)
  fs.mkdir(entry.parent)?
  fs.copy(tarball.path, entry)?
  let src = test.temp_dir(ctx, name: "cache-hit-src")?

  env ({LAPUTA_SOURCE_CACHE: cache.display(), LAPUTA_MIRROR: "", XSH_PM_TARGET_ARCH: "aarch64"}) {
    sources.stage_package_sources(url_package("https://upstream.invalid/demo-1.0.tar.gz", tarball.sha256), src)?
  }?

  assert fs.read_text(fp"{src}/hello.txt")? == "hello from the cache\n"
}

test test_url_source_fills_the_cache_from_the_local_mirror [fs, net, env, error] { |ctx|
  let tarball = demo_tarball(ctx, "mirror-fill")?
  let mirror = test.temp_dir(ctx, name: "mirror-fill-mirror")?
  let served = fp"{mirror}/sources/sha256/{tarball.sha256}"
  fs.mkdir(served.parent)?
  fs.copy(tarball.path, served)?
  let cache = test.temp_dir(ctx, name: "mirror-fill-cache")?
  let src = test.temp_dir(ctx, name: "mirror-fill-src")?

  # The mirror serves the cache layout by sha256; a `file://` mirror exercises
  # the same resolution order and verification as the HTTP one.
  env ({LAPUTA_SOURCE_CACHE: cache.display(), LAPUTA_MIRROR: f"file://{mirror}/", XSH_PM_TARGET_ARCH: "aarch64"}) {
    sources.stage_package_sources(url_package("https://upstream.invalid/demo-1.0.tar.gz", tarball.sha256), src)?
  }?

  assert fs.read_text(fp"{src}/hello.txt")? == "hello from the cache\n"
  assert hash.sha256(sources.source_cache_entry(cache, tarball.sha256))?.hex() == tarball.sha256
}

test test_missing_url_source_without_a_mirror_says_to_run_make_fetch [fs, net, env, error] { |ctx|
  let cache = test.temp_dir(ctx, name: "missing-cache")?
  let src = test.temp_dir(ctx, name: "missing-src")?

  env ({LAPUTA_SOURCE_CACHE: cache.display(), LAPUTA_MIRROR: "", XSH_PM_TARGET_ARCH: "aarch64"}) {
    expect_stage_error(
      url_package("https://upstream.invalid/demo-1.0.tar.gz", sha256_of_empty),
      src,
      ["https://upstream.invalid/demo-1.0.tar.gz", sha256_of_empty, "is not in the source cache", "make fetch"],
    )?
  }?

  assert sources.source_cache_entry(cache, sha256_of_empty).exists()? == false
}

test test_unreachable_http_mirror_is_asked_by_content_address [fs, net, env, error] { |ctx|
  let cache = test.temp_dir(ctx, name: "unreachable-cache")?
  let src = test.temp_dir(ctx, name: "unreachable-src")?

  env ({LAPUTA_SOURCE_CACHE: cache.display(), LAPUTA_MIRROR: "http://127.0.0.1:9", XSH_PM_TARGET_ARCH: "aarch64"}) {
    expect_stage_error(
      url_package("https://upstream.invalid/demo-1.0.tar.gz", sha256_of_empty),
      src,
      [f"http://127.0.0.1:9/sources/sha256/{sha256_of_empty}", "make fetch"],
    )?
  }?

  assert sources.source_cache_entry(cache, sha256_of_empty).exists()? == false
}

test test_mirror_bytes_with_the_wrong_sha256_never_enter_the_cache [fs, net, env, error] { |ctx|
  let tarball = demo_tarball(ctx, "mirror-mismatch")?
  let mirror = test.temp_dir(ctx, name: "mirror-mismatch-mirror")?
  let served = fp"{mirror}/sources/sha256/{sha256_of_empty}"
  fs.mkdir(served.parent)?
  fs.copy(tarball.path, served)?
  let cache = test.temp_dir(ctx, name: "mirror-mismatch-cache")?
  let src = test.temp_dir(ctx, name: "mirror-mismatch-src")?

  env ({LAPUTA_SOURCE_CACHE: cache.display(), LAPUTA_MIRROR: f"file://{mirror}", XSH_PM_TARGET_ARCH: "aarch64"}) {
    expect_stage_error(
      url_package("https://upstream.invalid/demo-1.0.tar.gz", sha256_of_empty),
      src,
      [f"expected sha256 {sha256_of_empty}, got {tarball.sha256}"],
    )?
  }?

  assert sources.source_cache_entry(cache, sha256_of_empty).exists()? == false
}

test test_corrupt_cache_entry_fails_checksum_verification [fs, net, env, error] { |ctx|
  let pinned = demo_tarball(ctx, "corrupt-pinned")?
  let impostor = demo_tarball(ctx, "corrupt-impostor", "other bytes\n")?
  let cache = test.temp_dir(ctx, name: "corrupt-entry-cache")?
  let entry = sources.source_cache_entry(cache, pinned.sha256)
  fs.mkdir(entry.parent)?
  # A well-formed archive with other bytes: only checksum verification can reject it.
  fs.copy(impostor.path, entry)?
  let src = test.temp_dir(ctx, name: "corrupt-entry-src")?

  env ({LAPUTA_SOURCE_CACHE: cache.display(), LAPUTA_MIRROR: "", XSH_PM_TARGET_ARCH: "aarch64"}) {
    expect_stage_error(
      url_package("https://upstream.invalid/demo-1.0.tar.gz", pinned.sha256),
      src,
      [f"expected {pinned.sha256}"],
    )?
  }?

  assert (fs.children(src)? |> count()) == 0
}

test test_url_sources_must_pin_a_sha256 [error] {
  match sources.pinned_url_sha256("demo", "https://upstream.invalid/demo.tar.gz", "SKIP") {
    Ok(_) => test.fail("SKIP unexpectedly pinned a URL source")?
    Err(problem) => assert "SKIP is only for repository-local sources" in problem.message
  }

  match sources.pinned_url_sha256("demo", "https://upstream.invalid/demo.tar.gz", "ABC") {
    Ok(_) => test.fail("a malformed sha256 unexpectedly pinned a URL source")?
    Err(problem) => assert "malformed sha256" in problem.message
  }

  assert sources.mirror_source_url("http://127.0.0.1:3000/", "abc") == "http://127.0.0.1:3000/sources/sha256/abc"
}

test test_source_placeholders_expand_only_as_whole_words [error] {
  let pkg = {...url_package("", sha256_of_empty), name: "tailscale", ver: "1.96.4"}

  assert util.expand_source("https://h/tailscale_VERSION_GOARCH.tgz", pkg, "aarch64", "aarch64") == "https://h/tailscale_1.96.4_arm64.tgz"
  assert util.expand_source("https://h/vMAJOR.MINOR/x-VERSION-ARCH.tar.xz", pkg, "x86_64", "x86_64") == "https://h/v1.96/x-1.96.4-x86_64.tar.xz"
  assert util.expand_source("TARGET_ARCH BUILD_ARCH TARGET_TRIPLE", pkg, "x86_64", "aarch64") == "x86_64 aarch64 x86_64-linux-musl"
  # Words that merely contain a placeholder stay as written.
  assert util.expand_source("PATCHES/SEARCH/ARCHIVE/PACKAGES", pkg, "aarch64", "aarch64") == "PATCHES/SEARCH/ARCHIVE/PACKAGES"
  assert util.expand_source("PATCH-PACKAGE", pkg, "aarch64", "aarch64") == "4-tailscale"
  # Substituted values are not rescanned for placeholders.
  test.eq(util.expand_source("VERSION", {...pkg, ver: "ARCH"}, "aarch64", "aarch64"), "ARCH")?
}

test test_local_repositories_are_loopback_or_file_trees [error] {
  assert util.is_local_repo_url("http://127.0.0.1:3000")
  assert util.is_local_repo_url("http://localhost:3000/")
  assert util.is_local_repo_url("file:///srv/repo")
  assert ! util.is_local_repo_url("https://127.0.0.1:3000")
  assert ! util.is_local_repo_url("http://127.0.0.1.example.test")
  assert ! util.is_local_repo_url("https://packages.example.test")
}

proc fetch_repository(ctx: TestContext, sources_text: Str) [fs, error] -> Result[Path] {
  let root = test.temp_dir(ctx, name: "fetch-repository")?
  let recipe = fp"{root}/packages/fetchdemo/PKGBUILD.xsh"
  fs.mkdir(recipe.parent)?
  fs.write(
    recipe,
    f"""##! Fetch fixture metapackage.
## Package name.
export let name = "fetchdemo"
## Package kind.
export let package_kind = "meta"
## Package version.
export let ver = "1.0"
## Package release.
export let rel = "1"
## Runtime dependencies.
export let deps = []
## Build-host dependencies.
export let mkdeps_host = []
## Pinned sources.
export let upstream_sources = [{sources_text}]
## No payload.
export let filetree = []
""",
  )?
  root
}

pure fetch_source_record(url: Str, sha256: Str) -> Str {
  f"""{{source: p"{url}", kind: "file", architectures: ["all"], checksums: [{{arch: "all", sha256: "{sha256}"}}]}},"""
}

test test_sources_fetch_caches_pins_and_reports_dead_and_mismatched_urls [fs, process, env, error] { |ctx|
  let upstream = test.temp_dir(ctx, name: "fetch-upstream")?
  fs.write(fp"{upstream}/good-1.0.txt", "good bytes\n")?
  fs.write(fp"{upstream}/changed.txt", "bytes that changed upstream\n")?
  let good_sha256 = hash.sha256(fp"{upstream}/good-1.0.txt")?.hex()
  let repository = fetch_repository(
    ctx,
    [
      fetch_source_record(f"file://{upstream}/good-VERSION.txt", good_sha256),
      fetch_source_record(f"file://{upstream}/gone.txt", "1111111111111111111111111111111111111111111111111111111111111111"),
      fetch_source_record(f"file://{upstream}/changed.txt", sha256_of_empty),
      fetch_source_record("files/local.txt", "SKIP"),
    ].join(" "),
  )?
  let cache = test.temp_dir(ctx, name: "fetch-cache")?
  let xsh = runner()?
  let modules = path.absolute(p".")?
  let argv = ["sources", "fetch", "--repo", repository.display(), "--all", "--target", "aarch64-linux-musl"]

  let first = run.capture --text XSH_MODULE_PATH=$modules LAPUTA_SOURCE_CACHE=$cache $xsh pm.xsh -- @argv ?
  assert first.status.ok == false
  assert "fetched" in first.stderr
  assert "dead fetchdemo" in first.stderr
  assert "gone.txt: missing file" in first.stderr
  assert f"mismatch fetchdemo: file://{upstream}/changed.txt: expected sha256 {sha256_of_empty}" in first.stderr
  assert "0 cached" in first.stdout
  assert "1 fetched" in first.stdout
  assert "2 failed" in first.stdout
  assert fs.read_text(sources.source_cache_entry(cache, good_sha256))? == "good bytes\n"
  assert sources.source_cache_entry(cache, sha256_of_empty).exists()? == false

  let second = run.capture --text XSH_MODULE_PATH=$modules LAPUTA_SOURCE_CACHE=$cache $xsh pm.xsh -- sources fetch --repo $repository fetchdemo ?
  assert "1 cached" in second.stdout
  assert "0 fetched" in second.stdout
}

test test_repo_checksum_reads_upstream_and_caches_the_new_pin [fs, process, env, error] { |ctx|
  let upstream = test.temp_dir(ctx, name: "checksum-upstream")?
  fs.write(fp"{upstream}/new-1.0.txt", "new upstream bytes\n")?
  let new_sha256 = hash.sha256(fp"{upstream}/new-1.0.txt")?.hex()
  # The recorded pin is stale; `repo checksum` reports what upstream serves now.
  let repository = fetch_repository(ctx, fetch_source_record(f"file://{upstream}/new-VERSION.txt", sha256_of_empty))?
  let cache = test.temp_dir(ctx, name: "checksum-cache")?
  let xsh = runner()?
  let modules = path.absolute(p".")?

  let cwd = test.temp_dir(ctx, name: "checksum-cwd")?
  let entrypoint = fp"{modules}/pm.xsh"
  var output = ""

  cd $cwd {
    output = run.text XSH_MODULE_PATH=$modules LAPUTA_SOURCE_CACHE=$cache XSH_PM_TARGET_ARCH=aarch64 $xsh $entrypoint -- repo checksum --repo $repository fetchdemo ?
  } ?

  assert output.trim() == f"fetchdemo {new_sha256}"
  assert fs.read_text(sources.source_cache_entry(cache, new_sha256))? == "new upstream bytes\n"
  # The download is staged in a private temporary directory, never the caller's cwd.
  assert (fs.children(cwd)? |> count()) == 0
}

# A Cargo.lock in the current format: a workspace member without `source`,
# crates.io named by both of its index forms, and multi-line dependency lists.
pure crate_set_lock(crates: List[sources.LockedCrate]) -> Str {
  var lines = [
    "# This file is automatically @generated by Cargo.",
    "version = 4",
    "",
    "[[package]]",
    "name = \"workspace-member\"",
    "version = \"0.1.0\"",
    "dependencies = [",
    " \"demo_crate\",",
    "]",
  ]
  var index = 0

  for item in crates {
    let source = if index % 2 == 0 {
      "registry+https://github.com/rust-lang/crates.io-index"
    } else {
      "sparse+https://index.crates.io/"
    }
    lines = lines.extend(
      [
        "",
        "[[package]]",
        f"name = \"{item.name}\"",
        f"version = \"{item.version}\"",
        f"source = \"{source}\"",
        f"checksum = \"{item.checksum}\"",
        "dependencies = [",
        " \"libc\",",
        "]",
      ],
    )
    index += 1
  }

  lines.join("\n") + "\n"
}

type DemoCrate = {item: sources.LockedCrate, path: Path}

# A `.crate` archive: one `NAME-VERSION/` directory, as crates.io packs it.
proc demo_crate(ctx: TestContext, name: Str, version: Str) [fs, error] -> Result[DemoCrate] {
  let tree = test.temp_dir(ctx, name: f"{name}-crate-tree")?
  fs.mkdir(fp"{tree}/{name}-{version}/src")?
  fs.write(fp"{tree}/{name}-{version}/Cargo.toml", f"[package]\nname = \"{name}\"\nversion = \"{version}\"\n")?
  fs.write(fp"{tree}/{name}-{version}/src/lib.rs", "")?
  let tarball = test.temp_path(ctx, name: f"{name}-{version}.tar.gz")
  archive.tar_create(tarball, tree, [fp"{name}-{version}"])?
  {item: {name, version, checksum: hash.sha256(tarball)?.hex()}, path: tarball}
}

proc cache_file(cache: Path, file: Path) [fs, error] -> Result[Str] {
  let sha256 = hash.sha256(file)?.hex()
  let entry = sources.source_cache_entry(cache, sha256)
  fs.mkdir(entry.parent)?
  fs.copy(file, entry, overwrite: true)?
  sha256
}

pure crate_set_package(lock_url: Str, lock_sha256: Str) -> types.Package {
  let base = url_package(lock_url, lock_sha256)
  {
    ...base,
    upstream_sources: [
      {
        source: fp"{lock_url} => vendor",
        kind: types.source_cargo_vendor(),
        architectures: [
          "all",
        ],
        checksums: [
          {
            arch: "all",
            sha256: lock_sha256,
          },
        ],
      },
    ],
  }
}

test test_cargo_lock_names_its_crates_io_crate_set [fs, error] { |ctx|
  let crates = [
    {name: "demo_crate", version: "0.1.0", checksum: "1111111111111111111111111111111111111111111111111111111111111111"},
    {name: "zstd-sys", version: "2.0.15+zstd.1.5.7", checksum: "2222222222222222222222222222222222222222222222222222222222222222"},
  ]
  let lockfile = test.temp_path(ctx, name: "Cargo.lock")
  fs.write(lockfile, crate_set_lock(crates))?

  test.eq(sources.cargo_lock_crates(lockfile)?, crates)?
  assert sources.crate_download_url(crates[1]) == "https://static.crates.io/crates/zstd-sys/zstd-sys-2.0.15+zstd.1.5.7.crate"
}

test test_cargo_lock_rejects_crates_without_a_content_address [fs, error] { |ctx|
  let lockfile = test.temp_path(ctx, name: "Cargo.lock")
  fs.write(
    lockfile,
    """version = 4

[[package]]
name = "forked"
version = "0.1.0"
source = "git+https://example.invalid/forked?rev=abc#abc"
""",
  )?

  match sources.cargo_lock_crates(lockfile) {
    Ok(_) => test.fail("a git dependency was accepted as a vendored crate")?
    Err(problem) => assert "forked 0.1.0 comes from git+https://example.invalid/forked" in problem.message
  }

  fs.write(
    lockfile,
    """[[package]]
name = "old"
version = "0.1.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
""",
  )?

  match sources.cargo_lock_crates(lockfile) {
    Ok(_) => test.fail("a crate without a checksum was accepted")?
    Err(problem) => assert "old 0.1.0 has no sha256 checksum" in problem.message
  }
}

test test_cargo_vendor_source_stages_cached_crates_as_a_directory_source [fs, net, env, error] { |ctx|
  let crate_file = demo_crate(ctx, "demo_crate", "0.1.0")?
  let cache = test.temp_dir(ctx, name: "crate-set-cache")?
  let lockfile = test.temp_path(ctx, name: "Cargo.lock")
  fs.write(lockfile, crate_set_lock([crate_file.item]))?
  let lock_sha256 = cache_file(cache, lockfile)?
  let src = test.temp_dir(ctx, name: "crate-set-src")?
  let pkg = crate_set_package("https://upstream.invalid/Cargo.lock", lock_sha256)

  # Every crate resolves before anything is extracted: an uncached crate
  # fails the whole source and names the fix.
  env ({LAPUTA_SOURCE_CACHE: cache.display(), LAPUTA_MIRROR: "", XSH_PM_TARGET_ARCH: "aarch64"}) {
    expect_stage_error(pkg, src, [sources.crate_download_url(crate_file.item), "make fetch"])?
  }?

  assert (fs.children(src)? |> count()) == 0
  assert cache_file(cache, crate_file.path)? == crate_file.item.checksum

  env ({LAPUTA_SOURCE_CACHE: cache.display(), LAPUTA_MIRROR: "", XSH_PM_TARGET_ARCH: "aarch64"}) {
    sources.stage_package_sources(pkg, src)?
  }?

  let vendored = fp"{src}/vendor/demo_crate-0.1.0"
  assert "name = \"demo_crate\"" in fs.read_text(fp"{vendored}/Cargo.toml")?
  let marker = fs.read_text(fp"{vendored}/.cargo-checksum.json")?
  assert json.decode(marker)? == json.decode(f"""{{"files": {{}}, "package": "{crate_file.item.checksum}"}}""")?
}

test test_sources_fetch_reads_the_cached_lockfile_for_its_crates [fs, process, env, error] { |ctx|
  let crate_file = demo_crate(ctx, "demo_crate", "0.1.0")?
  let upstream = test.temp_dir(ctx, name: "crate-set-upstream")?
  fs.write(fp"{upstream}/Cargo.lock", crate_set_lock([crate_file.item]))?
  let lock_sha256 = hash.sha256(fp"{upstream}/Cargo.lock")?.hex()
  let repository = fetch_repository(
    ctx,
    f"""{{source: p"file://{upstream}/Cargo.lock => vendor", kind: "cargo-vendor", architectures: ["all"], checksums: [{{arch: "all", sha256: "{lock_sha256}"}}]}},""",
  )?
  # The crate is already cached, so the crate pass finds it without
  # contacting crates.io.
  let cache = test.temp_dir(ctx, name: "crate-set-fetch-cache")?
  let _ = cache_file(cache, crate_file.path)?
  let xsh = runner()?
  let modules = path.absolute(p".")?

  let output = run.text XSH_MODULE_PATH=$modules LAPUTA_SOURCE_CACHE=$cache $xsh pm.xsh -- sources fetch --repo $repository --all --target aarch64-linux-musl ?

  assert "0 cached 1 fetched" in output
  assert "1 cached 0 fetched" in output
  assert sources.source_cache_entry(cache, lock_sha256).exists()?
}

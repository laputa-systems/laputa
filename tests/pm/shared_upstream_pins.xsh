##! Contract coverage for shared package upstream pins.
use pm.fingerprint
use pm.recipe
use pm.types
use pm.util

pure serialized_source(source: types.UpstreamSource) -> Record {
  {
    source: source.source.display(),
    kind: types.source_kind_text(source.kind),
    architectures: source.architectures,
    checksums: [{arch: checksum.arch, sha256: checksum.sha256} for checksum in source.checksums],
  }
}

proc serialized_sources(pkg: types.Package) -> Result[Str] {
  json.encode([serialized_source(source) for source in pkg.upstream_sources])?
}

pure expanded_sources(pkg: types.Package, arch: Str) -> List[Str] {
  [util.expand_source(source.source.display(), pkg, arch, arch) for source in pkg.upstream_sources]
}

test test_rust_distribution_sources_keep_the_loaded_records_and_target_urls [fs, env, error] {
  let root = path.absolute(p".")?
  let cargo_aarch64 = recipe.load_package_for_target(fp"{root}/packages/cargo", types.target_aarch64())?
  let cargo_x86_64 = recipe.load_package_for_target(fp"{root}/packages/cargo", types.target_x86_64())?
  let doas_aarch64 = recipe.load_package_for_target(fp"{root}/packages/doas-rs", types.target_aarch64())?
  let doas_x86_64 = recipe.load_package_for_target(fp"{root}/packages/doas-rs", types.target_x86_64())?

  assert cargo_aarch64.ver == "1.99.0"
  assert cargo_x86_64.ver == "1.99.0"
  assert doas_aarch64.ver == "0.1.0"
  assert doas_x86_64.ver == "0.1.0"
  assert serialized_sources(cargo_aarch64)? == serialized_sources(cargo_x86_64)?
  assert serialized_sources(doas_aarch64)? == serialized_sources(doas_x86_64)?
  let expected_cargo_rust_std = {
    source: "https://static.rust-lang.org/dist/2026-10-01/rust-std-VERSION-ARCH-unknown-linux-musl.tar.xz => rust-std",
    kind: "auto",
    architectures: ["all"],
    checksums: [
      {arch: "aarch64", sha256: "ea8fd309578a09c9e12401621a470e6d6b1047f25933207fb8a39d66647d4561"},
      {arch: "x86_64", sha256: "b106b0aa4565cc3525fd3161c69203a9e39044e6e6b4d618f261c3eeda14ad50"},
    ],
  }
  let expected_doas_rust_std = {
    source: "https://static.rust-lang.org/dist/2026-10-01/rust-std-1.99.0-ARCH-unknown-linux-musl.tar.xz => rust-std",
    kind: "auto",
    architectures: ["all"],
    checksums: [
      {arch: "aarch64", sha256: "ea8fd309578a09c9e12401621a470e6d6b1047f25933207fb8a39d66647d4561"},
      {arch: "x86_64", sha256: "b106b0aa4565cc3525fd3161c69203a9e39044e6e6b4d618f261c3eeda14ad50"},
    ],
  }
  let expected_cargo_sources = [
    {
      source: "https://static.rust-lang.org/dist/2026-10-01/cargo-VERSION-ARCH-unknown-linux-musl.tar.xz => cargo",
      kind: "auto",
      architectures: ["all"],
      checksums: [
        {arch: "aarch64", sha256: "bef13b92330b96e493ad9e3d15d2bf1ceade4a62e2501a6c06e9614acc2d1463"},
        {arch: "x86_64", sha256: "0f60a28de17fc24ac3a12e23a298cc3f9caf82c2fdd44e47232db6e2fcb421eb"},
      ],
    },
    {
      source: "https://static.rust-lang.org/dist/2026-10-01/rustc-VERSION-ARCH-unknown-linux-musl.tar.xz => rustc",
      kind: "auto",
      architectures: ["all"],
      checksums: [
        {arch: "aarch64", sha256: "678c660838d055a7beca6af6b06ce79e7596e15fb73bd854f6bde8aa6800b09f"},
        {arch: "x86_64", sha256: "fa4fa63f0bf10fad6665f40004d8848b19cf15c98c72668e49afb05bb11bba5a"},
      ],
    },
    expected_cargo_rust_std,
  ]
  let expected_doas_sources = [
    {
      source: "repository/doas-rs",
      kind: "auto",
      architectures: ["all"],
      checksums: [
        {arch: "all", sha256: "SKIP"},
      ],
    },
    {
      source: "repository/doas-rs/Cargo.lock => vendor",
      kind: "cargo-vendor",
      architectures: ["all"],
      checksums: [
        {arch: "all", sha256: "SKIP"},
      ],
    },
    expected_doas_rust_std,
  ]

  assert serialized_sources(cargo_aarch64)? == json.encode(expected_cargo_sources)?
  assert serialized_sources(doas_aarch64)? == json.encode(expected_doas_sources)?
  assert expanded_sources(cargo_aarch64, "aarch64") == [
    "https://static.rust-lang.org/dist/2026-10-01/cargo-1.99.0-aarch64-unknown-linux-musl.tar.xz => cargo",
    "https://static.rust-lang.org/dist/2026-10-01/rustc-1.99.0-aarch64-unknown-linux-musl.tar.xz => rustc",
    "https://static.rust-lang.org/dist/2026-10-01/rust-std-1.99.0-aarch64-unknown-linux-musl.tar.xz => rust-std",
  ]
  assert expanded_sources(cargo_x86_64, "x86_64") == [
    "https://static.rust-lang.org/dist/2026-10-01/cargo-1.99.0-x86_64-unknown-linux-musl.tar.xz => cargo",
    "https://static.rust-lang.org/dist/2026-10-01/rustc-1.99.0-x86_64-unknown-linux-musl.tar.xz => rustc",
    "https://static.rust-lang.org/dist/2026-10-01/rust-std-1.99.0-x86_64-unknown-linux-musl.tar.xz => rust-std",
  ]
  assert util.expand_source(doas_aarch64.upstream_sources[2].source.display(), doas_aarch64, "aarch64", "aarch64") ==
    "https://static.rust-lang.org/dist/2026-10-01/rust-std-1.99.0-aarch64-unknown-linux-musl.tar.xz => rust-std"
  assert util.expand_source(doas_x86_64.upstream_sources[2].source.display(), doas_x86_64, "x86_64", "x86_64") ==
    "https://static.rust-lang.org/dist/2026-10-01/rust-std-1.99.0-x86_64-unknown-linux-musl.tar.xz => rust-std"

  let rust_std = cargo_aarch64.upstream_sources[2]
  let changed_rust_std = {
    ...rust_std,
    checksums: [
      {...rust_std.checksums[0], sha256: "changed-aarch64"},
      rust_std.checksums[1],
    ],
  }
  let changed_cargo = {
    ...cargo_aarch64,
    upstream_sources: [cargo_aarch64.upstream_sources[0], cargo_aarch64.upstream_sources[1], changed_rust_std],
  }
  let arm_target = types.target_aarch64()
  let x86_target = types.target_x86_64()
  let arm_key = fingerprint.package_build_input(root, cargo_aarch64, arm_target)?
  let x86_key = fingerprint.package_build_input(root, cargo_aarch64, x86_target)?

  assert fingerprint.package_build_input(root, changed_cargo, arm_target)? != arm_key
  assert fingerprint.package_build_input(root, changed_cargo, x86_target)? == x86_key
}

test test_kernel_source_record_and_release_are_shared_by_all_recipes [fs, env, error] {
  let root = path.absolute(p".")?
  let linux_aarch64 = recipe.load_package_for_target(fp"{root}/packages/linux", types.target_aarch64())?
  let linux_x86_64 = recipe.load_package_for_target(fp"{root}/packages/linux", types.target_x86_64())?
  let headers_aarch64 = recipe.load_package_for_target(fp"{root}/packages/linux-headers", types.target_aarch64())?
  let headers_x86_64 = recipe.load_package_for_target(fp"{root}/packages/linux-headers", types.target_x86_64())?
  let perf_aarch64 = recipe.load_package_for_target(fp"{root}/packages/perf", types.target_aarch64())?
  let perf_x86_64 = recipe.load_package_for_target(fp"{root}/packages/perf", types.target_x86_64())?
  let expected_kernel_source = {
    source: "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.9.tar.xz",
    kind: "auto",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "b4c5dfbe51a364a6c7f03869200f88c8e1f77403539005f14b7fc6bc91b8d8ba"}],
  }

  for pkg in [linux_aarch64, linux_x86_64, headers_aarch64, headers_x86_64, perf_aarch64, perf_x86_64] {
    assert pkg.ver == "7.2.9"
    assert json.encode(serialized_source(pkg.upstream_sources[0]))? == json.encode(expected_kernel_source)?
  }

  assert serialized_sources(linux_aarch64)? == serialized_sources(linux_x86_64)?
  assert serialized_sources(headers_aarch64)? == serialized_sources(headers_x86_64)?
  assert serialized_sources(perf_aarch64)? == serialized_sources(perf_x86_64)?

  let source = headers_aarch64.upstream_sources[0]
  let changed_source = {
    ...source,
    checksums: [{...source.checksums[0], sha256: "changed-kernel-source"}],
  }
  let changed_headers = {...headers_aarch64, upstream_sources: [changed_source]}
  let arm_target = types.target_aarch64()
  let x86_target = types.target_x86_64()
  let arm_key = fingerprint.package_build_input(root, headers_aarch64, arm_target)?
  let x86_key = fingerprint.package_build_input(root, headers_x86_64, x86_target)?

  assert fingerprint.package_build_input(root, changed_headers, arm_target)? != arm_key
  assert fingerprint.package_build_input(root, changed_headers, x86_target)? != x86_key
}

##! XSH module `PKGBUILD` package and build operations.
use pm.util as pm_util

## Exported declaration `name`.
export const name = "cargo"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "1.99.0"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl", "llvm-toolchain", "gnu-stubs"]

## Exported declaration `mkdeps_host`.
export let mkdeps_host = []

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://static.rust-lang.org/dist/2026-10-01/cargo-VERSION-ARCH-unknown-linux-musl.tar.xz => cargo",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: "bef13b92330b96e493ad9e3d15d2bf1ceade4a62e2501a6c06e9614acc2d1463",
      },
      {
        arch: "x86_64",
        sha256: "0f60a28de17fc24ac3a12e23a298cc3f9caf82c2fdd44e47232db6e2fcb421eb",
      },
    ],
  },
  {
    source: p"https://static.rust-lang.org/dist/2026-10-01/rustc-VERSION-ARCH-unknown-linux-musl.tar.xz => rustc",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: "678c660838d055a7beca6af6b06ce79e7596e15fb73bd854f6bde8aa6800b09f",
      },
      {
        arch: "x86_64",
        sha256: "fa4fa63f0bf10fad6665f40004d8848b19cf15c98c72668e49afb05bb11bba5a",
      },
    ],
  },
  {
    source: p"https://static.rust-lang.org/dist/2026-10-01/rust-std-VERSION-ARCH-unknown-linux-musl.tar.xz => rust-std",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: "ea8fd309578a09c9e12401621a470e6d6b1047f25933207fb8a39d66647d4561",
      },
      {
        arch: "x86_64",
        sha256: "b106b0aa4565cc3525fd3161c69203a9e39044e6e6b4d618f261c3eeda14ad50",
      },
    ],
  },
]

## Exported declaration `nostrip`.
export const nostrip = true

const filetree_common = [
  {
    path: p"usr",
    kind: "tree",
  },
  {
    path: p"usr/bin/cargo",
    kind: "binary",
  },
  {
    path: p"usr/bin/rustc",
    kind: "binary",
  },
  {
    path: p"usr/bin/rustdoc",
    kind: "binary",
  },
  {
    path: p"usr/libexec/rust-analyzer-proc-macro-srv",
    kind: "binary",
  },
]

## Exported declaration `filetree_aarch64`.
export let filetree_aarch64 = filetree_common.extend(
  [
    {
      path: p"usr/lib/libdarling_macro-d6978fef7579dccc.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/libderive_setters-ba6bc1dc5b468d5c.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/libderive_where-f897ec00d6c7f23d.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/libdisplaydoc-04e3f2abf422740f.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/libproc_macro_hack-7e5da98310311669.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/libref_cast_impl-16df6c8b9fad173d.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/librustc_driver-a2ce9fb5b33aa5ca.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/librustc_index_macros-33541610b68e12aa.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/librustc_macros-48756471b91ca1a3.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/librustc_type_ir_macros-7f5c458537fcd1c9.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/libschemars_derive-ebce058871707d10.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/libserde_derive-9a8cb41715523100.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/libthiserror_impl-f0385dad4558faa1.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/libtracing_attributes-baa11dbab12a5c78.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/libunic_langid_macros_impl-85f6ed71e6bb6b22.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/libyoke_derive-bfe79b329fa69c84.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/libzerofrom_derive-6247a042ffdb8bd3.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/libzerovec_derive-d8fa9eff5fd8e6b0.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/lib/libstd-d4518673a6ad1c78.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/bin/gcc-ld/ld.lld",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/bin/gcc-ld/ld64.lld",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/bin/gcc-ld/lld-link",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/bin/gcc-ld/wasm-ld",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/bin/rust-lld",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/bin/rust-objcopy",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/bin/wasm-component-ld",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/lib/self-contained/Scrt1.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/lib/self-contained/crt1.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/lib/self-contained/crtbegin.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/lib/self-contained/crtbeginS.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/lib/self-contained/crtend.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/lib/self-contained/crtendS.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/lib/self-contained/crti.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/lib/self-contained/crtn.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/aarch64-unknown-linux-musl/lib/self-contained/rcrt1.o",
      kind: "binary",
    },
  ],
)

## Exported declaration `filetree_x86_64`.
export let filetree_x86_64 = filetree_common.extend(
  [
    {
      path: p"usr/lib/librustc_driver-fd7b847dfb04f3e6.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/lib/libstd-135dbb91b6c04a5d.so",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/bin/gcc-ld/ld.lld",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/bin/gcc-ld/ld64.lld",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/bin/gcc-ld/lld-link",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/bin/gcc-ld/wasm-ld",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/bin/rust-lld",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/bin/rust-objcopy",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/bin/wasm-component-ld",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/lib/self-contained/Scrt1.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/lib/self-contained/crt1.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/lib/self-contained/crtbegin.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/lib/self-contained/crtbeginS.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/lib/self-contained/crtend.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/lib/self-contained/crtendS.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/lib/self-contained/crti.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/lib/self-contained/crtn.o",
      kind: "binary",
    },
    {
      path: p"usr/lib/rustlib/x86_64-unknown-linux-musl/lib/self-contained/rcrt1.o",
      kind: "binary",
    },
  ],
)

## Exported declaration `filetree`.
export let filetree = filetree_aarch64

pure rust_dist_arch(arch: Str) -> Str {
  return "aarch64" when arch == "arm64"

  return "x86_64" when arch == "amd64"

  arch
}

## Exported declaration `build`.
export proc build(dest: Path) [fs, env, error] {
  let arch = rust_dist_arch(pm_util.target_arch()?)
  var cargo_src = p"cargo/cargo"
  var rustc_src = p"rustc/rustc"
  var rust_std_src = fp"rust-std/rust-std-{arch}-unknown-linux-musl"

  if ! cargo_src.exists() {
    cargo_src = fp"cargo/cargo-{ver}-{arch}-unknown-linux-musl/cargo"
  }

  if ! rustc_src.exists() {
    rustc_src = fp"rustc/rustc-{ver}-{arch}-unknown-linux-musl/rustc"
  }

  if ! rust_std_src.exists() {
    rust_std_src = fp"rust-std/rust-std-{ver}-{arch}-unknown-linux-musl/rust-std-{arch}-unknown-linux-musl"
  }

  var copied = fs.copy_tree(cargo_src, fp"{dest}/usr", parents: true, overwrite: true)?
  copied = fs.copy_tree(rustc_src, fp"{dest}/usr", parents: true, overwrite: true)?
  copied = fs.copy_tree(rust_std_src, fp"{dest}/usr", parents: true, overwrite: true)?
  let _ = copied
}

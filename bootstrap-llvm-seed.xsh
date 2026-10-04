#!/bin/xsh
# Verified bootstrap LLVM seed assembly before the package artifact graph can run.
# The typed build policy deliberately models musl -> llvm-toolchain as an external
# bootstrap edge: the first compiler must exist before a BuildPlan can rebuild musl.
# This adapter is therefore limited to the prebuilt LLVM seed. It uses the normal
# typed recipe boundary and source verifier, but does not masquerade as a completed
# package artifact or root generation.
use pm.recipe
use pm.sources

proc main(repo_root: Path, dest: Path) [fs, net, process, env, time, error] {
  let pkg = recipe.load_package(fp"${repo_root}/packages/llvm-toolchain")?
  let work_handle = fs.tempdir()?
  defer work_handle.close()?
  let work = work_handle.host_path()?
  let src = fp"${work}/source"

  fs.mkdir(src)?
  sources.prepare_package_source_tree(pkg, src)?
  recipe.call_prepare(pkg, src)?
  fs.remove(dest, missing_ok: true)?
  fs.mkdir(dest)?
  recipe.call_build(pkg, src, dest)?
}

main(@args)?

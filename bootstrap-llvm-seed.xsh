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
  let pkg = recipe.load_package(fp"${repo_root}/repo/llvm-toolchain")?
  let work_handle = fs.tempdir()?
  defer fs.close_root(work_handle)?
  let work = fs.root_path(work_handle)?
  let src = fp"${work}/source"

  fs.mkdir(src)?
  sources.prepare_package_source_tree(work, work, pkg, src, false, false, false)?
  recipe.call_prepare(pkg, src)?
  fs.remove(dest, missing_ok: true)?
  fs.mkdir(dest)?
  recipe.call_build(pkg, src, dest)?
}

main(@args)?

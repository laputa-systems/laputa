#!/bin/xsh
use pm.recipe
use pm.sources

proc main(repo_root: Path, source_cache: Path, dest: Path) [fs, net, process, env, time, error] {
  let pkg = recipe.load_package(fp"{repo_root}/packages/llvm-toolchain")?
  tempdir work {
    let src = fp"{work}/source"

    src.mkdir()
    env ({LAPUTA_SOURCE_CACHE: source_cache.display()}) {
      sources.prepare_package_source_tree(pkg, src)
    }
    recipe.call_prepare(pkg, src)
    dest.remove()
    dest.mkdir()
    recipe.call_build(pkg, src, dest)
  }
}

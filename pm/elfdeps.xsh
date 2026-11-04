##! PM elfdeps operations and shared package-manager policy.
use elf
use local
use util

## Why the loader cannot satisfy a DT_NEEDED entry from the package's runtime
## dependency closure: it names a build-time path, no installed package
## provides it, or the providing package is not a runtime dependency.
export enum ElfDependencyGap { BuildTimePath, Unprovided, Undeclared(Str) }

## Exported PM declaration `ElfDependencyFailure`.
export type ElfDependencyFailure = {pkg: Str, file: Path, soname: Str, gap: ElfDependencyGap}

const musl_loader_libraries = ["c", "pthread", "rt", "m", "dl", "util", "xnet"]

# musl's dynamic linker (ldso/dynlink.c) resolves `lib<name>.<anything>` for
# its reserved library names to itself, so `libc.musl-x86_64.so.1` and
# `libm.so.6` need only musl.
pure musl_loader_soname(soname: Str) -> Bool {
  for name in musl_loader_libraries {
    return true when soname.starts_with(f"lib{name}.")
  }

  false
}

pure path_basename_text(path_value: Path) -> Str {
  let text = path_value.display()
  let parts = text.split("/")
  parts.get(parts.len() - 1) ?? text
}

pure path_may_provide_library(rel_path: Path) -> Bool {
  let text = rel_path.display()
  (text.starts_with("lib/") or text.starts_with("usr/lib/")) and ".so" in path_basename_text(rel_path)
}

## Exported PM declaration `elf_info_mentions_musl`.
export pure elf_info_mentions_musl(needed: List[Str], interpreter: Str) -> Bool {
  return true when "ld-musl-" in interpreter

  "libc.so" in needed
}

## Exported PM declaration `runtime_dependency_closure`.
export pure runtime_dependency_closure(initial: List[Str], package_deps: Map[List[Str]]) -> Map[Bool] {
  var closure: Map[Bool] = {}
  var pending = initial
  var index = 0

  while index < pending.len() {
    let name = pending[index]
    index += 1
    continue when closure.get(name) ?? false
    closure[name] = true

    if name in package_deps {
      pending += package_deps.get(name) ?? []
    }
  }

  closure
}

## Exported PM declaration `missing_elf_runtime_dependencies`.
export pure missing_elf_runtime_dependencies(
  pkg_name: Str,
  deps: List[Str],
  needed: List[Str],
  interpreter: Str,
  providers: Map[Str],
) -> List[ElfDependencyFailure] {
  var allowed = {dep: true for dep in deps}
  missing_elf_runtime_dependencies_with_allowed(pkg_name, allowed, needed, interpreter, providers)
}

## Exported PM declaration `missing_elf_runtime_dependencies_with_allowed`.
export pure missing_elf_runtime_dependencies_with_allowed(
  pkg_name: Str,
  allowed: Map[Bool],
  needed: List[Str],
  interpreter: Str,
  providers: Map[Str],
) -> List[ElfDependencyFailure] {
  var failures: List[ElfDependencyFailure] = []

  if elf_info_mentions_musl(needed, interpreter) and pkg_name != "musl" and ! (allowed.get("musl") ?? false) {
    failures += [{pkg: pkg_name, file: fp"", soname: "libc.so", gap: .Undeclared("musl")}]
  }

  for soname in needed {
    # A DT_NEEDED path comes from linking a library by its build-time path
    # (one without a SONAME); the loader looks for that path, not a name, so
    # no runtime root satisfies it.
    if "/" in soname {
      failures += [{pkg: pkg_name, file: fp"", soname, gap: .BuildTimePath}]
      continue
    }

    guard let provider = providers.get(soname) else {
      failures += [{pkg: pkg_name, file: fp"", soname, gap: .Unprovided}] unless musl_loader_soname(soname)
      continue
    }

    if provider != pkg_name and ! (allowed.get(provider) ?? false) {
      failures += [{pkg: pkg_name, file: fp"", soname, gap: .Undeclared(provider)}]
    }
  }

  failures
}

proc library_link_reaches_file(root: Path, link: Path) [fs, error] -> Result[Bool, Error] {
  var current = link
  for _ in range(8) {
    return false unless current.exists()?
    return current.is_file()? unless current.is_symlink()?
    let target = current.readlink()?.display()
    current = if target.starts_with("/") { fp"{root}{target}" } else { fp"{current.parent}/{target}" }
  }

  false
}

## Exported PM declaration `collect_library_providers`.
export proc collect_library_providers(root: Path) [fs, error] -> Result[Map[Str], Error] {
  var providers: Map[Str] = {}
  let packages_db = util.packages_db_path(root)

  return providers unless packages_db.exists()

  let entries = fs.children(packages_db)
    |> where .kind == "dir"
    |> sort-by .name

  for entry in entries {
    let manifest = local.load_manifest(entry.path)?

    for rel_path in manifest {
      let path_value = fp"{root}/{rel_path}"

      if path_value.is_symlink()? {
        if path_may_provide_library(rel_path) and library_link_reaches_file(root, path_value)? {
          providers[path_basename_text(rel_path)] = entry.name
        }
        continue
      }

      continue unless path_value.exists()
      continue unless path_value.is_file()

      if let Ok(info) = elf.inspect(path_value) {
        if info.soname != "" {
          providers[info.soname] = entry.name
        } else if path_may_provide_library(rel_path) {
          providers[path_basename_text(rel_path)] = entry.name
        }
      } else {
        if path_may_provide_library(rel_path) {
          providers[path_basename_text(rel_path)] = entry.name
        }
      }
    }
  }

  providers
}

## Exported PM declaration `installed_file_elf_dependency_failures`.
export proc installed_file_elf_dependency_failures(
  pkg_name: Str,
  allowed: Map[Bool],
  rel_path: Path,
  path_value: Path,
  providers: Map[Str],
) [fs, error] -> Result[List[ElfDependencyFailure], Error] {
  return [] when path_value.is_symlink()

  if let Ok(info) = elf.inspect(path_value) {
    var failures = missing_elf_runtime_dependencies_with_allowed(
      pkg_name,
      allowed,
      info.needed,
      info.interpreter,
      providers,
    )

    failures = [
      {pkg: failure.pkg, file: rel_path, soname: failure.soname, gap: failure.gap}
      for failure in failures
    ]
    failures
  } else {
    []
  }
}

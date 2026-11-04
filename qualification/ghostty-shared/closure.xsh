use elf
use pm.elfdeps
use pm.local
use pm.proof

type Provider = {package: Str, path: Path, soname: Str}
type Consumer = {package: Str, path: Path, needed: List[Str], interpreter: Str}

cli main(root: Path) {
  let packages = fs.children(fp"{root}/var/lib/xsh-pm/packages")
    |> where .kind == "dir"
    |> sort-by .name
  var providers = elfdeps.collect_library_providers(root)?
  var owners: Map[Str] = {}
  var dependencies: Map[List[Str]] = {}
  var libraries: List[Provider] = []
  var consumers: List[Consumer] = []

  for package in packages {
    let metadata = json.read(fp"{package.path}/metadata.json")?.require(Record)?
    dependencies[package.name] = metadata.get("deps")?.require(List[Str])?
    for rel in local.load_manifest(package.path)? {
      let file_path = fp"{root}/{rel}"
      continue when file_path.is_symlink()
      continue unless file_path.is_file()
      let info = elf.inspect(file_path)?
      continue when info.class == ""
      proof.ensure(info.rpath == "" and info.runpath == "", "font-closure", f"{package.name}/{rel} has a private library search path")
      owners[file_path.resolve()?.display()] = package.name
      if info.soname != "" {
        libraries += [{package: package.name, path: rel, soname: info.soname}]
      }
      consumers += [{package: package.name, path: rel, needed: info.needed, interpreter: info.interpreter}]
    }
  }

  for package in packages {
    for rel in local.load_manifest(package.path)? {
      continue unless rel.display().starts_with("usr/lib/") or rel.display().starts_with("lib/")
      let parts = rel.display().split("/")
      let basename = parts.get(parts.len() - 1) ?? ""
      continue unless ".so" in basename
      let file_path = fp"{root}/{rel}"
      continue unless file_path.is_symlink()
      let owner = owners.get(file_path.resolve()?.display()) ?? ""
      continue when owner == ""
      providers[basename] = owner
    }
  }

  for expected in [
    {package: "freetype", soname: "libfreetype.so.6"},
    {package: "harfbuzz", soname: "libharfbuzz.so.0"},
    {package: "fontconfig", soname: "libfontconfig.so.1"},
  ] {
    let matches = libraries |> where .soname == expected.soname
    proof.ensure(matches.len() == 1, "font-closure", f"{expected.soname} has {matches.len()} providers")
    proof.ensure(matches[0].package == expected.package, "font-closure", f"{expected.soname} belongs to {matches[0].package}")
    let loader_target = fp"{root}/usr/lib/{expected.soname}".resolve()?
    let provider_target = fp"{root}/{matches[0].path}".resolve()?
    proof.ensure(loader_target == provider_target, "font-closure", f"{expected.soname} resolves to a different provider")
    print f"{expected.soname}: {matches[0].package}/{matches[0].path}"
  }

  for consumer in consumers {
    let allowed = elfdeps.runtime_dependency_closure(dependencies.get(consumer.package) ?? [], dependencies)
    let failures = elfdeps.missing_elf_runtime_dependencies_with_allowed(consumer.package, allowed, consumer.needed, consumer.interpreter, providers)
    proof.ensure(failures.is_empty(), "font-closure", f"{consumer.package}/{consumer.path} has {failures.len()} undeclared runtime dependencies")
    for soname in consumer.needed {
      proof.ensure(soname in providers, "font-closure", f"{consumer.package}/{consumer.path} needs unresolved {soname}")
    }
  }
  let ghostty = consumers |> where .package == "ghostty-custom" and .path == p"usr/bin/ghostty-custom"
  proof.ensure(ghostty.len() == 1, "font-closure", "missing Ghostty executable")
  for soname in ["libfreetype.so.6", "libharfbuzz.so.0", "libfontconfig.so.1"] {
    proof.ensure(soname in ghostty[0].needed, "font-closure", f"Ghostty does not import {soname}")
  }
  proof.ensure((libraries |> where .package == "ghostty-custom").is_empty(), "font-closure", "Ghostty distributes a shared library")
  print f"font closure verified: {packages.len()} packages, {consumers.len()} ELF files"
}

use elf
use pm.elfdeps
use pm.local
use pm.proof

type Component = {name: Str, language: Str, version: Str, origin: Str, markers: List[Str]}
type Unknown = {subject: Str, evidence: Str, settle: Str}
type Binary = {package: Str, path: Str, needed: List[Str], runpath: Str, components: List[Component], absent: List[Str], unknown: List[Unknown]}
type Provider = {package: Str, language: Str, retention: Str, role: Str}
type Archive = {file: Str, component: Str}
type PlaySymbols = {binary_buildid_note: Str, archives: List[Archive], max_unattributed_native_bytes: Int}
type Spec = {providers: List[Provider], binaries: List[Binary], play_symbols: PlaySymbols}
type Symbol = {name: Str, size: Int}

pure normalize_symbol(name: Str) -> Str {
  rx"\.(constprop|isra|part|cold|lto_priv|localalias)(\.[0-9]+)*$".replace(name, with: "")
}

pure is_rust_symbol(name: Str) -> Bool {
  name.starts_with("_R") or rx"17h[0-9a-f]{16}E$".matches(name)
}

proc nm_tool() [fs, process, env, error] -> Result[Path, Error] {
  if let Ok(tool) = process.which("nm") {
    return tool
  }
  process.which("llvm-nm")?
}

proc build_id(binary: Path) [fs, process, env, error] -> Result[Str, Error] {
  let readelf = proof.readelf_tool()?
  let notes = run.text $readelf "-n" $binary
  for line in notes.lines() {
    if let [_, id] = rx"Build ID: ([0-9a-f]+)".captures(line) {
      return id
    }
  }
  Err(proof.ProofError.Failed(kind: "native-census", message: f"{binary} has no build ID"))
}

proc defined_symbols(binary: Path, sized: Bool) [fs, process, env, error] -> Result[List[Symbol], Error] {
  let nm = nm_tool()?
  let result = if sized {
    run.capture --text $nm "-S" "--radix=d" "--defined-only" $binary
  } else {
    run.capture --text $nm "--defined-only" $binary
  }
  proof.ensure(result.status.success, "native-census/symbols", f"nm failed on {binary}")
  let listing = result.stdout
  var symbols: List[Symbol] = []
  for line in listing.lines() {
    let fields = line.fields()
    if sized and fields.len() == 4 {
      symbols += [{name: normalize_symbol(fields[3]), size: fields[1].parse_uint()?}]
    } else if sized == false and fields.len() == 3 {
      symbols += [{name: normalize_symbol(fields[2]), size: 0}]
    }
  }
  symbols
}

proc strings_of(file: Path) [fs, error] -> Result[List[Str], Error] {
  file.read_bytes()?.strings(min_len: 6)
}

proc found_markers(strings: List[Str], wanted: List[Str]) -> Map[Bool] {
  var found: Map[Bool] = {}
  for text in strings {
    for marker in wanted {
      if marker not in found and marker in text {
        found[marker] = true
      }
    }
  }
  found
}

proc census_binary(root: Path, spec: Binary, providers: Map[Str]) [fs, error] {
  let file = fp"{root}/{spec.path}"
  let kind = f"native-census/{spec.package}"
  proof.ensure(file.is_file()?, kind, f"{spec.path} is not installed")
  let info = elf.inspect(file.resolve()?)?
  print f"binary {spec.package}:{spec.path} {fs.stat(file)?.size} bytes"
  let actual = info.needed.join(" ")
  let expected = spec.needed.join(" ")
  proof.ensure(actual == expected, kind, f"NEEDED is [{actual}], expected [{expected}]")
  proof.ensure(info.runpath == spec.runpath and info.rpath == "", kind, f"RUNPATH is {info.runpath} and RPATH is {info.rpath}")
  for soname in info.needed {
    continue when soname.starts_with("libc.musl-")
    let owner = providers.get(soname) ?? ""
    proof.ensure(owner != "", kind, f"{soname} has no provider in the root")
    print f"  shared {soname} <- {owner}"
  }
  var wanted: List[Str] = spec.absent
  for component in spec.components {
    wanted += component.markers
  }
  let found = found_markers(strings_of(file)?, wanted)
  for component in spec.components {
    for marker in component.markers {
      proof.ensure(marker in found, kind, f"{component.name} lost marker {marker}")
    }
    print f"  static {component.name} [{component.language}] {component.version}: {component.origin}"
  }
  for marker in spec.absent {
    proof.ensure(marker not in found, kind, f"unexpected marker {marker}")
  }
  for item in spec.unknown {
    proof.ensure(item.evidence != "" and item.settle != "", kind, f"unknown {item.subject} lacks evidence or a settling step")
    print f"  unknown {item.subject}: {item.evidence}. Settle: {item.settle}"
  }
}

cli main census(root: Path, spec: Path = p"qualification/native-census/components.json", plan: Path = p"") {
  let packages = fs.children(fp"{root}/var/lib/xsh-pm/packages")
    |> where .kind == "dir"
    |> sort-by .name
  let table = json.read(spec)?.require(Spec)?
  let providers = elfdeps.collect_library_providers(root)?
  var dependencies: Map[List[Str]] = {}
  var installed: Map[Int] = {}
  var elf_packages: Map[Int] = {}
  var elf_count = 0
  var linked_edges: Map[Bool] = {}
  for package in packages {
    let metadata = json.read(fp"{package.path}/metadata.json")?.require(Record)?
    dependencies[package.name] = metadata.get("deps")?.require(List[Str])?
    for rel in local.load_manifest(package.path)? {
      let file_path = fp"{root}/{rel}"
      continue when file_path.is_symlink()
      continue unless file_path.is_file()
      let resolved = file_path.resolve()?.display()
      installed[resolved] = fs.stat(file_path)?.size
      let info = elf.inspect(file_path)?
      continue when info.class == ""
      elf_count += 1
      for soname in info.needed {
        let owner = providers.get(soname) ?? ""
        linked_edges[f"{package.name} {owner}"] = true
      }
      elf_packages[package.name] = (elf_packages.get(package.name) ?? 0) + 1
    }
  }
  var total_bytes = 0
  for size in installed.values() {
    total_bytes += size
  }
  print f"root {root}: {packages.len()} packages, {installed.len()} unique regular files, {total_bytes} bytes, {elf_count} ELF files"
  for package in packages {
    let count = elf_packages.get(package.name) ?? 0
    continue when count == 0
    let matches = table.providers |> where .package == package.name
    proof.ensure(matches.len() == 1, "native-census", f"{package.name} ships {count} ELF files and has {matches.len()} provider entries")
    print f"provider {package.name} [{matches[0].language}] {matches[0].retention}: {count} ELF files, {matches[0].role}"
  }
  for package in packages {
    let count = elf_packages.get(package.name) ?? 0
    continue when count == 0
    for dependency in dependencies[package.name] {
      continue when dependency == "musl" or f"{package.name} {dependency}" in linked_edges
      print f"declared without an ELF edge: {package.name} -> {dependency}"
    }
  }
  for entry in table.providers {
    proof.ensure(entry.package in dependencies, "native-census", f"provider entry {entry.package} is not installed")
  }
  if plan != p"" {
    let nodes = json.read(plan)?.require(Record)?.get("nodes")?.require(List[Record])?
    var not_installed: List[Str] = []
    for node in nodes {
      let name = node.get("name")?.require(Str)?
      not_installed += [name] unless name in dependencies
    }
    let joined = not_installed.join(" ")
    print f"planned but not installed: {not_installed.len()}: {joined}"
  }
  for binary in table.binaries {
    census_binary(root, binary, providers)
  }
  print f"native census verified: {table.binaries.len()} binaries"
}

cli main symbols(stripped: Path, unstripped: Path, spec: Path = p"qualification/native-census/components.json", archive_dirs: List[Path] = []) {
  let table = json.read(spec)?.require(Spec)?.play_symbols
  let kind = "native-census/symbols"
  proof.ensure(build_id(stripped)? == build_id(unstripped)?, kind, "the stripped and unstripped binaries differ")
  var owner: Map[Str] = {}
  for item in table.archives {
    var location = p""
    for directory in archive_dirs {
      let candidate = fp"{directory}/{item.file}"
      if location == p"" and candidate.exists() {
        location = candidate
      }
    }
    proof.ensure(location != p"", kind, f"{item.file} is in none of the archive directories")
    for symbol in defined_symbols(location, false)? {
      owner[symbol.name] = owner.get(symbol.name) ?? item.component
    }
  }
  var attributed: Map[Int] = {}
  var counts: Map[Int] = {}
  var rust = 0
  var unattributed = 0
  for symbol in defined_symbols(unstripped, true)? {
    let component = owner.get(symbol.name) ?? ""
    if component != "" {
      attributed[component] = (attributed.get(component) ?? 0) + symbol.size
      counts[component] = (counts.get(component) ?? 0) + 1
    } else if is_rust_symbol(symbol.name) {
      rust += symbol.size
    } else {
      unattributed += symbol.size
    }
  }
  var native = 0
  for component in attributed.keys() |> sort {
    print f"component {component}: {counts[component]} symbols, {attributed[component]} bytes"
    native += attributed[component]
  }
  print f"rust: {rust} bytes"
  print f"unattributed non-Rust: {unattributed} bytes"
  proof.ensure(native > 0, kind, "no symbol matched an archive")
  proof.ensure(unattributed <= table.max_unattributed_native_bytes, kind, f"{unattributed} unattributed native bytes exceed {table.max_unattributed_native_bytes}")
  print f"statically linked native symbols: {native} bytes"
}

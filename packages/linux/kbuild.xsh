##! XSH module `kbuild` package and build operations.
use pm.make

## Exported declaration `ScriptError`.
export error ScriptError = Failed(kind: Str, message: Str)

## Exported declaration `Kconfig`.
export type Kconfig = {enabled: Map[Bool], values: Map[Str]}

## Exported declaration `CompositeObject`.
export type CompositeObject = {object: Path, members: List[Path]}

## Exported declaration `ArchiveOwner`.
export type ArchiveOwner = {object: Path, dir: Path}

## Exported declaration `KbuildPlan`.
export type KbuildPlan = {
  dirs: List[Path],
  objects: List[Path],
  lib_objects: List[Path],
  archive_owners: List[ArchiveOwner],
  composites: List[CompositeObject],
  unsupported: List[Str],
}

## Exported declaration `BuiltinArchivePlan`.
export type BuiltinArchivePlan = {
  tasks: List[make.MakeTask],
  task_specs: List[Record],
  task_count: Int,
  archives: List[Path],
  link_inputs: List[Path],
  missing_sources: List[Path],
  generated_objects: List[Path],
  duplicate_outputs: List[Path],
}

## Serialized compile flags for one object, or `*` for a directory default.
export type CompileFlagsEntry = {dir: Str, object: Str, flags: List[Str]}

## Serialized archive owner shared by scan records and archive-analysis contexts.
export type ArchiveOwnerRecord = {object: Str, dir: Str}

## Serialized composite object shared by scan records and archive-analysis contexts.
export type CompositeRecord = {object: Str, members: List[Str]}

## Serialized Kbuild plan carried by directory scan records.
export type PlanRecord = {
  dirs: List[Str],
  objects: List[Str],
  lib_objects: List[Str],
  archive_owners: List[ArchiveOwnerRecord],
  composites: List[CompositeRecord],
  unsupported: List[Str],
}

## Serialized directory scan exchanged with discovery workers and the local-record cache.
export type ScanRecord = {dir: Str, file_hash: Str, plan: PlanRecord, child_dirs: List[Str], entries: List[Str]}

## Shared discovery-worker pool state guarded by the pool lock file.
export type PoolState = {pending: List[Str], active: Int, done: Bool, seen: List[Str], error: Str}

## Archive-analysis plan context shared with analysis workers.
export type ArchivePlanContext = {
  dirs: List[Str],
  objects: List[Str],
  lib_objects: List[Str],
  archive_owners: List[ArchiveOwnerRecord],
  composites: List[CompositeRecord],
}

## Archive-analysis compile flags shared with analysis workers.
export type ArchiveAnalysisFlags = {flags: List[CompileFlagsEntry]}

## Archive-analysis worker input for one object slice.
export type ArchiveAnalysisInput = {
  context: Str,
  start: Int,
  end: Int,
  flags: Str,
  emit_task_specs: Bool,
  cc: Str,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
}

## Archive-analysis input for one planned object or composite.
export type ArchiveAnalysisItem = {
  object: Str,
  owner: Str,
  library: Bool,
  pi: Bool,
  composite: Str,
  member_objects: List[Str],
  member_flags: List[List[Str]],
  flags: List[Str],
}

## Archive-analysis output for one item; task specs keep their kind-specific shape.
export type ArchiveAnalysisResult = {
  object: Str,
  owner: Str,
  library: Bool,
  tasks: List[Record],
  task_count: Int,
  archive_outputs: List[Str],
  archive_deps: List[Str],
  has_pi: Bool,
  link_inputs: List[Str],
  generated_objects: List[Str],
  missing_sources: List[Str],
}

# A compile task spec as emitted for materialized archive plans.
type ArchiveCompileTaskSpec = {source: Str, output: Str, argv: List[Str], depfile: Str, stamp: Str}

# A position-independent object spec: its base compile, then objcopy and the
# relocation check derived from `base` and `output`.
type ArchivePiTaskSpec = {base: Str, output: Str, base_task: ArchiveCompileTaskSpec}

type CompileFlagsCache = {format: Str, fingerprint: Str, flags: List[CompileFlagsEntry]}

type LocalRecordCache = {format: Str, key: Str, records: List[ScanRecord]}

type ArchiveTaskRecord = {
  name: Str,
  outputs: List[Str],
  inputs: List[Str],
  deps: List[Str],
  argv: List[Str],
  env: Record,
  cwd: Str,
  depfile: Str,
  stamp: Str,
}

type ArchivePlanSummaryFile = {
  archives: List[Str],
  link_inputs: List[Str],
  generated_objects: List[Str],
  missing_sources: List[Str],
  duplicate_outputs: List[Str],
  task_count: Int,
}

type ArchivePlanTasksFile = {tasks: List[ArchiveTaskRecord]}

## Exported declaration `DiscoverOptions`.
export type DiscoverOptions = {
  progress: Bool,
  progress_every: Int,
  jobs: Int,
  local_records: Bool,
  local_record_cache: Bool,
  build_plan: Bool,
}

type DiscoverState = {plan: KbuildPlan, seen: Map[Bool], visited: Int}

type DirScan = {dir: Path, plan: KbuildPlan, child_dirs: List[Path], entries: List[Path]}

type AggregateBarriers = {builtin_archive: Path, module_order: Path}

type LocalRecordGraph = {records: Map[DirScan], barriers: Map[AggregateBarriers], plan: KbuildPlan}

type DiscoverScans = {records: Map[DirScan], plan: KbuildPlan}

type KbuildSource = {file: Path, body: Str}

type ActiveDirObjects = {dir: Path, objects: List[Path]}

type ArchiveInputs = {objs: List[Path], deps: List[Str]}

type CompositeScan = {dir: Path, composites: List[CompositeObject]}

## x86 jump-label patch counts reported by the helper.
export type JumpLabelPatchResult = {scanned: Int, objects: Int, patches: Int}

type ParsedAssignment = {lhs: Str, op: Str, rhs: Str}

type ItemResult = {plan: KbuildPlan, dirs: List[Path], entries: List[Path]}

pure regex_captures(text: Str, pattern: Str) -> Result[List[Str]] {
  let re = regex.compile(pattern)?
  re.captures(text)
}

pure empty_plan() -> KbuildPlan {
  {
    dirs: [],
    objects: [],
    lib_objects: [],
    archive_owners: [],
    composites: [],
    unsupported: [],
  }
}

pure default_discover_options() -> DiscoverOptions {
  {
    progress: false,
    progress_every: 100,
    jobs: 1,
    local_records: false,
    local_record_cache: false,
    build_plan: true,
  }
}

## Exported declaration `planner_jobs`.
export pure planner_jobs() -> Int {
  let count = cpu.count()

  return 1 when count < 1

  count
}

proc root_vars(srcarch: Str) -> Map[Str] {
  var vars: Map[Str] = {}
  vars["ARCH_CORE"] = ""
  vars["ARCH_DRIVERS"] = ""
  vars["srctree"] = "."

  if srcarch == "arm64" {
    vars["ARCH_LIB"] = "lib/ arch/arm64/lib/"
  } else {
    vars["ARCH_DRIVERS"] = "arch/x86/pci/ arch/x86/power/ arch/x86/video/"
    vars["ARCH_LIB"] = "lib/ arch/x86/lib/"
    vars["BITS"] = "64"
  }

  vars
}

proc global_vars(srcarch: Str) -> Map[Str] {
  var vars: Map[Str] = {}
  vars["srctree"] = "."

  if srcarch == "x86" {
    vars["BITS"] = "64"
  }

  vars
}

proc kbuild_vars_for_dir(dir: Path, srcarch: Str) -> Map[Str] {
  let dir_key = path_key(dir)
  var vars = if dir_key == "." { root_vars(srcarch) } else { global_vars(srcarch) }
  vars["src"] = dir_key
  vars["obj"] = dir_key
  vars
}

pure path_key(path_value: Path) -> Str {
  let key = path_value.display()

  return "." when key == ""

  key
}

pure has_plan_path(paths: List[Path], path_value: Path) -> Bool {
  let key = path_key(path_value)

  for item in paths {
    return true when path_key(item) == key
  }

  false
}

pure add_dir(plan: KbuildPlan, dir: Path) -> KbuildPlan {
  return plan when has_plan_path(plan.dirs, dir)

  var dirs = plan.dirs
  dirs += [dir]
  {...plan, dirs: dirs}
}

pure add_object(plan: KbuildPlan, obj: Path) -> KbuildPlan {
  add_object_at(plan, obj, object_dir(obj))
}

pure add_object_at(plan: KbuildPlan, obj: Path, owner: Path) -> KbuildPlan {
  return plan when has_plan_path(plan.objects, obj)

  var objects = plan.objects
  objects += [obj]
  var owners = plan.archive_owners
  owners += [{object: obj, dir: owner}]
  {
    ...plan,
    objects: objects,
    archive_owners: owners,
  }
}

pure add_lib_object_at(plan: KbuildPlan, obj: Path, owner: Path) -> KbuildPlan {
  return plan when has_plan_path(plan.lib_objects, obj)

  var objects = plan.lib_objects
  objects += [obj]
  var owners = plan.archive_owners
  owners += [{object: obj, dir: owner}]
  {
    ...plan,
    lib_objects: objects,
    archive_owners: owners,
  }
}

pure add_composite(plan: KbuildPlan, composite: CompositeObject) -> KbuildPlan {
  let key = path_key(composite.object)

  for item in plan.composites {
    return plan when path_key(item.object) == key
  }

  var composites = plan.composites
  composites += [composite]
  {...plan, composites: composites}
}

pure add_unsupported(plan: KbuildPlan, message: Str) -> KbuildPlan {
  var unsupported = plan.unsupported
  unsupported += [message]
  {...plan, unsupported: unsupported}
}

proc merge_plan(base: KbuildPlan, addition: KbuildPlan) -> KbuildPlan {
  {
    dirs: base.dirs.extend(addition.dirs),
    objects: base.objects.extend(addition.objects),
    lib_objects: base.lib_objects.extend(addition.lib_objects),
    archive_owners: base.archive_owners.extend(addition.archive_owners),
    composites: base.composites.extend(addition.composites),
    unsupported: base.unsupported.extend(addition.unsupported),
  }
}

pure archive_owner_key(owners: Map[Str], obj: Path) -> Path {
  let object_key = path_key(obj)
  let default_owner = path_key(object_dir(obj))
  fp"{owners.get(object_key) ?? default_owner}"
}

pure join_rel(dir: Path, item: Str) -> Path {
  return normalize_rel_path(fp"{item}") when path_key(dir) == "."

  normalize_rel_path(fp"{dir}/{item}")
}

pure join_root(root: Path, rel: Path) -> Path {
  return root when path_key(rel) == "."

  fp"{root}/{rel}"
}

pure normalize_rel_path(path_value: Path) -> Path {
  var parts: List[Str] = []

  for part in path_value.display().split("/") {
    continue when part == "" or part == "."

    if part == ".." {
      if ! parts.is_empty() {
        parts = parts |> take(parts.len() - 1)
      }

      continue
    }

    parts += [part]
  }

  return p"." when parts.is_empty()

  fp"{parts.join("/")}"
}

## Exported declaration `write_text_if_changed`.
export proc write_text_if_changed(path_value: Path, data: Str) [fs, error] {
  path_value.parent.mkdir()

  return when path_value.exists() and path_value.read_text()? == data

  path_value.write(data)
}

## Exported declaration `copy_text_if_changed`.
export proc copy_text_if_changed(source: Path, dest: Path) [fs, error] {
  write_text_if_changed(dest, source.read_text()?)
}

pure dirname_for_item(dir: Path, item: Str) -> Path {
  let caps = regex_captures(item, "^(.*)/$") ?? []

  return join_rel(dir, caps[1]) when caps.len() >= 2

  join_rel(dir, item)
}

pure clean_config_value(raw: Str) -> Str {
  raw.trim().replace("\"", "")
}

pure config_header_value(value: Str) -> Str {
  return "1" when value == "y" or value == "m"

  match value.parse_int() {
    Ok(_) => return value
    Err(_) => {}
  }

  return value when value.starts_with("0x")

  f"\"{value}\""
}

pure config_auto_line(name: Str, value: Str) -> Str {
  return f"CONFIG_{name}=y" when value == "y"

  f"CONFIG_{name}={value}"
}

## Exported declaration `load_config`.
export proc load_config(path_value: Path) [fs, error] -> Result[Kconfig, Error] {
  var enabled: Map[Bool] = {}
  var values: Map[Str] = {}

  for raw in path_value.read_text()?.split("\n") {
    let line = raw.trim()

    if line.starts_with("CONFIG_") and "=" in line {
      # Only the first `=` ends the name: string values such as CONFIG_CMDLINE
      # contain more of them.
      let split_at = line.find("=") ?? 0
      let name = line.byte_slice(0, split_at).replace("CONFIG_", "")
      let value = clean_config_value(line.byte_slice(split_at + 1))
      values[name] = value

      if value == "y" {
        enabled[name] = true
      }
    }
  }

  {enabled: enabled, values: values}
}

pure empty_kconfig() -> Kconfig {
  let enabled: Map[Bool] = {}
  let values: Map[Str] = {}
  {enabled: enabled, values: values}
}

proc load_config_if_present(path_value: Path) -> Result[Kconfig] {
  return load_config(path_value)? when path_value.exists()

  empty_kconfig()
}

## Exported declaration `write_config_headers`.
export proc write_config_headers(config_path: Path, root: Path, release: Str, arch: Str = "arm64") [fs, error] {
  let config = load_config(config_path)?

  var autoconf = [
    "/*",
    " * Automatically generated file; DO NOT EDIT.",
    f" * Linux/{arch} {release} Kernel Configuration",
    " */",
  ]

  var auto_conf = [
    "#",
    "# Automatically generated file; DO NOT EDIT.",
    f"# Linux/{arch} {release} Kernel Configuration",
    "#",
  ]

  for name in config.values.keys() |> sort-by . {
    let value = config.values.get(name) ?? ""
    autoconf += [f"#define CONFIG_{name} {config_header_value(value)}"]
    auto_conf += [config_auto_line(name, value)]
  }

  fp"{root}/include/generated".mkdir()
  fp"{root}/include/config".mkdir()

  write_text_if_changed(
    fp"{root}/include/generated/autoconf.h",
    f"""{autoconf.join("\n")}
""",
  )

  write_text_if_changed(
    fp"{root}/include/config/auto.conf",
    f"""{auto_conf.join("\n")}
""",
  )
}

# linux/version.h for MAJOR.MINOR.SUB, as the top-level Makefile writes it.
proc version_header(release: Str) -> Result[Str] {
  let parts = [part.parse_int()? for part in release.split(".")]

  guard parts.len() == 3 else {
    return Err(ScriptError.Failed(kind: "kbuild-version", message: f"kernel release {release} is not MAJOR.MINOR.SUB"))
  }

  f"""#define LINUX_VERSION_CODE {parts[0] * 65536 + parts[1] * 256 + parts[2]}
#define KERNEL_VERSION(a,b,c) (((a) << 16) + ((b) << 8) + ((c) > 255 ? 255 : (c)))
#define LINUX_VERSION_MAJOR {parts[0]}
#define LINUX_VERSION_PATCHLEVEL {parts[1]}
#define LINUX_VERSION_SUBLEVEL {parts[2]}
"""
}

## Exported declaration `write_build_headers`.
export proc write_build_headers(root: Path, release: Str, arch: Str = "arm64") [fs, error] {
  fp"{root}/include/generated/uapi/linux".mkdir()
  let uts_machine = if arch == "x86" { "x86_64" } else { "aarch64" }

  write_text_if_changed(
    fp"{root}/include/generated/utsrelease.h",
    f"""#define UTS_RELEASE "{release}"
""",
  )

  write_text_if_changed(
    fp"{root}/include/generated/utsversion.h",
    """#define UTS_VERSION "#1 XSH"
""",
  )

  write_text_if_changed(
    fp"{root}/init/utsversion-tmp.h",
    """#define UTS_VERSION "#1 XSH"
""",
  )

  write_text_if_changed(
    fp"{root}/include/generated/compile.h",
    f"""#define UTS_MACHINE "{uts_machine}"
#define LINUX_COMPILE_BY "xsh"
#define LINUX_COMPILE_HOST "xsh"
#define LINUX_COMPILER "clang"
""",
  )

  if arch == "x86" {
    write_text_if_changed(
      fp"{root}/include/generated/vdso-offsets.h",
      """/* x86 vDSO deferred; no offsets yet */
""",
    )
  } else {
    write_text_if_changed(
      fp"{root}/include/generated/vdso-offsets.h",
      """#define vdso_offset_sigtramp 0x058c
""",
    )
  }

  write_text_if_changed(fp"{root}/include/generated/uapi/linux/version.h", version_header(release)?)
}

# The `NAME += header.h` entries of one Kbuild variable.
proc kbuild_header_list(file: Path, variable: Str) -> Result[List[Str]] {
  var names: List[Str] = []

  for line in file.read_text()?.lines() {
    let fields = line.fields()
    continue unless fields.len() == 3 and fields[0] == variable and fields[1] == "+="
    names += [fields[2]]
  }

  names
}

# scripts/Makefile.asm-headers for one asm directory: asm-generic's
# mandatory-y headers the arch does not provide, plus the arch's generic-y,
# minus its generated-y, each become a one-line include of the asm-generic
# header in the arch's generated directory.
proc write_asm_wrapper_dir(root: Path, mandatory_kbuild: Path, arch_dir: Path, generated_dir: Path) {
  let arch_kbuild = fp"{root}/{arch_dir}/Kbuild"
  let arch_lists_exist = arch_kbuild.exists()?
  let generic = if arch_lists_exist { kbuild_header_list(arch_kbuild, "generic-y")? } else { [] }
  let generated = if arch_lists_exist { kbuild_header_list(arch_kbuild, "generated-y")? } else { [] }
  var wanted = generic

  for header in kbuild_header_list(fp"{root}/{mandatory_kbuild}", "mandatory-y")? {
    continue when fp"{root}/{arch_dir}/{header}".exists()
    wanted += [header]
  }

  fp"{root}/{generated_dir}".mkdir()

  for header in wanted {
    continue when header in generated

    write_text_if_changed(
      fp"{root}/{generated_dir}/{header}",
      f"""#include <asm-generic/{header}>
""",
    )
  }
}

## Writes the kernel and uapi asm-generic wrapper headers Kbuild generates for `srcarch`.
export proc write_asm_generic_wrappers(root: Path, srcarch: Str) [fs, error] {
  write_asm_wrapper_dir(
    root,
    p"include/asm-generic/Kbuild",
    fp"arch/{srcarch}/include/asm",
    fp"arch/{srcarch}/include/generated/asm",
  )

  write_asm_wrapper_dir(
    root,
    p"include/uapi/asm-generic/Kbuild",
    fp"arch/{srcarch}/include/uapi/asm",
    fp"arch/{srcarch}/include/generated/uapi/asm",
  )
}

## Writes asm/kernel-hwcap.h from the uapi hwcap.h, as arch/arm64/tools/gen-kernel-hwcaps.sh does:
## one KERNEL_HWCAP_<NAME> per `#define HWCAP<n>_<NAME>`, through __khwcap<n>_feature.
export proc generate_arm64_kernel_hwcaps(root: Path) [fs, error] {
  let define_re = rx"^#define HWCAP[0-9]*_[A-Z0-9_]+"
  let name_re = rx".*HWCAP([0-9]*)_([A-Z0-9_]+).*"
  var lines = ["#ifndef __ASM_KERNEL_HWCAPS_H", "#define __ASM_KERNEL_HWCAPS_H", "", "/* Generated file - do not edit */", ""]

  for line in fp"{root}/arch/arm64/include/uapi/asm/hwcap.h".read_text()?.lines() {
    continue unless define_re.matches(line)

    if let [_, index, name, ..] = name_re.captures(line) {
      lines += [f"#define KERNEL_HWCAP_{name}\t__khwcap{index}_feature({name})"]
    }
  }

  lines += ["", "#endif /* __ASM_KERNEL_HWCAPS_H */"]
  fp"{root}/arch/arm64/include/generated/asm".mkdir()

  write_text_if_changed(
    fp"{root}/arch/arm64/include/generated/asm/kernel-hwcap.h",
    f"""{lines.join("\n")}
""",
  )
}

## Exported declaration `generate_arm64_cpucap_defs`.
export proc generate_arm64_cpucap_defs(root: Path) [fs, error] {
  var lines = [
    "#ifndef __ASM_CPUCAP_DEFS_H",
    "#define __ASM_CPUCAP_DEFS_H",
    "",
    "/* Generated file - do not edit */",
    "",
  ]

  var cap = 0

  for raw in fp"{root}/arch/arm64/tools/cpucaps".read_text()?.split("\n") {
    let line = raw.trim()

    if line != "" and ! line.starts_with("#") {
      lines += [f"#define ARM64_{line} {cap}"]
      cap += 1
    }
  }

  lines += [f"#define ARM64_NCAPS {cap}"]
  lines += [""]
  lines += ["#endif /* __ASM_CPUCAP_DEFS_H */"]
  fp"{root}/arch/arm64/include/generated/asm".mkdir()

  write_text_if_changed(
    fp"{root}/arch/arm64/include/generated/asm/cpucap-defs.h",
    f"""{lines.join("\n")}
""",
  )
}

pure config_value(config: Kconfig, name: Str) -> Str {
  config.values.get(name) ?? ""
}

pure expand_subst(raw: Str, config: Kconfig) -> Str {
  let marker = "$(subst m,y,$(CONFIG_"

  return raw unless marker in raw

  let chunks = raw.split(marker)
  var out = chunks[0]

  for chunk in chunks |> drop(1) {
    let parts = chunk.split("))")

    if parts.len() == 1 {
      out = f"{out}{marker}{chunk}"
    } else {
      let name = parts[0]
      var value = config_value(config, name)

      if value == "m" {
        value = "y"
      }

      out = f"{out}{value}{parts |> drop(1).join("))")}"
    }
  }

  out
}

pure expand_config_refs(raw: Str, config: Kconfig) -> Str {
  let marker = "$(CONFIG_"

  return raw unless marker in raw

  let chunks = raw.split(marker)
  var out = chunks[0]

  for chunk in chunks |> drop(1) {
    let parts = chunk.split(")")

    if parts.len() == 1 {
      out = f"{out}{marker}{chunk}"
    } else {
      out = f"{out}{config_value(config, parts[0])}{parts |> drop(1).join(")")}"
    }
  }

  out
}

pure expand_make_vars(raw: Str, vars: Map[Str]) -> Str {
  let marker = "$("

  return raw unless marker in raw

  let chunks = raw.split(marker)
  var out = chunks[0]

  for chunk in chunks |> drop(1) {
    let parts = chunk.split(")")

    if parts.len() == 1 {
      out = f"{out}{marker}{chunk}"
    } else {
      out = f"{out}{vars.get(parts[0]) ?? ""}{parts |> drop(1).join(")")}"
    }
  }

  out
}

pure expand_braced_config_refs(raw: Str, config: Kconfig) -> Str {
  let marker = "\${CONFIG_"

  return raw unless marker in raw

  let chunks = raw.split(marker)
  var out = chunks[0]

  for chunk in chunks |> drop(1) {
    let parts = chunk.split("}")

    if parts.len() == 1 {
      out = f"{out}{marker}{chunk}"
    } else {
      out = f"{out}{config_value(config, parts[0])}{parts |> drop(1).join("}")}"
    }
  }

  out
}

pure expand_vars(raw: Str, vars: Map[Str], config: Kconfig, srcarch: Str) -> Str {
  return raw when ! ("$(" in raw) and ! ("\${CONFIG_" in raw)

  if ! ("$(subst m,y,$(CONFIG_" in raw) and ! ("$(CONFIG_" in raw) and ! ("$(SRCARCH)" in raw) and ! ("\${CONFIG_" in raw) {
    return expand_make_vars(raw, vars)
  }

  var out = expand_braced_config_refs(expand_subst(raw, config).replace("$(SRCARCH)", srcarch), config)

  return out unless "$(" in out

  out = expand_config_refs(out, config)
  expand_make_vars(out, vars)
}

proc logical_lines(body: Str) -> List[Str] {
  if ! ("#" in body) and ! ("\\" in body) {
    var direct: List[Str] = []

    for raw in body.split("\n") {
      let trimmed = raw.trim()

      if trimmed != "" {
        direct += [trimmed]
      }
    }

    return direct
  }

  var lines: List[Str] = []
  var current = ""

  for raw in body.split("\n") {
    let comment_index = raw.find("#") ?? -1
    let without_comment = if comment_index >= 0 { raw.byte_slice(0, comment_index) } else { raw }
    let trimmed = without_comment.trim()

    if trimmed == "" {
      if current.trim() != "" {
        lines += [current.trim()]
        current = ""
      }

      continue
    }

    if trimmed.ends_with("\\") {
      current = f"{current} {trimmed.replace("\\", "")}"
    } else {
      lines += [f"{current} {trimmed}".trim()]
      current = ""
    }
  }

  if current.trim() != "" {
    lines += [current.trim()]
  }

  lines
}

proc included_kbuild_lines(
  root: Path,
  line: Str,
  vars: Map[Str],
  config: Kconfig,
  srcarch: Str,
) -> Result[List[Str]] {
  guard line.starts_with("include ") else {
    return []
  }

  let raw_spec = (line.split("include ").get(1) ?? "").trim()

  return [] when "$(objtree)" in raw_spec

  let spec = expand_vars(raw_spec, vars, config, srcarch)

  return [] when spec == "" or " " in spec or "$(" in spec or spec.starts_with("/")

  let rel = normalize_rel_path(fp"{spec}")
  logical_lines(join_root(root, rel).read_text()?)
}

pure parse_assignment_at(line: Str, marker: Str, marker_len: Int, index: Int) -> ParsedAssignment {
  {
    lhs: line.byte_slice(0, index).trim(),
    op: marker,
    rhs: line.byte_slice(index + marker_len).trim(),
  }
}

pure parse_assignment(line: Str) -> Result[ParsedAssignment] {
  let append_index = line.find("+=") ?? -1

  return parse_assignment_at(line, "+=", 2, append_index) when append_index >= 0

  let simple_index = line.find(":=") ?? -1

  return parse_assignment_at(line, ":=", 2, simple_index) when simple_index >= 0

  let conditional_index = line.find("?=") ?? -1

  return parse_assignment_at(line, "?=", 2, conditional_index) when conditional_index >= 0

  let assignment_index = line.find("=") ?? -1

  return parse_assignment_at(line, "=", 1, assignment_index) when assignment_index >= 0

  Err(ScriptError.Failed(kind: "kbuild-skip-line", message: line))
}

pure active_obj_lhs(expanded: Str) -> Bool {
  expanded == "obj-y" or expanded == "lib-y" or expanded == "subdir-y"
}

pure active_var_lhs(expanded: Str) -> Str {
  return expanded when expanded == "KVM"

  return expanded when expanded.ends_with("-y")

  return expanded when expanded.ends_with("-objs")

  return expanded when expanded.ends_with("_files")

  ""
}

proc conditional_value(raw: Str, vars: Map[Str], config: Kconfig, srcarch: Str) -> Str {
  let expanded = expand_vars(raw, vars, config, srcarch)

  if expanded.starts_with("CONFIG_") {
    return config_value(config, expanded.replace("CONFIG_", ""))
  }

  expanded
}

proc eval_make_compare(line: Str, keyword: Str, vars: Map[Str], config: Kconfig, srcarch: Str) -> Result[Bool] {
  let prefix = f"{keyword} ("

  if ! line.starts_with(prefix) {
    return Err(ScriptError.Failed(kind: "kbuild-not-conditional", message: line))
  }

  let rest = line.split(prefix).get(1) ?? ""
  let parts = rest.split(",")

  return Err(ScriptError.Failed(kind: "kbuild-not-conditional", message: line)) when parts.len() < 2

  let left = conditional_value(parts[0].trim(), vars, config, srcarch)
  let right = expand_vars(parts |> drop(1).join(",").replace(")", "").trim(), vars, config, srcarch)

  return left == right when keyword == "ifeq"

  left != right
}

proc eval_conditional(line: Str, vars: Map[Str], config: Kconfig, srcarch: Str) -> Result[Bool] {
  if line.starts_with("ifeq ($(CONFIG_") or line.starts_with("ifeq ($(SRCARCH)") or line.starts_with("ifeq ($(BITS)") {
    return eval_make_compare(line, "ifeq", vars, config, srcarch)
  }

  if line.starts_with("ifneq ($(CONFIG_") or line.starts_with("ifneq ($(SRCARCH)") or line.starts_with("ifneq ($(BITS)") {
    return eval_make_compare(line, "ifneq", vars, config, srcarch)
  }

  if line.starts_with("ifdef ") {
    let parts = line.fields()

    return conditional_value(parts[1], vars, config, srcarch) != "" when parts.len() >= 2
  }

  if line.starts_with("ifndef ") {
    let parts = line.fields()

    return conditional_value(parts[1], vars, config, srcarch) == "" when parts.len() >= 2
  }

  Err(ScriptError.Failed(kind: "kbuild-not-conditional", message: line))
}

pure active_conditional(stack: List[Bool]) -> Bool {
  stack[-1]
}

pure object_stem(item: Str) -> Str {
  item.replace(".o", "")
}

pure object_item_for_dir(dir: Path, item: Str, as_lib: Bool = false) -> Str {
  if ! as_lib and path_key(dir) == "arch/x86/boot/startup" and item.ends_with(".o") {
    return f"{object_stem(item)}.pi.o"
  }

  item
}

proc composite_members(dir: Path, item: Str, vars: Map[Str]) -> List[Path] {
  var members: List[Path] = []
  let stem = object_stem(item)

  for member in (vars.get(f"{stem}-y") ?? "").fields() {
    if member.ends_with(".o") {
      members += [join_rel(dir, member)]
    }
  }

  for member in (vars.get(f"{stem}-objs") ?? "").fields() {
    if member.ends_with(".o") {
      members += [join_rel(dir, member)]
    }
  }

  unique_paths(members)
}

stream active_objects_for_dir(dir: Path, vars: Map[Str]) -> Stream[Path] {
  var objects: List[Path] = []
  var words = (vars.get("obj-y") ?? "").fields()
  words += (vars.get("lib-y") ?? "").fields()

  for item in words {
    let active_item = object_item_for_dir(dir, item)

    if active_item.ends_with(".o") {
      let obj = join_rel(dir, active_item)

      if ! has_plan_path(objects, obj) {
        objects += [obj]
        yield obj
      }

      for member in composite_members(dir, active_item, vars) {
        if ! has_plan_path(objects, member) {
          objects += [member]
          yield member
        }
      }
    }
  }

  for obj in extra_objects_for_dir(dir) {
    if ! has_plan_path(objects, obj) {
      objects += [obj]
      yield obj
    }
  }
}

pure extra_objects_for_dir(dir: Path) -> List[Path] {
  if path_key(dir) == "arch/x86/entry/vdso/vdso64" {
    return [join_rel(dir, "vdso64-image.o")]
  }

  []
}

pure plan_objects(plan: KbuildPlan) -> List[Path] {
  plan.objects.extend(plan.lib_objects)
}

proc vars_for_dir(root: Path, dir: Path, config: Kconfig, srcarch: Str) -> Result[Map[Str]] {
  let file = kbuild_file(join_root(root, dir))?
  var vars = kbuild_vars_for_dir(dir, srcarch)
  var active_stack = [true]
  var lines = logical_lines(file.read_text()?)
  var line_index = 0

  while line_index < lines.len() {
    let line = lines[line_index]
    line_index += 1

    if line.starts_with("ifeq ") or line.starts_with("ifneq ") or line.starts_with("ifdef ") or line.starts_with(
      "ifndef ",
    ) {
      if let Ok(active) = eval_conditional(line, vars, config, srcarch) {
        active_stack += [active_conditional(active_stack) and active]
        continue
      }
    }

    if line == "else" {
      let parent = if active_stack.len() > 1 { active_stack[-2] } else { true }
      let current = active_conditional(active_stack)
      active_stack = active_stack |> take(active_stack.len() - 1).push(parent and ! current)
      continue
    }

    if line == "endif" {
      if active_stack.len() > 1 {
        active_stack = active_stack |> take(active_stack.len() - 1)
      }

      continue
    }

    continue unless active_conditional(active_stack)

    if line.starts_with("include ") {
      let included = included_kbuild_lines(root, line, vars, config, srcarch)?
      lines = [@lines |> take(line_index), @included, @lines |> drop(line_index)]
      continue
    }

    if let Ok(assign) = parse_assignment(line) {
      let expanded_lhs = expand_vars(assign.lhs, vars, config, srcarch)
      let lhs = active_var_lhs(expanded_lhs)

      if lhs != "" {
        if path_key(dir) == "arch/x86/boot/startup" and lhs == "obj-y" and assign.rhs.starts_with(
          "$(patsubst %.o,%.pi.o,$(obj-y))",
        ) {
          var rewritten = [object_item_for_dir(dir, item) for item in (vars.get("obj-y") ?? "").fields()]
          vars[lhs] = rewritten.join(" ")
          continue
        }

        let rhs = expand_vars(assign.rhs, vars, config, srcarch)

        if assign.op == "+=" {
          vars[lhs] = f"{vars.get(lhs) ?? ""} {rhs}".trim()
        } else if assign.op != "?=" or (vars.get(lhs) ?? "") == "" {
          vars[lhs] = rhs
        }
      }
    }
  }

  vars
}

pure object_cflags_lhs(expanded: Str) -> Str {
  if expanded.starts_with("CFLAGS_") and expanded.ends_with(".o") {
    return expanded.replace("CFLAGS_", "")
  }

  ""
}

proc kbuild_compile_flags_for_dir(
  root: Path,
  dir: Path,
  config: Kconfig,
  srcarch: Str,
) -> Result[Map[List[Str]]] {
  var file = p""

  if let Ok(value) = kbuild_file(join_root(root, dir)) {
    file = value
  } else {
    return map.empty()
  }

  var vars = kbuild_vars_for_dir(dir, srcarch)
  let dir_key = path_key(dir)
  let local_dir = if dir_key == "." { "." } else { f"./{dir_key}" }
  vars["src"] = local_dir
  vars["obj"] = local_dir
  var flags: Map[List[Str]] = {}
  var subdir_flags: List[Str] = []
  var active_stack = [true]
  var lines = logical_lines(file.read_text()?)
  var line_index = 0

  while line_index < lines.len() {
    let line = lines[line_index]
    line_index += 1

    if line.starts_with("ifeq ") or line.starts_with("ifneq ") or line.starts_with("ifdef ") or line.starts_with(
      "ifndef ",
    ) {
      if let Ok(active) = eval_conditional(line, vars, config, srcarch) {
        active_stack += [active_conditional(active_stack) and active]
        continue
      }
    }

    if line == "else" {
      let parent = if active_stack.len() > 1 { active_stack[-2] } else { true }
      let current = active_conditional(active_stack)
      active_stack = active_stack |> take(active_stack.len() - 1).push(parent and ! current)
      continue
    }

    if line == "endif" {
      if active_stack.len() > 1 {
        active_stack = active_stack |> take(active_stack.len() - 1)
      }

      continue
    }

    continue unless active_conditional(active_stack)

    if line.starts_with("include ") {
      let included = included_kbuild_lines(root, line, vars, config, srcarch)?
      lines = [@lines |> take(line_index), @included, @lines |> drop(line_index)]
      continue
    }

    if let Ok(assign) = parse_assignment(line) {
      let expanded_lhs = expand_vars(assign.lhs, vars, config, srcarch)
      let rhs = expand_vars(assign.rhs, vars, config, srcarch)

      if expanded_lhs == "subdir-ccflags-y" or expanded_lhs == "ccflags-y" {
        let rhs_flags = rhs.fields()

        if assign.op == "+=" {
          subdir_flags += rhs_flags
        } else if assign.op != "?=" or subdir_flags.is_empty() {
          subdir_flags = rhs_flags
        }

        continue
      }

      let object_name = object_cflags_lhs(expanded_lhs)

      if object_name != "" {
        let key = path_key(join_rel(dir, object_name))
        let current = flags.get(key) ?? []

        if assign.op == "+=" {
          flags[key] = current.extend(rhs.fields())
        } else if assign.op != "?=" or current.is_empty() {
          flags[key] = rhs.fields()
        }

        continue
      }

      let lhs = active_var_lhs(expanded_lhs)

      if lhs != "" {
        if assign.op == "+=" {
          vars[lhs] = f"{vars.get(lhs) ?? ""} {rhs}".trim()
        } else if assign.op != "?=" or (vars.get(lhs) ?? "") == "" {
          vars[lhs] = rhs
        }
      }
    }
  }

  if ! subdir_flags.is_empty() {
    flags["*"] = subdir_flags
  }

  flags
}

proc kbuild_compile_flags_for_dirs(
  root: Path,
  dirs: List[Path],
  config: Kconfig,
  srcarch: Str,
) -> Result[Map[Map[List[Str]]]] {
  var by_dir: Map[Map[List[Str]]] = {}
  var dir_index = 0

  for dir in dirs {
    dir_index += 1

    write_text_if_changed(
      fp"{root}/.xsh-kbuild-progress",
      f"""xsh-kbuild-compile-flags-dir {dir_index}/{dirs.len()} {dir}
""",
    )

    by_dir[path_key(dir)] = kbuild_compile_flags_for_dir(root, dir, config, srcarch)?
  }

  by_dir
}

pure compile_flags_cache_format() -> Str {
  "linux-kbuild-compile-flags-v2"
}

pure compile_flags_cache_entries(flags: Map[Map[List[Str]]]) -> List[CompileFlagsEntry] {
  var entries: List[CompileFlagsEntry] = []

  for dir_key in flags.keys() {
    let empty_dir_flags: Map[List[Str]] = {}
    let dir_flags = flags.get(dir_key) ?? empty_dir_flags

    for object_key in dir_flags.keys() {
      entries += [{dir: dir_key, object: object_key, flags: dir_flags.get(object_key) ?? []}]
    }
  }

  entries
}

pure compile_flags_from_cache_entries(entries: List[CompileFlagsEntry]) -> Result[Map[Map[List[Str]]]] {
  var flags: Map[Map[List[Str]]] = {}

  for entry in entries {
    let empty_dir_flags: Map[List[Str]] = {}
    let dir_flags = (flags.get(entry.dir) ?? empty_dir_flags).set(entry.object, entry.flags)
    flags[entry.dir] = dir_flags
  }

  flags
}

proc compile_flags_fingerprint(
  root: Path,
  dirs: List[Path],
  config_path: Path,
  srcarch: Str,
) -> Result[Str] {
  let dir_fingerprints = dirs
    |> par-map(jobs: planner_jobs()) { |dir|
      fingerprint_dir_line(root, dir)?
    }
  let config_hash = if config_path.exists() { hash.sha256(config_path)?.hex() } else { "missing" }

  f"""format {compile_flags_cache_format()}
srcarch {srcarch}
config {config_hash}
dirs {dirs.len()}
{path_strings(dirs).join("\n")}
kbuild-files
{dir_fingerprints.join("\n")}
"""
}

proc read_compile_flags_cache(path_value: Path, fingerprint: Str) -> Result[Map[Map[List[Str]]]] {
  let stored = json.read(path_value)?.require(Record)?
  let format = if "format" in stored { stored.get("format")?.require(Str)? } else { "" }

  if format != compile_flags_cache_format() {
    return Err(ScriptError.Failed(kind: "kbuild-compile-flags-cache-stale", message: "compile flags cache has stale format"))
  }

  let cache = stored.require(CompileFlagsCache)?

  if fingerprint != "" and cache.fingerprint.trim() != fingerprint.trim() {
    return Err(ScriptError.Failed(kind: "kbuild-compile-flags-cache-stale", message: "compile flags cache fingerprint mismatch"))
  }

  compile_flags_from_cache_entries(cache.flags)?
}

proc write_compile_flags_cache(path_value: Path, fingerprint: Str, flags: Map[Map[List[Str]]]) {
  write_text_if_changed(
    path_value,
    json.encode(
      {format: compile_flags_cache_format(), fingerprint: fingerprint, flags: compile_flags_cache_entries(flags)},
    )?,
  )
}

proc cached_kbuild_compile_flags_for_dirs(
  root: Path,
  dirs: List[Path],
  config: Kconfig,
  srcarch: Str,
) -> Result[Map[Map[List[Str]]]] {
  let cache_dir = fp"{e"XSH_LINUX_KBUILD_COMPILE_FLAGS_CACHE_DIR" ?? e"XSH_LINUX_KBUILD_PLAN_CACHE_DIR" ?? "/var/cache/laputa/linux-kbuild"}"
  let stable_cache_path = fp"{cache_dir}/linux-{srcarch}.compile-flags.json"
  let local_cache_path = fp"{root}/.xsh-kbuild-compile-flags.json"
  let trust_cache = (e"XSH_LINUX_KBUILD_TRUST_COMPILE_FLAGS_CACHE" ?? "") == "1"
  let fingerprint = if trust_cache {
    ""
  } else {
    compile_flags_fingerprint(root, dirs, fp"{root}/.config", srcarch)?
  }

  if stable_cache_path.exists() {
    match read_compile_flags_cache(stable_cache_path, fingerprint) {
      Ok(flags) => {
        write_text_if_changed(
          fp"{root}/.xsh-kbuild-progress",
          f"""xsh-kbuild-compile-flags-cache stable-hit {dirs.len()} dirs
""",
        )

        write_compile_flags_cache(local_cache_path, fingerprint, flags)
        return flags
      }
      Err(error) => write_text_if_changed(
        fp"{root}/.xsh-kbuild-progress",
        f"""xsh-kbuild-compile-flags-cache stable-miss {error.message}
""",
      )
    }
  }

  if local_cache_path.exists() {
    match read_compile_flags_cache(local_cache_path, fingerprint) {
      Ok(flags) => {
        write_text_if_changed(
          fp"{root}/.xsh-kbuild-progress",
          f"""xsh-kbuild-compile-flags-cache local-hit {dirs.len()} dirs
""",
        )

        cache_dir.mkdir()
        write_compile_flags_cache(stable_cache_path, fingerprint, flags)
        return flags
      }
      Err(error) => write_text_if_changed(
        fp"{root}/.xsh-kbuild-progress",
        f"""xsh-kbuild-compile-flags-cache local-miss {error.message}
""",
      )
    }
  }

  let flags = kbuild_compile_flags_for_dirs(root, dirs, config, srcarch)?
  write_compile_flags_cache(local_cache_path, fingerprint, flags)
  cache_dir.mkdir()
  write_compile_flags_cache(stable_cache_path, fingerprint, flags)
  flags
}

pure kbuild_compile_flags_in_makefile_dir(by_dir: Map[Map[List[Str]]], makefile_dir: Path, obj: Path) -> List[Str] {
  let empty_dir_flags: Map[List[Str]] = {}
  let dir_flags = by_dir.get(path_key(makefile_dir)) ?? empty_dir_flags
  let object_flags = dir_flags.get(path_key(obj)) ?? []
  (dir_flags.get("*") ?? []).extend(object_flags)
}

pure kbuild_compile_flags_for_object(by_dir: Map[Map[List[Str]]], obj: Path) -> List[Str] {
  kbuild_compile_flags_in_makefile_dir(by_dir, object_dir(obj), obj)
}

# A composite's members build under the Makefile that lists them, which is
# the composite's directory even for a member such as x86/xor-avx.o.
pure kbuild_compile_flags_for_member(by_dir: Map[Map[List[Str]]], composite: Path, member: Path) -> List[Str] {
  kbuild_compile_flags_in_makefile_dir(by_dir, object_dir(composite), member)
}

## Exported declaration `augment_missing_composites`.
export proc augment_missing_composites(
  root: Path,
  config: Kconfig,
  plan: KbuildPlan,
  srcarch: Str = "arm64",
) [fs, error] -> Result[KbuildPlan, Error] {
  var composites = plan.composites
  var dirs: List[Path] = []
  var missing_by_dir: Map[List[Path]] = {}

  for obj in plan_objects(plan) {
    match source_for_object(obj) {
      Ok(_) => {}
      Err(_) => {
        if ! is_known_generated_object(obj) {
          match composite_for(composites, obj) {
            Ok(_) => {}
            Err(_) => {
              let dir = object_dir(obj)
              let dir_key = path_key(dir)
              let current = missing_by_dir.get(dir_key) ?? []

              if current.is_empty() {
                dirs += [dir]
              }

              missing_by_dir[dir_key] = current.push(obj)
            }
          }
        }
      }
    }
  }

  let scans: List[CompositeScan] = dirs
    |> par-map(jobs: planner_jobs()) { |dir|
      let vars = vars_for_dir(root, dir, config, srcarch)?
      var found = []

      for obj in missing_by_dir.get(path_key(dir)) ?? [] {
        let members = composite_members(dir, obj.name, vars)

        if ! members.is_empty() {
          found += [{object: obj, members: members}]
        }
      }

      {dir: dir, composites: found}
    }

  var composites_by_dir: Map[List[CompositeObject]] = {[path_key(scan.dir)]: scan.composites for scan in scans}
  for dir in dirs {
    composites += composites_by_dir.get(path_key(dir)) ?? []
  }

  {...plan, composites: composites}
}

## Exported declaration `prune_inactive_objects`.
export proc prune_inactive_objects(
  root: Path,
  config: Kconfig,
  plan: KbuildPlan,
  srcarch: Str = "arm64",
) [fs, error] -> Result[KbuildPlan, Error] {
  var active: Map[Bool] = {}

  let dir_objects: List[ActiveDirObjects] = plan.dirs
    |> par-map(jobs: planner_jobs()) { |dir|
      let vars = vars_for_dir(root, dir, config, srcarch)?
      {dir: dir, objects: active_objects_for_dir(dir, vars).collect()}
    }

  for row in dir_objects {
    for obj in row.objects {
      active[path_key(obj)] = true
    }
  }

  var objects = [obj for obj in plan.objects if active.get(path_key(obj)) ?? false]
  var composites = [composite for composite in plan.composites if active.get(path_key(composite.object)) ?? false]
  var lib_objects = [obj for obj in plan.lib_objects if active.get(path_key(obj)) ?? false]
  {...plan, objects: objects, lib_objects: lib_objects, composites: composites}
}

## Exported declaration `refresh_plan_dirs`.
export proc refresh_plan_dirs(
  root: Path,
  config: Kconfig,
  plan: KbuildPlan,
  srcarch: Str,
  dirs: List[Path],
) [fs, error] -> Result[KbuildPlan, Error] {
  var next = plan
  let jobs = planner_jobs()

  write_text_if_changed(
    fp"{root}/.xsh-kbuild-progress",
    f"""xsh-kbuild-refresh-plan-dirs start {dirs.len()} jobs {jobs}
""",
  )

  var objects_by_dir: Map[List[Path]] = {}
  var composites_by_dir: Map[List[CompositeObject]] = {}
  var scan_index = 0

  for dir in dirs {
    scan_index += 1

    write_text_if_changed(
      fp"{root}/.xsh-kbuild-progress",
      f"""xsh-kbuild-refresh-plan-dir-scan {scan_index}/{dirs.len()} {dir}
""",
    )

    let vars = vars_for_dir(root, dir, config, srcarch)?
    var objects: List[Path] = []
    var composites = []

    for obj in active_objects_for_dir(dir, vars) {
      objects += [obj]
      let members = composite_members(dir, obj.name, vars)

      if ! members.is_empty() {
        composites += [{object: obj, members: members}]
      }
    }

    objects_by_dir[path_key(dir)] = objects
    composites_by_dir[path_key(dir)] = composites
  }

  var dirs_all = next.dirs
  var objects_all = next.objects
  var composites_all = next.composites
  var dir_index = 0

  for dir in dirs {
    dir_index += 1

    write_text_if_changed(
      fp"{root}/.xsh-kbuild-progress",
      f"""xsh-kbuild-refresh-plan-dir-merge {dir_index}/{dirs.len()} {dir}
""",
    )

    dirs_all += [dir]
    objects_all += objects_by_dir.get(path_key(dir)) ?? []
    composites_all += composites_by_dir.get(path_key(dir)) ?? []
  }

  normalize_plan({...next, dirs: dirs_all, objects: objects_all, composites: composites_all})
}

## Exported declaration `refresh_x86_kernel_config_objects`.
export proc refresh_x86_kernel_config_objects(config: Kconfig, plan: KbuildPlan) [fs, error] -> Result[KbuildPlan, Error] {
  var objects: List[Path] = []
  var dirs: List[Path] = []

  if config_value(config, "UTS_NS") == "y" or config_value(config, "USER_NS") == "y" or config_value(config, "PID_NS") == "y" or config_value(
    config,
    "FREEZER",
  ) == "y" {
    dirs += [p"kernel"]
  }

  if config_value(config, "TIME_NS") == "y" {
    dirs += [p"kernel/time"]
  }

  if config_value(config, "MEMCG") == "y" {
    dirs += [p"mm"]
  }

  if config_value(config, "KVM_GUEST") == "y" {
    objects += [p"arch/x86/kernel/kvm.o"]
    objects += [p"arch/x86/kernel/kvmclock.o"]
  }

  if config_value(config, "PARAVIRT") == "y" {
    objects += [p"arch/x86/kernel/paravirt.o"]
    objects += [p"arch/x86/kernel/paravirt-spinlocks.o"]
  }

  if config_value(config, "PARAVIRT_CLOCK") == "y" {
    objects += [p"arch/x86/kernel/pvclock.o"]
  }

  if config_value(config, "HYPERVISOR_GUEST") == "y" {
    objects += [p"arch/x86/kernel/cpu/vmware.o"]
    objects += [p"arch/x86/kernel/cpu/hypervisor.o"]
    objects += [p"arch/x86/kernel/cpu/mshyperv.o"]
  }

  if config_value(config, "WIRELESS") == "y" {
    dirs += [p"net/wireless"]
  }

  if config_value(config, "MAC80211") == "y" {
    dirs += [p"net/mac80211"]
  }

  if config_value(config, "VHOST_MENU") == "y" {
    dirs += [p"drivers/vhost"]
  }

  if config_value(config, "VSOCKETS") == "y" {
    dirs += [p"net/vmw_vsock"]
  }

  if config_value(config, "BRIDGE") == "y" {
    dirs += [p"net/bridge"]
  }

  if config_value(config, "BRIDGE_NETFILTER") == "y" or config_value(config, "NF_TABLES_BRIDGE") == "y" {
    dirs += [p"net/bridge/netfilter"]
  }

  if config_value(config, "NF_TABLES") == "y" {
    dirs += [p"net/netfilter"]
    dirs += [p"net/ipv4/netfilter"]
    dirs += [p"net/ipv6/netfilter"]
  }

  if config_value(config, "XFRM") == "y" {
    dirs += [p"net/xfrm"]
    dirs += [p"net/ipv4"]
    dirs += [p"net/ipv6"]
  }

  if config_value(config, "MACVLAN") == "y" or config_value(config, "TAP") == "y" or config_value(config, "VETH") == "y" {
    dirs += [p"drivers/net"]
  }

  if config_value(config, "BT") == "y" {
    dirs += [p"net/bluetooth"]
    dirs += [p"drivers/bluetooth"]
  }

  if config_value(config, "NEW_LEDS") == "y" {
    dirs += [p"drivers/leds"]
    dirs += [p"drivers/leds/trigger"]
  }

  if config_value(config, "BTRFS_FS") == "y" {
    dirs += [p"fs/btrfs"]
  }

  if config_value(config, "FS_POSIX_ACL") == "y" {
    dirs += [p"fs"]
  }

  if config_value(config, "FUSE_FS") == "y" {
    dirs += [p"fs/fuse"]
  }

  if config_value(config, "OVERLAY_FS") == "y" {
    dirs += [p"fs/overlayfs"]
  }

  if config_value(config, "BPF_SYSCALL") == "y" {
    dirs += [p"kernel/bpf"]
  }

  if config_value(config, "BPF_JIT") == "y" {
    dirs += [p"arch/x86/net"]
  }

  if config_value(config, "BINARY_PRINTF") == "y" {
    dirs += [p"lib"]
  }

  if config_value(config, "TASKS_RCU") == "y" or config_value(config, "TASKS_TRACE_RCU") == "y" {
    dirs += [p"kernel/rcu"]
  }

  if config_value(config, "BPF_STREAM_PARSER") == "y" or config_value(config, "NET_SOCK_MSG") == "y" {
    dirs += [p"net/core"]
    dirs += [p"net/ipv4"]
    dirs += [p"net/ipv6"]
  }

  if config_value(config, "CGROUPS") == "y" {
    dirs += [p"kernel/cgroup"]
  }

  if config_value(config, "PM") == "y" {
    dirs += [p"kernel/power"]
  }

  if config_value(config, "DMA_OPS_HELPERS") == "y" {
    dirs += [p"kernel/dma"]
  }

  if config_value(config, "ACPI_SLEEP") == "y" {
    dirs += [p"arch/x86/kernel/acpi"]
  }

  if config_value(config, "CPU_FREQ") == "y" {
    dirs += [p"drivers/cpufreq"]
  }

  if config_value(config, "INTEL_IDLE") == "y" {
    dirs += [p"drivers/idle"]
  }

  if config_value(config, "IOMMU_SUPPORT") == "y" {
    dirs += [p"drivers/iommu"]
  }

  if config_value(config, "GENERIC_PT") == "y" or config_value(config, "AMD_IOMMU") == "y" or config_value(
    config,
    "INTEL_IOMMU",
  ) == "y" {
    dirs += [p"drivers/iommu/generic_pt/fmt"]
  }

  if config_value(config, "INTEL_IOMMU") == "y" or config_value(config, "DMAR_TABLE") == "y" or config_value(
    config,
    "IRQ_REMAP",
  ) == "y" {
    dirs += [p"drivers/iommu/intel"]
  }

  if config_value(config, "AMD_IOMMU") == "y" {
    dirs += [p"drivers/iommu/amd"]
  }

  if config_value(config, "VFIO") == "y" {
    dirs += [p"drivers/vfio"]
  }

  if config_value(config, "VFIO_PCI") == "y" {
    dirs += [p"drivers/vfio/pci"]
  }

  if config_value(config, "INPUT_MOUSEDEV") == "y" or config_value(config, "INPUT_JOYDEV") == "y" {
    dirs += [p"drivers/input"]
  }

  if config_value(config, "INPUT_MISC") == "y" and config_value(config, "INPUT_UINPUT") == "y" {
    dirs += [p"drivers/input/misc"]
  }

  if config_value(config, "USB_VIDEO_CLASS") == "y" {
    dirs += [p"drivers/media/usb/uvc"]
    dirs += [p"drivers/media/common"]
  }

  if config_value(config, "SND_USB_AUDIO") == "y" {
    dirs += [p"sound/usb"]
  }

  if config_value(config, "CRYPTO_LIB_ARC4") == "y" {
    dirs += [p"lib/crypto"]
  }

  if config_value(config, "CRYPTO_ECDH") == "y" {
    dirs += [p"crypto"]
  }

  if config_value(config, "SND") == "y" {
    dirs += [p"sound/core"]
  }

  var next = plan

  if ! objects.is_empty() {
    next = add_plan_objects(add_dir(next, p"arch/x86/kernel"), objects)
  }

  if ! dirs.is_empty() {
    next = refresh_plan_dirs(p".", config, next, "x86", dirs)?
  }

  if config_value(config, "IOMMU_PT_AMDV1") == "y" {
    next = add_object(add_dir(next, p"drivers/iommu/generic_pt/fmt"), p"drivers/iommu/generic_pt/fmt/iommu_amdv1.o")
  }

  if config_value(config, "IOMMU_PT_X86_64") == "y" {
    next = add_object(add_dir(next, p"drivers/iommu/generic_pt/fmt"), p"drivers/iommu/generic_pt/fmt/iommu_x86_64.o")
  }

  if config_value(config, "IOMMU_PT_VTDSS") == "y" {
    next = add_object(add_dir(next, p"drivers/iommu/generic_pt/fmt"), p"drivers/iommu/generic_pt/fmt/iommu_vtdss.o")
  }

  if config_value(config, "ZSTD_DECOMPRESS") == "y" {
    let obj = p"lib/zstd/zstd_decompress.o"

    next = add_composite(
      add_object(next, obj),
      {
        object: obj,
        members: [
          p"lib/zstd/zstd_decompress_module.o",
          p"lib/zstd/decompress/huf_decompress.o",
          p"lib/zstd/decompress/zstd_ddict.o",
          p"lib/zstd/decompress/zstd_decompress.o",
          p"lib/zstd/decompress/zstd_decompress_block.o",
        ],
      },
    )
  }

  if config_value(config, "ZSTD_COMMON") == "y" {
    let obj = p"lib/zstd/zstd_common.o"

    next = add_composite(
      add_object(next, obj),
      {
        object: obj,
        members: [
          p"lib/zstd/zstd_common_module.o",
          p"lib/zstd/common/debug.o",
          p"lib/zstd/common/entropy_common.o",
          p"lib/zstd/common/error_private.o",
          p"lib/zstd/common/fse_decompress.o",
          p"lib/zstd/common/zstd_common.o",
        ],
      },
    )
  }

  next
}

## Exported declaration `refresh_plan_composite_members`.
export proc refresh_plan_composite_members(
  root: Path,
  config: Kconfig,
  plan: KbuildPlan,
  srcarch: Str,
  objects: List[Path],
) [fs, error] -> Result[KbuildPlan, Error] {
  var refreshed: Map[CompositeObject] = {}
  var member_paths: Map[Bool] = {}

  for obj in objects {
    let dir = object_dir(obj)
    let vars = vars_for_dir(root, dir, config, srcarch)?
    let members = composite_members(dir, obj.name, vars)

    if ! members.is_empty() {
      refreshed[path_key(obj)] = {object: obj, members: members}

      for member in members {
        member_paths[path_key(member)] = true
      }
    }
  }

  var composites: List[CompositeObject] = []
  var seen: Map[Bool] = {}

  for composite in plan.composites {
    let key = path_key(composite.object)

    if key in refreshed {
      composites += [refreshed.get(key)?]
      seen[key] = true
    } else {
      composites += [composite]
    }
  }

  for obj in objects {
    let key = path_key(obj)

    if key in refreshed and ! (seen.get(key) ?? false) {
      composites += [refreshed.get(key)?]
    }
  }

  var top_objects = [obj for obj in plan.objects if ! (member_paths.get(path_key(obj)) ?? false)]
  normalize_plan({...plan, objects: top_objects, composites: composites})
}

## Exported declaration `add_plan_objects`.
export proc add_plan_objects(plan: KbuildPlan, objects: List[Path]) [] -> KbuildPlan {
  var next = plan

  for obj in objects {
    next = add_object(next, obj)
  }

  next
}

proc apply_item(
  plan: KbuildPlan,
  dir: Path,
  item: Str,
  vars: Map[Str],
  as_lib: Bool = false,
  build_plan: Bool = true,
) -> ItemResult {
  return {plan: plan, dirs: [], entries: []} when item == ""

  if "$(" in item {
    let next = if build_plan { add_unsupported(plan, f"{path_key(dir)}: unresolved token {item}") } else { plan }
    return {plan: next, dirs: [], entries: []}
  }

  if item.ends_with("/") {
    let child = dirname_for_item(dir, item)
    let next = if build_plan { add_dir(plan, child) } else { plan }
    return {plan: next, dirs: [child], entries: [child]}
  }

  if item.ends_with(".o") {
    let active_item = object_item_for_dir(dir, item, as_lib)
    let obj = join_rel(dir, active_item)
    let members = if build_plan { composite_members(dir, active_item, vars) } else { [] }
    var next = if ! build_plan {
      plan
    } else if as_lib {
      add_lib_object_at(plan, obj, dir)
    } else {
      add_object_at(plan, obj, dir)
    }

    if ! members.is_empty() {
      next = add_composite(next, {object: obj, members: members})
    }

    return {plan: next, dirs: [], entries: [obj]}
  }

  let next = if build_plan { add_unsupported(plan, f"{path_key(dir)}: unsupported token {item}") } else { plan }
  {plan: next, dirs: [], entries: []}
}

proc apply_words(
  plan: KbuildPlan,
  dir: Path,
  words: List[Str],
  vars: Map[Str],
  as_lib: Bool = false,
  build_plan: Bool = true,
) -> ItemResult {
  var current = plan
  var dirs: List[Path] = []
  var entries: List[Path] = []

  if ! build_plan {
    for item in words {
      if item.ends_with("/") {
        dirs += [dirname_for_item(dir, item)]
      }
    }

    return {plan: plan, dirs: dirs, entries: []}
  }

  for item in words {
    let applied = apply_item(current, dir, item, vars, as_lib, build_plan)
    current = applied.plan
    dirs += applied.dirs
    entries += applied.entries
  }

  {plan: current, dirs: dirs, entries: entries}
}

proc kbuild_file(dir_abs: Path) -> Result[Path] {
  var has_makefile = false

  for entry in fs.children(dir_abs, stat: false, ordered: false)? {
    return fp"{dir_abs}/Kbuild" when entry.name == "Kbuild"

    if entry.name == "Makefile" {
      has_makefile = true
    }
  }

  return fp"{dir_abs}/Makefile" when has_makefile

  Err(ScriptError.Failed(kind: "kbuild-missing", message: f"missing Kbuild or Makefile in {dir_abs}"))
}

proc read_kbuild_source(dir_abs: Path) -> Result[KbuildSource] {
  let file = kbuild_file(dir_abs)?
  {file: file, body: file.read_text()?}
}

proc emit_discover_progress(root: Path, options: DiscoverOptions, state: DiscoverState, rel: Path) {
  if options.progress and options.progress_every > 0 {
    let count = state.visited

    if count == 1 or count % options.progress_every == 0 {
      let message = f"xsh-kbuild-discover {count} visited {state.plan.dirs.len()} dirs {state.plan.objects.len()} objects current={path_key(rel)}"

      fp"{root}/.xsh-kbuild-progress".write(
        f"""{message}
""",
      )

      print $message
    }
  }
}

proc emit_stage_progress(root: Path, options: DiscoverOptions, message: Str) {
  if options.progress {
    fp"{root}/.xsh-kbuild-progress".write(
      f"""{message}
""",
    )

    print $message
  }
}

proc emit_merge_progress(root: Path, options: DiscoverOptions, state: DiscoverState, rel: Path) {
  if options.progress and options.progress_every > 0 {
    let count = state.visited

    if count == 1 or count % options.progress_every == 0 {
      emit_stage_progress(
        root,
        options,
        f"xsh-kbuild-merge {count} merged {state.plan.dirs.len()} dirs {state.plan.objects.len()} objects current={path_key(rel)}",
      )
    }
  }
}

proc emit_line_progress(root: Path, options: DiscoverOptions, rel: Path, line_no: Int, line: Str) {
  if options.progress and options.progress_every == 1 {
    fp"{root}/.xsh-kbuild-progress".write(
      f"""xsh-kbuild-line current={path_key(rel)} line={line_no} text={line}
""",
    )
  }
}

proc emit_batch_progress(root: Path, options: DiscoverOptions, pending: List[Path]) {
  if options.progress {
    fp"{root}/.xsh-kbuild-progress".write(
      f"""xsh-kbuild-batch count={pending.len()} sample={path_strings(pending |> take(16)).join(",")}
""",
    )
  }
}

pure kbuild_scanner_kind(body: Str) -> Int {
  if "ifeq " in body or "ifneq " in body or "ifdef " in body or "ifndef " in body or "include " in body or """
else""" in body or """
endif""" in body or body.starts_with("else") or body.starts_with("endif") {
    return 2
  }

  return 1 when "$(" in body or "\${CONFIG_" in body

  0
}

pure maybe_plan_assignment(line: Str) -> Bool {
  line.starts_with("obj") or line.starts_with("lib") or line.starts_with("subdir") or line.starts_with("KVM") or "-y" in line or "-objs" in line or "_files" in line or "$(" in line
}

proc scan_simple_kbuild(
  root: Path,
  rel: Path,
  lines: List[Str],
  srcarch: Str,
  options: DiscoverOptions,
) -> Result[DirScan] {
  var plan = add_dir(empty_plan(), rel)
  let vars = kbuild_vars_for_dir(rel, srcarch)
  var mutable_vars = vars
  var child_dirs: List[Path] = []
  var entries: List[Path] = []
  var object_rhs: List[Str] = []
  var lib_rhs: List[Str] = []
  var line_no = 0

  for line in lines {
    if options.progress and options.progress_every == 1 {
      line_no += 1
      emit_line_progress(root, options, rel, line_no, line)
    }

    if "=" in line and maybe_plan_assignment(line) and ! line.starts_with("ccflags-") and ! line.starts_with("asflags-") and ! line.starts_with(
      "ldflags-",
    ) and ! line.starts_with("rustflags-") and ! line.starts_with("subdir-ccflags-") and ! line.starts_with(
      "subdir-asflags-",
    ) and ! line.starts_with("subdir-rustflags-") {
      if let Ok(assign) = parse_assignment(line) {
        let lhs = assign.lhs

        if active_obj_lhs(lhs) {
          if lhs == "lib-y" {
            lib_rhs += [assign.rhs]
          } else if lhs == "subdir-y" {
            for item in assign.rhs.fields() {
              child_dirs += [join_rel(rel, item)]
            }
          } else {
            object_rhs += [assign.rhs]
          }
        } else if active_var_lhs(lhs) != "" {
          if assign.op == "+=" {
            mutable_vars[lhs] = f"{mutable_vars.get(lhs) ?? ""} {assign.rhs}".trim()
          } else if assign.op != "?=" or (mutable_vars.get(lhs) ?? "") == "" {
            mutable_vars[lhs] = assign.rhs
          }
        }
      }
    }
  }

  for rhs in object_rhs {
    let applied = apply_words(plan, rel, rhs.fields(), mutable_vars, false, options.build_plan)
    plan = applied.plan
    child_dirs += applied.dirs
    entries += applied.entries
  }

  if srcarch == "x86" {
    for obj in extra_objects_for_dir(rel) {
      if options.build_plan {
        plan = add_object(plan, obj)
      }

      entries += [obj]
    }
  }

  for rhs in lib_rhs {
    let applied = apply_words(plan, rel, rhs.fields(), mutable_vars, true, options.build_plan)
    plan = applied.plan
    child_dirs += applied.dirs
  }

  {dir: rel, plan: plan, child_dirs: child_dirs, entries: entries}
}

proc scan_flat_kbuild(
  root: Path,
  rel: Path,
  config: Kconfig,
  lines: List[Str],
  srcarch: Str,
  options: DiscoverOptions,
) -> Result[DirScan] {
  var plan = add_dir(empty_plan(), rel)
  var vars = kbuild_vars_for_dir(rel, srcarch)
  var child_dirs: List[Path] = []
  var entries: List[Path] = []
  var object_rhs: List[Str] = []
  var lib_rhs: List[Str] = []
  var line_no = 0

  for line in lines {
    if options.progress and options.progress_every == 1 {
      line_no += 1
      emit_line_progress(root, options, rel, line_no, line)
    }

    if "=" in line and maybe_plan_assignment(line) and ! line.starts_with("ccflags-") and ! line.starts_with("asflags-") and ! line.starts_with(
      "ldflags-",
    ) and ! line.starts_with("rustflags-") and ! line.starts_with("subdir-ccflags-") and ! line.starts_with(
      "subdir-asflags-",
    ) and ! line.starts_with("subdir-rustflags-") {
      if let Ok(assign) = parse_assignment(line) {
        let expanded_lhs = expand_vars(assign.lhs, vars, config, srcarch)
        let lhs = active_var_lhs(expanded_lhs)

        if active_obj_lhs(expanded_lhs) {
          let rhs = expand_vars(assign.rhs, vars, config, srcarch)

          if expanded_lhs == "lib-y" {
            lib_rhs += [rhs]
          } else if expanded_lhs == "subdir-y" {
            for item in rhs.fields() {
              child_dirs += [join_rel(rel, item)]
            }
          } else {
            object_rhs += [rhs]
          }
        } else if lhs != "" {
          let rhs = expand_vars(assign.rhs, vars, config, srcarch)

          if assign.op == "+=" {
            vars[lhs] = f"{vars.get(lhs) ?? ""} {rhs}".trim()
          } else if assign.op != "?=" or (vars.get(lhs) ?? "") == "" {
            vars[lhs] = rhs
          }
        }
      }
    }
  }

  for rhs in object_rhs {
    let applied = apply_words(plan, rel, rhs.fields(), vars, false, options.build_plan)
    plan = applied.plan
    child_dirs += applied.dirs
    entries += applied.entries
  }

  if srcarch == "x86" {
    for obj in extra_objects_for_dir(rel) {
      if options.build_plan {
        plan = add_object(plan, obj)
      }

      entries += [obj]
    }
  }

  for rhs in lib_rhs {
    let applied = apply_words(plan, rel, rhs.fields(), vars, true, options.build_plan)
    plan = applied.plan
    child_dirs += applied.dirs
  }

  {dir: rel, plan: plan, child_dirs: child_dirs, entries: entries}
}

proc scan_discover_dir(
  root: Path,
  rel: Path,
  config: Kconfig,
  srcarch: Str,
  options: DiscoverOptions,
) -> Result[DirScan] {
  let rel_key = path_key(rel)
  let dir_abs = join_root(root, rel)
  let source_result = read_kbuild_source(dir_abs)

  if let Err(err) = source_result {
    let plan = add_unsupported(add_dir(empty_plan(), rel), err.message)
    return {dir: rel, plan: plan, child_dirs: [], entries: []}
  }

  let source = source_result?

  if options.progress and options.progress_every == 1 {
    emit_stage_progress(root, options, f"xsh-kbuild-scan-start current={rel_key}")
  }

  var lines = logical_lines(source.body)

  let scanner_kind = kbuild_scanner_kind(source.body)

  return scan_simple_kbuild(root, rel, lines, srcarch, options) when scanner_kind == 0

  if scanner_kind == 1 {
    return scan_flat_kbuild(root, rel, config, lines, srcarch, options)
  }

  var plan = add_dir(empty_plan(), rel)
  var vars = kbuild_vars_for_dir(rel, srcarch)
  var child_dirs: List[Path] = []
  var entries: List[Path] = []
  var object_rhs: List[Str] = []
  var lib_rhs: List[Str] = []
  var active_stack = [true]
  var line_no = 0
  var line_index = 0

  while line_index < lines.len() {
    let line = lines[line_index]
    line_index += 1
    if options.progress and options.progress_every == 1 {
      line_no += 1
      emit_line_progress(root, options, rel, line_no, line)
    }

    if line.starts_with("ifeq ") or line.starts_with("ifneq ") or line.starts_with("ifdef ") or line.starts_with(
      "ifndef ",
    ) {
      if let Ok(active) = eval_conditional(line, vars, config, srcarch) {
        active_stack += [active_conditional(active_stack) and active]
        continue
      }
    }

    if line == "else" {
      let parent = if active_stack.len() > 1 { active_stack[-2] } else { true }
      let current = active_conditional(active_stack)
      active_stack = active_stack |> take(active_stack.len() - 1).push(parent and ! current)
      continue
    }

    if line == "endif" {
      if active_stack.len() > 1 {
        active_stack = active_stack |> take(active_stack.len() - 1)
      }

      continue
    }

    continue unless active_conditional(active_stack)

    if line.starts_with("include ") {
      let included = included_kbuild_lines(root, line, vars, config, srcarch)?
      lines = [@lines |> take(line_index), @included, @lines |> drop(line_index)]
      continue
    }

    if "=" in line and maybe_plan_assignment(line) and ! line.starts_with("ccflags-") and ! line.starts_with("asflags-") and ! line.starts_with(
      "ldflags-",
    ) and ! line.starts_with("rustflags-") and ! line.starts_with("subdir-ccflags-") and ! line.starts_with(
      "subdir-asflags-",
    ) and ! line.starts_with("subdir-rustflags-") {
      if let Ok(assign) = parse_assignment(line) {
        let expanded_lhs = expand_vars(assign.lhs, vars, config, srcarch)
        let lhs = active_var_lhs(expanded_lhs)

        if active_obj_lhs(expanded_lhs) {
          let rhs = expand_vars(assign.rhs, vars, config, srcarch)

          if expanded_lhs == "lib-y" {
            lib_rhs += [rhs]
          } else if expanded_lhs == "subdir-y" {
            for item in rhs.fields() {
              child_dirs += [join_rel(rel, item)]
            }
          } else {
            object_rhs += [rhs]
          }
        } else if lhs != "" {
          let rhs = expand_vars(assign.rhs, vars, config, srcarch)

          if assign.op == "+=" {
            vars[lhs] = f"{vars.get(lhs) ?? ""} {rhs}".trim()
          } else if assign.op != "?=" or (vars.get(lhs) ?? "") == "" {
            vars[lhs] = rhs
          }
        }
      }
    }
  }

  for rhs in object_rhs {
    let applied = apply_words(plan, rel, rhs.fields(), vars, false, options.build_plan)
    plan = applied.plan
    child_dirs += applied.dirs
    entries += applied.entries
  }

  if srcarch == "x86" {
    for obj in extra_objects_for_dir(rel) {
      if options.build_plan {
        plan = add_object(plan, obj)
      }

      entries += [obj]
    }
  }

  for rhs in lib_rhs {
    let applied = apply_words(plan, rel, rhs.fields(), vars, true, options.build_plan)
    plan = applied.plan
    child_dirs += applied.dirs
  }

  {dir: rel, plan: plan, child_dirs: child_dirs, entries: entries}
}

proc unique_unseen_paths(paths: List[Path], seen: Map[Bool]) -> List[Path] {
  var unique: List[Path] = []
  var local_seen = seen

  for path_value in paths {
    let key = path_key(path_value)

    if ! (local_seen.get(key) ?? false) {
      local_seen[key] = true
      unique += [path_value]
    }
  }

  unique
}

proc scan_discover_batch_serial(
  root: Path,
  pending: List[Path],
  config: Kconfig,
  srcarch: Str,
  options: DiscoverOptions,
) -> Result[List[DirScan]] {
  var scans: List[DirScan] = []

  for dir in pending {
    emit_stage_progress(root, options, f"xsh-kbuild-scan {path_key(dir)}")
    scans += [scan_discover_dir(root, dir, config, srcarch, options)?]
  }

  scans
}

proc scan_discover_batch_parallel(
  root: Path,
  pending: List[Path],
  config: Kconfig,
  srcarch: Str,
  options: DiscoverOptions,
) -> Result[List[DirScan]] {
  pending
    |> par-map(jobs: options.jobs) { |dir|
      scan_discover_dir(root, dir, config, srcarch, options)?
    }
}

## Exported declaration `scan_record_for_dir`.
export proc scan_record_for_dir(
  root: Path,
  config: Kconfig,
  srcarch: Str,
  dir: Path,
) [fs, error] -> Result[ScanRecord, Error] {
  let scan = scan_discover_dir(root, dir, config, srcarch, default_discover_options())?
  local_record_record(scan, "")
}

## Exported declaration `plan_from_record_values`.
export proc plan_from_record_values(records: List[ScanRecord]) [error] -> Result[KbuildPlan, Error] {
  var scan_by_dir: Map[ScanRecord] = {item.dir: item for item in records}
  var seen: Map[Bool] = {}
  var frontier = [p"."]
  var plan_dirs: List[Path] = []
  var planned_objects: List[Path] = []
  var plan_lib_objects: List[Path] = []
  var plan_archive_owners: List[ArchiveOwnerRecord] = []
  var plan_composites: List[CompositeRecord] = []
  var plan_unsupported: List[Str] = []

  while ! frontier.is_empty() {
    let pending = unique_unseen_paths(frontier, seen)
    frontier = []

    for dir in pending {
      let scan = scan_by_dir.get(path_key(dir))?
      let {plan: {dirs, objects, lib_objects, archive_owners, composites, unsupported, ..}, ..} = scan

      for item in dirs {
        plan_dirs += [fp"{item}"]
      }

      for item in objects {
        planned_objects += [fp"{item}"]
      }

      for item in lib_objects {
        plan_lib_objects += [fp"{item}"]
      }

      for owner in archive_owners {
        plan_archive_owners += [owner]
      }

      for composite in composites {
        plan_composites += [composite]
      }

      for item in unsupported {
        plan_unsupported += [item]
      }

      for child in scan.child_dirs {
        let child_path = fp"{child}"
        if ! (seen.get(path_key(child_path)) ?? false) {
          frontier += [child_path]
        }
      }
    }
  }

  let archive_owners = archive_owners_from_records(plan_archive_owners)?
  let composites = composites_from_records(plan_composites)?
  normalize_plan({
    dirs: plan_dirs,
    objects: planned_objects,
    lib_objects: plan_lib_objects,
    archive_owners: archive_owners,
    composites: composites,
    unsupported: plan_unsupported,
  })
}

proc discover_records_process_pool(
  root: Path,
  config: Path,
  srcarch: Str,
  options: DiscoverOptions,
  xsh_bin: Path,
  worker: Path,
) -> Result[KbuildPlan] {
  let prefix = f"/tmp/xsh-kbuild-pool-{time.now()}"
  let state_path = fp"{prefix}-state.json"
  let lock_path = fp"{prefix}-lock"
  defer state_path.remove(missing_ok: true)?
  defer lock_path.remove(missing_ok: true)?

  json.write(
    state_path,
    PoolState(pending: ["."], active: 0, done: false, seen: ["."], error: ""),
  )

  let worker_count = if options.jobs < 1 { 1 } else if options.jobs > 16 { 16 } else { options.jobs }
  var handles = []
  var output_paths: List[Path] = []
  # Loop-body defers run per iteration; remove worker outputs after the merge instead.
  defer {
    for output_path in output_paths {
      output_path.remove(missing_ok: true)
    }
  }

  for index in range(worker_count) {
    let output_path = fp"{prefix}-output-{index}.json"
    output_paths += [output_path]
    let command = process.command_argv(
      xsh_bin,
      [
        xsh_bin,
        worker,
        "--",
        root,
        config,
        srcarch,
        state_path,
        lock_path,
        output_path,
      ],
    )
    handles += [spawn command?]
  }

  let statuses = wait handles?
  for status in statuses {
    guard status.exited_with(0) else {
      return Err(ScriptError.Failed(kind: "kbuild-process-pool", message: "a discovery worker failed"))
    }
  }

  let state = json.read(state_path)?.require(PoolState)?

  if state.error != "" {
    return Err(ScriptError.Failed(kind: "kbuild-process-pool", message: state.error))
  }

  var records: List[ScanRecord] = []
  for output_path in output_paths {
    let batch = json.read(output_path)?.require(List[ScanRecord])?
    records += batch
  }

  plan_from_record_values(records)?
}

## Exported declaration `discover_plan_with_process_pool`.
export proc discover_plan_with_process_pool(
  root: Path,
  config: Path,
  srcarch: Str,
  options: DiscoverOptions,
  xsh_bin: Path,
  worker: Path,
) [fs, process, time, error] -> Result[KbuildPlan, Error] {
  discover_records_process_pool(root, config, srcarch, options, xsh_bin, worker)?
}

proc discover_scans(
  root: Path,
  config: Kconfig,
  srcarch: Str,
  options: DiscoverOptions,
) -> Result[DiscoverScans] {
  var scans: Map[DirScan] = {}
  var seen: Map[Bool] = {}
  var frontier = [p"."]
  var aggregate = empty_plan()
  var visited = 0

  while ! frontier.is_empty() {
    emit_stage_progress(root, options, f"xsh-kbuild-frontier-start frontier={frontier.len()}")
    let pending = unique_unseen_paths(frontier, seen)
    emit_stage_progress(root, options, f"xsh-kbuild-frontier-pending pending={pending.len()}")
    frontier = []

    for dir in pending {
      seen[path_key(dir)] = true
    }

    emit_batch_progress(root, options, pending)
    let batch = if options.local_records and options.jobs > 1 {
      scan_discover_batch_parallel(root, pending, config, srcarch, options)?
    } else {
      scan_discover_batch_serial(root, pending, config, srcarch, options)?
    }

    var batch_plan = empty_plan()
    var batch_index = 0

    for dir in pending {
      let scan = batch.get(batch_index)?
      batch_index += 1
      scans[path_key(dir)] = scan
      visited += 1
      if options.local_records {
        batch_plan = merge_plan(batch_plan, scan.plan)
      }

      if options.progress {
        emit_discover_progress(root, options, {plan: aggregate, seen: seen, visited: visited}, dir)
      }

      for child in scan.child_dirs {
        if ! (seen.get(path_key(child)) ?? false) {
          frontier += [child]
        }
      }
    }

    if options.local_records {
      aggregate = merge_plan(aggregate, batch_plan)
    }
  }

  {records: scans, plan: aggregate}
}

pure aggregate_barriers(dir: Path) -> AggregateBarriers {
  let key = path_key(dir)

  return {builtin_archive: p"built-in.a", module_order: p"modules.order"} when key == "."

  {
    builtin_archive: fp"{key}/built-in.a",
    module_order: fp"{key}/modules.order",
  }
}

proc discover_local_record_graph(
  root: Path,
  config: Kconfig,
  srcarch: Str,
  options: DiscoverOptions,
) -> Result[LocalRecordGraph] {
  let scans = discover_scans(root, config, srcarch, options)?
  var barriers: Map[AggregateBarriers] = {}

  for key in scans.records.keys() {
    let scan = scans.records.get(key)?
    barriers[key] = aggregate_barriers(scan.dir)
  }

  {records: scans.records, barriers: barriers, plan: scans.plan}
}

pure local_record_cache_path(root: Path) -> Path {
  fp"{root}/.xsh-kbuild-local-records.json"
}

proc local_record_cache_key(config: Path, srcarch: Str) -> Result[Str] {
  let config_hash = if config.exists() { hash.sha256(config)?.hex() } else { "missing" }
  bytes.from_text(f"linux-local-records-v1\t{srcarch}\t{config_hash}").sha256().hex()
}

pure local_record_record(scan: DirScan, file_hash: Str) -> ScanRecord {
  {
    dir: path_key(scan.dir),
    file_hash: file_hash,
    plan: plan_record(scan.plan),
    child_dirs: path_strings(scan.child_dirs),
    entries: path_strings(scan.entries),
  }
}

proc local_record_from_record(item: ScanRecord) -> Result[DirScan] {
  {
    dir: fp"{item.dir}",
    plan: {
      dirs: paths_from_strings(item.plan.dirs)?,
      objects: paths_from_strings(item.plan.objects)?,
      lib_objects: paths_from_strings(item.plan.lib_objects)?,
      archive_owners: archive_owners_from_records(item.plan.archive_owners)?,
      composites: composites_from_records(item.plan.composites)?,
      unsupported: item.plan.unsupported,
    },
    child_dirs: paths_from_strings(item.child_dirs)?,
    entries: paths_from_strings(item.entries)?,
  }
}

proc write_local_record_graph(root: Path, config: Path, srcarch: Str, graph: LocalRecordGraph) {
  let cache = local_record_cache_path(root)
  let key = local_record_cache_key(config, srcarch)?
  var records: List[ScanRecord] = []

  for dir_key in graph.records.keys() {
    let scan = graph.records.get(dir_key)?
    let file = kbuild_file(join_root(root, scan.dir))?
    records += [local_record_record(scan, hash.sha256(file)?.hex())]
  }

  json.write(cache, LocalRecordCache(format: "linux-local-records-v1", key:, records:))
}

proc read_local_record_graph(root: Path, config: Path, srcarch: Str) -> Result[LocalRecordGraph] {
  let cache = local_record_cache_path(root)

  if ! cache.exists() {
    return Err(ScriptError.Failed(kind: "local-record-cache-missing", message: "local-record cache does not exist"))
  }

  let stored = json.read(cache)?.require(Record)?
  let format = stored.get("format")?.require(Str)?

  if format != "linux-local-records-v1" {
    return Err(ScriptError.Failed(kind: "local-record-cache-format", message: "unsupported local-record cache format"))
  }

  let cached = stored.require(LocalRecordCache)?
  let expected_key = local_record_cache_key(config, srcarch)?

  if cached.key != expected_key {
    return Err(ScriptError.Failed(kind: "local-record-cache-key", message: "local-record cache key does not match"))
  }

  var record_map: Map[DirScan] = {}
  var barriers: Map[AggregateBarriers] = {}

  for item in cached.records {
    let scan = local_record_from_record(item)?
    let file = kbuild_file(join_root(root, scan.dir))?

    if hash.sha256(file)?.hex() != item.file_hash {
      return Err(
        ScriptError.Failed(kind: "local-record-cache-stale", message: f"local-record cache is stale for {path_key(scan.dir)}"),
      )
    }

    let dir_key = path_key(scan.dir)
    record_map[dir_key] = scan
    barriers[dir_key] = aggregate_barriers(scan.dir)
  }

  var plan = empty_plan()

  for key in record_map.keys() {
    plan = merge_plan(plan, record_map.get(key)?.plan)
  }

  {records: record_map, barriers: barriers, plan: plan}
}

proc merge_discovered_scans_with_options(
  root: Path,
  options: DiscoverOptions,
  scan_by_dir: Map[DirScan],
  rel: Path,
  state: DiscoverState,
) -> Result[DiscoverState] {
  let rel_key = path_key(rel)

  return state when state.seen.get(rel_key) ?? false

  let scan = scan_by_dir.get(rel_key)?

  var next: DiscoverState = DiscoverState(
    plan: merge_plan(state.plan, scan.plan),
    seen: state.seen.set(rel_key, true),
    visited: state.visited + 1,
  )

  emit_merge_progress(root, options, next, rel)

  for child in scan.child_dirs {
    let child_next: DiscoverState = merge_discovered_scans_with_options(root, options, scan_by_dir, child, next)?
    next = child_next
  }

  next
}

proc merge_local_record_graph_with_options(
  root: Path,
  options: DiscoverOptions,
  graph: LocalRecordGraph,
  rel: Path,
  state: DiscoverState,
) -> Result[DiscoverState] {
  let rel_key = path_key(rel)

  return state when state.seen.get(rel_key) ?? false

  let scan = graph.records.get(rel_key)?
  let next: DiscoverState = DiscoverState(
    plan: merge_plan(state.plan, scan.plan),
    seen: state.seen.set(rel_key, true),
    visited: state.visited + 1,
  )

  if options.progress {
    let barriers = graph.barriers.get(rel_key)?
    let barrier_label = f"{path_key(barriers.builtin_archive)} {path_key(barriers.module_order)}"
    emit_merge_progress(root, options, next, rel)
    emit_stage_progress(root, options, f"xsh-kbuild-local-record {rel_key} barriers={barrier_label}")
  }

  var merged = next

  for child in scan.child_dirs {
    merged = merge_local_record_graph_with_options(root, options, graph, child, merged)?
  }

  merged
}

## Exported declaration `discover_plan`.
export proc discover_plan(root: Path, config: Kconfig, srcarch: Str = "arm64") [fs, error] -> Result[KbuildPlan, Error] {
  discover_plan_with_options(root, config, srcarch, default_discover_options())
}

## Exported declaration `discover_plan_with_options`.
export proc discover_plan_with_options(
  root: Path,
  config: Kconfig,
  srcarch: Str,
  options: DiscoverOptions,
) [fs, error] -> Result[KbuildPlan, Error] {
  var scans: Map[DirScan] = {}
  var local_graph: LocalRecordGraph = {records: {}, barriers: {}, plan: empty_plan()}

  if options.local_records {
    if options.local_record_cache {
      if let Ok(cached) = read_local_record_graph(root, fp"{root}/.config", srcarch) {
        local_graph = cached
      } else {
        local_graph = discover_local_record_graph(root, config, srcarch, options)?
        write_local_record_graph(root, fp"{root}/.config", srcarch, local_graph)
      }
    } else {
      local_graph = discover_local_record_graph(root, config, srcarch, options)?
    }

    scans = local_graph.records
  } else {
    scans = discover_scans(root, config, srcarch, options)?.records
  }

  emit_stage_progress(root, options, "xsh-kbuild-discover-scans complete")

  let state = if options.local_records {
    merge_local_record_graph_with_options(
      root,
      options,
      local_graph,
      p".",
      {plan: empty_plan(), seen: map.empty(), visited: 0},
    )?
  } else {
    merge_discovered_scans_with_options(
      root,
      options,
      scans,
      p".",
      {plan: empty_plan(), seen: map.empty(), visited: 0},
    )?
  }

  let plan = normalize_plan(state.plan)

  emit_stage_progress(
    root,
    options,
    f"xsh-kbuild-discover-complete {plan.dirs.len()} dirs {plan.objects.len()} objects {plan.composites.len()} composites",
  )

  plan
}

pure path_strings(paths: List[Path]) -> List[Str] {
  [path_key(path_value) for path_value in paths]
}

proc paths_from_strings(items: List[Str]) -> Result[List[Path]] {
  [path_from_string(item)? for item in items]
}

proc unique_paths(paths: List[Path]) -> List[Path] {
  var unique: List[Path] = []
  var seen: Map[Bool] = {}

  for path_value in paths {
    let key = path_key(path_value)

    if ! (seen.get(key) ?? false) {
      seen[key] = true
      unique += [path_value]
    }
  }

  unique
}

proc unique_composites(composites: List[CompositeObject]) -> List[CompositeObject] {
  var unique: List[CompositeObject] = []
  var seen: Map[Bool] = {}

  for composite in composites {
    let key = path_key(composite.object)

    if ! (seen.get(key) ?? false) {
      seen[key] = true
      unique += [composite]
    }
  }

  unique
}

proc normalize_plan(plan: KbuildPlan) -> KbuildPlan {
  let lib_objects = unique_paths(plan.lib_objects)
  var lib_object_seen = {[path_key(obj)]: true for obj in lib_objects}
  {
    dirs: unique_paths(plan.dirs),
    objects: [obj for obj in unique_paths(plan.objects) if ! (lib_object_seen.get(path_key(obj)) ?? false)],
    lib_objects: lib_objects,
    archive_owners: plan.archive_owners,
    composites: unique_composites(plan.composites),
    unsupported: plan.unsupported,
  }
}

proc sorted_paths(paths: List[Path]) -> List[Path] {
  paths |> sort-by .display()
}

pure composite_records(composites: List[CompositeObject]) -> List[CompositeRecord] {
  [{object: path_key(item.object), members: path_strings(item.members)} for item in composites]
}

proc composites_from_records(items: List[CompositeRecord]) -> Result[List[CompositeObject]] {
  var composites: List[CompositeObject] = [
    {object: fp"{item.object}", members: paths_from_strings(item.members)?}
    for item in items
  ]
  composites
}

proc archive_owners_from_records(items: List[ArchiveOwnerRecord]) [error] -> Result[List[ArchiveOwner]] {
  var owners: List[ArchiveOwner] = [{object: fp"{item.object}", dir: fp"{item.dir}"} for item in items]
  owners
}

pure plan_record(plan: KbuildPlan) -> PlanRecord {
  {
    dirs: path_strings(plan.dirs),
    objects: path_strings(plan.objects),
    lib_objects: path_strings(plan.lib_objects),
    archive_owners: [{object: path_key(item.object), dir: path_key(item.dir)} for item in plan.archive_owners],
    composites: composite_records(plan.composites),
    unsupported: plan.unsupported,
  }
}

pure discovered_plan_text(plan: KbuildPlan) -> Str {
  var out = ""

  for dir in plan.dirs {
    out = f"""{out}dir	{path_key(dir)}
"""
  }

  for obj in plan.objects {
    out = f"""{out}obj	{path_key(obj)}
"""
  }

  for obj in plan.lib_objects {
    out = f"""{out}lib	{path_key(obj)}
"""
  }

  for owner in plan.archive_owners {
    out = f"""{out}archive	{path_key(owner.object)}	{path_key(owner.dir)}
"""
  }

  for composite in plan.composites {
    out = f"""{out}composite	{path_key(composite.object)}	{path_strings(composite.members).join("\t")}
"""
  }

  for item in plan.unsupported {
    out = f"""{out}unsupported	{item}
"""
  }

  out
}

## Exported declaration `write_discovered_plan`.
export proc write_discovered_plan(plan: KbuildPlan, out: Path) [fs, error] {
  write_text_if_changed(out, discovered_plan_text(plan))
}

## Exported declaration `read_discovered_plan`.
export proc read_discovered_plan(path_value: Path) [fs, error] -> Result[KbuildPlan, Error] {
  let text = path_value.read_text()?

  return read_discovered_plan_text(path_value) unless text.trim().starts_with("{")

  let stored = json.read(path_value)?.require(Record)?
  let dirs = stored.get("dirs")?.require(List[Str])?
  let objects = stored.get("objects")?.require(List[Str])?
  let lib_objects = if "lib_objects" in stored { stored.get("lib_objects")?.require(List[Str])? } else { [] }
  let archive_owners = if "archive_owners" in stored {
    stored.get("archive_owners")?.require(List[ArchiveOwnerRecord])?
  } else {
    []
  }
  let composites = if "composites" in stored { stored.get("composites")?.require(List[CompositeRecord])? } else { [] }
  let unsupported = if "unsupported" in stored { stored.get("unsupported")?.require(List[Str])? } else { [] }

  {
    dirs: unique_paths(paths_from_strings(dirs)?),
    objects: unique_paths(paths_from_strings(objects)?),
    lib_objects: unique_paths(paths_from_strings(lib_objects)?),
    archive_owners: archive_owners_from_records(archive_owners)?,
    composites: composites_from_records(composites)?,
    unsupported: unsupported,
  }
}

## Exported declaration `parse_discovered_plan_text`.
export proc parse_discovered_plan_text(text: Str) [error] -> Result[KbuildPlan, Error] {
  var dirs: List[Str] = []
  var objects: List[Str] = []
  var lib_objects: List[Str] = []
  var archive_owners: List[ArchiveOwner] = []
  var composites: List[CompositeObject] = []
  var unsupported: List[Str] = []

  for raw in text.split("\n") {
    let line = raw.trim()
    continue when line == ""
    let parts = line.split("\t")
    let kind = parts[0]

    match kind {
      "dirs" => dirs = parts |> drop(1)
      "dir" => dirs += [parts.get(1) ?? ""]
      "objects" => objects = parts |> drop(1)
      "obj" => objects += [parts.get(1) ?? ""]
      "lib_objects" => lib_objects = parts |> drop(1)
      "lib" => lib_objects += [parts.get(1) ?? ""]
      "archive" => archive_owners += [{object: fp"{parts.get(1) ?? ""}", dir: fp"{parts.get(2) ?? "."}"}]
      "composite" => composites += [{object: fp"{parts.get(1) ?? ""}", members: paths_from_strings(parts |> drop(2))?}]
      "unsupported" => unsupported += [parts.get(1) ?? ""]
      else => {}
    }
  }

  {
    dirs: paths_from_strings(dirs)?,
    objects: paths_from_strings(objects)?,
    lib_objects: paths_from_strings(lib_objects)?,
    archive_owners: archive_owners,
    composites: composites,
    unsupported: unsupported,
  }
}

## Exported declaration `read_discovered_plan_text`.
export proc read_discovered_plan_text(path_value: Path) [fs, error] -> Result[KbuildPlan, Error] {
  parse_discovered_plan_text(path_value.read_text()?)
}

proc fingerprint_dir_line(root: Path, dir: Path) -> Result[Str] {
  var line = ""

  match kbuild_file(join_root(root, dir)) {
    Ok(file) => {
      let rel = file.strip_prefix(root)?
      line = f"{path_key(rel)} {hash.sha256(file)?.hex()}"
    }
    Err(err) => line = f"{path_key(dir)} missing {err.message}"
  }

  line
}

## Exported declaration `plan_fingerprint`.
export proc plan_fingerprint(root: Path, config_path: Path, plan: KbuildPlan) [fs, error] -> Result[Str, Error] {
  # The top-level Makefile carries VERSION/PATCHLEVEL/SUBLEVEL, so a plan
  # discovered in another kernel release never matches.
  f"""format linux-kbuild-plan-fingerprint-v10
config {hash.sha256(config_path)?.hex()}
makefile {hash.sha256(fp"{root}/Makefile")?.hex()}
dirs {plan.dirs.len()}
objects {plan.objects.len()}
lib_objects {plan.lib_objects.len()}
composites {plan.composites.len()}
"""
}

pure task_record(task: make.MakeTask) -> Result[ArchiveTaskRecord] {
  Ok({
    name: task.name,
    outputs: path_strings(task.outputs),
    inputs: path_strings(task.inputs),
    deps: task.deps,
    argv: make.argv_text(task.argv)?,
    env: task.env,
    cwd: task.cwd.display(),
    depfile: task.depfile.display(),
    stamp: task.stamp.display(),
  })
}

pure task_records(tasks: List[make.MakeTask]) -> Result[List[ArchiveTaskRecord]] {
  [task_record(task)? for task in tasks]
}

pure archive_plan_report_format() -> Str {
  "linux-archive-plan-v4"
}

## Exported declaration `archive_plan_summary_path`.
export pure archive_plan_summary_path(report_path: Path) -> Path {
  fp"{report_path}.summary"
}

pure duplicate_task_outputs(tasks: List[make.MakeTask]) -> List[Path] {
  var outputs: Map[Bool] = {}
  var duplicates: List[Path] = []

  for task in tasks {
    for output in task.outputs {
      let key = path_key(output)
      continue when key == ""

      if outputs.get(key) ?? false {
        if ! has_plan_path(duplicates, output) {
          duplicates += [output]
        }
      } else {
        outputs[key] = true
      }
    }
  }

  duplicates
}

## Exported declaration `write_archive_plan_summary`.
export proc write_archive_plan_summary(archive_plan: BuiltinArchivePlan, out: Path) [fs, env, time, error] {
  let encode_start = archive_plan_timing_start("report-summary-encode")
  let summary = json.encode({
    format: archive_plan_report_format(),
    archives: path_strings(archive_plan.archives),
    link_inputs: path_strings(archive_plan.link_inputs),
    generated_objects: path_strings(archive_plan.generated_objects),
    missing_sources: path_strings(archive_plan.missing_sources),
    duplicate_outputs: path_strings(duplicate_task_outputs(archive_plan.tasks)),
    task_count: archive_plan.tasks.len(),
  })?
  archive_plan_timing_done("report-summary-encode", encode_start)
  write_text_if_changed(out, summary)
}

## Exported declaration `write_archive_plan_report`.
export proc write_archive_plan_report(archive_plan: BuiltinArchivePlan, out: Path) [fs, env, time, error] {
  let records_start = archive_plan_timing_start("report-task-records")
  let task_rows = task_records(archive_plan.tasks)?
  archive_plan_timing_done("report-task-records", records_start)

  let encode_start = archive_plan_timing_start("report-encode")
  let report = json.encode({
    format: archive_plan_report_format(),
    archives: path_strings(archive_plan.archives),
    link_inputs: path_strings(archive_plan.link_inputs),
    generated_objects: path_strings(archive_plan.generated_objects),
    missing_sources: path_strings(archive_plan.missing_sources),
    duplicate_outputs: path_strings(duplicate_task_outputs(archive_plan.tasks)),
    task_count: archive_plan.tasks.len(),
    tasks: task_rows,
  })?
  archive_plan_timing_done("report-encode", encode_start)

  let write_start = archive_plan_timing_start("report-write")
  write_text_if_changed(out, report)
  archive_plan_timing_done("report-write", write_start)

  write_archive_plan_summary(archive_plan, archive_plan_summary_path(out))
}

proc path_from_string(item: Str) [error] -> Result[Path] {
  return p"" when item == ""

  fp"{item}"
}

proc task_from_record(item: ArchiveTaskRecord) -> Result[make.MakeTask] {
  {
    name: item.name,
    outputs: paths_from_strings(item.outputs)?,
    inputs: paths_from_strings(item.inputs)?,
    deps: item.deps,
    argv: [@item.argv],
    cwd: path_from_string(item.cwd)?,
    env: item.env,
    depfile: path_from_string(item.depfile)?,
    stamp: path_from_string(item.stamp)?,
  }
}

proc read_archive_plan_record(path_value: Path, stale_message: Str) -> Result[Record] {
  let stored = json.read(path_value)?.require(Record)?
  let format = if "format" in stored { stored.get("format")?.require(Str)? } else { "" }

  if format != archive_plan_report_format() {
    return Err(ScriptError.Failed(kind: "kbuild-archive-plan-cache-stale", message: stale_message))
  }

  stored
}

proc read_archive_plan_tasks(path_value: Path) -> Result[List[make.MakeTask]] {
  let stored = json.read(path_value)?.require(ArchivePlanTasksFile)?
  [task_from_record(row)? for row in stored.tasks]
}

proc archive_plan_from_summary(
  summary: ArchivePlanSummaryFile,
  tasks: List[make.MakeTask],
) -> Result[BuiltinArchivePlan] {
  {
    tasks: tasks,
    task_specs: [],
    task_count: summary.task_count,
    archives: paths_from_strings(summary.archives)?,
    link_inputs: paths_from_strings(summary.link_inputs)?,
    missing_sources: paths_from_strings(summary.missing_sources)?,
    generated_objects: paths_from_strings(summary.generated_objects)?,
    duplicate_outputs: paths_from_strings(summary.duplicate_outputs)?,
  }
}

## Exported declaration `read_archive_plan_report`.
export proc read_archive_plan_report(path_value: Path) [fs, error] -> Result[BuiltinArchivePlan, Error] {
  let stored = read_archive_plan_record(path_value, "archive plan cache has stale format")?
  let tasks = [task_from_record(row)? for row in stored.require(ArchivePlanTasksFile)?.tasks]
  archive_plan_from_summary(stored.require()?, tasks)?
}

## Exported declaration `read_archive_plan_summary`.
export proc read_archive_plan_summary(path_value: Path) [fs, error] -> Result[BuiltinArchivePlan, Error] {
  let stored = read_archive_plan_record(path_value, "archive plan summary has stale format")?
  archive_plan_from_summary(stored.require()?, [])?
}

## Exported declaration `read_archive_plan_object_outputs`.
export proc read_archive_plan_object_outputs(path_value: Path) [fs, error] -> Result[List[Path], Error] {
  let stored = read_archive_plan_record(path_value, "archive plan cache has stale format")?
  var outputs: List[Path] = [
    path_from_string(item)?
    for row in stored.require(ArchivePlanTasksFile)?.tasks
    for item in row.outputs
    if item.ends_with(".o")
  ]
  outputs
}

pure task_has_output(task: make.MakeTask, output: Path) -> Bool {
  let key = path_key(output)

  for item in task.outputs {
    return true when path_key(item) == key
  }

  false
}

pure find_task_name_by_output(tasks: List[make.MakeTask], output: Path) -> Result[Str] {
  for task in tasks {
    return task.name when task_has_output(task, output)
  }

  Err(ScriptError.Failed(kind: "kbuild-task-output-missing", message: f"no archive-plan task produces {output}"))
}

proc collect_task_closure(task_deps: Map[List[Str]], target: Str, selected: Map[Bool]) -> Map[Bool] {
  return selected when selected.get(target) ?? false

  var next = selected.set(target, true)

  for dep in task_deps.get(target) ?? [] {
    next = collect_task_closure(task_deps, dep, next)
  }

  next
}

proc archive_task_deps_by_name(tasks: List[make.MakeTask]) -> Map[List[Str]] {
  var by_name = {task.name: task.deps for task in tasks}
  by_name
}

## Exported declaration `select_archive_tasks_outputs`.
export proc select_archive_tasks_outputs(
  tasks: List[make.MakeTask],
  outputs: List[Path],
) [error] -> Result[List[make.MakeTask], Error] {
  let task_deps = archive_task_deps_by_name(tasks)
  var selected: Map[Bool] = {}

  for output in outputs {
    let target = find_task_name_by_output(tasks, output)?
    selected = collect_task_closure(task_deps, target, selected)
  }

  [task for task in tasks if selected.get(task.name) ?? false]
}

## Exported declaration `run_archive_tasks_output`.
export proc run_archive_tasks_output(
  tasks: List[make.MakeTask],
  output: Path,
  jobs_count: Int = 1,
) [fs, process, env, error] {
  make.run_tasks(select_archive_tasks_outputs(tasks, [output])?, jobs_count)
}

## Exported declaration `run_archive_tasks_outputs`.
export proc run_archive_tasks_outputs(
  tasks: List[make.MakeTask],
  outputs: List[Path],
  jobs_count: Int = 1,
) [fs, process, env, error] {
  make.run_tasks(select_archive_tasks_outputs(tasks, outputs)?, jobs_count)
}

## Exported declaration `run_archive_plan_output`.
export proc run_archive_plan_output(plan_path: Path, output: Path, jobs_count: Int = 1) [fs, process, env, error] {
  let tasks = read_archive_plan_tasks(plan_path)?
  run_archive_tasks_output(tasks, output, jobs_count)
}

## Exported declaration `write_plan`.
export proc write_plan(
  root: Path,
  config_path: Path,
  out: Path,
  srcarch: Str = "arm64",
) [fs, error] -> Result[KbuildPlan, Error] {
  let config = load_config(config_path)?
  let plan = discover_plan(root, config, srcarch)?
  write_discovered_plan(plan, out)
  plan
}

pure obj_out_path(obj: Path) -> Path {
  fp".xsh-kbuild/obj/{obj}"
}

pure composite_for(composites: List[CompositeObject], obj: Path) -> Result[CompositeObject] {
  let key = path_key(obj)

  for composite in composites {
    return composite when path_key(composite.object) == key
  }

  Err(ScriptError.Failed(kind: "kbuild-not-composite", message: f"{key} is not a composite object"))
}

proc composite_map(composites: List[CompositeObject]) -> Map[CompositeObject] {
  var mapped: Map[CompositeObject] = {[path_key(composite.object)]: composite for composite in composites}
  mapped
}

proc composite_member_map(composites: List[CompositeObject]) -> Map[CompositeObject] {
  var mapped: Map[CompositeObject] = {
    [path_key(member)]: composite
    for composite in composites
    for member in composite.members
  }
  mapped
}

proc source_for_object(obj: Path) -> Result[Path] {
  var candidates = [obj]
  let stem = obj.name.replace(".o", "")

  if path_key(obj).starts_with("drivers/firmware/efi/libstub/lib-") {
    candidates += [fp"lib/{stem.replace("lib-", "")}.c"]
  }

  if stem.ends_with("_") {
    candidates += [join_rel(object_dir(obj), f"{stem}64.o")]
  }

  if path_key(obj) == "arch/x86/kernel/head.o" {
    candidates += [p"arch/x86/kernel/head_64.o"]
  }

  for candidate in candidates {
    let c_src = candidate.with_ext("c")

    return c_src when c_src.exists()

    let asm_src = candidate.with_ext("S")

    return asm_src when asm_src.exists()

    let raw_asm_src = candidate.with_ext("s")

    return raw_asm_src when raw_asm_src.exists()
  }

  Err(ScriptError.Failed(kind: "kbuild-missing-source", message: f"missing source for {obj}"))
}

pure is_asm_source(src: Path) -> Bool {
  let name = src.display()
  name.ends_with(".S") or name.ends_with(".s")
}

pure asm_keeps_forced_include(arg: Str) -> Bool {
  arg in [
    "include/linux/compiler-version.h",
    "./include/linux/compiler-version.h",
    "include/linux/kconfig.h",
    "./include/linux/kconfig.h",
    "include/linux/compiler_types.h",
    "./include/linux/compiler_types.h",
    "include/generated/asm-offsets.h",
    "./include/generated/asm-offsets.h",
  ]
}

proc asm_includes(args: List[Str]) -> List[Str] {
  var filtered: List[Str] = []
  var skip_next = false

  for arg in args {
    if skip_next {
      if asm_keeps_forced_include(arg) {
        filtered += ["-include", arg]
      }

      skip_next = false
      continue
    }

    if arg == "-include" {
      skip_next = true
      continue
    }

    filtered += [arg]
  }

  filtered.push("-include").push("./include/generated/asm-offsets.h")
}

proc asm_cflags(_: List[Str]) -> List[Str] {
  [
    "-D__KERNEL__",
    "-D__ASSEMBLY__",
    "-D__ASSEMBLER__",
    "-fno-PIE",
    "-mlittle-endian",
    "-DKASAN_SHADOW_SCALE_SHIFT=",
    "-fno-asynchronous-unwind-tables",
    "-fno-unwind-tables",
  ]
}

pure object_key_from_out(out: Path) -> Str {
  out.display().replace(".xsh-kbuild/obj/", "").replace(".o", "")
}

pure object_base_name_from_out(out: Path) -> Str {
  out.name.replace(".o", "").replace("-", "_")
}

pure kbuild_object_defs_for_module(out: Path, mod_out: Path) -> List[Str] {
  let modfile = object_key_from_out(mod_out)
  let basename = object_base_name_from_out(out)
  let modname = object_base_name_from_out(mod_out)
  let identifier = modname.replace("-", "_")

  let base = [
    f"-DKBUILD_MODFILE=\"{modfile}\"",
    f"-DKBUILD_BASENAME=\"{basename}\"",
    f"-DKBUILD_MODNAME=\"{modname}\"",
    f"-D__KBUILD_MODNAME={identifier}",
  ]

  if modfile.starts_with("drivers/acpi/acpica/") {
    return base.extend(["-D_LINUX", "-DBUILDING_ACPICA"])
  }

  return base.push("-DI915") when modfile.starts_with("drivers/gpu/drm/i915/")

  if modfile.starts_with("arch/arm64/kvm/hyp/nvhe/") or modfile.ends_with(".nvhe") {
    return base.extend(["-D__KVM_NVHE_HYPERVISOR__", "-D__DISABLE_EXPORTS", "-D__DISABLE_TRACE_MMIO__"])
  }

  if modfile.starts_with("arch/arm64/kvm/hyp/") {
    return base.push("-D__KVM_VHE_HYPERVISOR__")
  }

  base
}

pure is_pi_output(out: Path) -> Bool {
  "/arch/arm64/kernel/pi/" in out.display()
}

pure is_x86_startup_pi_base_output(out: Path) -> Bool {
  "/arch/x86/boot/startup/" in out.display()
}

proc pi_compile_cflags(args: List[Str], out: Path) -> List[Str] {
  if is_x86_startup_pi_base_output(out) {
    var out_args = [arg for arg in args if arg != "-O2" and arg != "-fno-PIE" and arg != "-mcmodel=kernel"]

    return out_args.extend(
      [
        "-D__DISABLE_EXPORTS",
        "-mcmodel=small",
        "-fPIC",
        "-Os",
        "-DDISABLE_BRANCH_PROFILING",
        "-fno-stack-protector",
        "-D__NO_FORTIFY",
        "-fno-jump-tables",
      ],
    )
  }

  return args unless is_pi_output(out)

  var out_args = [arg for arg in args if arg != "-fno-function-sections" and arg != "-fno-data-sections"]

  out_args += [
      "-fpie",
      "-Os",
      "-DDISABLE_BRANCH_PROFILING",
      "-mbranch-protection=none",
      "-D__DISABLE_EXPORTS",
      "-ffreestanding",
      "-D__NO_FORTIFY",
      "-fno-asynchronous-unwind-tables",
      "-fno-unwind-tables",
      "-fno-addrsig",
    ]

  if out.name == "map_range.o" {
    out_args += ["-mstrict-align"]
  }

  out_args
}

proc object_compile_cflags(args: List[Str], out: Path) -> List[Str] {
  guard out.display().ends_with("/crypto/jitterentropy.o") else {
    return args
  }

  var out_args = args
  out_args.push("-O0")
}

proc pi_compile_includes(args: List[Str], out: Path) -> List[Str] {
  if is_x86_startup_pi_base_output(out) {
    var out_args = args
    out_args += ["-include"]
    return out_args.push("include/linux/hidden.h")
  }

  return args unless is_pi_output(out)

  var out_args = args
  out_args += ["-I./scripts/dtc/libfdt"]
  out_args += ["-include"]
  out_args.push("include/linux/hidden.h")
}

proc trace_compile_includes(args: List[Str], src: Path) -> List[Str] {
  var out_args = args
  out_args.push(f"-I./{src.parent}")
}

proc arch_local_compile_includes(args: List[Str], src: Path, triple: Str) -> List[Str] {
  let dir = path_key(src.parent)
  var out_args = args

  if triple == "x86_64-linux-gnu" {
    out_args += ["-I./arch/x86/include/asm/trace"]
  }

  if dir.starts_with("arch/x86/kvm/") or dir == "arch/x86/kvm" or dir == "virt/kvm" {
    out_args += ["-I./arch/x86/kvm"]
  }

  if triple == "aarch64-linux-gnu" and (dir.starts_with("arch/arm64/kvm/hyp/") or dir == "arch/arm64/kvm/hyp" or dir == "arch/arm64/kvm") {
    out_args += ["-I./arch/arm64/kvm/hyp/include"]
    out_args += ["-I./arch/arm64/kvm"]
  }

  if dir.starts_with("drivers/gpu/drm/i915/") {
    out_args += ["-I./drivers/gpu/drm/i915"]
    out_args += ["-I./drivers/gpu/drm/i915/display"]
    out_args += ["-I./drivers/gpu/drm/i915/gem"]
    out_args += ["-I./drivers/gpu/drm/i915/gt"]
  }

  if dir == "drivers/media/dvb-frontends" {
    out_args += ["-I./drivers/media/tuners"]
    out_args += ["-I./drivers/media/usb/dvb-usb-v2"]
  }

  if dir == "drivers/media/tuners" {
    out_args += ["-I./drivers/media/dvb-frontends"]
  }

  if dir == "drivers/media/v4l2-core" {
    out_args += ["-I./drivers/media/dvb-frontends"]
    out_args += ["-I./drivers/media/tuners"]
  }

  if dir == "drivers/media/spi" {
    out_args += ["-I./drivers/media/dvb-frontends/cxd2880"]
  }

  return out_args when dir != "lib/crypto" and dir != "lib/crc"

  let local_arch = if triple == "x86_64-linux-gnu" { "x86" } else { "arm64" }
  out_args.push(f"-I./{dir}/{local_arch}")
}

proc libfdt_compile_includes(args: List[Str], out: Path) -> List[Str] {
  let key = object_key_from_out(out)

  if key == "lib/fdt" or key == "lib/fdt_addresses" or key == "lib/fdt_empty_tree" or key == "lib/fdt_ro" or key == "lib/fdt_rw" or key == "lib/fdt_strerror" or key == "lib/fdt_sw" or key == "lib/fdt_wip" {
    var out_args = args
    return out_args.push("-I./scripts/dtc/libfdt")
  }

  args
}

proc version_compile_includes(args: List[Str], out: Path) -> List[Str] {
  if object_key_from_out(out) == "init/version" or path_key(out) == "init/version-timestamp.o" {
    var out_args = args
    out_args += ["-include"]
    return out_args.push("init/utsversion-tmp.h")
  }

  args
}

## Exported declaration `compile_kbuild_task`.
export proc compile_kbuild_task(
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  src: Path,
  out: Path,
  deps: List[Str] = [],
) [] -> make.MakeTask {
  compile_kbuild_task_for_module(cc, triple, cflags, defs, includes, src, out, out, deps)
}

proc compile_kbuild_task_for_module(
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  src: Path,
  out: Path,
  mod_out: Path,
  deps: List[Str] = [],
) -> make.MakeTask {
  let compile_cflags = object_compile_cflags(pi_compile_cflags(cflags, out), out)

  let object_includes = arch_local_compile_includes(
    trace_compile_includes(
      version_compile_includes(libfdt_compile_includes(pi_compile_includes(includes, out), out), out),
      src,
    ),
    src,
    triple,
  )

  let task_cflags = if is_asm_source(src) { asm_cflags(compile_cflags) } else { compile_cflags }
  let task_defs = defs.extend(kbuild_object_defs_for_module(out, mod_out))
  let task_includes = if is_asm_source(src) { asm_includes(object_includes) } else { object_includes }
  make.compile_c_task(cc, triple, task_cflags, task_defs, task_includes, src, out, deps)
}

proc pi_objcopy_task(cc: Path, input: Path, out: Path, deps: List[Str] = []) -> make.MakeTask {
  let _ = cc
  let tool_path = host_build_path()
  var argv = ["llvm-objcopy", "--prefix-symbols=__pi_", "--remove-section=.note.gnu.property"]

  if out.name.starts_with("lib-") {
    argv += ["--prefix-alloc-sections=.init"]
  }

  argv += [input.display(), out.display()]

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: [
      input,
    ],
    deps: deps,
    argv: [
      @argv,
    ],
    cwd: p".",
    env: {
      PATH: tool_path,
    },
    depfile: p"",
    stamp: fp"{out}.cmd",
  }
}

pure pi_relacheck_path() -> Path {
  p".xsh-kbuild/host/arch/arm64/kernel/pi/relacheck"
}

proc host_build_cc() -> Path {
  let root = e"XSH_PM_BUILD_ROOT" ?? ""

  return fp"{root}/usr/bin/cc" when root != ""

  p"cc"
}

proc host_build_path() -> Str {
  let root = e"XSH_PM_BUILD_ROOT" ?? ""
  let current = e"PATH" ?? ""

  return f"{root}/usr/lib/llvm-toolchain/bin:{root}/usr/bin:{current}" when root != ""

  current
}

proc host_build_ld_library_path() -> Str {
  let root = e"XSH_PM_BUILD_ROOT" ?? ""
  let current = e"LD_LIBRARY_PATH" ?? ""

  return current when root == ""

  return f"{root}/usr/lib:{root}/usr/lib/llvm23/lib" when current == ""

  f"{root}/usr/lib:{root}/usr/lib/llvm23/lib:{current}"
}

proc pi_relacheck_build_task(cc: Path) -> make.MakeTask {
  let _ = cc
  let host_cc = host_build_cc()
  let host_path = host_build_path()
  let host_ld_library_path = host_build_ld_library_path()
  let src = p"arch/arm64/kernel/pi/relacheck.c"
  let out = pi_relacheck_path()

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: [
      src,
    ],
    deps: [],
    argv: [
      host_cc.display(),
      "-Wall",
      "-Wmissing-prototypes",
      "-Wstrict-prototypes",
      "-O2",
      "-fomit-frame-pointer",
      "-std=gnu11",
      "-I",
      "./scripts/include",
      "-o",
      out.display(),
      src.display(),
    ],
    cwd: p".",
    env: {
      TMPDIR: out.parent.display(),
      PATH: host_path,
      LD_LIBRARY_PATH: host_ld_library_path,
      XSH_MAKE_NATIVE_CROSS: "0",
    },
    depfile: p"",
    stamp: fp"{out}.cmd",
  }
}

proc pi_relacheck_task(relacheck: Path, input: Path, original: Path, deps: List[Str]) -> make.MakeTask {
  let stamp = fp"{input}.relacheck.cmd"

  {
    name: f"{input}:relacheck",
    outputs: [
      stamp,
    ],
    inputs: [
      relacheck,
      input,
      original,
    ],
    deps: deps,
    argv: [
      relacheck.display(),
      input.display(),
      original.display(),
    ],
    cwd: p".",
    env: {},
    depfile: p"",
    stamp: stamp,
  }
}

## Exported declaration `generate_empty_root_dtb_asm`.
export proc generate_empty_root_dtb_asm(root: Path) [fs, error] {
  write_text_if_changed(
    fp"{root}/drivers/of/empty_root.dtb.S",
    """#include <asm-generic/vmlinux.lds.h>
.section .rodata,"a"
.balign STRUCT_ALIGNMENT
.global __dtb_empty_root_begin
__dtb_empty_root_begin:
.byte 0xd0,0x0d,0xfe,0xed,0x00,0x00,0x00,0x83,0x00,0x00,0x00,0x38
.byte 0x00,0x00,0x00,0x68,0x00,0x00,0x00,0x28,0x00,0x00,0x00,0x11
.byte 0x00,0x00,0x00,0x10,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x1b
.byte 0x00,0x00,0x00,0x30,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
.byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01
.byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x03,0x00,0x00,0x00,0x04
.byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x02,0x00,0x00,0x00,0x03
.byte 0x00,0x00,0x00,0x04,0x00,0x00,0x00,0x0f,0x00,0x00,0x00,0x02
.byte 0x00,0x00,0x00,0x02,0x00,0x00,0x00,0x09,0x23,0x61,0x64,0x64
.byte 0x72,0x65,0x73,0x73,0x2d,0x63,0x65,0x6c,0x6c,0x73,0x00,0x23
.byte 0x73,0x69,0x7a,0x65,0x2d,0x63,0x65,0x6c,0x6c,0x73,0x00
.global __dtb_empty_root_end
__dtb_empty_root_end:
.balign STRUCT_ALIGNMENT
""",
  )
}

## Exported declaration `generate_crc32table_header`.
export proc generate_crc32table_header(root: Path, cc: Path) [fs, process, env, error] {
  let gen = fp"{root}/lib/crc/gen_crc32table"
  let source = fp"{root}/lib/crc/gen_crc32table.c"
  let argv = [cc.display(), "-Iinclude", "-Iinclude/generated", "-o", gen.display(), source.display()]
  let build_root = e"XSH_PM_BUILD_ROOT" ?? ""
  let build_env = {PATH: f"{build_root}/usr/bin:{e"PATH" ?? ""}"}

  let compile_command = if build_root != "" {
    process.command_argv(argv[0], argv, env: build_env)
  } else {
    process.command_argv(argv[0], argv)
  }

  let compile_status = process.run(compile_command)?

  if ! compile_status.ok {
    return Err(ScriptError.Failed(kind: "linux-crc32table-compile", message: f"command failed: {argv.join(" ")}"))
  }

  let output = run.text $gen ?
  write_text_if_changed(fp"{root}/lib/crc/crc32table.h", output)
}

## Exported declaration `generate_raid6_sources`.
export proc generate_raid6_sources(root: Path, cc: Path) [fs, process, env, error] {
  let int_uc = fp"{root}/lib/raid/raid6/int.uc".read_text()?

  for n in [1, 2, 4, 8] {
    var lines: List[Str] = []

    for line in int_uc.split("\n") {
      let reps = if "$$" in line { n } else { 1 }
      var i = 0

      while i < reps {
        lines += [line.replace("$$", f"{i}").replace("$#", f"{n}").replace("$*", "$")]
        i += 1
      }
    }

    write_text_if_changed(
      fp"{root}/lib/raid/raid6/int{n}.c",
      f"""{lines.join("\n")}
""",
    )
  }

  let gen = fp"{root}/lib/raid/raid6/mktables"
  let source = fp"{root}/lib/raid/raid6/mktables.c"

  let argv = [
    cc.display(),
    "-O2",
    "-std=gnu11",
    "-Wall",
    "-I./tools/include",
    "-o",
    gen.display(),
    source.display(),
  ]

  let build_root = e"XSH_PM_BUILD_ROOT" ?? ""
  let build_env = {PATH: f"{build_root}/usr/bin:{e"PATH" ?? ""}"}

  let compile_command = if build_root != "" {
    process.command_argv(argv[0], argv, env: build_env)
  } else {
    process.command_argv(argv[0], argv)
  }

  let compile_status = process.run(compile_command)?

  if ! compile_status.ok {
    return Err(ScriptError.Failed(kind: "linux-raid6-mktables-compile", message: f"command failed: {argv.join(" ")}"))
  }

  let tables = run.text $gen ?
  write_text_if_changed(fp"{root}/lib/raid/raid6/tables.c", tables)
}

pure dir_archive(dir: Path) -> Path {
  return p".xsh-kbuild/built-in.a" when path_key(dir) == "."

  fp".xsh-kbuild/{dir}/built-in.a"
}

pure dir_lib_archive(dir: Path) -> Path {
  return p".xsh-kbuild/lib.a" when path_key(dir) == "."

  fp".xsh-kbuild/{dir}/lib.a"
}

proc insert_archive_before(
  objs: List[Path],
  deps: List[Str],
  archive_path: Path,
  dep: Str,
  marker: Path,
) -> ArchiveInputs {
  var out_objs: List[Path] = []
  var out_deps: List[Str] = []
  var inserted = false
  var index = 0
  let marker_key = path_key(marker)

  for obj in objs {
    if ! inserted and path_key(obj) == marker_key {
      out_objs += [archive_path]
      out_deps += [dep]
      inserted = true
    }

    out_objs += [obj]
    out_deps += [deps[index]]
    index += 1
  }

  if ! inserted {
    out_objs += [archive_path]
    out_deps += [dep]
  }

  {objs: out_objs, deps: out_deps}
}

pure object_dir(obj: Path) -> Path {
  guard "/" in obj.display() else {
    return p"."
  }

  obj.parent
}

pure archive_parent_key(key: Str) -> Str {
  return "arch/x86" when key == "arch/x86/boot/startup"

  return "drivers/iommu" when key == "drivers/iommu/generic_pt/fmt"

  if key == "." or ! ("/" in key) or (key.starts_with("arch/") and key.split("/").len() == 2) {
    return "."
  }

  let parts = key.split("/")
  parts |> take(parts.len() - 1).join("/")
}

pure is_known_generated_object(obj: Path) -> Bool {
  let key = path_key(obj)
  key.ends_with(".pi.o") or key.ends_with(".dtb.o") or key == "lib/crypto/powerpc/aesp8-ppc.o" or key == "lib/crypto/arm/sha256-core.o" or key == "lib/crypto/arm64/sha256-core.o" or key == "lib/crypto/arm/sha512-core.o" or key == "lib/crypto/arm64/sha512-core.o"
}

pure is_pi_object(obj: Path) -> Bool {
  path_key(obj).ends_with(".pi.o")
}

pure archive_object_cflags_from_extra(cflags: List[Str], extra_flags: List[Str], obj: Path) -> List[Str] {
  let base = cflags.extend(extra_flags)
  if path_key(obj).starts_with("drivers/firmware/efi/libstub/") {
    return efi_libstub_cflags(base)
  }

  base
}

pure pi_base_name(obj: Path) -> Str {
  obj.name.replace(".pi.o", "")
}

pure pi_base_object(obj: Path) -> Path {
  join_rel(object_dir(obj), f"{pi_base_name(obj)}.o")
}

pure pi_source(obj: Path) -> Path {
  let base = pi_base_name(obj)

  return fp"lib/{base.replace("lib-", "")}.c" when base.starts_with("lib-")

  join_rel(object_dir(obj), f"{base}.c")
}

pure abi_enabled(abi: Str, abis: List[Str]) -> Bool {
  return true when abis.is_empty()

  abi in abis
}

pure syscall_line(nr: Int, native: Str, compat: Str, noreturn: Str) -> Result[Str] {
  if compat != "" and noreturn == "noreturn" {
    return f"__SYSCALL_COMPAT_NORETURN({nr}, {native}, {compat})"
  }

  return f"__SYSCALL_NORETURN({nr}, {native})" when noreturn == "noreturn"

  return f"__SYSCALL_WITH_COMPAT({nr}, {native}, {compat})" when compat != ""

  return f"__SYSCALL({nr}, {native})" when native != ""

  f"__SYSCALL({nr}, sys_ni_syscall)"
}

## Exported declaration `generate_syscall_table`.
export proc generate_syscall_table(table: Path, out: Path, abis: List[Str] = []) [fs, error] {
  var lines: List[Str] = []
  var next_nr = 0

  for raw in table.read_text()?.split("\n") {
    let line = raw.split("#")[0].trim()

    if line != "" {
      let fields = line.fields()
      let nr = fields[0].parse_int()?
      let abi = fields[1]

      if abi_enabled(abi, abis) {
        if next_nr > nr {
          return Err(ScriptError.Failed(kind: "kbuild-syscall-order", message: f"{table} is not sorted at syscall {nr}"))
        }

        while next_nr < nr {
          lines += [f"__SYSCALL({next_nr}, sys_ni_syscall)"]
          next_nr += 1
        }

        let native = fields.get(3) ?? ""
        let compat = if (fields.get(4) ?? "") == "-" { "" } else { fields.get(4) ?? "" }
        let noreturn = fields.get(5) ?? ""

        if noreturn != "" and noreturn != "noreturn" {
          return Err(ScriptError.Failed(kind: "kbuild-syscall-noreturn", message: f"invalid noreturn marker '{noreturn}'"))
        }

        lines += [syscall_line(nr, native, compat, noreturn)?]
        next_nr = nr + 1
      }
    }
  }

  write_text_if_changed(
    out,
    f"""{lines.join("\n")}
""",
  )
}

## Exported declaration `generate_syscall_numbers`.
export proc generate_syscall_numbers(
  table: Path,
  out: Path,
  header_guard: Str,
  syscall_count_name: Str,
  prefix: Str = "",
  abis: List[Str] = [],
) [fs, error] {
  var lines = [f"#ifndef {header_guard}", f"#define {header_guard}", ""]
  var max_nr = -1

  for raw in table.read_text()?.split("\n") {
    let line = raw.split("#")[0].trim()

    if line != "" {
      let fields = line.fields()
      let nr = fields[0].parse_int()?
      let abi = fields[1]

      if abi_enabled(abi, abis) {
        lines += [f"#define __NR_{prefix}{fields[2]} {nr}"]

        if nr > max_nr {
          max_nr = nr
        }
      }
    }
  }

  lines += [
      "",
      "#ifdef __KERNEL__",
      f"#define {syscall_count_name} {max_nr + 1}",
      "#endif",
      "",
      f"#endif /* {header_guard} */",
    ]

  write_text_if_changed(
    out,
    f"""{lines.join("\n")}
""",
  )
}

## Exported declaration `generate_arm64_syscall_tables`.
export proc generate_arm64_syscall_tables(root: Path) [fs, error] {
  generate_syscall_table(
    fp"{root}/arch/arm64/tools/syscall_64.tbl",
    fp"{root}/arch/arm64/include/generated/asm/syscall_table_64.h",
    ["common", "64", "renameat", "rlimit", "memfd_secret"],
  )

  generate_syscall_table(
    fp"{root}/arch/arm64/tools/syscall_32.tbl",
    fp"{root}/arch/arm64/include/generated/asm/syscall_table_32.h",
    ["common", "32", "renameat", "rlimit", "memfd_secret"],
  )

  generate_syscall_numbers(
    fp"{root}/arch/arm64/tools/syscall_64.tbl",
    fp"{root}/arch/arm64/include/generated/uapi/asm/unistd_64.h",
    "_UAPI_ASM_UNISTD_64_H",
    "__NR_syscalls",
    "",
    ["common", "64", "renameat", "rlimit", "memfd_secret"],
  )

  generate_syscall_numbers(
    fp"{root}/arch/arm64/tools/syscall_32.tbl",
    fp"{root}/arch/arm64/include/generated/asm/unistd_32.h",
    "_UAPI_ASM_UNISTD_32_H",
    "__NR_syscalls",
    "",
    ["common", "32", "renameat", "rlimit", "memfd_secret"],
  )

  generate_syscall_numbers(
    fp"{root}/arch/arm64/tools/syscall_32.tbl",
    fp"{root}/arch/arm64/include/generated/asm/unistd_compat_32.h",
    "_UAPI_ASM_UNISTD_COMPAT_32_H",
    "__NR_compat32_syscalls",
    "compat32_",
    ["common", "32", "renameat", "rlimit", "memfd_secret"],
  )
}

## Exported declaration `generate_x86_syscall_tables`.
export proc generate_x86_syscall_tables(root: Path) [fs, error] {
  generate_syscall_table(
    fp"{root}/arch/x86/entry/syscalls/syscall_64.tbl",
    fp"{root}/arch/x86/include/generated/asm/syscalls_64.h",
    ["common", "64", "renameat", "rlimit", "memfd_secret"],
  )

  generate_syscall_numbers(
    fp"{root}/arch/x86/entry/syscalls/syscall_64.tbl",
    fp"{root}/arch/x86/include/generated/uapi/asm/unistd_64.h",
    "_UAPI_ASM_UNISTD_64_H",
    "__NR_syscalls",
    "",
    ["common", "64", "renameat", "rlimit", "memfd_secret"],
  )

  generate_syscall_numbers(
    fp"{root}/arch/x86/entry/syscalls/syscall_64.tbl",
    fp"{root}/arch/x86/include/generated/asm/unistd_64_x32.h",
    "_ASM_X86_UNISTD_64_X32_H",
    "__NR_x32_syscalls",
    "x32_",
    ["common", "x32", "renameat", "rlimit", "memfd_secret"],
  )

  generate_syscall_numbers(
    fp"{root}/arch/x86/entry/syscalls/syscall_32.tbl",
    fp"{root}/arch/x86/include/generated/asm/unistd_32_ia32.h",
    "_ASM_X86_UNISTD_32_IA32_H",
    "__NR_ia32_syscalls",
    "ia32_",
    ["i386"],
  )
}

## Exported declaration `generate_offsets_header`.
export proc generate_offsets_header(asm_path: Path, out: Path, header_guard: Str) [fs, error] {
  var lines = [
    f"#ifndef {header_guard}",
    f"#define {header_guard}",
    "/*",
    " * DO NOT MODIFY.",
    " *",
    " * This file was generated by Kbuild",
    " */",
    "",
  ]

  for raw in asm_path.read_text()?.split("\n") {
    let line = raw.trim()

    match regex_captures(line, "\\.ascii\\s+\"->([^\"]*)\"") {
      Ok(caps) => {
        if caps.len() >= 2 {
          let body = caps[1].trim()

          if body == "" {
            lines += [""]
          } else {
            let parts = body.fields()
            let name = parts.get(0) ?? ""
            let value = (parts.get(1) ?? "").replace("$", "")
            let comment = parts |> drop(2)

            if name != "" and value != "" {
              lines += [f"#define {name} {value} /* {comment.join(" ")} */"]
            }
          }
        }
      }
      Err(_) => {}
    }
  }

  lines += [""]
  lines += ["#endif"]

  write_text_if_changed(
    out,
    f"""{lines.join("\n")}
""",
  )
}

## Exported declaration `image_argv_task`.
export proc image_argv_task(
  objcopy_argv: List[Str],
  vmlinux: Path,
  image: Path,
  deps: List[Str] = [],
) [env] -> make.MakeTask {
  let tool_path = host_build_path()

  {
    name: image.display(),
    outputs: [
      image,
    ],
    inputs: [
      vmlinux,
    ],
    deps: deps,
    argv: [
      @objcopy_argv,
      "-O",
      "binary",
      "-R",
      ".note",
      "-R",
      ".note.gnu.build-id",
      "-R",
      ".comment",
      "-S",
      vmlinux.display(),
      image.display(),
    ],
    cwd: p".",
    env: {
      PATH: tool_path,
    },
    depfile: p"",
    stamp: fp"{image}.cmd",
  }
}

## Exported declaration `image_task`.
export proc image_task(objcopy: Path, vmlinux: Path, image: Path, deps: List[Str] = []) [env] -> make.MakeTask {
  image_argv_task([objcopy.display()], vmlinux, image, deps)
}

proc x86_compressed_vmlinux_bin_task(
  objcopy: Path,
  vmlinux: Path,
  out: Path,
  deps: List[Str] = [],
) -> make.MakeTask {
  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: [
      vmlinux,
    ],
    deps: deps,
    argv: [
      objcopy.display(),
      "-R",
      ".comment",
      "-S",
      vmlinux.display(),
      out.display(),
    ],
    cwd: p".",
    env: {},
    depfile: p"",
    stamp: fp"{out}.cmd",
  }
}

## Exported declaration `vmlinux_archive_argv_task`.
export proc vmlinux_archive_argv_task(
  ar_argv: List[Str],
  inputs: List[Path],
  out: Path,
  deps: List[Str] = [],
) [env] -> make.MakeTask {
  var argv = ar_argv.extend(["cDPrST", out.display()])
  let tool_path = host_build_path()

  for input in inputs {
    argv += [input.display()]
  }

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: inputs,
    deps: deps,
    argv: [
      @argv,
    ],
    cwd: p".",
    env: {
      PATH: tool_path,
    },
    depfile: p"",
    stamp: fp"{out}.cmd",
  }
}

## Exported declaration `vmlinux_archive_task`.
export proc vmlinux_archive_task(ar: Path, inputs: List[Path], out: Path, deps: List[Str] = []) [env] -> make.MakeTask {
  vmlinux_archive_argv_task([ar.display()], inputs, out, deps)
}

## Exported declaration `vmlinux_o_task`.
export proc vmlinux_o_task(
  ld: Path,
  kbuild_ldflags: List[Str],
  kernel_archive: Path,
  libs: List[Path],
  out: Path,
  deps: List[Str] = [],
) [env] -> make.MakeTask {
  vmlinux_o_argv_task([ld.display()], kbuild_ldflags, kernel_archive, libs, out, deps)
}

## Exported declaration `vmlinux_o_argv_task`.
export proc vmlinux_o_argv_task(
  ld_argv: List[Str],
  kbuild_ldflags: List[Str],
  kernel_archive: Path,
  libs: List[Path],
  out: Path,
  deps: List[Str] = [],
) [env] -> make.MakeTask {
  let tool_path = host_build_path()
  var argv = ld_argv
  argv += kbuild_ldflags

  argv += ["-r", "-o", out.display(), "--whole-archive", kernel_archive.display(), "--no-whole-archive", "--start-group"]

  for lib in libs {
    argv += [lib.display()]
  }

  argv += ["--end-group"]

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: [
      kernel_archive,
    ].extend(libs),
    deps: deps,
    argv: [
      @argv,
    ],
    cwd: p".",
    env: {
      PATH: tool_path,
    },
    depfile: p"",
    stamp: fp"{out}.cmd",
  }
}

## Exported declaration `vmlinux_unstripped_task`.
export proc vmlinux_unstripped_task(
  ld: Path,
  kbuild_ldflags: List[Str],
  ldflags_vmlinux: List[Str],
  linker_script: Path,
  kernel_archive: Path,
  libs: List[Path],
  export_obj: Path,
  version_obj: Path,
  out: Path,
  deps: List[Str] = [],
) [env] -> make.MakeTask {
  vmlinux_unstripped_argv_task(
    [ld.display()],
    kbuild_ldflags,
    ldflags_vmlinux,
    linker_script,
    kernel_archive,
    libs,
    export_obj,
    version_obj,
    out,
    deps,
  )
}

## Exported declaration `vmlinux_unstripped_argv_task`.
export proc vmlinux_unstripped_argv_task(
  ld_argv: List[Str],
  kbuild_ldflags: List[Str],
  ldflags_vmlinux: List[Str],
  linker_script: Path,
  kernel_archive: Path,
  libs: List[Path],
  export_obj: Path,
  version_obj: Path,
  out: Path,
  deps: List[Str] = [],
) [env] -> make.MakeTask {
  let tool_path = host_build_path()
  var argv = ld_argv
  argv = [@argv, @kbuild_ldflags, @ldflags_vmlinux]
  argv += ["--script", linker_script.display(), "-o", out.display()]

  argv += [
      "--whole-archive",
      kernel_archive.display(),
      export_obj.display(),
      version_obj.display(),
      "--no-whole-archive",
      "--start-group",
    ]

  for lib in libs {
    argv += [lib.display()]
  }

  argv += ["--end-group"]

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: [
      kernel_archive,
      linker_script,
      export_obj,
      version_obj,
    ].extend(libs),
    deps: deps,
    argv: [
      @argv,
    ],
    cwd: p".",
    env: {
      PATH: tool_path,
    },
    depfile: p"",
    stamp: fp"{out}.cmd",
  }
}

## Exported declaration `arm64_vmlinux_ldflags`.
export pure arm64_vmlinux_ldflags(config: Kconfig) -> List[Str] {
  let base = ["--no-undefined", "-X", "--pic-veneer"]

  let relocatable = if config_value(config, "RELOCATABLE") == "y" {
    base.extend(["-shared", "-Bsymbolic", "-z", "notext", "--no-apply-dynamic-relocs"])
  } else {
    base
  }

  let with_build_id = relocatable.push("--build-id=sha1")

  let with_relr = if config_value(config, "RELR") == "y" {
    with_build_id.push("--pack-dyn-relocs=relr")
  } else {
    with_build_id
  }

  with_relr.push("--orphan-handling=warn")
}

## Exported declaration `vmlinux_strip_argv_task`.
export proc vmlinux_strip_argv_task(
  objcopy_argv: List[Str],
  unstripped: Path,
  out: Path,
  deps: List[Str] = [],
) [env] -> make.MakeTask {
  let tool_path = host_build_path()

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: [
      unstripped,
    ],
    deps: deps,
    argv: [
      @objcopy_argv,
      "--remove-section=.modinfo",
      "-w",
      "--strip-unneeded-symbol=__mod_device_table__*",
      unstripped.display(),
      out.display(),
    ],
    cwd: p".",
    env: {
      PATH: tool_path,
    },
    depfile: p"",
    stamp: fp"{out}.cmd",
  }
}

## Exported declaration `vmlinux_strip_task`.
export proc vmlinux_strip_task(
  objcopy: Path,
  unstripped: Path,
  out: Path,
  deps: List[Str] = [],
) [env] -> make.MakeTask {
  vmlinux_strip_argv_task([objcopy.display()], unstripped, out, deps)
}

proc x86_vmlinux_strip_argv_task(
  objcopy_argv: List[Str],
  unstripped: Path,
  out: Path,
  deps: List[Str] = [],
) -> make.MakeTask {
  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: [
      unstripped,
    ],
    deps: deps,
    argv: [
      @objcopy_argv,
      "--remove-section=.modinfo",
      "--remove-section=.rel*",
      "--remove-section=!.rel*.dyn",
      "--remove-section=.rel.*",
      "-w",
      "--strip-unneeded-symbol=__mod_device_table__*",
      unstripped.display(),
      out.display(),
    ],
    cwd: p".",
    env: {},
    depfile: p"",
    stamp: fp"{out}.cmd",
  }
}

## Exported declaration `write_image`.
export proc write_image(objcopy: Path, vmlinux: Path, image: Path) [fs, process, env, error] {
  make.run_tasks([image_task(objcopy, vmlinux, image)], 1)
}

proc generate_vmlinux_lds(cc: Path, out: Path) [fs, process, error] {
  let depfile = fp"{out}.d"
  let src = p"arch/arm64/kernel/vmlinux.lds.S"

  run (
    $cc
    "-target"
    "aarch64-linux-gnu"
    "-E"
    "-MMD"
    "-MP"
    "-MF"
    $depfile
    "-nostdinc"
    "-I./arch/arm64/include"
    "-I./arch/arm64/include/generated"
    "-I./include"
    "-I./include/generated"
    "-I./arch/arm64/include/uapi"
    "-I./arch/arm64/include/generated/uapi"
    "-I./include/uapi"
    "-I./include/generated/uapi"
    "-include"
    "./include/linux/compiler-version.h"
    "-include"
    "./include/linux/kconfig.h"
    "-D__KERNEL__"
    "-mlittle-endian"
    "-DKASAN_SHADOW_SCALE_SHIFT="
    "-P"
    "-Uarm64"
    "-D__ASSEMBLY__"
    "-DLINKER_SCRIPT"
    "-o"
    $out
    $src
  ) ?
}

proc generate_vmlinux_lds_x86(cc: Path, out: Path) [fs, process, error] {
  let depfile = fp"{out}.d"
  let src = p"arch/x86/kernel/vmlinux.lds.S"

  run (
    $cc
    "-target"
    "x86_64-linux-gnu"
    "-E"
    "-MMD"
    "-MP"
    "-MF"
    $depfile
    "-nostdinc"
    "-I./arch/x86/include"
    "-I./arch/x86/include/generated"
    "-I./include"
    "-I./include/generated"
    "-I./arch/x86/include/uapi"
    "-I./arch/x86/include/generated/uapi"
    "-I./include/uapi"
    "-I./include/generated/uapi"
    "-include"
    "./include/linux/compiler-version.h"
    "-include"
    "./include/linux/kconfig.h"
    "-D__KERNEL__"
    "-DKASAN_SHADOW_SCALE_SHIFT="
    "-P"
    "-D__ASSEMBLY__"
    "-DLINKER_SCRIPT"
    "-o"
    $out
    $src
  ) ?
}

## Exported declaration `x86_vmlinux_ldflags`.
export pure x86_vmlinux_ldflags(config: Kconfig) -> List[Str] {
  let base = ["--no-undefined", "-X", "-z", "max-page-size=0x200000"]
  let with_relr = if config_value(config, "RELR") == "y" { base.push("--pack-dyn-relocs=relr") } else { base }
  let with_build_id = with_relr.push("--build-id=sha1")

  let with_relocs = if config_value(config, "ARCH_VMLINUX_NEEDS_RELOCS") == "y" {
    with_build_id.extend(["--emit-relocs", "--discard-none"])
  } else {
    with_build_id
  }

  with_relocs.push("--orphan-handling=warn")
}

# On x86 the EFI stub library links only into the compressed boot image
# (`build_x86_compressed_kernel` takes its own lib.a), never into vmlinux: its
# objects carry private copies of lib/ helpers such as vsnprintf and
# skip_spaces without the symbol prefix arm64 gives them, so whole-archiving
# them into vmlinux.a defines those symbols twice.
## The archives and objects whole-archived into the x86 vmlinux.a.
export pure vmlinux_x86_archive_inputs(link_inputs: List[Path]) -> List[Path] {
  if ! link_inputs.is_empty() {
    return [input for input in link_inputs if ! path_key(input).starts_with(".xsh-kbuild/obj/drivers/firmware/efi/libstub/")]
  }

  [p".xsh-kbuild/built-in.a", p".xsh-kbuild/arch/x86/lib/lib.a", p".xsh-kbuild/lib/lib.a"]
}

pure efi_libstub_stems_x86() -> List[Str] {
  [
    "alignedmem",
    "efi-stub-helper",
    "file",
    "gop",
    "lib-cmdline",
    "lib-ctype",
    "mem",
    "pci",
    "printk",
    "random",
    "randomalloc",
    "secureboot",
    "skip_spaces",
    "smbios",
    "tpm",
    "vsprintf",
    "x86-5lvl",
    "x86-stub",
  ]
}

pure efi_libstub_source_x86(stem: Str) -> Path {
  return fp"lib/{stem.replace("lib-", "")}.c" when stem.starts_with("lib-")

  return fp"drivers/firmware/efi/libstub/x86-stub.c" when stem == "x86-stub"

  fp"drivers/firmware/efi/libstub/{stem}.c"
}

proc append_x86_relocs(relocs: Path, input: Path, out: Path) {
  let input_text = input.display()
  let reloc_data = run.capture --bytes $relocs $input_text ?

  if ! reloc_data.status.ok {
    return Err(ScriptError.Failed(kind: "linux-x86-relocs", message: f"relocs failed for {input}"))?
  }

  let abs_relocs = run.capture --bytes $relocs "--abs-relocs" $input_text ?

  if ! abs_relocs.status.ok {
    return Err(ScriptError.Failed(kind: "linux-x86-relocs", message: f"relocs --abs-relocs failed for {input}"))?
  }

  out.write(bytes.concat([p"arch/x86/boot/compressed/vmlinux.bin".read_bytes()?, reloc_data.stdout]))
}

proc write_x86_voffset_header(nm: Path, input: Path) {
  let symbol_re = rx"^([0-9a-fA-F]+) [ABbCDGRSTtVW] (_text|__start_rodata|_sinittext|__inittext_end|__bss_start|_end)$"

  let symbols = run.text $nm $input ?
  var lines: List[Str] = []

  for raw in symbols.lines() {
    let caps = symbol_re.captures(raw)

    if caps.len() >= 3 {
      lines += [f"#define VO_{caps[2]} _AC(0x{caps[1]},UL)"]
    }
  }

  if lines.is_empty() {
    return Err(ScriptError.Failed(kind: "linux-x86-voffset", message: f"no voffset symbols found in {input}"))?
  }

  write_text_if_changed(
    p"arch/x86/boot/voffset.h",
    f"""{lines.join("\n")}
""",
  )
}

proc write_x86_zoffset_header(nm: Path, input: Path) {
  let symbol_re = rx"^([0-9a-fA-F]+) [a-zA-Z] (startup_32|efi.._stub_entry|efi(32)?_pe_entry|input_data|kernel_info|_end|_ehead|_text|_e?data|_e?sbat|z_.*)$"

  let symbols = run.text $nm $input ?
  var lines: List[Str] = []

  for raw in symbols.lines() {
    let caps = symbol_re.captures(raw)

    if caps.len() >= 3 {
      lines += [f"#define ZO_{caps[2]} 0x{caps[1]}"]
    }
  }

  if lines.is_empty() {
    return Err(ScriptError.Failed(kind: "linux-x86-zoffset", message: f"no zoffset symbols found in {input}"))?
  }

  write_text_if_changed(
    p"arch/x86/boot/zoffset.h",
    f"""{lines.join("\n")}
""",
  )
}

pure x86_compressed_cflags() -> List[Str] {
  [
    "-D__KERNEL__",
    "-m64",
    "-O2",
    "-std=gnu11",
    "-fms-extensions",
    "-fno-strict-aliasing",
    "-fPIE",
    "-Wundef",
    "-DDISABLE_BRANCH_PROFILING",
    # The decompressor runs before CPU feature checks: clang's x86-64
    # baseline, not the -march=x86-64-v3 the `cc` wrapper would add.
    "-march=x86-64",
    "-mcmodel=small",
    "-mno-red-zone",
    "-mno-mmx",
    "-mno-sse",
    "-ffreestanding",
    "-fshort-wchar",
    "-fno-stack-protector",
    "-Wno-address-of-packed-member",
    "-Wno-gnu",
    "-Wno-microsoft-anon-tag",
    "-Wno-pointer-sign",
    "-fno-asynchronous-unwind-tables",
    "-D__DISABLE_EXPORTS",
    "-include",
    "include/linux/hidden.h",
  ]
}

pure x86_compressed_includes() -> List[Str] {
  [
    "-nostdinc",
    "-I./arch/x86/boot/compressed",
    "-I./arch/x86/boot",
    "-I./arch/x86/lib",
    "-I./arch/x86/include",
    "-I./arch/x86/include/generated",
    "-I./include",
    "-I./arch/x86/include/uapi",
    "-I./arch/x86/include/generated/uapi",
    "-I./include/uapi",
    "-I./include/generated/uapi",
    "-include",
    "./include/linux/compiler-version.h",
    "-include",
    "./include/linux/kconfig.h",
    "-include",
    "./include/linux/compiler_types.h",
  ]
}

pure x86_linker_script_includes() -> List[Str] {
  [
    "-nostdinc",
    "-I./arch/x86/boot/compressed",
    "-I./arch/x86/boot",
    "-I./arch/x86/lib",
    "-I./arch/x86/include",
    "-I./arch/x86/include/generated",
    "-I./include",
    "-I./arch/x86/include/uapi",
    "-I./arch/x86/include/generated/uapi",
    "-I./include/uapi",
    "-I./include/generated/uapi",
    "-include",
    "./include/linux/kconfig.h",
  ]
}

pure x86_setup_cflags() -> List[Str] {
  [
    "-D__KERNEL__",
    "-std=gnu11",
    "-fms-extensions",
    "-m16",
    "-g",
    "-Os",
    "-DDISABLE_BRANCH_PROFILING",
    "-D__DISABLE_EXPORTS",
    "-Wall",
    "-Wstrict-prototypes",
    "-march=i386",
    "-mregparm=3",
    "-fno-strict-aliasing",
    "-fomit-frame-pointer",
    "-fno-pic",
    "-mno-mmx",
    "-mno-sse",
    "-fcf-protection=none",
    "-ffreestanding",
    "-fno-stack-protector",
    "-Wno-address-of-packed-member",
    "-mstack-alignment=4",
    "-Wno-gnu",
    "-Wno-microsoft-anon-tag",
    "-D_SETUP",
    "-fno-asynchronous-unwind-tables",
  ]
}

pure x86_setup_includes() -> List[Str] {
  [
    "-nostdinc",
    "-I./arch/x86/boot",
    "-I./arch/x86/include",
    "-I./arch/x86/include/generated",
    "-I./include",
    "-I./arch/x86/include/uapi",
    "-I./arch/x86/include/generated/uapi",
    "-I./include/uapi",
    "-I./include/generated/uapi",
    "-include",
    "./include/linux/compiler-version.h",
    "-include",
    "./include/linux/kconfig.h",
    "-include",
    "./include/linux/compiler_types.h",
  ]
}

proc preprocess_x86_boot_lds(cc: Path, source: Path, out: Path, includes: List[Str]) {
  let argv = [
    cc.display(),
    "-target",
    "x86_64-linux-gnu",
    "-Wno-unused-command-line-argument",
    "-D__ASSEMBLY__",
    "-DLINKER_SCRIPT",
    "-Ux86_64",
    "-E",
    "-P",
    @includes,
    source.display(),
    "-o",
    out.display(),
  ]

  run $cc ${argv |> drop(1)} ?
}

proc build_x86_compressed_kernel(
  cc: Path,
  unstripped: Path,
  vmlinux: Path,
  efi_lib: Path,
  jobs_count: Int,
) {
  let objcopy = process.which("llvm-objcopy")?
  let nm = process.which("llvm-nm")?
  let ld = process.which("ld.lld")?
  let relocs = p"arch/x86/tools/relocs"
  let compressed = p"arch/x86/boot/compressed"
  compressed.mkdir()
  p".xsh-kbuild/host/arch/x86/boot/compressed".mkdir()
  let kernel_bin = fp"{compressed}/vmlinux.bin"
  let kernel_all = fp"{compressed}/vmlinux.bin.all"
  let kernel_gz = fp"{compressed}/vmlinux.bin.gz"
  let piggy_s = fp"{compressed}/piggy.S"
  let mkpiggy = p".xsh-kbuild/host/arch/x86/boot/compressed/mkpiggy"
  let compressed_lds = fp"{compressed}/vmlinux.lds"
  let compressed_vmlinux = fp"{compressed}/vmlinux"
  let boot_vmlinux_bin = p"arch/x86/boot/vmlinux.bin"
  make.run_tasks([x86_compressed_vmlinux_bin_task(objcopy, vmlinux, kernel_bin)], 1)
  append_x86_relocs(relocs, vmlinux, kernel_all)
  archive.compress(kernel_all, kernel_gz, format: "gzip", level: 9, overwrite: true)
  run $cc "-O2" "-std=gnu11" "-Wall" "-I./tools/include" "-o" $mkpiggy "arch/x86/boot/compressed/mkpiggy.c" ?
  let piggy_text = run.text $mkpiggy $kernel_gz ?
  write_text_if_changed(piggy_s, piggy_text)
  write_x86_voffset_header(nm, unstripped)
  preprocess_x86_boot_lds(cc, fp"{compressed}/vmlinux.lds.S", compressed_lds, x86_linker_script_includes())
  let base_cflags = x86_compressed_cflags()
  let includes = x86_compressed_includes()
  var tasks: List[make.MakeTask] = []
  var objects: List[Path] = []

  for item in [
    {
      source: p"arch/x86/boot/compressed/kernel_info.S",
      object: p"arch/x86/boot/compressed/kernel_info.o",
      asm: true,
    },
    {
      source: p"arch/x86/boot/compressed/head_64.S",
      object: p"arch/x86/boot/compressed/head_64.o",
      asm: true,
    },
    {
      source: p"arch/x86/boot/compressed/misc.c",
      object: p"arch/x86/boot/compressed/misc.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/compressed/string.c",
      object: p"arch/x86/boot/compressed/string.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/compressed/cmdline.c",
      object: p"arch/x86/boot/compressed/cmdline.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/compressed/error.c",
      object: p"arch/x86/boot/compressed/error.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/compressed/piggy.S",
      object: p"arch/x86/boot/compressed/piggy.o",
      asm: true,
    },
    {
      source: p"arch/x86/boot/compressed/cpuflags.c",
      object: p"arch/x86/boot/compressed/cpuflags.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/compressed/early_serial_console.c",
      object: p"arch/x86/boot/compressed/early_serial_console.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/compressed/kaslr.c",
      object: p"arch/x86/boot/compressed/kaslr.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/compressed/ident_map_64.c",
      object: p"arch/x86/boot/compressed/ident_map_64.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/compressed/idt_64.c",
      object: p"arch/x86/boot/compressed/idt_64.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/compressed/idt_handlers_64.S",
      object: p"arch/x86/boot/compressed/idt_handlers_64.o",
      asm: true,
    },
    {
      source: p"arch/x86/boot/compressed/pgtable_64.c",
      object: p"arch/x86/boot/compressed/pgtable_64.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/compressed/acpi.c",
      object: p"arch/x86/boot/compressed/acpi.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/compressed/efi.c",
      object: p"arch/x86/boot/compressed/efi.o",
      asm: false,
    },
  ] {
    let item_cflags = if item.asm { base_cflags.push("-D__ASSEMBLY__") } else { base_cflags }
    let item_defs = if item.asm { ["-D__DISABLE_EXPORTS"] } else { [] }
    var task = compile_kbuild_task(cc, "x86_64-linux-gnu", item_cflags, item_defs, includes, item.source, item.object)

    if item.source == p"arch/x86/boot/compressed/piggy.S" {
      task = {...task, inputs: task.inputs.push(kernel_gz)}
    }

    tasks += [task]
    objects += [item.object]
  }

  make.run_tasks(tasks, jobs_count)

  var argv = [
    ld.display(),
    "-m",
    "elf_x86_64",
    "-pie",
    "--no-dynamic-linker",
    "-z",
    "noexecstack",
    "-u",
    "efi_pe_entry",
    "-T",
    compressed_lds.display(),
    "-o",
    compressed_vmlinux.display(),
  ]

  for object in objects {
    argv += [object.display()]
  }

  argv += [efi_lib.display()]
  argv += [".xsh-kbuild/arch/x86/boot/startup/lib.a"]
  run $ld ${argv |> drop(1)} ?
  write_x86_zoffset_header(nm, compressed_vmlinux)
  make.run_tasks([image_task(objcopy, compressed_vmlinux, boot_vmlinux_bin)], 1)
}

proc build_x86_setup_image(cc: Path, jobs_count: Int) {
  let ld = process.which("ld.lld")?
  let objcopy = process.which("llvm-objcopy")?
  let boot = p"arch/x86/boot"
  p".xsh-kbuild/host/arch/x86/boot".mkdir()
  let mkcpustr = p".xsh-kbuild/host/arch/x86/boot/mkcpustr"
  run $cc "-O2" "-std=gnu11" "-Wall" "-I./tools/include" "-include" "include/generated/autoconf.h" "-D__EXPORTED_HEADERS__" "-o" $mkcpustr "arch/x86/boot/mkcpustr.c" ?
  write_text_if_changed(fp"{boot}/cpustr.h", run.text $mkcpustr?)
  let base_cflags = x86_setup_cflags()
  let includes = x86_setup_includes()
  var tasks: List[make.MakeTask] = []
  var objects: List[Path] = []

  for item in [
    {
      source: p"arch/x86/boot/a20.c",
      object: p"arch/x86/boot/a20.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/bioscall.S",
      object: p"arch/x86/boot/bioscall.o",
      asm: true,
    },
    {
      source: p"arch/x86/boot/cmdline.c",
      object: p"arch/x86/boot/cmdline.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/copy.S",
      object: p"arch/x86/boot/copy.o",
      asm: true,
    },
    {
      source: p"arch/x86/boot/cpu.c",
      object: p"arch/x86/boot/cpu.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/cpuflags.c",
      object: p"arch/x86/boot/cpuflags.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/cpucheck.c",
      object: p"arch/x86/boot/cpucheck.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/early_serial_console.c",
      object: p"arch/x86/boot/early_serial_console.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/edd.c",
      object: p"arch/x86/boot/edd.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/header.S",
      object: p"arch/x86/boot/header.o",
      asm: true,
    },
    {
      source: p"arch/x86/boot/main.c",
      object: p"arch/x86/boot/main.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/memory.c",
      object: p"arch/x86/boot/memory.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/pm.c",
      object: p"arch/x86/boot/pm.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/pmjump.S",
      object: p"arch/x86/boot/pmjump.o",
      asm: true,
    },
    {
      source: p"arch/x86/boot/printf.c",
      object: p"arch/x86/boot/printf.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/regs.c",
      object: p"arch/x86/boot/regs.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/string.c",
      object: p"arch/x86/boot/string.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/tty.c",
      object: p"arch/x86/boot/tty.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/video.c",
      object: p"arch/x86/boot/video.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/video-mode.c",
      object: p"arch/x86/boot/video-mode.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/version.c",
      object: p"arch/x86/boot/version.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/video-vga.c",
      object: p"arch/x86/boot/video-vga.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/video-vesa.c",
      object: p"arch/x86/boot/video-vesa.o",
      asm: false,
    },
    {
      source: p"arch/x86/boot/video-bios.c",
      object: p"arch/x86/boot/video-bios.o",
      asm: false,
    },
  ] {
    let item_cflags = if item.asm { base_cflags.push("-D__ASSEMBLY__") } else { base_cflags }
    # Assembler tasks keep only defines, not cflags. header.S's vid_mode
    # defaults to ASK_VGA, which stops a direct `-kernel` boot at a 30 s
    # video-mode prompt; upstream builds the setup with SVGA_MODE=NORMAL_VGA.
    let item_defs = if item.asm { ["-D__DISABLE_EXPORTS", "-D_SETUP", "-DSVGA_MODE=NORMAL_VGA"] } else { [] }
    let item_triple = if item.asm { "i386-linux-gnu" } else { "x86_64-linux-gnu" }
    let task = compile_kbuild_task(cc, item_triple, item_cflags, item_defs, includes, item.source, item.object)
    tasks += [task]
    objects += [item.object]
  }

  make.run_tasks(tasks, jobs_count)

  var argv = [
    ld.display(),
    "-m",
    "elf_i386",
    "-z",
    "noexecstack",
    "-T",
    "arch/x86/boot/setup.ld",
    "-o",
    "arch/x86/boot/setup.elf",
  ]

  for object in objects {
    argv += [object.display()]
  }

  run $ld ${argv |> drop(1)} ?
  run $objcopy "-O" "binary" "arch/x86/boot/setup.elf" "arch/x86/boot/setup.bin" ?
}

proc write_x86_bzimage(setup: Path, payload: Path, image: Path) {
  let setup_data = setup.read_bytes()?
  let payload_data = payload.read_bytes()?
  let remainder = setup_data.len() % 4096
  let padding_len = if remainder == 0 { 0 } else { 4096 - remainder }
  image.write(bytes.concat([setup_data, bytes.zero(padding_len)?, payload_data]))
}

## Exported declaration `build_scratch_x86_final`.
export proc build_scratch_x86_final(
  cc: Path,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  link_inputs: List[Path],
  jobs_count: Int = 1,
) [fs, process, env, error] {
  write_minimal_vmlinux_export(p".")
  let _ = cc
  let ar_argv = ["llvm-ar"]
  let ld_argv = ["ld.lld"]
  let objcopy_argv = ["llvm-objcopy"]
  let vmlinux_a = p"vmlinux.a"
  let unstripped = p"vmlinux.unstripped"
  let vmlinux = p"vmlinux"
  let image = p"arch/x86/boot/bzImage"
  let efi_lib = p"drivers/firmware/efi/libstub/lib.a"
  let support_lib = p"lib/xsh-final-lib.a"
  let kbuild_ldflags = ["-m", "elf_x86_64", "-z", "norelro", "-z", "noexecstack"]
  let ldflags_vmlinux = x86_vmlinux_ldflags(load_config(p".config")?)
  write_ubsan_stubs(p".")
  let lds = p"arch/x86/kernel/vmlinux.lds"
  generate_vmlinux_lds_x86(cc, lds)
  vmlinux_a.remove(missing_ok: true)
  unstripped.remove(missing_ok: true)
  vmlinux.remove(missing_ok: true)
  fp"arch/x86/boot".mkdir()
  image.remove(missing_ok: true)
  var tasks: List[make.MakeTask] = []

  let export_task = compile_kbuild_task(
    cc,
    "x86_64-linux-gnu",
    cflags,
    defs,
    includes,
    p".vmlinux.export.c",
    p".vmlinux.export.o",
  )

  tasks += [export_task]

  let version_task = compile_kbuild_task(
    cc,
    "x86_64-linux-gnu",
    cflags,
    defs,
    includes,
    p"init/version-timestamp.c",
    p"init/version-timestamp.o",
  )

  tasks += [version_task]
  var stub_objs: List[Path] = []
  var stub_deps: List[Str] = []

  for stem in efi_libstub_stems_x86() {
    let obj = fp"drivers/firmware/efi/libstub/{stem}.o"
    let stub = fp"drivers/firmware/efi/libstub/{stem}.stub.o"
    let src = efi_libstub_source_x86(stem)

    let compile_task = compile_kbuild_task(
      cc,
      "x86_64-linux-gnu",
      efi_libstub_cflags_x86(cflags),
      defs,
      includes,
      src,
      obj,
    )

    let copy_task = efi_stubcopy_task_x86(obj, stub, [compile_task.name])
    tasks += [compile_task]
    tasks += [copy_task]
    stub_objs += [stub]
    stub_deps += [copy_task.name]
  }

  let efi_archive = efi_libstub_archive_task(ar_argv, stub_objs, efi_lib, stub_deps)
  tasks += [efi_archive]
  var support_objs: List[Path] = []
  var support_deps: List[Str] = []

  for obj in final_support_lib_sources() {
    let src = source_for_object(obj)?
    let task = compile_kbuild_task(cc, "x86_64-linux-gnu", final_support_cflags(cflags, obj), defs, includes, src, obj)
    tasks += [task]
    support_objs += [obj]
    support_deps += [task.name]
  }

  let ubsan_stubs = p".xsh-kbuild/obj/lib/xsh-ubsan-stubs.o"

  let ubsan_task = compile_kbuild_task(
    cc,
    "x86_64-linux-gnu",
    cflags.push("-fno-sanitize=undefined"),
    defs,
    includes,
    p".xsh-kbuild/generated/xsh-ubsan-stubs.c",
    ubsan_stubs,
  )

  tasks += [ubsan_task]
  support_objs += [ubsan_stubs]
  support_deps += [ubsan_task.name]
  let support_archive = efi_libstub_archive_task(ar_argv, support_objs, support_lib, support_deps)
  tasks += [support_archive]
  let archive_inputs = vmlinux_x86_archive_inputs(link_inputs)
  let archive_task = vmlinux_archive_argv_task(ar_argv, archive_inputs, vmlinux_a, [])
  tasks += [archive_task]

  let linked_task = vmlinux_unstripped_argv_task(
    ld_argv,
    kbuild_ldflags,
    ldflags_vmlinux,
    lds,
    vmlinux_a,
    [efi_lib, support_lib],
    p".vmlinux.export.o",
    p"init/version-timestamp.o",
    unstripped,
    [export_task.name, version_task.name, efi_archive.name, support_archive.name, archive_task.name],
  )

  let strip_task = x86_vmlinux_strip_argv_task(objcopy_argv, unstripped, vmlinux, [linked_task.name])
  tasks += [linked_task]
  tasks += [strip_task]
  make.run_tasks(tasks, jobs_count)
  build_x86_compressed_kernel(cc, unstripped, vmlinux, efi_lib, jobs_count)
  build_x86_setup_image(cc, jobs_count)
  write_x86_bzimage(p"arch/x86/boot/setup.bin", p"arch/x86/boot/vmlinux.bin", image)
}

## Exported declaration `write_minimal_vmlinux_export`.
export proc write_minimal_vmlinux_export(root: Path) [fs, error] {
  write_text_if_changed(
    fp"{root}/.vmlinux.export.c",
    """/* Generated by the scratch-native XSH Linux build. */
""",
  )
}

pure efi_libstub_stems() -> List[Str] {
  [
    "alignedmem",
    "arm64-stub",
    "arm64",
    "efi-stub-entry",
    "efi-stub-helper",
    "efi-stub",
    "fdt",
    "file",
    "gop",
    "intrinsics",
    "kaslr",
    "lib-cmdline",
    "lib-ctype",
    "lib-fdt",
    "lib-fdt_empty_tree",
    "lib-fdt_ro",
    "lib-fdt_rw",
    "lib-fdt_sw",
    "lib-fdt_wip",
    "mem",
    "pci",
    "primary_display",
    "printk",
    "random",
    "randomalloc",
    "secureboot",
    "skip_spaces",
    "smbios",
    "string",
    "systable",
    "tpm",
    "vsprintf",
  ]
}

pure final_support_lib_sources() -> List[Path] {
  [
    p"lib/fdt.o",
    p"lib/fdt_addresses.o",
    p"lib/fdt_empty_tree.o",
    p"lib/fdt_ro.o",
    p"lib/fdt_rw.o",
    p"lib/fdt_strerror.o",
    p"lib/fdt_sw.o",
    p"lib/fdt_wip.o",
  ]
}

pure efi_libstub_source(stem: Str) -> Path {
  return fp"lib/{stem.replace("lib-", "")}.c" when stem.starts_with("lib-")

  fp"drivers/firmware/efi/libstub/{stem}.c"
}

pure efi_libstub_cflags(cflags: List[Str]) -> List[Str] {
  cflags.extend(
    [
      "-fpie",
      "-fno-unwind-tables",
      "-fno-asynchronous-unwind-tables",
      "-I./scripts/dtc/libfdt",
      "-Os",
      "-DDISABLE_BRANCH_PROFILING",
      "-include",
      "include/linux/hidden.h",
      "-D__NO_FORTIFY",
      "-ffreestanding",
      "-fno-stack-protector",
      "-D__DISABLE_EXPORTS",
    ],
  )
}

pure efi_libstub_cflags_x86(cflags: List[Str]) -> List[Str] {
  cflags.extend(
    [
      "-mcmodel=small",
      "-m64",
      "-fPIC",
      "-fno-strict-aliasing",
      "-mno-red-zone",
      "-mno-mmx",
      "-mno-sse",
      "-fshort-wchar",
      "-Wno-pointer-sign",
      "-Wno-address-of-packed-member",
      "-Wno-gnu",
      "-Wno-microsoft-anon-tag",
      "-fno-unwind-tables",
      "-fno-asynchronous-unwind-tables",
      "-Os",
      "-DDISABLE_BRANCH_PROFILING",
      "-include",
      "include/linux/hidden.h",
      "-D__NO_FORTIFY",
      "-ffreestanding",
      "-fno-stack-protector",
      "-fno-addrsig",
      "-D__DISABLE_EXPORTS",
    ],
  )
}

pure final_support_cflags(cflags: List[Str], out: Path) -> List[Str] {
  let _ = out
  cflags.extend(["-I./scripts/dtc/libfdt", "-fno-sanitize=undefined"])
}

## Exported declaration `write_ubsan_stubs`.
export proc write_ubsan_stubs(root: Path) [fs, error] {
  write_text_if_changed(
    fp"{root}/.xsh-kbuild/generated/xsh-ubsan-stubs.c",
    """void __ubsan_handle_type_mismatch_v1(void) {}
void __ubsan_handle_type_mismatch_v1_abort(void) {}
void __ubsan_handle_shift_out_of_bounds(void) {}
void __ubsan_handle_shift_out_of_bounds_abort(void) {}
void __ubsan_handle_out_of_bounds(void) {}
void __ubsan_handle_out_of_bounds_abort(void) {}
void __ubsan_handle_add_overflow(void) {}
void __ubsan_handle_add_overflow_abort(void) {}
void __ubsan_handle_sub_overflow(void) {}
void __ubsan_handle_sub_overflow_abort(void) {}
void __ubsan_handle_mul_overflow(void) {}
void __ubsan_handle_mul_overflow_abort(void) {}
void __ubsan_handle_divrem_overflow(void) {}
void __ubsan_handle_divrem_overflow_abort(void) {}
void __ubsan_handle_negate_overflow(void) {}
void __ubsan_handle_negate_overflow_abort(void) {}
void __ubsan_handle_load_invalid_value(void) {}
void __ubsan_handle_load_invalid_value_abort(void) {}
void __ubsan_handle_builtin_unreachable(void) {}
void __ubsan_handle_pointer_overflow(void) {}
void __ubsan_handle_pointer_overflow_abort(void) {}
void __ubsan_handle_invalid_builtin(void) {}
void __ubsan_handle_invalid_builtin_abort(void) {}
void __ubsan_handle_nonnull_arg(void) {}
void __ubsan_handle_nonnull_arg_abort(void) {}
void __ubsan_handle_nullability_arg(void) {}
void __ubsan_handle_nullability_arg_abort(void) {}
void __ubsan_handle_vla_bound_not_positive(void) {}
void __ubsan_handle_vla_bound_not_positive_abort(void) {}
void __ubsan_handle_alignment_assumption(void) {}
void __ubsan_handle_alignment_assumption_abort(void) {}
""",
  )
}

proc efi_stubcopy_task(input: Path, out: Path, deps: List[Str]) -> make.MakeTask {
  let tool_path = host_build_path()

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: [
      input,
    ],
    deps: deps,
    argv: [
      "llvm-objcopy",
      "--remove-section=.note.gnu.property",
      "--prefix-alloc-sections=.init",
      "--prefix-symbols=__efistub_",
      input.display(),
      out.display(),
    ],
    cwd: p".",
    env: {
      PATH: tool_path,
    },
    depfile: p"",
    stamp: fp"{out}.cmd",
  }
}

proc efi_stubcopy_task_x86(input: Path, out: Path, deps: List[Str]) -> make.MakeTask {
  let tool_path = host_build_path()

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: [
      input,
    ],
    deps: deps,
    argv: [
      "llvm-objcopy",
      "--remove-section=.note.gnu.property",
      input.display(),
      out.display(),
    ],
    cwd: p".",
    env: {
      PATH: tool_path,
    },
    depfile: p"",
    stamp: fp"{out}.cmd",
  }
}

proc efi_libstub_archive_task(
  ar_argv: List[Str],
  inputs: List[Path],
  out: Path,
  deps: List[Str],
) -> make.MakeTask {
  let tool_path = host_build_path()
  var argv = ar_argv.extend(["cDPrsT", out.display()])

  for input in inputs {
    argv += [input.display()]
  }

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: inputs,
    deps: deps,
    argv: [
      @argv,
    ],
    cwd: p".",
    env: {
      PATH: tool_path,
    },
    depfile: p"",
    stamp: fp"{out}.cmd",
  }
}

proc vmlinux_archive_inputs() -> List[Path] {
  [p".xsh-kbuild/built-in.a", p".xsh-kbuild/arch/arm64/lib/lib.a", p".xsh-kbuild/lib/lib.a"]
}

## Exported declaration `build_scratch_arm64_final`.
export proc build_scratch_arm64_final(
  cc: Path,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  jobs_count: Int = 1,
) [fs, process, env, error] {
  write_minimal_vmlinux_export(p".")
  let _ = cc
  let ar_argv = ["llvm-ar"]
  let ld_argv = ["ld.lld"]
  let objcopy_argv = ["llvm-objcopy"]
  let vmlinux_a = p"vmlinux.a"
  let unstripped = p"vmlinux.unstripped"
  let vmlinux = p"vmlinux"
  let image = p"arch/arm64/boot/Image"
  let efi_lib = p"drivers/firmware/efi/libstub/lib.a"
  let support_lib = p"lib/xsh-final-lib.a"
  let kbuild_ldflags = ["-EL", "-maarch64elf", "-z", "norelro", "-z", "noexecstack"]
  let ldflags_vmlinux = arm64_vmlinux_ldflags(load_config(p".config")?)
  write_ubsan_stubs(p".")
  let lds = p"arch/arm64/kernel/vmlinux.lds"
  generate_vmlinux_lds(cc, lds)
  vmlinux_a.remove(missing_ok: true)
  unstripped.remove(missing_ok: true)
  vmlinux.remove(missing_ok: true)
  image.remove(missing_ok: true)
  var tasks: List[make.MakeTask] = []

  let export_task = compile_kbuild_task(
    cc,
    "aarch64-linux-gnu",
    cflags,
    defs,
    includes,
    p".vmlinux.export.c",
    p".vmlinux.export.o",
  )

  tasks += [export_task]

  let version_task = compile_kbuild_task(
    cc,
    "aarch64-linux-gnu",
    cflags,
    defs,
    includes,
    p"init/version-timestamp.c",
    p"init/version-timestamp.o",
  )

  tasks += [version_task]
  var stub_objs: List[Path] = []
  var stub_deps: List[Str] = []

  for stem in efi_libstub_stems() {
    let obj = fp"drivers/firmware/efi/libstub/{stem}.o"
    let stub = fp"drivers/firmware/efi/libstub/{stem}.stub.o"
    let src = efi_libstub_source(stem)

    let compile_task = compile_kbuild_task(
      cc,
      "aarch64-linux-gnu",
      efi_libstub_cflags(cflags),
      defs,
      includes,
      src,
      obj,
    )

    let copy_task = efi_stubcopy_task(obj, stub, [compile_task.name])
    tasks += [compile_task]
    tasks += [copy_task]
    stub_objs += [stub]
    stub_deps += [copy_task.name]
  }

  let efi_archive = efi_libstub_archive_task(ar_argv, stub_objs, efi_lib, stub_deps)
  tasks += [efi_archive]
  var support_objs: List[Path] = []
  var support_deps: List[Str] = []

  for obj in final_support_lib_sources() {
    let src = source_for_object(obj)?
    let task = compile_kbuild_task(cc, "aarch64-linux-gnu", final_support_cflags(cflags, obj), defs, includes, src, obj)
    tasks += [task]
    support_objs += [obj]
    support_deps += [task.name]
  }

  let ubsan_stubs = p".xsh-kbuild/obj/lib/xsh-ubsan-stubs.o"

  let ubsan_task = compile_kbuild_task(
    cc,
    "aarch64-linux-gnu",
    cflags.push("-fno-sanitize=undefined"),
    defs,
    includes,
    p".xsh-kbuild/generated/xsh-ubsan-stubs.c",
    ubsan_stubs,
  )

  tasks += [ubsan_task]
  support_objs += [ubsan_stubs]
  support_deps += [ubsan_task.name]
  let support_archive = efi_libstub_archive_task(ar_argv, support_objs, support_lib, support_deps)
  tasks += [support_archive]
  let archive_task = vmlinux_archive_argv_task(ar_argv, vmlinux_archive_inputs(), vmlinux_a, [])
  tasks += [archive_task]

  let linked_task = vmlinux_unstripped_argv_task(
    ld_argv,
    kbuild_ldflags,
    ldflags_vmlinux,
    lds,
    vmlinux_a,
    [efi_lib, support_lib],
    p".vmlinux.export.o",
    p"init/version-timestamp.o",
    unstripped,
    [export_task.name, version_task.name, efi_archive.name, support_archive.name, archive_task.name],
  )

  let strip_task = vmlinux_strip_argv_task(objcopy_argv, unstripped, vmlinux, [linked_task.name])
  let img_task = image_argv_task(objcopy_argv, vmlinux, image, [strip_task.name])
  tasks += [linked_task]
  tasks += [strip_task]
  tasks += [img_task]
  make.run_tasks(tasks, jobs_count)
}

## Exported declaration `relink_existing_arm64`.
export proc relink_existing_arm64(ar: Path, ld: Path, objcopy: Path, jobs_count: Int = 1) [fs, process, env, error] {
  relink_existing_arm64_argv([ar.display()], [ld.display()], [objcopy.display()], jobs_count)
}

## Exported declaration `relink_existing_arm64_llvm`.
export proc relink_existing_arm64_llvm(jobs_count: Int = 1) [fs, process, env, error] {
  relink_existing_arm64_argv(["llvm-ar"], ["ld.lld"], ["llvm-objcopy"], jobs_count)
}

## Exported declaration `relink_existing_arm64_argv`.
export proc relink_existing_arm64_argv(
  ar_argv: List[Str],
  ld_argv: List[Str],
  objcopy_argv: List[Str],
  jobs_count: Int = 1,
) [fs, process, env, error] {
  let vmlinux_a = p"vmlinux.a"
  let vmlinux_o = p"vmlinux.o"
  let unstripped = p"vmlinux.unstripped"
  let vmlinux = p"vmlinux"
  let image = p"arch/arm64/boot/Image"
  let efi_lib = p"drivers/firmware/efi/libstub/lib.a"
  let kbuild_ldflags = ["-EL", "-maarch64elf", "-z", "norelro", "-z", "noexecstack"]
  let ldflags_vmlinux = arm64_vmlinux_ldflags(load_config(p".config")?)
  vmlinux_a.remove(missing_ok: true)
  vmlinux_o.remove(missing_ok: true)
  unstripped.remove(missing_ok: true)
  vmlinux.remove(missing_ok: true)
  image.remove(missing_ok: true)

  let archive_task = vmlinux_archive_argv_task(
    ar_argv,
    [p"built-in.a", p"arch/arm64/lib/lib.a", p"lib/lib.a"],
    vmlinux_a,
  )

  let reloc_task = vmlinux_o_argv_task(ld_argv, kbuild_ldflags, vmlinux_a, [efi_lib], vmlinux_o, [archive_task.name])

  let linked_task = vmlinux_unstripped_argv_task(
    ld_argv,
    kbuild_ldflags,
    ldflags_vmlinux,
    p"arch/arm64/kernel/vmlinux.lds",
    vmlinux_a,
    [efi_lib],
    p".vmlinux.export.o",
    p"init/version-timestamp.o",
    unstripped,
    [archive_task.name],
  )

  let strip_task = vmlinux_strip_argv_task(objcopy_argv, unstripped, vmlinux, [linked_task.name])
  let img_task = image_argv_task(objcopy_argv, vmlinux, image, [strip_task.name])
  make.run_tasks([archive_task, reloc_task, linked_task, strip_task, img_task], jobs_count)
}

## Exported declaration `build_builtin_archives`.
export proc build_builtin_archives(
  plan: KbuildPlan,
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  jobs_count: Int,
) [fs, process, env, time, error] -> Result[List[Path], Error] {
  let archive_plan = plan_builtin_archives(plan, cc, triple, cflags, defs, includes)?
  run_builtin_archive_plan(archive_plan, jobs_count)
}

## Exported declaration `run_builtin_archive_plan`.
export proc run_builtin_archive_plan(
  archive_plan: BuiltinArchivePlan,
  jobs_count: Int,
) [fs, process, env, error] -> Result[List[Path], Error] {
  if ! archive_plan.missing_sources.is_empty() {
    print "xsh-kbuild-missing-objects" archive_plan.missing_sources.len() "tolerated"
  }

  if ! archive_plan.generated_objects.is_empty() {
    return Err(
      ScriptError.Failed(
        kind: "kbuild-generated-objects",
        message: f"{archive_plan.generated_objects.len()} generated Kbuild objects need generator tasks",
      ),
    )
  }

  make.run_tasks(archive_plan.tasks, jobs_count)
  archive_plan.archives
}

proc x86_jump_label_helper_source() -> Result[Path] {
  return p"x86-jump-label-patch.c" when p"x86-jump-label-patch.c".exists()

  Err(ScriptError.Failed(kind: "kbuild-x86-jump-label-helper", message: "missing x86-jump-label-patch.c"))
}

proc x86_jump_label_helper() -> Result[Path] {
  let cc = process.which("cc")?
  let helper = p".xsh-kbuild/host/x86-jump-label-patch"
  let source = x86_jump_label_helper_source()?
  helper.parent.mkdir()
  run $cc "-O2" "-std=c11" "-Wall" "-Wextra" "-o" $helper $source ?
  helper
}

pure parse_jump_label_helper_summary(line: Str) -> JumpLabelPatchResult {
  let words = line.words()
  var scanned = 0
  var objects = 0
  var patches = 0
  var index = 0

  while index < words.len() {
    if index > 0 and words[index] == "objects" {
      scanned = words[index - 1].parse_int() ?? scanned
    }

    if index > 0 and words[index] == "patched-objects" {
      objects = words[index - 1].parse_int() ?? objects
    }

    if index > 0 and words[index] == "patches" {
      patches = words[index - 1].parse_int() ?? patches
    }

    index += 1
  }

  {scanned, objects, patches}
}

## Exported declaration `patch_x86_jump_label_outputs`.
export proc patch_x86_jump_label_outputs(outputs: List[Path]) [fs, process, error] -> Result[JumpLabelPatchResult, Error] {
  let helper = x86_jump_label_helper()?
  var argv = [output.display() for output in outputs if output.exists()?]
  archive_plan_progress(f"xsh-kbuild-x86-jump-label-scan start {argv.len()} objects")
  let output = run.text $helper @argv ?
  let summary = parse_jump_label_helper_summary(output.trim())

  archive_plan_progress(
    f"xsh-kbuild-x86-jump-label-scan complete {summary.scanned} objects {summary.patches} patches",
  )

  summary
}

pure has_archive_output(task: make.MakeTask) -> Bool {
  for output in task.outputs {
    return true when output.display().ends_with(".a")
  }

  false
}

pure archive_rerun_tasks(tasks: List[make.MakeTask]) -> List[make.MakeTask] {
  var archive_names = {task.name: true for task in tasks if has_archive_output(task)}
  var rerun: List[make.MakeTask] = []

  for task in tasks {
    continue unless has_archive_output(task)
    var deps = [dep for dep in task.deps if archive_names.get(dep) ?? false]
    rerun += [{...task, deps}]
  }

  rerun
}

proc rerun_x86_jump_label_archives(tasks: List[make.MakeTask], jobs_count: Int) {
  let archive_tasks = archive_rerun_tasks(tasks)
  archive_plan_progress(f"xsh-kbuild-x86-jump-label-archive-rerun start {archive_tasks.len()} archives")
  make.run_tasks(archive_tasks, jobs_count)
  archive_plan_progress(f"xsh-kbuild-x86-jump-label-archive-rerun complete {archive_tasks.len()} archives")
}

## Exported declaration `patch_x86_jump_label_archive_plan`.
export proc patch_x86_jump_label_archive_plan(
  archive_plan: BuiltinArchivePlan,
  jobs_count: Int,
) [fs, process, env, error] {
  var outputs: List[Path] = [
    output
    for task in archive_plan.tasks
    for output in task.outputs
    if output.display().ends_with(".o")
  ]
  let result = patch_x86_jump_label_outputs(outputs)?

  if result.patches > 0 {
    print "xsh-kbuild-x86-jump-label-nops" ${result.patches} "in" ${result.objects} "objects"
    rerun_x86_jump_label_archives(archive_plan.tasks, jobs_count)
  }
}

## Exported declaration `run_x86_builtin_archive_plan`.
export proc run_x86_builtin_archive_plan(
  archive_plan: BuiltinArchivePlan,
  jobs_count: Int,
) [fs, process, env, error] -> Result[List[Path], Error] {
  let archives = run_builtin_archive_plan(archive_plan, jobs_count)?
  patch_x86_jump_label_archive_plan(archive_plan, jobs_count)
  archives
}

proc archive_plan_progress(message: Str) {
  write_text_if_changed(
    p".xsh-kbuild-progress",
    f"""{message}
""",
  )
}

proc archive_plan_timing_start(stage: Str) -> Int {
  if (e"XSH_LINUX_KBUILD_TIMING" ?? "") == "1" {
    print "linux-kbuild-archive-timing-start" $stage
    return time.now()
  }

  0
}

proc archive_plan_timing_done(stage: Str, start: Int) {
  if (e"XSH_LINUX_KBUILD_TIMING" ?? "") == "1" {
    print "linux-kbuild-archive-timing-done" $stage ${time.now() - start} "ms"
  }
}

pure skip_planned_object(config: Kconfig, obj: Path) -> Bool {
  let key = path_key(obj)

  if key == "kernel/jump_label.o" and config_value(config, "JUMP_LABEL") != "y" {
    return true
  }

  if key == "arch/x86/kernel/jump_label.o" and config_value(config, "JUMP_LABEL") != "y" {
    return true
  }

  false
}

pure archive_analysis_record_for_object(
  obj: Path,
  owner: Path,
  library: Bool,
  pi: Bool,
  composites_by_object: Map[CompositeObject],
  compile_flags_by_dir: Map[Map[List[Str]]],
) -> ArchiveAnalysisItem {
  let key = path_key(obj)

  if key in composites_by_object {
    let default_composite: CompositeObject = CompositeObject(object: obj, members: [])
    let composite = composites_by_object.get(key) ?? default_composite
    return {
      object: key,
      owner: path_key(owner),
      library: library,
      pi: pi,
      composite: path_key(composite.object),
      member_objects: [path_key(member) for member in composite.members],
      member_flags: [
        kbuild_compile_flags_for_member(compile_flags_by_dir, composite.object, member)
        for member in composite.members
      ],
      flags: [],
    }
  }

  let flags_object = if pi { pi_base_object(obj) } else { obj }
  {
    object: key,
    owner: path_key(owner),
    library: library,
    pi: pi,
    composite: "",
    member_objects: [],
    member_flags: [],
    flags: kbuild_compile_flags_for_object(compile_flags_by_dir, flags_object),
  }
}

pure archive_analysis_plan_context(plan: KbuildPlan) -> ArchivePlanContext {
  {
    dirs: path_strings(plan.dirs),
    objects: path_strings(plan.objects),
    lib_objects: path_strings(plan.lib_objects),
    archive_owners: [
      {
        object: path_key(owner.object),
        dir: path_key(owner.dir),
      }
      for owner in plan.archive_owners
    ],
    composites: [
      {
        object: path_key(composite.object),
        members: path_strings(composite.members),
      }
      for composite in plan.composites
    ],
  }
}

proc archive_analysis_plan_context_slice(
  context: ArchivePlanContext,
  start: Int,
  end: Int,
) [error] -> Result[ArchivePlanContext] {
  let {objects: object_values, lib_objects: lib_object_values, ..} = context
  let object_count = object_values.len()
  let object_start = if start < object_count { start } else { object_count }
  let object_end = if end < object_count { end } else { object_count }
  let lib_start = if start > object_count { start - object_count } else { 0 }
  let lib_end = if end > object_count { end - object_count } else { 0 }
  let objects = object_values
    |> drop(object_start)
    |> take(object_end - object_start)
  let lib_objects = lib_object_values
    |> drop(lib_start)
    |> take(lib_end - lib_start)
  var selected: Map[Bool] = {obj: true for obj in objects}
  for obj in lib_objects {
    selected[obj] = true
  }

  var archive_owners: List[ArchiveOwnerRecord] = [
    owner
    for owner in context.archive_owners
    if selected.get(owner.object) ?? false
  ]
  var composites: List[CompositeRecord] = []
  for composite in context.composites {
    var selected_member = selected.get(composite.object) ?? false
    for member in composite.members {
      if selected.get(member) ?? false {
        selected_member = true
      }
    }

    if selected_member {
      composites += [composite]
    }
  }

  {
    dirs: [],
    objects: objects,
    lib_objects: lib_objects,
    archive_owners: archive_owners,
    composites: composites,
  }
}

proc archive_analysis_plan_from_context(context: ArchivePlanContext) -> Result[KbuildPlan] {
  {
    dirs: paths_from_strings(context.dirs)?,
    objects: paths_from_strings(context.objects)?,
    lib_objects: paths_from_strings(context.lib_objects)?,
    archive_owners: archive_owners_from_records(context.archive_owners)?,
    composites: composites_from_records(context.composites)?,
    unsupported: [],
  }
}

pure archive_analysis_raw_item(
  obj: Path,
  owner: Path,
  library: Bool,
  pi: Bool,
  composites_by_object: Map[CompositeObject],
) -> ArchiveAnalysisItem {
  let key = path_key(obj)

  if key in composites_by_object {
    let default_composite: CompositeObject = CompositeObject(object: obj, members: [])
    let composite = composites_by_object.get(key) ?? default_composite
    return {
      object: key,
      owner: path_key(owner),
      library: library,
      pi: pi,
      composite: path_key(composite.object),
      member_objects: [path_key(member) for member in composite.members],
      member_flags: [],
      flags: [],
    }
  }

  {
    object: key,
    owner: path_key(owner),
    library: library,
    pi: pi,
    composite: "",
    member_objects: [],
    member_flags: [],
    flags: [],
  }
}

proc archive_analysis_slice_items(
  plan: KbuildPlan,
  config: Kconfig,
  start: Int,
  end: Int,
) [error] -> Result[List[ArchiveAnalysisItem]] {
  let composites_by_object = composite_map(plan.composites)
  let composite_members_by_object = composite_member_map(plan.composites)
  var archive_owner_by_object = {
    [path_key(owner.object)]: path_key(owner.dir)
    for owner in plan.archive_owners
  }
  let object_count = plan.objects.len()
  var items: List[ArchiveAnalysisItem] = []
  var index = start

  while index < end {
    let library = index >= object_count
    let object_index = if library { index - object_count } else { index }
    let obj = if library {
      plan.lib_objects.get(object_index) ?? p"."
    } else {
      plan.objects.get(object_index) ?? p"."
    }

    if ! skip_planned_object(config, obj) and path_key(obj) not in composite_members_by_object {
      items += [archive_analysis_raw_item(
          obj,
          archive_owner_key(archive_owner_by_object, obj),
          library,
          if library {
            false
          } else {
            is_pi_object(obj)
          },
          composites_by_object,
        )]
    }

    index += 1
  }

  items
}

proc archive_analysis_items_with_compile_flags(
  items: List[ArchiveAnalysisItem],
  compile_flags_by_dir: Map[Map[List[Str]]],
) [error] -> Result[List[ArchiveAnalysisItem]] {
  var enriched: List[ArchiveAnalysisItem] = []

  for item in items {
    let object = fp"{item.object}"
    let flags_object = if item.pi { pi_base_object(object) } else { object }
    let member_flags = [
      kbuild_compile_flags_for_member(compile_flags_by_dir, fp"{item.composite}", fp"{member}")
      for member in item.member_objects
    ]

    enriched += [{
      ...item,
      flags: if item.composite == "" { kbuild_compile_flags_for_object(compile_flags_by_dir, flags_object) } else { [] },
      member_flags: member_flags,
    }]
  }

  enriched
}

proc archive_analysis_flag_entries_for_plan_range(
  plan: KbuildPlan,
  start: Int,
  end: Int,
  flag_entries: List[CompileFlagsEntry],
) [error] -> Result[List[CompileFlagsEntry]] {
  var dirs: Map[Bool] = {}
  var objects: Map[Bool] = {}
  let object_count = plan.objects.len()
  let composites_by_object = composite_map(plan.composites)
  var index = start

  while index < end {
    let library = index >= object_count
    let object_index = if library { index - object_count } else { index }
    let obj = if library {
      plan.lib_objects.get(object_index) ?? p"."
    } else {
      plan.objects.get(object_index) ?? p"."
    }
    let flags_object = if ! library and is_pi_object(obj) { pi_base_object(obj) } else { obj }
    let flags_key = path_key(flags_object)
    dirs[path_key(object_dir(flags_object))] = true
    objects[flags_key] = true

    if path_key(obj) in composites_by_object {
      let object_key = path_key(obj)
      let default_composite: CompositeObject = CompositeObject(object: obj, members: [])
      let composite = composites_by_object.get(object_key) ?? default_composite
      for member in composite.members {
        dirs[path_key(object_dir(member))] = true
        objects[path_key(member)] = true
      }
    }

    index += 1
  }

  var filtered: List[CompileFlagsEntry] = [
    entry
    for entry in flag_entries
    if (entry.object == "*" and (dirs.get(entry.dir) ?? false)) or (objects.get(entry.object) ?? false)
  ]
  filtered
}

## Exported declaration `analyze_archive_plan_slice`.
export proc analyze_archive_plan_slice(
  context: ArchivePlanContext,
  start: Int,
  end: Int,
  flag_entries: List[CompileFlagsEntry],
  emit_task_specs: Bool,
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
) [fs, error] -> Result[List[ArchiveAnalysisResult], Error] {
  let slice_context = archive_analysis_plan_context_slice(context, start, end)?
  let plan = archive_analysis_plan_from_context(slice_context)?
  let config = load_config_if_present(p".config")?
  let relevant_flags = archive_analysis_flag_entries_for_plan_range(plan, 0, end - start, flag_entries)?
  let compile_flags_by_dir = compile_flags_from_cache_entries(relevant_flags)?
  let items = archive_analysis_slice_items(plan, config, 0, end - start)?
  let enriched = archive_analysis_items_with_compile_flags(items, compile_flags_by_dir)?
  analyze_archive_items_impl(enriched, cc, triple, cflags, defs, includes, emit_task_specs)?
}

proc archive_analysis_items(
  plan: KbuildPlan,
  config: Kconfig,
  compile_flags_by_dir: Map[Map[List[Str]]],
) -> Result[List[ArchiveAnalysisItem]] {
  let maps_start = archive_plan_timing_start("item-maps")
  let composites_by_object = composite_map(plan.composites)
  let composite_members_by_object = composite_member_map(plan.composites)
  var archive_owner_by_object = {
    [path_key(owner.object)]: path_key(owner.dir)
    for owner in plan.archive_owners
  }
  archive_plan_timing_done("item-maps", maps_start)

  let object_items_start = archive_plan_timing_start("item-objects")
  var items: List[ArchiveAnalysisItem] = []

  for obj in plan.objects {
    continue when skip_planned_object(config, obj)
    continue when path_key(obj) in composite_members_by_object
    items += [archive_analysis_record_for_object(
        obj,
        archive_owner_key(archive_owner_by_object, obj),
        false,
        is_pi_object(obj),
        composites_by_object,
        compile_flags_by_dir,
      )]
  }

  for obj in plan.lib_objects {
    continue when path_key(obj) in composite_members_by_object
    items += [archive_analysis_record_for_object(
        obj,
        archive_owner_key(archive_owner_by_object, obj),
        true,
        false,
        composites_by_object,
        compile_flags_by_dir,
      )]
  }

  archive_plan_timing_done("item-objects", object_items_start)

  items
}

proc archive_analysis_items_for_plan(
  plan: KbuildPlan,
  triple: Str,
) -> Result[List[ArchiveAnalysisItem]] {
  let config = load_config_if_present(p".config")?
  let compile_flags_by_dir = cached_kbuild_compile_flags_for_dirs(
    p".",
    plan.dirs,
    config,
    if triple == "x86_64-linux-gnu" {
      "x86"
    } else {
      "arm64"
    },
  )?
  archive_analysis_items(plan, config, compile_flags_by_dir)?
}

pure archive_analysis_result(
  object: Str,
  owner: Str,
  library: Bool,
  tasks: List[Record],
  task_count: Int,
  archive_outputs: List[Path],
  archive_deps: List[Str],
  has_pi: Bool,
  link_inputs: List[Path],
  generated_objects: List[Path],
  missing_sources: List[Path],
) -> ArchiveAnalysisResult {
  {
    object: object,
    owner: owner,
    library: library,
    tasks: tasks,
    task_count: task_count,
    archive_outputs: path_strings(archive_outputs),
    archive_deps: archive_deps,
    has_pi: has_pi,
    link_inputs: path_strings(link_inputs),
    generated_objects: path_strings(generated_objects),
    missing_sources: path_strings(missing_sources),
  }
}

proc archive_compile_task_spec(
  object: Path,
  source: Path,
  out: Path,
  module_out: Path,
  extra_flags: List[Str],
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  emit_task_specs: Bool,
) [error] -> Result[Record] {
  if emit_task_specs {
    let compile_cflags = object_compile_cflags(
      pi_compile_cflags(archive_object_cflags_from_extra(cflags, extra_flags, object), out),
      out,
    )
    let object_includes = arch_local_compile_includes(
      trace_compile_includes(
        version_compile_includes(libfdt_compile_includes(pi_compile_includes(includes, out), out), out),
        source,
      ),
      source,
      triple,
    )
    let task_cflags = if is_asm_source(source) { asm_cflags(compile_cflags) } else { compile_cflags }
    let task_defs = defs.extend(kbuild_object_defs_for_module(out, module_out))
    let task_includes = if is_asm_source(source) { asm_includes(object_includes) } else { object_includes }
    let depfile = fp"{out}.d"
    var argv: List[Str] = [cc.display(), "-target", triple, "-c"]
    argv = [@argv, @task_cflags, @task_defs, @task_includes]
    argv += [source.display(), "-o", out.display(), "-MMD", "-MP", "-MF", depfile.display()]

    return {
      kind: "compile",
      source: source.display(),
      output: out.display(),
      argv: argv,
      depfile: depfile.display(),
      stamp: fp"{out}.cmd".display(),
    }
  }

  {
    kind: "compile",
    object: path_key(object),
    source: source.display(),
    output: out.display(),
    module: module_out.display(),
    flags: extra_flags,
  }
}

proc analyze_archive_items_impl(
  items: List[ArchiveAnalysisItem],
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  emit_task_specs: Bool,
) -> Result[List[ArchiveAnalysisResult]] {
  var results: List[ArchiveAnalysisResult] = []

  for item in items {
    let {object: object_key, owner: owner_key, library, pi, composite: composite_key, flags, ..} = item
    let obj = fp"{object_key}"
    var task_specs: List[Record] = []
    var task_count = 0
    var archive_outputs: List[Path] = []
    var archive_deps: List[Str] = []
    var has_pi = false
    var link_inputs: List[Path] = []
    var generated_objects: List[Path] = []
    var missing_sources: List[Path] = []

    if composite_key != "" {
      let {member_objects, member_flags, ..} = item
      let composite_out = obj_out_path(fp"{composite_key}")

      var member_index = 0
      for member_key in member_objects {
        let member_cflags = member_flags.get(member_index) ?? []
        let member = fp"{member_key}"

        if let Ok(source) = source_for_object(member) {
          let member_out = obj_out_path(member)
          let task_spec = archive_compile_task_spec(
            member,
            source,
            member_out,
            composite_out,
            member_cflags,
            cc,
            triple,
            cflags,
            defs,
            includes,
            emit_task_specs,
          )?
          task_specs += [task_spec]
          task_count += 1
          archive_outputs += [member_out]
          archive_deps += [member_out.display()]
        } else {
          if is_known_generated_object(member) {
            generated_objects += [member]
          } else {
            missing_sources += [member]
          }
        }

        member_index += 1
      }
    } else if pi {
      let source = pi_source(obj)

      if source.exists() {
        let base_out = obj_out_path(pi_base_object(obj))
        let out = obj_out_path(obj)
        let base_task_spec = archive_compile_task_spec(
          pi_base_object(obj),
          source,
          base_out,
          base_out,
          flags,
          cc,
          triple,
          cflags,
          defs,
          includes,
          emit_task_specs,
        )?
        has_pi = true
        task_count += 3
        archive_outputs += [out]
        archive_deps += [f"{out}:relacheck"]
        task_specs += [{
          kind: "pi",
          object: object_key,
          source: source.display(),
          base: base_out.display(),
          output: out.display(),
          base_task: base_task_spec,
        }]
      } else {
        generated_objects += [obj]
      }
    } else {
      if let Ok(source) = source_for_object(obj) {
        let out = obj_out_path(obj)
        let task_spec = archive_compile_task_spec(
          obj,
          source,
          out,
          out,
          flags,
          cc,
          triple,
          cflags,
          defs,
          includes,
          emit_task_specs,
        )?
        task_specs += [task_spec]
        task_count += 1
        archive_outputs += [out]
        archive_deps += [out.display()]
      } else {
        let out = obj_out_path(obj)

        if out.exists() {
          link_inputs += [out]
        } else if is_known_generated_object(obj) {
          generated_objects += [obj]
        } else {
          missing_sources += [obj]
        }
      }
    }

    results += [archive_analysis_result(
        object_key,
        owner_key,
        library,
        task_specs,
        task_count,
        archive_outputs,
        archive_deps,
        has_pi,
        link_inputs,
        generated_objects,
        missing_sources,
      )]
  }

  results
}

# Caller-built items may use the legacy `members: [{object, flags}]` composite shape.
proc archive_analysis_item_from_record(item: Record) -> Result[ArchiveAnalysisItem] {
  let members = if "members" in item { item.get("members")?.require(List[Record])? } else { [] }
  let member_objects = if "member_objects" in item {
    item.get("member_objects")?.require(List[Str])?
  } else {
    [member.get("object")?.require(Str)? for member in members]
  }
  let member_flags = if "member_flags" in item {
    item.get("member_flags")?.require(List[List[Str]])?
  } else {
    [member.get("flags")?.require(List[Str])? for member in members]
  }

  {
    object: item.get("object")?.require()?,
    owner: item.get("owner")?.require()?,
    library: item.get("library")?.require()?,
    pi: item.get("pi")?.require()?,
    composite: item.get("composite")?.require()?,
    member_objects,
    member_flags,
    flags: item.get("flags")?.require()?,
  }
}

## Exported declaration `analyze_archive_items`.
export proc analyze_archive_items(items: List[Record]) [fs, error] -> Result[List[ArchiveAnalysisResult], Error] {
  let typed_items = [archive_analysis_item_from_record(item)? for item in items]
  analyze_archive_items_impl(typed_items, p".", "", [], [], [], false)?
}

## Exported declaration `analyze_archive_items_with_task_specs`.
export proc analyze_archive_items_with_task_specs(
  items: List[ArchiveAnalysisItem],
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
) [fs, error] -> Result[List[ArchiveAnalysisResult], Error] {
  analyze_archive_items_impl(items, cc, triple, cflags, defs, includes, true)?
}

pure archive_analysis_worker_count(requested: Int, item_count: Int) -> Int {
  return 0 when item_count == 0

  let bounded = if requested < 1 { 1 } else if requested > 16 { 16 } else { requested }
  if bounded > item_count { item_count } else { bounded }
}

proc archive_analysis_process_pool(
  plan: KbuildPlan,
  compile_flags_by_dir: Map[Map[List[Str]]],
  requested_jobs: Int,
  xsh_bin: Path,
  worker: Path,
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
) -> Result[List[ArchiveAnalysisResult]] {
  let item_count = plan.objects.len() + plan.lib_objects.len()
  let flag_entries = compile_flags_cache_entries(compile_flags_by_dir)
  let worker_count = archive_analysis_worker_count(requested_jobs, item_count)
  let emit_task_specs = (e"XSH_LINUX_KBUILD_ARCHIVE_ONLY" ?? "") != "1"

  if worker_count <= 1 {
    let config = load_config_if_present(p".config")?
    let items = archive_analysis_items(plan, config, compile_flags_by_dir)?
    return analyze_archive_items_impl(items, cc, triple, cflags, defs, includes, emit_task_specs)?
  }

  let prefix = f"/tmp/xsh-kbuild-archive-analysis-{time.now()}"
  let context_path = fp"{prefix}-context.json"
  json.write(context_path, archive_analysis_plan_context(plan))
  defer context_path.remove(missing_ok: true)?
  let flags_path = fp"{prefix}-flags.json"
  json.write(flags_path, ArchiveAnalysisFlags(flags: flag_entries))
  defer flags_path.remove(missing_ok: true)?
  var handles = []
  var output_paths: List[Path] = []
  var input_paths: List[Path] = []
  # Loop-body defers run per iteration, before workers read their inputs.
  defer {
    for temp_path in [@input_paths, @output_paths] {
      temp_path.remove(missing_ok: true)
    }
  }

  for index in range(worker_count) {
    let start = index * item_count / worker_count
    let end = (index + 1) * item_count / worker_count
    let input_path = fp"{prefix}-input-{index}.json"
    let output_path = fp"{prefix}-output-{index}.json"
    json.write(
      input_path,
      ArchiveAnalysisInput(
        context: context_path.display(),
        start:,
        end:,
        flags: flags_path.display(),
        emit_task_specs:,
        cc: cc.display(),
        triple:,
        cflags:,
        defs:,
        includes:,
      ),
    )
    input_paths += [input_path]
    output_paths += [output_path]

    let command = process.command_argv(
      xsh_bin,
      [
        xsh_bin,
        worker,
        "--",
        input_path,
        output_path,
      ],
    )
    handles += [spawn command?]
  }

  let statuses = wait handles?
  for status in statuses {
    guard status.exited_with(0) else {
      return Err(ScriptError.Failed(kind: "kbuild-archive-analysis-pool", message: "an archive-analysis worker failed"))
    }
  }

  var results: List[ArchiveAnalysisResult] = []
  for output_path in output_paths {
    let worker_results = json.read(output_path)?.require(List[ArchiveAnalysisResult])?
    results += worker_results
  }

  results
}

pure archive_compile_task_from_spec(spec: ArchiveCompileTaskSpec) -> make.MakeTask {
  let source = fp"{spec.source}"
  let output = fp"{spec.output}"

  {
    name: output.display(),
    outputs: [
      output,
    ],
    inputs: [
      source,
    ],
    deps: [],
    argv: [@spec.argv],
    cwd: p".",
    env: {},
    depfile: fp"{spec.depfile}",
    stamp: fp"{spec.stamp}",
  }
}

proc assemble_builtin_archive_plan(
  plan: KbuildPlan,
  cc: Path,
  analysis_results: List[ArchiveAnalysisResult],
) -> Result[BuiltinArchivePlan] {
  let materialize_tasks = (e"XSH_LINUX_KBUILD_ARCHIVE_ONLY" ?? "") != "1"
  let result_merge_start = archive_plan_timing_start("merge-results")
  var tasks: List[make.MakeTask] = []
  var deferred_task_specs: List[Record] = []
  var task_count = 0
  var objects_by_dir: Map[List[Path]] = {}
  var deps_by_dir: Map[List[Str]] = {}
  var lib_objects_by_dir: Map[List[Path]] = {}
  var lib_deps_by_dir: Map[List[Str]] = {}
  var missing_sources: List[Path] = []
  var generated_objects: List[Path] = []
  var link_inputs: List[Path] = []
  var link_input_seen: Map[Bool] = {}
  var pi_relacheck_added = false

  for result in analysis_results {
    let {owner: owner_key, library, tasks: result_tasks, task_count: result_task_count, archive_outputs: result_archive_outputs, archive_deps: result_archive_deps, has_pi: result_has_pi, link_inputs: result_link_inputs, ..} = result

    if ! materialize_tasks {
      deferred_task_specs += result_tasks
    }

    if materialize_tasks {
      for spec in result_tasks {
        let kind = spec.get("kind")?.require(Str)?

        if kind == "pi" {
          let pi_spec = spec.require(ArchivePiTaskSpec)?
          let out = fp"{pi_spec.output}"
          let base_out = fp"{pi_spec.base}"
          let check_task_name = f"{out}:relacheck"

          if ! pi_relacheck_added {
            if materialize_tasks {
              tasks += [pi_relacheck_build_task(cc)]
            }

            task_count += 1
            pi_relacheck_added = true
          }

          if materialize_tasks {
            let base_task = archive_compile_task_from_spec(pi_spec.base_task)
            let objcopy_task = pi_objcopy_task(cc, base_out, out, [base_task.name])
            let check_task = pi_relacheck_task(
              pi_relacheck_path(),
              out,
              base_out,
              [objcopy_task.name, pi_relacheck_path().display()],
            )

            tasks += [base_task, objcopy_task, check_task]
          }

          task_count += 3
          let input_key = path_key(out)
          if ! (link_input_seen.get(input_key) ?? false) {
            link_input_seen[input_key] = true
            link_inputs += [out]
          }

          objects_by_dir = objects_by_dir.push(owner_key, out)
          deps_by_dir = deps_by_dir.push(owner_key, check_task_name)
        } else if kind == "compile" {
          let compile_spec = spec.require(ArchiveCompileTaskSpec)?
          let out = fp"{compile_spec.output}"

          if materialize_tasks {
            tasks += [archive_compile_task_from_spec(compile_spec)]
          }

          task_count += 1
          let input_key = path_key(out)
          if ! (link_input_seen.get(input_key) ?? false) {
            link_input_seen[input_key] = true
            link_inputs += [out]
          }

          if library {
            lib_objects_by_dir = lib_objects_by_dir.push(owner_key, out)
            lib_deps_by_dir = lib_deps_by_dir.push(owner_key, out.display())
          } else {
            objects_by_dir = objects_by_dir.push(owner_key, out)
            deps_by_dir = deps_by_dir.push(owner_key, out.display())
          }
        } else {
          return Err(ScriptError.Failed(kind: "kbuild-archive-analysis", message: f"unknown archive-analysis task kind {kind}"))
        }
      }
    } else {
      if result_has_pi and ! pi_relacheck_added {
        task_count += 1
        pi_relacheck_added = true
      }

      task_count += result_task_count
      var output_index = 0
      for output in result_archive_outputs {
        let output_path = fp"{output}"
        link_inputs += [output_path]
        let dep = result_archive_deps.get(output_index) ?? ""

        if library {
          lib_objects_by_dir = lib_objects_by_dir.push(owner_key, output_path)
          if dep != "" {
            lib_deps_by_dir = lib_deps_by_dir.push(owner_key, dep)
          }
        } else {
          objects_by_dir = objects_by_dir.push(owner_key, output_path)
          if dep != "" {
            deps_by_dir = deps_by_dir.push(owner_key, dep)
          }
        }

        output_index += 1
      }
    }

    for input in result_link_inputs {
      let input_path = fp"{input}"
      let input_key = path_key(input_path)
      if ! (link_input_seen.get(input_key) ?? false) {
        link_input_seen[input_key] = true
        link_inputs += [input_path]
      }

      if library {
        lib_objects_by_dir = lib_objects_by_dir.push(owner_key, input_path)
      } else {
        objects_by_dir = objects_by_dir.push(owner_key, input_path)
      }
    }

    for item in result.generated_objects {
      generated_objects += [fp"{item}"]
    }

    for item in result.missing_sources {
      missing_sources += [fp"{item}"]
    }
  }

  archive_plan_progress(
    f"xsh-kbuild-archive-plan analysis-complete {analysis_results.len()} items {task_count} tasks",
  )
  archive_plan_timing_done("merge-results", result_merge_start)
  let barrier_merge_start = archive_plan_timing_start("merge-barriers")
  var archives: List[Path] = []
  let children_start = archive_plan_timing_start("merge-children")
  var children_by_dir: Map[List[Path]] = {}
  var parent_by_dir: Map[Str] = {}
  var dir_count = 0

  for dir in plan.dirs {
    dir_count += 1

    if dir_count % 100 == 0 {
      archive_plan_progress(f"xsh-kbuild-archive-plan children {dir_count}/{plan.dirs.len()}")
    }

    if path_key(dir) != "." {
      let dir_key = path_key(dir)
      let parent_key = archive_parent_key(dir_key)
      parent_by_dir[dir_key] = parent_key
      children_by_dir = children_by_dir.push(parent_key, dir)
    }
  }

  archive_plan_timing_done("merge-children", children_start)

  let needed_start = archive_plan_timing_start("merge-needed")
  var archive_needed: Map[Bool] = {}
  var dir_index = plan.dirs.len()

  while dir_index > 0 {
    dir_index -= 1
    let dir = plan.dirs[dir_index]
    let dir_key = path_key(dir)
    let needed = ! (objects_by_dir.get(dir_key) ?? []).is_empty() or (archive_needed.get(dir_key) ?? false)

    archive_needed[dir_key] = needed

    if needed {
      let parent_key = parent_by_dir.get(dir_key) ?? ""
      if parent_key != "" {
        archive_needed[parent_key] = true
      }
    }
  }

  archive_plan_timing_done("merge-needed", needed_start)

  archive_plan_progress("xsh-kbuild-archive-plan needed-complete")
  archive_plan_timing_done("merge-barriers", barrier_merge_start)

  let archive_merge_start = archive_plan_timing_start("merge-archives")
  var archive_dir_count = 0

  for dir in plan.dirs {
    archive_dir_count += 1

    if archive_dir_count % 100 == 0 {
      archive_plan_progress(
        f"xsh-kbuild-archive-plan archives {archive_dir_count}/{plan.dirs.len()} tasks={tasks.len()} archives={archives.len()}",
      )
    }

    let dir_key = path_key(dir)
    let lib_objs = lib_objects_by_dir.get(dir_key) ?? []

    if ! lib_objs.is_empty() {
      let sorted_lib_objs = sorted_paths(lib_objs)
      let lib_archive = dir_lib_archive(dir)
      let lib_deps = lib_deps_by_dir.get(dir_key) ?? []
      if materialize_tasks {
        tasks += [vmlinux_archive_argv_task(["llvm-ar"], sorted_lib_objs, lib_archive, lib_deps)]
      }

      task_count += 1
      archives += [lib_archive]
    }

    var objs = objects_by_dir.get(dir_key) ?? []
    var deps = deps_by_dir.get(dir_key) ?? []
    var child_archives: List[Path] = []
    var marker_archive = p""
    var marker_dep = ""
    var has_marker_archive = false

    for child in children_by_dir.get(dir_key) ?? [] {
      if archive_needed.get(path_key(child)) ?? false {
        let child_archive = dir_archive(child)

        if dir_key == "arch/arm64/kernel" and path_key(child) == "arch/arm64/kernel/pi" {
          marker_archive = child_archive
          marker_dep = child_archive.display()
          has_marker_archive = true
        } else {
          child_archives += [child_archive]
        }
      }
    }

    if has_marker_archive {
      let inserted = insert_archive_before(
        objs,
        deps,
        marker_archive,
        marker_dep,
        p".xsh-kbuild/obj/arch/arm64/kernel/rsi.o",
      )
      objs = inserted.objs
      deps = inserted.deps
    }

    for child_archive in child_archives {
      objs += [child_archive]
      deps += [child_archive.display()]
    }

    if archive_needed.get(dir_key) ?? false {
      let built_archive = dir_archive(dir)
      if materialize_tasks {
        tasks += [vmlinux_archive_argv_task(["llvm-ar"], objs, built_archive, deps)]
      }

      task_count += 1
      archives += [built_archive]
    }
  }

  archive_plan_timing_done("merge-archives", archive_merge_start)

  archive_plan_progress(f"xsh-kbuild-archive-plan complete {task_count} tasks {archives.len()} archives")

  {
    tasks: if materialize_tasks { tasks } else { [] },
    task_specs: if materialize_tasks { [] } else { deferred_task_specs },
    task_count: task_count,
    archives: archives,
    link_inputs: link_inputs,
    missing_sources: missing_sources,
    generated_objects: generated_objects,
    duplicate_outputs: if materialize_tasks { duplicate_task_outputs(tasks) } else { [] },
  }
}

## Exported declaration `plan_builtin_archives`.
export proc plan_builtin_archives(
  plan: KbuildPlan,
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
) [fs, env, time, error] -> Result[BuiltinArchivePlan, Error] {
  let items = archive_analysis_items_for_plan(plan, triple)?
  let emit_task_specs = (e"XSH_LINUX_KBUILD_ARCHIVE_ONLY" ?? "") != "1"
  let results = analyze_archive_items_impl(
    items,
    cc,
    triple,
    cflags,
    defs,
    includes,
    emit_task_specs,
  )?
  assemble_builtin_archive_plan(plan, cc, results)
}

# Archive analysis is isolated at a process boundary because source probes and
# task-spec construction dominate cold planning on the mounted kernel tree.
# The serial planner remains the fallback for callers that do not request
# workers; parallel results are merged in the original object order above the
# archive dependency barriers.
## Exported declaration `plan_builtin_archives_with_analysis_workers`.
export proc plan_builtin_archives_with_analysis_workers(
  plan: KbuildPlan,
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  analysis_jobs: Int,
  xsh_bin: Path,
  worker: Path,
) [fs, process, env, time, error] -> Result[BuiltinArchivePlan, Error] {
  guard analysis_jobs > 1 else {
    return plan_builtin_archives(plan, cc, triple, cflags, defs, includes)?
  }

  let config = load_config_if_present(p".config")?
  let flags_start = archive_plan_timing_start("item-flags")
  let compile_flags_by_dir = cached_kbuild_compile_flags_for_dirs(
    p".",
    plan.dirs,
    config,
    if triple == "x86_64-linux-gnu" {
      "x86"
    } else {
      "arm64"
    },
  )?
  archive_plan_timing_done("item-flags", flags_start)
  archive_plan_progress(
    f"xsh-kbuild-archive-plan analysis-start {plan.objects.len() + plan.lib_objects.len()} items {analysis_jobs} requested-workers",
  )
  let analysis_start = archive_plan_timing_start("analysis")
  let results = archive_analysis_process_pool(
    plan,
    compile_flags_by_dir,
    analysis_jobs,
    xsh_bin,
    worker,
    cc,
    triple,
    cflags,
    defs,
    includes,
  )?
  archive_plan_timing_done("analysis", analysis_start)
  let merge_start = archive_plan_timing_start("merge")
  let archive_plan = assemble_builtin_archive_plan(plan, cc, results)?
  archive_plan_timing_done("merge", merge_start)
  archive_plan
}

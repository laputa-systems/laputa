error IterationError = Failed(kind: Str, message: Str)

pure default_sources() -> List[Str] {
  return [
    "mm/vmstat.c",
    "arch/x86/kernel/kvm.c",
    "arch/x86/kernel/kvmclock.c",
    "arch/x86/kernel/paravirt.c",
    "arch/x86/kvm/vmx/main.c",
    "arch/x86/kvm/svm/svm.c",
  ]
}

pure log_name(mode: Str) -> Str {
  return f"laputa-linux-amd64-${mode}.log"
}

proc log_path(mode: Str) [env, error] -> Result[Path] {
  let dir = env.get("XSH_LINUX_ITER_LOG_DIR") ?? "/tmp"
  return fp"${dir}/${log_name(mode)}"
}

proc jobs() [env] -> Str {
  return env.get("LINUX_KBUILD_JOBS") ?? env.get("XSH_LINUX_KBUILD_JOBS") ?? "32"
}

proc host_xsh() [env] -> Str {
  return env.get("XSH_HOST") ?? "/home/josh/d/laputa-systems/xsh/target/debug/xsh"
}

proc mirror_url() [env] -> Str {
  return env.get("LAPUTA_MIRROR_URL") ?? "https://laputa.17166969.xyz"
}

proc packages_root() [fs, env, error] -> Result[Path] {
  let configured = env.get("LAPUTA_PACKAGES_ROOT") ?? ""

  if configured.trim() != "" {
    return fp"${configured}"
  }

  let home = env.get("HOME") ?? ""

  if home != "" {
    let home_root = fp"${home}/d/laputa-systems/packages"

    if fs.exists(home_root)? {
      return home_root
    }
  }

  let cwd = fs.cwd()?
  let sibling = fp"${cwd.parent}/packages"

  if fs.exists(sibling)? {
    return sibling
  }

  if home != "" {
    return fp"${home}/d/laputa-systems/packages"
  }

  return sibling
}

pure env_assignment(name: Str, value: Str) -> Str {
  return f"${name}=${value}"
}

proc package_argv(stage: Str, only: Str = "") [fs, env, error] -> Result[List[Str]] {
  var trusted = env.get("XSH_LINUX_KBUILD_TRUST_PLAN_CACHE") ?? ""
  let pm_root = packages_root()?.display()
  let job_count = jobs()

  if only != "" {
    trusted = "1"
  }

  var argv = [
    "doas",
    "env",
    env_assignment("HOME", env.get("HOME") ?? "/home/josh"),
    env_assignment("PATH", "/home/josh/.cargo/bin:/usr/local/bin:/usr/bin:/bin"),
    env_assignment("XSH_HOST", host_xsh()),
    env_assignment("LAPUTA_PACKAGES_ROOT", pm_root),
    env_assignment("XSH_MODULE_PATH", pm_root),
    env_assignment("XSH_PM_REPO", mirror_url()),
    env_assignment("XSH_PM_PUBLIC_REPO", mirror_url()),
    env_assignment("XSH_LINUX_KBUILD_PROGRESS", "1"),
    env_assignment("XSH_LINUX_KBUILD_PROGRESS_EVERY", env.get("XSH_LINUX_KBUILD_PROGRESS_EVERY") ?? "100"),
    env_assignment("XSH_LINUX_KBUILD_TIMING", "1"),
    env_assignment("XSH_MAKE_PROGRESS", "1"),
    env_assignment("MAKEFLAGS", f"-s -j${job_count}"),
    env_assignment("XSH_LINUX_KBUILD_JOBS", job_count),
    env_assignment("XSH_LINUX_KBUILD_DISCOVER_JOBS", job_count),
    env_assignment("XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN", "1"),
    env_assignment("XSH_LINUX_KBUILD_FORCE_DISCOVER", env.get("XSH_LINUX_KBUILD_FORCE_DISCOVER") ?? ""),
    env_assignment("XSH_LINUX_KBUILD_FORCE_ARCHIVES", env.get("XSH_LINUX_KBUILD_FORCE_ARCHIVES") ?? ""),
    env_assignment("XSH_LINUX_KBUILD_REUSE_ARCHIVES", env.get("XSH_LINUX_KBUILD_REUSE_ARCHIVES") ?? ""),
    env_assignment("XSH_LINUX_KBUILD_ONLY", only),
  ]

  if stage != "" {
    argv = argv.push(env_assignment("XSH_LINUX_KBUILD_STOP_AFTER", stage))
  }

  argv = argv.extend(
    [
      env_assignment("XSH_LINUX_KBUILD_TRUST_PLAN_CACHE", trusted),
      env_assignment("XSH_LINUX_KBUILD_USE_PLAN", env.get("XSH_LINUX_KBUILD_USE_PLAN") ?? ""),
      env_assignment("XSH_LINUX_KBUILD_USE_PLAN_TEXT", env.get("XSH_LINUX_KBUILD_USE_PLAN_TEXT") ?? ""),
      env_assignment("XSH_LINUX_KBUILD_USE_PLAN_TEXT_INLINE", env.get("XSH_LINUX_KBUILD_USE_PLAN_TEXT_INLINE") ?? ""),
      "make",
      "amd64-package-test",
      "PKGNAME=linux",
      f"LINUX_KBUILD_JOBS=${job_count}",
    ],
  )

  return argv
}

proc run_logged(mode: Str, argv: List[Str], expected: Str = "") [fs, process, env, time, error] {
  let log = log_path(mode)?
  fs.remove(log, missing_ok: true)?
  let start = time.now()
  print "linux-iteration-start" ${mode} $log

  let status = process.run(
    process.command_argv(argv[0], argv, cwd: fs.cwd()?, stdout: log, stderr: log, stderr_append: true),
  )?

  let elapsed = time.now() - start

  if expected != "" {
    if log.read_text()?.contains(expected) {
      print "linux-iteration-ok" ${mode} ${elapsed}ms $log
      return
    }

    return Err(
      IterationError.Failed(
        "linux-iteration-marker-missing",
        f"${mode} did not reach expected marker '${expected}'; see ${log.display()}",
      ),
    )
  }

  if status.ok {
    print "linux-iteration-ok" ${mode} ${elapsed}ms $log
    return
  }

  if status.exited() {
    return Err(
      IterationError.Failed(
        "linux-iteration-command-failed",
        f"${mode} exited ${status.exit_code()?}; see ${log.display()}",
      ),
    )
  }

  return Err(IterationError.Failed("linux-iteration-command-signaled", f"${mode} was signaled; see ${log.display()}"))
}

proc run_stage(stage: Str) [fs, process, env, time, error] {
  if ! (stage in ["prepare", "discover", "plan", "compile", "link"]) {
    return Err(IterationError.Failed("linux-iteration-stage", f"unsupported stage ${stage}"))
  }

  run_logged(stage, package_argv(stage)?, f"linux-kbuild-stopped: stopped after ${stage}")?
}

pure build_rel(name: Str) -> Int {
  let parts = name.split("-")

  if parts.len() < 3 {
    return -1
  }

  return parts[parts.len() - 1].parse_int() ?? -1
}

proc latest_build_src() [fs, env, error] -> Result[Path] {
  let home = env.get("HOME") ?? "/home/josh"
  let root = fp"${home}/.cache/laputa/amd64-package-test/.set-build-root/var/tmp/pm-build"
  var best = p""
  var best_rel = -1

  if ! root.exists()? {
    return Err(IterationError.Failed("linux-iteration-cache-missing", f"missing ${root.display()}"))
  }

  for entry in fs.walk(root, gitignore: false) {
    if entry.kind == "dir" and entry.name.starts_with("linux-") {
      let src = fp"${entry.path}/src"

      if src.exists()? {
        let rel = build_rel(entry.name)

        if rel > best_rel {
          best = src
          best_rel = rel
        }
      }
    }
  }

  if best_rel < 0 {
    return Err(
      IterationError.Failed("linux-iteration-build-src-missing", f"no linux build src under ${root.display()}"),
    )
  }

  return best
}

proc archive_plan_path() [fs, env, error] -> Result[Path] {
  let src = latest_build_src()?
  return fp"${src}/.xsh-kbuild-archive-plan.json"
}

pure string_list_contains(items: List[Str], value: Str) -> Bool {
  for item in items {
    if item == value {
      return true
    }
  }

  return false
}

pure output_objects(outputs: List[Str]) -> List[Str] {
  [output for output in outputs if output.ends_with(".o")]
}

proc outputs_for_source(plan_path: Path, source: Str) [fs, error] -> Result[List[Str]] {
  if source.ends_with(".o") {
    return [source]
  }

  let stored: Record = json.read(plan_path)?
  let rows: List[Record] = stored.get("tasks")?
  var outputs: List[Str] = []

  for row in rows {
    let inputs: List[Str] = row.get("inputs")?
    let argv: List[Str] = row.get("argv")?

    if string_list_contains(inputs, source) or string_list_contains(argv, source) {
      outputs = outputs.extend(output_objects(row.get("outputs")?))
    }
  }

  if outputs.len() > 0 {
    return outputs
  }

  if source.ends_with(".c") or source.ends_with(".S") {
    return [f".xsh-kbuild/obj/${source.replace(".c", ".o").replace(".S", ".o")}"]
  }

  return Err(
    IterationError.Failed("linux-iteration-source-unmapped", f"could not map ${source} through ${plan_path.display()}"),
  )
}

proc mapped_outputs(raw_sources: List[Str]) [fs, env, error] -> Result[List[Str]] {
  let plan_path = archive_plan_path()?

  if ! plan_path.exists()? {
    return Err(
      IterationError.Failed("linux-iteration-archive-plan-missing", f"missing ${plan_path.display()}; run plan first"),
    )
  }

  var outputs: List[Str] = []
  let sources = if raw_sources.len() == 0 { default_sources() } else { raw_sources }

  for source in sources {
    let mapped = outputs_for_source(plan_path, source)?
    print "linux-iteration-source" $source outputs.join(" ") mapped.join(",")
    outputs = outputs.extend(mapped)
  }

  return outputs
}

proc run_object(raw_sources: List[Str]) [fs, process, env, time, error] {
  let outputs = mapped_outputs(raw_sources)?
  run_logged("object", package_argv("", outputs.join(","))?, "linux-native-kbuild-target-complete")?
}

proc print_sources(raw_sources: List[Str]) [fs, env, error] {
  let _ = mapped_outputs(raw_sources)?
}

proc count_outputs_under(root: Path, suffix: Str) [fs, error] -> Result[Int] {
  var count = 0

  if ! root.exists()? {
    return 0
  }

  for entry in fs.walk(root, gitignore: false) {
    if entry.kind == "file" and entry.name.ends_with(suffix) {
      count = count + 1
    }
  }

  return count
}

proc print_file_probe(label: Str, path_value: Path) [fs, error] {
  if path_value.exists()? {
    print "linux-iteration-cache" ${label} present $path_value sha256 hash.sha256(path_value)?.hex()
  } else {
    print "linux-iteration-cache" ${label} missing $path_value
  }
}

proc cache_report() [fs, env, error] {
  let src = latest_build_src()?
  let obj = fp"${src}/.xsh-kbuild/obj"
  let plan = fp"${src}/.xsh-kbuild-plan.json"
  let fingerprint = fp"${src}/.xsh-kbuild-plan.fingerprint"
  let archive_plan = fp"${src}/.xsh-kbuild-archive-plan.json"
  print "linux-iteration-cache" $src $src
  print_file_probe("config", fp"${src}/.config")?
  print_file_probe("plan", plan)?
  print_file_probe("fingerprint", fingerprint)?
  print_file_probe("archive-plan", archive_plan)?
  print "linux-iteration-cache" objects ${count_outputs_under(obj, ".o")?}
  print "linux-iteration-cache" stamps ${count_outputs_under(obj, ".cmd")?}

  if archive_plan.exists()? {
    let stored: Record = json.read(archive_plan)?
    let tasks: List[Record] = stored.get("tasks")?
    let missing: List[Str] = stored.get("missing_sources")?
    let generated: List[Str] = stored.get("generated_objects")?
    let archives: List[Str] = stored.get("archives")?
    print "linux-iteration-cache" "archive-plan" "tasks" tasks.len() "archives" archives.len() "generated" generated.len() "missing" missing.len()
  }
}

proc write_config(out: Path) [fs, env, error] {
  let fragment = fp"${packages_root()?}/repo/linux/files/config/x86_64/base-x86_64.fragment"
  let text = fragment.read_text()?.trim()

  fs.write(
    out,
    f"""# Generated by linux-iteration.xsh from package config fragments.
#
${text}
""",
  )?
}

pure y_symbols(text: Str) -> Map[Bool] {
  var symbols: Map[Bool] = {}

  for raw in text.split("\n") {
    let line = raw.trim()

    if line.starts_with("CONFIG_") and line.ends_with("=y") {
      symbols[line] = true
    }
  }

  return symbols
}

proc kconfig_proof() [fs, env, time, error] {
  let out = fp"${env.get("XSH_LINUX_ITER_CONFIG_OUT") ?? "/tmp/laputa-linux-amd64.config"}"
  let fragment = fp"${packages_root()?}/repo/linux/files/config/x86_64/base-x86_64.fragment"
  let start = time.now()
  write_config(out)?
  let elapsed = time.now() - start
  let generated = out.read_text()?
  let base = fragment.read_text()?
  let base_y = y_symbols(base)
  var added = 0

  for raw in generated.split("\n") {
    let line = raw.trim()

    if line.starts_with("CONFIG_") and line.ends_with("=y") and ! base_y.get(line, false) {
      added = added + 1
      print "linux-iteration-kconfig-added" $line
    }

    if line.starts_with("CONFIG_RISCV") or line.starts_with("CONFIG_ARC_") or line == "CONFIG_the=y" or line == "CONFIG_it=y" {
      return Err(IterationError.Failed("linux-iteration-kconfig-bogus-symbol", f"generated config contains ${line}"))
    }
  }

  if added != 0 {
    return Err(
      IterationError.Failed("linux-iteration-kconfig-added-symbols", f"generated config added ${added} =y symbols"),
    )
  }

  print "linux-iteration-kconfig-proof" ok ${elapsed}ms $out
}

proc usage() [error] {
  return Err(
    IterationError.Failed(
      "linux-iteration-usage",
      "usage: linux-iteration.xsh config|prepare|discover|plan|compile|link|package|object [source...]|sources [source...]|cache|kconfig-proof",
    ),
  )
}

proc main(...argv: List[Str]) [fs, process, env, time, error] {
  if argv.len() == 0 {
    usage()?
  }

  let mode = argv[0]
  let rest = argv |> drop(1)

  if mode == "config" {
    let out = fp"${env.get("XSH_LINUX_ITER_CONFIG_OUT") ?? "/tmp/laputa-linux-amd64.config"}"
    let start = time.now()
    write_config(out)?
    print "linux-iteration-config" ok ${time.now() - start}ms $out
    return
  }

  if mode == "package" {
    run_logged("package", package_argv("")?)?
    return
  }

  if mode == "object" {
    run_object(rest)?
    return
  }

  if mode == "sources" {
    print_sources(rest)?
    return
  }

  if mode == "cache" {
    cache_report()?
    return
  }

  if mode == "kconfig-proof" {
    kconfig_proof()?
    return
  }

  if mode in ["prepare", "discover", "plan", "compile", "link"] {
    run_stage(mode)?
    return
  }

  usage()?
}

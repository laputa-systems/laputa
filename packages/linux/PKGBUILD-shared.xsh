##! XSH module `PKGBUILD-shared` package and build operations.
use kbuild
use pm.make

## Exported declaration `build_jobs`.
export proc build_jobs() [env, error] -> Result[Int, Error] {
  let raw = e"XSH_LINUX_KBUILD_JOBS" ?? ""

  if raw != "" {
    let parsed = raw as Int

    if parsed <= 0 {
      return Err(
        kbuild.ScriptError.Failed(kind: "linux-kbuild-jobs", message: "XSH_LINUX_KBUILD_JOBS must be a positive integer"),
      )
    }

    return parsed
  }

  make.jobs()
}

## Exported declaration `archive_analysis_jobs`.
export proc archive_analysis_jobs() [env, error] -> Result[Int, Error] {
  let raw = e"XSH_LINUX_KBUILD_ARCHIVE_ANALYSIS_JOBS" ?? ""

  return 8 when raw == ""

  let parsed = raw as Int

  if parsed <= 0 {
    return Err(
      kbuild.ScriptError.Failed(
        kind: "linux-kbuild-archive-analysis-jobs",
        message: "XSH_LINUX_KBUILD_ARCHIVE_ANALYSIS_JOBS must be a positive integer",
      ),
    )
  }

  parsed
}

## Exported declaration `discover_options_from_env`.
export proc discover_options_from_env() [env, error] -> Result[kbuild.DiscoverOptions, Error] {
  let every_text = e"XSH_LINUX_KBUILD_PROGRESS_EVERY" ?? "100"
  let jobs_text = e"XSH_LINUX_KBUILD_DISCOVER_JOBS" ?? ""
  let jobs_count = if jobs_text == "" { build_jobs()? } else { jobs_text as Int }

  {
    progress: (e"XSH_LINUX_KBUILD_PROGRESS" ?? "") == "1",
    progress_every: every_text as Int,
    jobs: jobs_count,
    local_records: (e"XSH_LINUX_KBUILD_LOCAL_RECORDS" ?? "") == "1",
    local_record_cache: (e"XSH_LINUX_KBUILD_LOCAL_RECORD_CACHE" ?? "") == "1" and (e"XSH_LINUX_KBUILD_FORCE_DISCOVER" ?? "") != "1",
    build_plan: true,
  }
}

proc staged_recipe_helper(name: Str) -> Result[Path] {
  let recipe_dir = (e"XSH_PM_RECIPE_DIR" ?? "").trim()

  if recipe_dir == "" {
    return Err(kbuild.ScriptError.Failed(kind: "linux-recipe-helper", message: f"missing XSH_PM_RECIPE_DIR for {name}"))
  }

  let helper = fp"{recipe_dir}/{name}"

  if ! helper.exists() {
    return Err(
      kbuild.ScriptError.Failed(kind: "linux-recipe-helper", message: f"missing staged recipe helper: {helper}"),
    )
  }

  helper
}

## Exported declaration `discover_package_plan`.
export proc discover_package_plan(srcarch: Str) [fs, process, env, time, error] -> Result[kbuild.KbuildPlan, Error] {
  (discover_package_with_inputs(srcarch)?).discovery.plan
}

type PackageDiscovery = {config: kbuild.Kconfig, discovery: kbuild.KbuildDiscovery}

proc discover_package_with_inputs(srcarch: Str) [fs, process, env, time, error] -> Result[PackageDiscovery, Error] {
  let config = kbuild.load_config(p".config")?
  let options = discover_options_from_env()?

  if ! options.local_record_cache {
    let xsh_bin = process.which("xsh")?
    let worker = staged_recipe_helper("kbuild-pool-worker.xsh")?
    let discovery = kbuild.discover_plan_with_process_pool(
      p".",
      config,
      srcarch,
      options,
      xsh_bin,
      worker,
    )?
    return {config: config, discovery: discovery}
  }

  {config: config, discovery: kbuild.discover_with_inputs(p".", config, srcarch, options)?}
}

## Exported declaration `write_materialized_outputs`.
export proc write_materialized_outputs(outputs: List[Path]) [fs, error] {
  var text = """format linux-materialized-outputs-v1
"""

  for output in outputs {
    text = f"""{text}{output}
"""
  }

  kbuild.write_text_if_changed(p".xsh-kbuild/materialized-outputs", text)
}

## Exported declaration `requested_stop_after`.
export proc requested_stop_after() [env, error] -> Result[Str, Error] {
  let requested = e"XSH_LINUX_KBUILD_STOP_AFTER" ?? ""

  return "" when requested == ""

  if requested not in ["prepare", "discover", "plan", "compile", "link"] {
    return Err(
      kbuild.ScriptError.Failed(
        kind: "linux-kbuild-stop-after",
        message: f"XSH_LINUX_KBUILD_STOP_AFTER must be prepare, discover, plan, compile, or link; got '{requested}'",
      ),
    )
  }

  requested
}

## Exported declaration `stop_after`.
export proc stop_after(stage: Str) [env, error] {
  if requested_stop_after()? == stage {
    return Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-stopped", message: f"stopped after {stage}"))
  }
}

## Exported declaration `timing_start`.
export proc timing_start(stage: Str) [env, time] -> Int {
  if (e"XSH_LINUX_KBUILD_TIMING" ?? "") == "1" {
    print "linux-kbuild-timing-start" $stage
    return time.now()
  }

  0
}

## Exported declaration `timing_done`.
export proc timing_done(stage: Str, start: Int) [env, time] {
  if (e"XSH_LINUX_KBUILD_TIMING" ?? "") == "1" {
    let elapsed = time.now() - start
    print "linux-kbuild-timing-done" $stage $elapsed "ms"
  }
}

## Exported declaration `emit_plan_if_enabled`.
export proc emit_plan_if_enabled(plan: kbuild.KbuildPlan) [fs, env, error] {
  if (e"XSH_LINUX_KBUILD_PLAN" ?? "") == "1" {
    kbuild.write_discovered_plan(plan, p".xsh-kbuild-plan.json")
    print "xsh-kbuild-plan" plan.dirs.len() "dirs" plan.objects.len() "objects" plan.unsupported.len() "unsupported"
  }
}

## Exported declaration `emit_kbuild_progress`.
export proc emit_kbuild_progress(message: Str) [fs, env, error] {
  if (e"XSH_LINUX_KBUILD_PROGRESS" ?? "") == "1" {
    kbuild.write_text_if_changed(
      p".xsh-kbuild-progress",
      f"""{message}
""",
    )

    print $message
  }
}

proc remove_archive_plan_cache() {
  p".xsh-kbuild-archive-plan.json".remove()
  p".xsh-kbuild-archive-plan.json.summary".remove()
  p".xsh-kbuild-archive-plan.fingerprint".remove()
}

proc archive_plan_cache_fingerprint(
  prepared: kbuild.PreparedArchivePlan,
  cc: Path,
  srcarch: Str,
  cflags: List[Str],
  includes: List[Str],
) -> Result[Str] {
  let plan = prepared.plan
  let triple = prepared.triple
  let items = prepared.items
  let inputs_hash = bytes.from_text(json.encode({cc: cc.display(), srcarch: srcarch, triple: triple, cflags: cflags, includes: includes, items: items})?).sha256().hex()
  f"""format linux-archive-plan-cache-v2
srcarch {srcarch}
triple {triple}
inputs {inputs_hash}
plan
{kbuild.plan_fingerprint(p".", p".config", plan, srcarch)?}
cflags
{cflags.join("\n")}
includes
{includes.join("\n")}
"""
}

type ArchiveCacheRead = {plan: kbuild.BuiltinArchivePlan, payloads: kbuild.ArchivePlanPayloads}
type ArchiveCacheManifest = {fingerprint: Str, report_hash: Str, summary_hash: Str}

pure archive_payload_hash(payload: Str) -> Str {
  bytes.from_text(payload).sha256().hex()
}

proc read_archive_plan_cache(path_value: Path, fingerprint: Str, report: Path, plan_only: Bool) -> Result[ArchiveCacheRead] {
  let manifest = json.read(path_value)?.require(ArchiveCacheManifest)?
  let payloads: kbuild.ArchivePlanPayloads = {
    report: if plan_only { "" } else { report.read_text()? },
    summary: kbuild.archive_plan_summary_path(report).read_text()?,
  }
  if manifest.fingerprint != fingerprint or manifest.summary_hash != archive_payload_hash(payloads.summary) or
      (! plan_only and manifest.report_hash != archive_payload_hash(payloads.report)) {
    return Err(kbuild.ScriptError.Failed(kind: "kbuild-archive-plan-cache-stale", message: "archive plan cache fingerprint mismatch"))
  }
  let plan = if plan_only { kbuild.parse_archive_plan_summary(payloads.summary)? } else { kbuild.parse_archive_plan_report(payloads.report)? }
  {plan: plan, payloads: payloads}
}

proc write_archive_plan_cache(report: Path, path_value: Path, fingerprint: Str, payloads: kbuild.ArchivePlanPayloads) {
  kbuild.write_text_if_changed(report, payloads.report)
  kbuild.write_text_if_changed(kbuild.archive_plan_summary_path(report), payloads.summary)
  let manifest: ArchiveCacheManifest = {
    fingerprint: fingerprint, report_hash: archive_payload_hash(payloads.report), summary_hash: archive_payload_hash(payloads.summary),
  }
  kbuild.write_text_if_changed(path_value, json.encode(manifest)?)
}

## Exported declaration `cached_archive_plan`.
export proc cached_archive_plan(
  plan: kbuild.KbuildPlan,
  cc: Path,
  srcarch: Str,
  triple: Str,
  cflags: List[Str],
  includes: List[Str],
) [fs, process, env, time, error] -> Result[kbuild.BuiltinArchivePlan, Error] {
  if srcarch != "arm64" and srcarch != "x86" {
    return Err(
      kbuild.ScriptError.Failed(
        kind: "linux-native-kbuild-unsupported-arch",
        message: f"native scratch Kbuild final link is only implemented for arm64 and x86; {srcarch} needs new arch support",
      ),
    )
  }

  let archive_report = p".xsh-kbuild-archive-plan.json"
  let archive_fingerprint = p".xsh-kbuild-archive-plan.fingerprint"
  let stable_cache_dir = fp"{e"XSH_LINUX_KBUILD_PLAN_CACHE_DIR" ?? "/var/cache/laputa/linux-kbuild"}"
  let stable_archive_report = fp"{stable_cache_dir}/linux-{srcarch}.archive-plan.json"
  let stable_archive_fingerprint = fp"{stable_cache_dir}/linux-{srcarch}.archive-plan.fingerprint"
  let prepared = kbuild.prepare_archive_analysis(plan, triple)?
  let fingerprint_start = timing_start("archive-fingerprint")
  let fingerprint = archive_plan_cache_fingerprint(prepared, cc, srcarch, cflags, includes)?
  timing_done("archive-fingerprint", fingerprint_start)
  let reuse_archive_plan = (e"XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN" ?? "") == "1"
  let archive_only = (e"XSH_LINUX_KBUILD_ARCHIVE_ONLY" ?? "") == "1"
  let plan_only = requested_stop_after()? == "plan" and (e"XSH_LINUX_KBUILD_ONLY" ?? "") == ""

  if reuse_archive_plan and (e"XSH_LINUX_KBUILD_FORCE_ARCHIVES" ?? "") != "1" {
    if archive_report.exists() or (plan_only and kbuild.archive_plan_summary_path(archive_report).exists()) {
      match read_archive_plan_cache(archive_fingerprint, fingerprint, archive_report, plan_only) {
        Ok(cached) => {
          emit_kbuild_progress(f"xsh-kbuild-archive-plan-cache {cached.plan.task_count} tasks")
          return cached.plan
        }
        Err(error) => emit_kbuild_progress(f"xsh-kbuild-archive-plan-cache miss {error.message}")
      }
    }

    if stable_archive_report.exists() or (plan_only and kbuild.archive_plan_summary_path(stable_archive_report).exists()) {
      match read_archive_plan_cache(stable_archive_fingerprint, fingerprint, stable_archive_report, plan_only) {
        Ok(cached) => {
          emit_kbuild_progress(f"xsh-kbuild-archive-plan-stable-cache {cached.plan.task_count} tasks")
          if ! plan_only {
            write_archive_plan_cache(archive_report, archive_fingerprint, fingerprint, cached.payloads)
          }
          return cached.plan
        }
        Err(error) => emit_kbuild_progress(f"xsh-kbuild-archive-plan-stable-cache miss {error.message}")
      }
    }
  }

  emit_kbuild_progress(
    f"xsh-kbuild-archive-plan-start {plan.dirs.len()} dirs {plan.objects.len()} objects {plan.composites.len()} composites",
  )

  let analysis_jobs = archive_analysis_jobs()?
  let worker = staged_recipe_helper("kbuild-archive-analysis-worker.xsh")?
  let archive_plan = kbuild.plan_builtin_archives_with_analysis_workers(
    prepared,
    cc,
    cflags,
    [],
    includes,
    analysis_jobs,
    /bin/xsh,
    worker,
  )?

  if archive_only {
    emit_kbuild_progress(
      f"xsh-kbuild-archive-plan {archive_plan.task_count} tasks {archive_plan.archives.len()} archives {archive_plan.link_inputs.len()} link-inputs {archive_plan.generated_objects.len()} generated {archive_plan.missing_sources.len()} missing",
    )
    return archive_plan
  }

  let report_start = timing_start("archive-report")
  let payloads = kbuild.archive_plan_payloads(archive_plan)?
  write_archive_plan_cache(archive_report, archive_fingerprint, fingerprint, payloads)
  stable_cache_dir.mkdir()
  write_archive_plan_cache(stable_archive_report, stable_archive_fingerprint, fingerprint, payloads)
  timing_done("archive-report", report_start)

  emit_kbuild_progress(
    f"xsh-kbuild-archive-plan {archive_plan.task_count} tasks {archive_plan.archives.len()} archives {archive_plan.link_inputs.len()} link-inputs {archive_plan.generated_objects.len()} generated {archive_plan.missing_sources.len()} missing",
  )

  archive_plan
}

## Exported declaration `cached_package_plan`.
export proc cached_package_plan(srcarch: Str) [fs, process, env, time, error] -> Result[kbuild.KbuildPlan, Error] {
  let _ = kbuild.load_config(p".config")?
  let explicit_inline = e"XSH_LINUX_KBUILD_USE_PLAN_TEXT_INLINE" ?? ""
  let explicit_text = e"XSH_LINUX_KBUILD_USE_PLAN_TEXT" ?? ""
  let explicit = e"XSH_LINUX_KBUILD_USE_PLAN" ?? ""

  if explicit_inline != "" {
    emit_kbuild_progress("xsh-kbuild-plan-cache explicit-inline-read")
    let plan = kbuild.parse_discovered_plan_text(explicit_inline)?
    print "xsh-kbuild-plan-cache" "explicit-inline" plan.dirs.len() "dirs" plan.objects.len() "objects" \
      plan.composites.len() "composites"
    return plan
  }

  if explicit_text != "" {
    emit_kbuild_progress(f"xsh-kbuild-plan-cache explicit-text-read {explicit_text}")
    let plan = kbuild.read_discovered_plan_text(fp"{explicit_text}")?
    print "xsh-kbuild-plan-cache" "explicit-text" $explicit_text plan.dirs.len() "dirs" plan.objects.len() "objects" \
      plan.composites.len() "composites"
    return plan
  }

  if explicit != "" {
    emit_kbuild_progress(f"xsh-kbuild-plan-cache explicit-read {explicit}")
    let plan = kbuild.read_discovered_plan(fp"{explicit}")?
    print "xsh-kbuild-plan-cache" "explicit" $explicit plan.dirs.len() "dirs" plan.objects.len() "objects" \
      plan.composites.len() "composites"
    return plan
  }

  let force_discover = (e"XSH_LINUX_KBUILD_FORCE_DISCOVER" ?? "") == "1"
  let plan_path = p".xsh-kbuild-plan.json"
  let fingerprint_path = p".xsh-kbuild-plan.fingerprint"
  let stable_cache_dir = fp"{e"XSH_LINUX_KBUILD_PLAN_CACHE_DIR" ?? "/var/cache/laputa/linux-kbuild"}"
  let stable_plan_path = fp"{stable_cache_dir}/linux-{srcarch}.plan.json"
  let stable_fingerprint_path = fp"{stable_cache_dir}/linux-{srcarch}.plan.fingerprint"

  if force_discover {
    emit_kbuild_progress("xsh-kbuild-plan-cache force-discover")
  }

  if ! force_discover and plan_path.exists() and fingerprint_path.exists() {
    emit_kbuild_progress("xsh-kbuild-plan-cache read")
    let plan = kbuild.read_discovered_plan(plan_path)?
    emit_kbuild_progress(f"xsh-kbuild-plan-cache fingerprint {plan.dirs.len()} dirs {plan.objects.len()} objects")

    if (e"XSH_LINUX_KBUILD_TRUST_PLAN_CACHE" ?? "") == "1" {
      print "xsh-kbuild-plan-cache" "trusted" plan.dirs.len() "dirs" plan.objects.len() "objects" \
        plan.composites.len() "composites"
      return plan
    }

    let fingerprint = kbuild.plan_fingerprint(p".", p".config", plan, srcarch)?

    if fingerprint_path.read_text()?.trim() == fingerprint.trim() {
      print "xsh-kbuild-plan-cache" "hit" plan.dirs.len() "dirs" plan.objects.len() "objects" plan.composites.len() \
        "composites"
      return plan
    }

    if stable_plan_path.exists() and stable_fingerprint_path.exists() {
      emit_kbuild_progress("xsh-kbuild-plan-cache stale-stable-read")
      let stable_plan = kbuild.read_discovered_plan(stable_plan_path)?
      let stable_fingerprint = kbuild.plan_fingerprint(p".", p".config", stable_plan, srcarch)?

      if stable_fingerprint_path.read_text()?.trim() == stable_fingerprint.trim() {
        kbuild.write_discovered_plan(stable_plan, plan_path)

        kbuild.write_text_if_changed(
          fingerprint_path,
          f"""{stable_fingerprint}
""",
        )

        print "xsh-kbuild-plan-cache" "stale-stable-hit" stable_plan.dirs.len() "dirs" stable_plan.objects.len() \
          "objects" stable_plan.composites.len() "composites"
        return stable_plan
      }
    }

    emit_kbuild_progress("xsh-kbuild-plan-cache stale")
  }

  if ! force_discover and stable_plan_path.exists() and stable_fingerprint_path.exists() {
    emit_kbuild_progress("xsh-kbuild-plan-cache stable-read")
    let stable_plan = kbuild.read_discovered_plan(stable_plan_path)?
    let stable_fingerprint = kbuild.plan_fingerprint(p".", p".config", stable_plan, srcarch)?

    if stable_fingerprint_path.read_text()?.trim() == stable_fingerprint.trim() {
      kbuild.write_discovered_plan(stable_plan, plan_path)

      kbuild.write_text_if_changed(
        fingerprint_path,
        f"""{stable_fingerprint}
""",
      )

      print "xsh-kbuild-plan-cache" "stable-hit" stable_plan.dirs.len() "dirs" stable_plan.objects.len() "objects" \
        stable_plan.composites.len() "composites"
      return stable_plan
    }

    emit_kbuild_progress("xsh-kbuild-plan-cache stable-miss")
  }

  emit_kbuild_progress("xsh-kbuild-plan discover-start")
  let makefile_hash = hash.sha256(p"Makefile")?.hex()
  let observed = discover_package_with_inputs(srcarch)?
  let plan = observed.discovery.plan
  emit_kbuild_progress(f"xsh-kbuild-plan write {plan.dirs.len()} dirs {plan.objects.len()} objects")
  kbuild.write_discovered_plan(plan, plan_path)
  remove_archive_plan_cache()
  emit_kbuild_progress("xsh-kbuild-plan fingerprint")
  let fingerprint = kbuild.plan_fingerprint_for_discovery(observed.config, observed.discovery, srcarch, makefile_hash)?

  kbuild.write_text_if_changed(
    fingerprint_path,
    f"""{fingerprint}
""",
  )

  stable_cache_dir.mkdir()
  kbuild.write_discovered_plan(plan, stable_plan_path)

  kbuild.write_text_if_changed(
    stable_fingerprint_path,
    f"""{fingerprint}
""",
  )

  emit_plan_if_enabled(plan)
  plan
}

## Exported declaration `add_extra_objects_from_env`.
export proc add_extra_objects_from_env(plan: kbuild.KbuildPlan) [env, error] -> Result[kbuild.KbuildPlan, Error] {
  let raw = (e"XSH_LINUX_KBUILD_EXTRA_OBJECTS" ?? "").replace(",", with: " ")
  var objects = [fp"{item}" for item in raw.words()]
  kbuild.add_plan_objects(plan, objects)
}

proc parse_kbuild_only_outputs(raw: Str) [error] -> Result[List[Path]] {
  let outputs: List[Path] = collect {
    for item in raw.split(",") {
      let trimmed = item.trim()

      yield fp"{trimmed}" when trimmed != ""
    }
  }

  if outputs.is_empty() {
    return Err(
      kbuild.ScriptError.Failed(
        kind: "linux-native-kbuild-target-empty",
        message: "XSH_LINUX_KBUILD_ONLY must name at least one archive-plan output",
      ),
    )
  }

  outputs
}

## Exported declaration `run_targeted_kbuild_outputs`.
export proc run_targeted_kbuild_outputs(
  archive_plan: kbuild.BuiltinArchivePlan,
  only: Str,
) [fs, process, env, time, error] {
  let outputs = parse_kbuild_only_outputs(only)?
  let jobs_count = build_jobs()?
  let selected = kbuild.select_archive_tasks_outputs(archive_plan.tasks, outputs)?
  print "linux-native-kbuild-target-plan" selected.len() "tasks" outputs.len() "outputs"

  if requested_stop_after()? == "plan" {
    kbuild.write_archive_plan_report(archive_plan, p".xsh-kbuild-archive-plan.json")
    stop_after("plan")
  }

  make.run_tasks(selected, jobs_count)
  stop_after("compile")

  return Err(
    kbuild.ScriptError.Failed(
      kind: "linux-native-kbuild-target-complete",
      message: f"native scratch Kbuild ran outputs.len() requested target(s); continue with the next targeted object batch or the full archive graph",
    ),
  )
}

## Exported declaration `require_valid_archive_plan`.
export proc require_valid_archive_plan(archive_plan: kbuild.BuiltinArchivePlan) [error] {
  guard archive_plan.duplicate_outputs.is_empty() else {
    return Err(
      kbuild.ScriptError.Failed(kind: "linux-native-kbuild-duplicate-output", message: "archive plan has duplicate output"),
    )
  }

  var outputs: Map[Bool] = {}

  for task in archive_plan.tasks {
    for output in task.outputs {
      let key = output.display()
      continue when key == ""

      if outputs.get(key) ?? false {
        return Err(
          kbuild.ScriptError.Failed(kind: "linux-native-kbuild-duplicate-output", message: "archive plan has duplicate output"),
        )
      }

      outputs[key] = true
    }
  }
}

## Exported declaration `require_complete_x86_archive_plan`.
export proc require_complete_x86_archive_plan(archive_plan: kbuild.BuiltinArchivePlan) [error] {
  require_valid_archive_plan(archive_plan)

  if ! archive_plan.generated_objects.is_empty() {
    return Err(
      kbuild.ScriptError.Failed(
        kind: "linux-native-kbuild-generated-incomplete",
        message: f"x86 full package build still has {archive_plan.generated_objects.len()} generated object(s); generate or exclude them before linking",
      ),
    )
  }

  if ! archive_plan.missing_sources.is_empty() {
    return Err(
      kbuild.ScriptError.Failed(
        kind: "linux-native-kbuild-missing-sources",
        message: f"x86 full package build still has {archive_plan.missing_sources.len()} selected object(s) without direct sources; restore/generate/exclude them before linking",
      ),
    )
  }
}

## Exported declaration `native_tool`.
export proc native_tool(name: Str) [fs, process, env, error] -> Result[Path, Error] {
  let build_root = e"XSH_PM_BUILD_ROOT" ?? ""

  if build_root != "" {
    let tool = fp"{build_root}/usr/bin/{name}"

    return tool when tool.exists()
  }

  process.which(name)?
}

## Exported declaration `run_native_command`.
export proc run_native_command(argv: List[Str]) [process, env, error] {
  let build_root = e"XSH_PM_BUILD_ROOT" ?? ""

  let command = if build_root != "" {
    process.command_argv(argv[0], argv, env: {PATH: f"{build_root}/usr/bin:{e"PATH" ?? ""}"})
  } else {
    process.command_argv(argv[0], argv)
  }

  let status = process.run(command)?

  if ! status.ok {
    return Err(
      kbuild.ScriptError.Failed(kind: "linux-native-kbuild-command", message: f"command failed: {argv.join(" ")}"),
    )
  }
}

## Exported declaration `write_default_builtin_initramfs`.
export proc write_default_builtin_initramfs(cc: Path) [fs, process, env, error] {
  # Keep Linux's default built-in cpio, not a userspace initramfs. With
  # CONFIG_INITRAMFS_SOURCE="", upstream kbuild generates usr/default_cpio_list:
  # /dev, /dev/console, and /root. Those entries are enough for the kernel's
  # no-initramfs block-root path to create /dev/root before mounting the real
  # ext4 root, where xinit then runs as /init.
  #
  # The XSH native Kbuild path does not run usr/Makefile, so we must explicitly
  # generate the same usr/initramfs_inc_data payload here. Writing an empty file
  # regresses direct block-root boot with "Failed to create /dev/root".
  p".xsh-kbuild/host".mkdir()
  let gen = p".xsh-kbuild/host/gen_init_cpio"
  run_native_command([cc.display(), "-O2", "-o", gen.display(), "usr/gen_init_cpio.c"])
  let output = run.capture --bytes $gen "usr/default_cpio_list"

  if ! output.status.ok {
    return Err(kbuild.ScriptError.Failed(kind: "linux-initramfs-default-cpio", message: "gen_init_cpio failed"))
  }

  p"usr/initramfs_inc_data".write(output.stdout)
}

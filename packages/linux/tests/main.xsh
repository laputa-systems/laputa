use packages.linux.kbuild
use packages.linux.PKGBUILD-shared as linux_shared
use pm.make

type ArchiveTaskReport = {argv: List[Str], outputs: List[Str]}

type ArchivePlanReport = {task_count: Int, tasks: List[ArchiveTaskReport]}

type ArchiveCompileTaskReport = {source: Str, flags: List[Str]}

type ArchiveAnalysisResult = {object: Str, tasks: List[ArchiveCompileTaskReport]}

proc write_fixture(root: Path) {
  fp"{root}/init/lib".mkdir()
  fp"{root}/block".mkdir()
  fp"{root}/net".mkdir()
  fp"{root}/fs".mkdir()
  fp"{root}/fs/proc".mkdir()
  fp"{root}/fs/devpts".mkdir()
  fp"{root}/fs/ramfs".mkdir()
  fp"{root}/mm".mkdir()
  fp"{root}/arch/arm64/kernel".mkdir()

  fp"{root}/.config".write(
    """CONFIG_BLOCK=y
CONFIG_NET=y
CONFIG_INET=y
CONFIG_HYPERV=m
CONFIG_MMU=y
CONFIG_UNIX98_PTYS=y
# CONFIG_UNUSED is not set
""",
  )

  fp"{root}/Kbuild".write(
    """core-y += arch/$(SRCARCH)/kernel/
obj-y += init/
obj-y += fs/ mm/
obj-y += core.o $(core-y)
helper_files = libhelper.o
lib-y += $(helper_files)
combo-y += combo-a.o combo-b.o
obj-y += combo.o
obj-$(CONFIG_BLOCK) += block/
obj-$(CONFIG_NET) += net/
obj-$(CONFIG_UNUSED) += unused/
obj-$(subst m,y,$(CONFIG_HYPERV)) += hyperv.o
ifeq ($(CONFIG_BLOCK),y)
obj-y += conditional.o
endif
ifeq ($(CONFIG_UNUSED),y)
obj-y += skipped.o
endif
""",
  )

  fp"{root}/Makefile".write(
    """obj-y += wrong-precedence.o
""",
  )

  fp"{root}/init/Kbuild".write(
    """obj-y += main.o \\
  lib/
""",
  )

  fp"{root}/init/lib/Makefile".write(
    """obj-y += helper.o
""",
  )

  fp"{root}/block/Kbuild".write(
    """obj-y := blk-core.o
""",
  )

  fp"{root}/net/Kbuild".write(
    """obj-$(CONFIG_INET) += ipv4.o
""",
  )

  fp"{root}/fs/Kbuild".write(
    """obj-y += proc/ devpts/ ramfs/
""",
  )

  fp"{root}/fs/devpts/Kbuild".write(
    """obj-$(CONFIG_UNIX98_PTYS) += devpts.o
devpts-$(CONFIG_UNIX98_PTYS) := inode.o
""",
  )

  fp"{root}/fs/proc/Makefile".write(
    """obj-y += proc.o
proc-y := nommu.o task_nommu.o
proc-$(CONFIG_MMU) := task_mmu.o
proc-y += inode.o
""",
  )

  fp"{root}/fs/ramfs/Kbuild".write(
    """obj-y += ramfs.o
file-mmu-y := file-nommu.o
file-mmu-$(CONFIG_MMU) := file-mmu.o
ramfs-objs += inode.o $(file-mmu-y)
""",
  )

  fp"{root}/mm/Kbuild".write(
    """obj-y += mm.o
mmu-y := nommu.o
mmu-$(CONFIG_MMU) := highmem.o memory.o
""",
  )

  fp"{root}/arch/arm64/kernel/Kbuild".write(
    """obj-y += head.o
""",
  )
}

pure contains_path(paths: List[Path], target: Str) -> Bool {
  for path_value in paths {
    return true when path_value.display() == target
  }

  false
}

proc test_builtin_archive_plan(
  cache: Path,
  plan: kbuild.KbuildPlan,
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
) [fs, env, time, error] -> Result[kbuild.BuiltinArchivePlan] {
  env ({XSH_LINUX_KBUILD_PLAN_CACHE_DIR: cache.display(), XSH_LINUX_KBUILD_COMPILE_FLAGS_CACHE_DIR: cache.display(),
    XSH_LINUX_KBUILD_TRUST_COMPILE_FLAGS_CACHE: "0"}) {
    return kbuild.plan_builtin_archives(plan, cc, triple, cflags, defs, includes)?
  }
}

proc test_builtin_archive_plan_with_workers(
  cache: Path,
  plan: kbuild.KbuildPlan,
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  analysis_jobs: Int,
  xsh_bin: Path,
  worker: Path,
) [fs, process, env, time, error] -> Result[kbuild.BuiltinArchivePlan] {
  env ({XSH_LINUX_KBUILD_PLAN_CACHE_DIR: cache.display(), XSH_LINUX_KBUILD_COMPILE_FLAGS_CACHE_DIR: cache.display(),
    XSH_LINUX_KBUILD_TRUST_COMPILE_FLAGS_CACHE: "0"}) {
    return kbuild.plan_builtin_archives_with_analysis_workers(
      plan,
      cc,
      triple,
      cflags,
      defs,
      includes,
      analysis_jobs,
      xsh_bin,
      worker,
    )?
  }
}

pure composite_has_member(plan: kbuild.KbuildPlan, object: Str, member: Str) -> Bool {
  for composite in plan.composites {
    if composite.object.display() == object {
      return contains_path(composite.members, member)
    }
  }

  false
}

test test_kbuild_discovers_configured_obj_y_dirs_and_objects [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-kbuild")?
  write_fixture(root)
  let config = kbuild.load_config(fp"{root}/.config")?
  let plan = kbuild.discover_plan(root, config, "arm64")?
  assert contains_path(plan.dirs, ".")
  assert contains_path(plan.dirs, "init")
  assert contains_path(plan.dirs, "init/lib")
  assert contains_path(plan.dirs, "block")
  assert contains_path(plan.dirs, "net")
  assert contains_path(plan.dirs, "arch/arm64/kernel")
  assert contains_path(plan.dirs, "unused") == false
  assert contains_path(plan.objects, "core.o")
  assert contains_path(plan.objects, "wrong-precedence.o") == false
  assert contains_path(plan.lib_objects, "libhelper.o")
  assert contains_path(plan.objects, "combo.o")
  assert plan.composites.len() == 4
  assert plan.composites[0].object == "combo.o"
  assert contains_path(plan.composites[0].members, "combo-a.o")
  assert contains_path(plan.composites[0].members, "combo-b.o")
  assert contains_path(plan.objects, "hyperv.o")
  assert contains_path(plan.objects, "conditional.o")
  assert contains_path(plan.objects, "skipped.o") == false
  assert contains_path(plan.objects, "init/main.o")
  assert contains_path(plan.objects, "init/lib/helper.o")
  assert contains_path(plan.objects, "block/blk-core.o")
  assert contains_path(plan.objects, "net/ipv4.o")
  assert contains_path(plan.objects, "arch/arm64/kernel/head.o")
  assert contains_path(plan.objects, "fs/proc/proc.o")
  assert contains_path(plan.objects, "fs/ramfs/ramfs.o")
  assert contains_path(plan.objects, "mm/mm.o")
  assert contains_path(plan.objects, "fs/proc/nommu.o") == false
  assert contains_path(plan.objects, "fs/proc/task_nommu.o") == false
  assert contains_path(plan.objects, "fs/ramfs/file-nommu.o") == false
  assert contains_path(plan.objects, "mm/nommu.o") == false
  assert composite_has_member(plan, "fs/proc/proc.o", "fs/proc/task_mmu.o")
  assert composite_has_member(plan, "fs/ramfs/ramfs.o", "fs/ramfs/file-mmu.o")
  assert composite_has_member(plan, "fs/devpts/devpts.o", "fs/devpts/inode.o")
  assert plan.unsupported.is_empty()
}

test test_kbuild_worker_records_bind_included_inputs [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-kbuild-worker-inputs")?
  fp"{root}/.config".write("")
  fp"{root}/Kbuild".write("include $(src)/objects.include\n")
  let included = fp"{root}/objects.include"
  included.write("obj-y := before.o\n")
  let config = kbuild.load_config(fp"{root}/.config")?
  let before = kbuild.scan_record_for_dir(root, config, "x86", p".")?
  included.write("obj-y := after.o\n")
  let after = kbuild.scan_record_for_dir(root, config, "x86", p".")?
  assert before.plan.objects == ["before.o"]
  assert after.plan.objects == ["after.o"]
  assert before.file_hash != ""
  assert before.file_hash != after.file_hash
}

test test_kbuild_local_record_graph_matches_default [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-kbuild-local-records")?
  let default_out = test.temp_path(ctx, name: "linux-kbuild-default-plan")
  let local_out = test.temp_path(ctx, name: "linux-kbuild-local-plan")
  write_fixture(root)
  let config = kbuild.load_config(fp"{root}/.config")?
  let default_plan = kbuild.discover_plan(root, config, "arm64")?
  let local_plan = kbuild.discover_plan_with_options(
    root,
    config,
    "arm64",
    {
      progress: false,
      progress_every: 100,
      jobs: 1,
      local_records: true,
      local_record_cache: false,
      build_plan: true,
    },
  )?
  kbuild.write_discovered_plan(default_plan, default_out)
  kbuild.write_discovered_plan(local_plan, local_out)
  assert default_out.read_text()? == local_out.read_text()?
}

test test_kbuild_local_record_cache_reuses_and_invalidates [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-kbuild-local-cache")?
  write_fixture(root)
  let config = kbuild.load_config(fp"{root}/.config")?
  let options = {
    progress: false,
    progress_every: 100,
    jobs: 1,
    local_records: true,
    local_record_cache: true,
    build_plan: true,
  }
  let first = kbuild.discover_plan_with_options(root, config, "arm64", options)?
  let second = kbuild.discover_plan_with_options(root, config, "arm64", options)?
  assert first.objects.len() == second.objects.len()

  let root_kbuild = fp"{root}/Kbuild"
  let original = root_kbuild.read_text()?
  root_kbuild.write(
    f"""{original}obj-y += cached.o
""",
  )
  let third = kbuild.discover_plan_with_options(root, config, "arm64", options)?
  assert contains_path(third.objects, "cached.o")
}

test test_kbuild_local_record_cache_binds_parsed_configuration [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-kbuild-config-snapshot")?
  let config_path = fp"{root}/.config"
  fp"{root}/Kbuild".write("obj-$(CONFIG_TEST) += chosen.o\n")
  config_path.write("CONFIG_TEST=y\n")
  let enabled = kbuild.load_config(config_path)?
  config_path.write("# CONFIG_TEST is not set\n")
  let disabled = kbuild.load_config(config_path)?
  let options = {progress: false, progress_every: 100, jobs: 1, local_records: true, local_record_cache: true, build_plan: true}
  let first = kbuild.discover_plan_with_options(root, enabled, "x86", options)?
  assert contains_path(first.objects, "chosen.o")
  let second = kbuild.discover_plan_with_options(root, disabled, "x86", options)?
  assert ! contains_path(second.objects, "chosen.o")
}

test test_kbuild_rebuilds_legacy_local_records_after_make_semantics_change [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-kbuild-legacy-records")?
  write_fixture(root)
  let config = kbuild.load_config(fp"{root}/.config")?
  let options = {progress: false, progress_every: 100, jobs: 1, local_records: true, local_record_cache: true, build_plan: true}
  let _ = kbuild.discover_plan_with_options(root, config, "arm64", options)?
  let cache = fp"{root}/.xsh-kbuild-local-records.json"
  let original = cache.read_text()?
  let stale = original.replace("init/main.o", with: "init/stale.o").replace("linux-local-records-v4", with: "linux-local-records-v3")
  assert stale != original
  cache.write(stale)
  let refreshed = kbuild.discover_plan_with_options(root, config, "arm64", options)?
  assert contains_path(refreshed.objects, "init/main.o")
  assert ! contains_path(refreshed.objects, "init/stale.o")
  assert "linux-local-records-v4" in cache.read_text()?
}

test test_kbuild_rebuilds_legacy_discovered_plan_cache [fs, process, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-legacy-plan")?
  let cache = test.temp_dir(ctx, name: "linux-legacy-plan-cache")?
  write_fixture(root)
  cd root {
    env ({XSH_LINUX_KBUILD_PLAN_CACHE_DIR: cache.display(), XSH_LINUX_KBUILD_LOCAL_RECORDS: "1",
      XSH_LINUX_KBUILD_LOCAL_RECORD_CACHE: "1", XSH_LINUX_KBUILD_DISCOVER_JOBS: "1",
      XSH_LINUX_KBUILD_TRUST_PLAN_CACHE: "0", XSH_LINUX_KBUILD_FORCE_DISCOVER: "0",
      XSH_LINUX_KBUILD_USE_PLAN_TEXT_INLINE: "", XSH_LINUX_KBUILD_USE_PLAN_TEXT: "", XSH_LINUX_KBUILD_USE_PLAN: ""}) {
      let _ = linux_shared.cached_package_plan("arm64")?
      for plan_file in [p".xsh-kbuild-plan.json", fp"{cache}/linux-arm64.plan.json"] {
        let original = plan_file.read_text()?
        let stale = original.replace("init/main.o", with: "init/stale.o")
        assert stale != original
        plan_file.write(stale)
      }
      for fingerprint in [p".xsh-kbuild-plan.fingerprint", fp"{cache}/linux-arm64.plan.fingerprint"] {
        let current = fingerprint.read_text()?
        fingerprint.write(current.replace("linux-kbuild-plan-fingerprint-v11", with: "linux-kbuild-plan-fingerprint-v10"))
      }
      let refreshed = linux_shared.cached_package_plan("arm64")?
      assert contains_path(refreshed.objects, "init/main.o")
      assert ! contains_path(refreshed.objects, "init/stale.o")
      assert "linux-kbuild-plan-fingerprint-v11" in p".xsh-kbuild-plan.fingerprint".read_text()?
      for plan_file in [p".xsh-kbuild-plan.json", fp"{cache}/linux-arm64.plan.json"] {
        let original = plan_file.read_text()?
        plan_file.write(original.replace("init/main.o", with: "init/stale.o"))
      }
      let repaired = linux_shared.cached_package_plan("arm64")?
      assert contains_path(repaired.objects, "init/main.o")
      assert ! contains_path(repaired.objects, "init/stale.o")
    }?
  }
}

test test_kbuild_plan_cache_distinguishes_source_architectures [fs, process, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-plan-arch-change")?
  let cache = test.temp_dir(ctx, name: "linux-plan-arch-cache")?
  fp"{root}/.config".write("")
  fp"{root}/Makefile".write("")
  fp"{root}/Kbuild".write("""ifeq ($(SRCARCH),arm64)
obj-y += arm.o
else
obj-y += x86.o
endif
""")
  cd root {
    env ({XSH_LINUX_KBUILD_PLAN_CACHE_DIR: cache.display(), XSH_LINUX_KBUILD_LOCAL_RECORDS: "1",
      XSH_LINUX_KBUILD_LOCAL_RECORD_CACHE: "1", XSH_LINUX_KBUILD_DISCOVER_JOBS: "1",
      XSH_LINUX_KBUILD_TRUST_PLAN_CACHE: "0", XSH_LINUX_KBUILD_FORCE_DISCOVER: "0",
      XSH_LINUX_KBUILD_USE_PLAN_TEXT_INLINE: "", XSH_LINUX_KBUILD_USE_PLAN_TEXT: "", XSH_LINUX_KBUILD_USE_PLAN: ""}) {
      let arm = linux_shared.cached_package_plan("arm64")?
      assert contains_path(arm.objects, "arm.o")
      let x86 = linux_shared.cached_package_plan("x86")?
      assert contains_path(x86.objects, "x86.o")
      assert ! contains_path(x86.objects, "arm.o")
    }?
  }
}

test test_kbuild_plan_cache_invalidates_nested_and_included_makefiles [fs, process, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-plan-input-change")?
  let cache = test.temp_dir(ctx, name: "linux-plan-input-cache")?
  write_fixture(root)
  let nested = fp"{root}/init/Kbuild"
  nested.write(nested.read_text()? + "include $(src)/extra.include\n")
  let included = fp"{root}/init/extra.include"
  included.write("obj-y += included-before.o\n")
  cd root {
    env ({XSH_LINUX_KBUILD_PLAN_CACHE_DIR: cache.display(), XSH_LINUX_KBUILD_LOCAL_RECORDS: "1",
      XSH_LINUX_KBUILD_LOCAL_RECORD_CACHE: "1", XSH_LINUX_KBUILD_DISCOVER_JOBS: "1",
      XSH_LINUX_KBUILD_TRUST_PLAN_CACHE: "0", XSH_LINUX_KBUILD_FORCE_DISCOVER: "0",
      XSH_LINUX_KBUILD_USE_PLAN_TEXT_INLINE: "", XSH_LINUX_KBUILD_USE_PLAN_TEXT: "", XSH_LINUX_KBUILD_USE_PLAN: ""}) {
      let first = linux_shared.cached_package_plan("arm64")?
      assert contains_path(first.objects, "init/included-before.o")
      included.write("obj-y += included-after.o\n")
      let second = linux_shared.cached_package_plan("arm64")?
      assert contains_path(second.objects, "init/included-after.o")
      assert ! contains_path(second.objects, "init/included-before.o")
      nested.write(nested.read_text()? + "obj-y += nested-added.o\n")
      let third = linux_shared.cached_package_plan("arm64")?
      assert contains_path(third.objects, "init/nested-added.o")
    }?
  }
}

test test_kbuild_writes_text_plan [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-kbuild-text")?
  let out = test.temp_path(ctx, name: "plan.json")
  write_fixture(root)
  let plan = kbuild.write_plan(root, fp"{root}/.config", out, "arm64")?
  let stored = out.read_text()?
  assert "obj\tinit/main.o" in stored
  let loaded = kbuild.read_discovered_plan(out)?
  assert loaded.objects.len() == plan.objects.len()
  assert contains_path(loaded.objects, "init/main.o")
}

test test_kbuild_expands_nested_make_functions_and_replaces_object_assignments [fs, error] { |ctx|
  for mode in ["flat", "conditional"] {
    let root = test.temp_dir(ctx, name: f"linux-kbuild-make-functions-{mode}")?
    fp"{root}/.config".write("CONFIG_TEST=y\n")
    let assignments = """obj-y := one.o café.o
obj-y := $(patsubst %.o,%.pi.o,$(obj-y))
lib-y := core.o
lib-y := $(patsubst %.o,%.stub.o,$(lib-y))
vdsos-y := 64 x32 café
obj-y += $(foreach x,$(vdsos-y),café$(x)-image.o)
empty-y :=
empty-y ?= unwanted.o
obj-y += $(empty-y)
"""
    let source = if mode == "conditional" { "ifeq ($(CONFIG_TEST),y)\n" + assignments + "endif\n" } else { assignments }
    fp"{root}/Kbuild".write(source)
    let config = kbuild.load_config(fp"{root}/.config")?
    let plan = kbuild.discover_plan(root, config, "x86")?
    assert [item.display() for item in plan.objects] == ["one.pi.o", "café.pi.o", "café64-image.o", "caféx32-image.o", "cafécafé-image.o"]
    assert [item.display() for item in plan.lib_objects] == ["core.stub.o"]
    assert plan.unsupported.is_empty(), plan.unsupported.join("\n")
  }
}

test test_kbuild_simple_assignments_replace_prior_object_lists [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-kbuild-simple-assignments")?
  fp"{root}/.config".write("")
  fp"{root}/Kbuild".write("""obj-y := discarded.o
obj-y := retained.o
obj-y += appended.o
lib-y := old.o
lib-y := new.o
""")
  let config = kbuild.load_config(fp"{root}/.config")?
  let plan = kbuild.discover_plan(root, config, "x86")?
  assert [item.display() for item in plan.objects] == ["retained.o", "appended.o"]
  assert [item.display() for item in plan.lib_objects] == ["new.o"]
  assert plan.unsupported.is_empty(), plan.unsupported.join("\n")
}

test test_kbuild_constructs_builtin_archive_tasks [fs, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-archive-tasks")?
  let cache = test.temp_dir(ctx, name: "linux-archive-cache")?
  write_fixture(root)

  fp"{root}/core.c".write(
    """int core(void) { return 0; }
""",
  )

  fp"{root}/libhelper.c".write(
    """int libhelper(void) { return 0; }
""",
  )

  fp"{root}/hyperv.c".write(
    """int hyperv(void) { return 0; }
""",
  )

  fp"{root}/conditional.c".write(
    """int conditional(void) { return 0; }
""",
  )

  fp"{root}/combo-a.c".write(
    """int combo_a(void) { return 0; }
""",
  )

  fp"{root}/combo-b.c".write(
    """int combo_b(void) { return 0; }
""",
  )

  fp"{root}/init/main.c".write(
    """int init_main(void) { return 0; }
""",
  )

  fp"{root}/init/lib/helper.S".write(
    """.text
""",
  )

  fp"{root}/fs/proc/task_mmu.c".write(
    """int task_mmu(void) { return 0; }
""",
  )

  fp"{root}/fs/proc/inode.c".write(
    """int proc_inode(void) { return 0; }
""",
  )

  fp"{root}/fs/devpts/inode.c".write(
    """int devpts_inode(void) { return 0; }
""",
  )

  fp"{root}/fs/ramfs/inode.c".write(
    """int ramfs_inode(void) { return 0; }
""",
  )

  fp"{root}/fs/ramfs/file-mmu.c".write(
    """int ramfs_file_mmu(void) { return 0; }
""",
  )

  fp"{root}/mm/mm.c".write(
    """int mm(void) { return 0; }
""",
  )

  fp"{root}/block/blk-core.c".write(
    """int blk_core(void) { return 0; }
""",
  )

  fp"{root}/net/ipv4.c".write(
    """int ipv4(void) { return 0; }
""",
  )

  fp"{root}/arch/arm64/kernel/head.S".write(
    """.text
""",
  )

  let config = kbuild.load_config(fp"{root}/.config")?
  let plan = kbuild.discover_plan(root, config, "arm64")?

  cd root {
    let archive_plan = test_builtin_archive_plan(
      cache,
      plan,
      /usr/bin/cc,
      "aarch64-linux-gnu",
      ["-D__KERNEL__", "-O2", "-mgeneral-regs-only", "-mbranch-protection=pac-ret"],
      [],
      [
        "-Iinclude",
        "-nostdinc",
        "-include",
        "include/linux/compiler-version.h",
        "-include",
        "include/linux/kconfig.h",
        "-include",
        "include/generated/utsversion.h",
        "-include",
        "include/linux/compiler_types.h",
      ],
    )?

    assert archive_plan.missing_sources.is_empty()
    assert archive_plan.generated_objects.is_empty()
    assert archive_plan.tasks.len() == 29
    assert contains_path(archive_plan.archives, ".xsh-kbuild/built-in.a")
    assert contains_path(archive_plan.archives, ".xsh-kbuild/lib.a")
    assert contains_path(archive_plan.archives, ".xsh-kbuild/init/built-in.a")
    assert contains_path(archive_plan.archives, ".xsh-kbuild/init/lib/built-in.a")
    let report = fp"{root}/archive-plan.json"
    kbuild.write_archive_plan_report(archive_plan, report)
    let stored = json.read(report)?.require(ArchivePlanReport)?
    let {task_count, tasks, ..} = stored
    assert task_count == archive_plan.tasks.len()
    assert tasks.len() == archive_plan.tasks.len()
    let first = tasks[0]
    let {argv, outputs, ..} = first
    assert ! argv.is_empty()
    assert ! outputs.is_empty()
    var saw_asm = false

    for task in archive_plan.tasks {
      if task.name == ".xsh-kbuild/obj/init/lib/helper.o" {
        saw_asm = true
        let asm_argv = make.argv_text(task.argv)?
        assert "-D__ASSEMBLY__" in asm_argv
        assert "-fno-PIE" in asm_argv
        assert "-DKASAN_SHADOW_SCALE_SHIFT=" in asm_argv
        assert "-nostdinc" in asm_argv
        assert "include/linux/compiler-version.h" in asm_argv
        assert "include/linux/kconfig.h" in asm_argv
        assert "-O2" in asm_argv == false
        assert "-mgeneral-regs-only" in asm_argv == false
        assert "-mbranch-protection=pac-ret" in asm_argv == false
        assert "include/generated/utsversion.h" in asm_argv == false
        assert "include/linux/compiler_types.h" in asm_argv
      }
    }

    assert saw_asm
  }
}

test test_kbuild_plans_pi_relacheck_after_objcopy [fs, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-pi-relacheck")?
  let cache = test.temp_dir(ctx, name: "linux-pi-cache")?
  fp"{root}/arch/arm64/kernel/pi".mkdir()
  fp"{root}/.config".write("")

  fp"{root}/Kbuild".write(
    """obj-y += arch/arm64/kernel/pi/
""",
  )

  fp"{root}/arch/arm64/kernel/pi/Makefile".write(
    """obj-y += idreg-override.pi.o
""",
  )

  fp"{root}/arch/arm64/kernel/pi/idreg-override.c".write(
    """int idreg_override;
""",
  )

  fp"{root}/arch/arm64/kernel/pi/relacheck.c".write(
    """int main(int argc, char **argv) { return argc < 3; }
""",
  )

  cd root {
    let config = kbuild.load_config(p".config")?
    let plan = kbuild.discover_plan(p".", config, "arm64")?

    let archive_plan = test_builtin_archive_plan(
      cache,
      plan,
      /usr/bin/cc,
      "aarch64-linux-gnu",
      ["-fno-function-sections", "-fno-data-sections"],
      [],
      [],
    )?

    let relacheck = ".xsh-kbuild/host/arch/arm64/kernel/pi/relacheck"
    let pi_object = p".xsh-kbuild/obj/arch/arm64/kernel/pi/idreg-override.pi.o"
    let relacheck_task_name = f"{pi_object}:relacheck"
    var saw_build_task = false
    var saw_check_task = false
    var saw_archive_dep = false

    for task in archive_plan.tasks {
      if task.name == relacheck {
        saw_build_task = true
      }

      if task.name == relacheck_task_name {
        saw_check_task = true
        assert relacheck in task.argv
        assert pi_object.display() in task.argv
        assert fp"{pi_object}.relacheck.cmd" in task.outputs
        assert pi_object.display() in task.deps
        assert relacheck in task.deps
      }

      if task.name == ".xsh-kbuild/arch/arm64/kernel/pi/built-in.a" {
        saw_archive_dep = relacheck_task_name in task.deps
      }
    }

    assert saw_build_task
    assert saw_check_task
    assert saw_archive_dep
  }
}

test test_kbuild_runs_archive_plan_output_from_json [fs, process, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-archive-runner")?
  let first = fp"{root}/first.txt"
  let second = fp"{root}/second.txt"
  let unused = fp"{root}/unused.txt"
  let source = fp"{root}/source.txt"
  let calls = fp"{root}/calls.txt"
  let plan = fp"{root}/archive-plan.json"
  let no_strings: List[Str] = []
  source.write("first")

  json.write(
    plan,
    {
      archives: no_strings,
      generated_objects: no_strings,
      missing_sources: no_strings,
      task_count: 3,
      tasks: [
        {
          name: "first",
          outputs: [
            first.display(),
          ],
          inputs: [source.display()],
          deps: no_strings,
          argv: [
            "/bin/sh",
            "-c",
            f"cat {source} > {first}; printf 'first\\n' >> {calls}",
          ],
          env: {},
          cwd: root.display(),
          depfile: "",
          stamp: fp"{root}/first.cmd".display(),
        },
        {
          name: "second",
          outputs: [
            second.display(),
          ],
          inputs: [
            first.display(),
          ],
          deps: [
            "first",
          ],
          argv: [
            "/bin/sh",
            "-c",
            f"cat {first} > {second}; printf second >> {second}; printf 'second\\n' >> {calls}",
          ],
          env: {},
          cwd: root.display(),
          depfile: "",
          stamp: fp"{root}/second.cmd".display(),
        },
        {
          name: "unused",
          outputs: [unused.display()],
          inputs: no_strings,
          deps: no_strings,
          argv: ["/bin/sh", "-c", f"printf unused > {unused}"],
          env: {},
          cwd: root.display(),
          depfile: "",
          stamp: fp"{root}/unused.cmd".display(),
        },
      ],
    },
  )

  kbuild.run_archive_plan_output(plan, second, 1)
  assert first.read_text()? == "first"
  assert second.read_text()? == "firstsecond"
  assert ! unused.exists()?
  assert calls.read_text()? == "first\nsecond\n"
  kbuild.run_archive_plan_output(plan, second, 1)
  assert calls.read_text()? == "first\nsecond\n"
  fs.set_times(second, mtime_sec: 4039372800)?
  source.write("changed")
  fs.set_times(source, mtime_sec: 4070908800)?
  kbuild.run_archive_plan_output(plan, second, 1)
  assert first.read_text()? == "changed"
  assert second.read_text()? == "changedsecond"
  assert calls.read_text()? == "first\nsecond\nfirst\nsecond\n"
  assert ! unused.exists()?
  let archive_plan: kbuild.BuiltinArchivePlan = {
    tasks: [
      {name: "first", outputs: [first], inputs: [source], deps: [], argv: ["/bin/true"], cwd: root,
        env: {}, depfile: p"", stamp: p""},
      {name: "second", outputs: [second], inputs: [first], deps: ["first"], argv: ["/bin/true"], cwd: root,
        env: {}, depfile: p"", stamp: p""},
      {name: "unused", outputs: [unused], inputs: [], deps: [], argv: ["/bin/true"], cwd: root,
        env: {}, depfile: p"", stamp: p""},
    ],
    task_specs: [],
    task_count: 3,
    archives: [],
    link_inputs: [],
    missing_sources: [],
    generated_objects: [],
    duplicate_outputs: [],
  }
  cd root {
    env ({XSH_LINUX_KBUILD_STOP_AFTER: "plan", XSH_LINUX_KBUILD_JOBS: "1"}) {
      match linux_shared.run_targeted_kbuild_outputs(archive_plan, second.display()) {
        Ok(_) => test.fail("plan stop unexpectedly succeeded")
        Err(kbuild.ScriptError.Failed {kind, message}) => {
          assert kind == "linux-kbuild-stopped"
          assert message == "stopped after plan"
        }
        Err(problem) => test.fail(f"unexpected plan stop error: {problem.message}")
      }
    }
    let report = json.read(p".xsh-kbuild-archive-plan.json")?.require(ArchivePlanReport)?
    assert report.task_count == 3
    assert report.tasks.len() == 3
  }
  assert calls.read_text()? == "first\nsecond\nfirst\nsecond\n"
}

test test_kbuild_reports_missing_builtin_archive_sources [fs, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-archive-missing")?
  let cache = test.temp_dir(ctx, name: "linux-missing-cache")?

  fp"{root}/present.c".write(
    """int present(void) { return 0; }
""",
  )

  let plan: kbuild.KbuildPlan = kbuild.KbuildPlan(
    dirs: [
      p".",
    ],
    objects: [
      p"present.o",
      p"missing.o",
    ],
    lib_objects: [],
    archive_owners: [],
    composites: [],
    unsupported: [],
  )

  cd root {
    let archive_plan = test_builtin_archive_plan(cache, plan, /usr/bin/cc, "aarch64-linux-gnu", [], [], [])?
    assert archive_plan.missing_sources.len() == 1
    assert archive_plan.generated_objects.is_empty()
    assert contains_path(archive_plan.missing_sources, "missing.o")
    assert archive_plan.archives.len() == 1
  }
}

test test_kbuild_archive_analysis_preserves_item_order [fs, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-archive-analysis")?
  fp"{root}/first.c".write(
    """int first(void) { return 0; }
""",
  )
  fp"{root}/second.c".write(
    """int second(void) { return 0; }
""",
  )

  cd root {
    let results = kbuild.analyze_archive_items(
      [
        {
          object: "first.o",
          owner: ".",
          library: false,
          pi: false,
          composite: "",
          members: [],
          flags: [
            "-DFIRST",
          ],
        },
        {
          object: "second.o",
          owner: "lib",
          library: true,
          pi: false,
          composite: "",
          members: [],
          flags: [
            "-DSECOND",
          ],
        },
      ],
    )?.require(List[ArchiveAnalysisResult])?
    assert results.len() == 2
    assert results[0].object == "first.o"
    assert results[1].object == "second.o"

    let first_tasks = results[0].tasks
    let second_tasks = results[1].tasks
    assert first_tasks[0].source == "first.c"
    assert second_tasks[0].source == "second.c"
    assert first_tasks[0].flags == ["-DFIRST"]
    assert second_tasks[0].flags == ["-DSECOND"]
  }
}

test test_kbuild_parallel_archive_analysis_matches_serial [fs, process, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-archive-analysis-pool")?
  let cache = test.temp_dir(ctx, name: "linux-analysis-cache")?
  let worker = path.absolute(p"packages/linux/kbuild-archive-analysis-worker.xsh")?
  let xsh_bin = process.which("xsh")?
  fp"{root}/.config".write("")
  fp"{root}/Kbuild".write("")
  fp"{root}/first.c".write(
    """int first(void) { return 0; }
""",
  )
  fp"{root}/second.c".write(
    """int second(void) { return 0; }
""",
  )

  let plan: kbuild.KbuildPlan = kbuild.KbuildPlan(
    dirs: [
      p".",
    ],
    objects: [
      p"first.o",
      p"second.o",
    ],
    lib_objects: [],
    archive_owners: [
      {
        object: p"first.o",
        dir: p".",
      },
      {
        object: p"second.o",
        dir: p".",
      },
    ],
    composites: [],
    unsupported: [],
  )

  cd root {
    let serial = test_builtin_archive_plan(cache, plan, /usr/bin/cc, "aarch64-linux-gnu", [], [], [])?
    let parallel = test_builtin_archive_plan_with_workers(
      cache,
      plan,
      /usr/bin/cc,
      "aarch64-linux-gnu",
      [],
      [],
      [],
      2,
      xsh_bin,
      worker,
    )?
    assert parallel.archives == serial.archives
    assert parallel.link_inputs == serial.link_inputs
    assert parallel.generated_objects == serial.generated_objects
    assert parallel.missing_sources == serial.missing_sources
    assert parallel.tasks.len() == serial.tasks.len()

    for index in range(serial.tasks.len()) {
      assert parallel.tasks[index].name == serial.tasks[index].name
      assert make.argv_text(parallel.tasks[index].argv)? == make.argv_text(serial.tasks[index].argv)?
      assert parallel.tasks[index].deps == serial.tasks[index].deps
    }

    env ({
      XSH_LINUX_KBUILD_ARCHIVE_ONLY: "1",
    }) {
      let compact_serial = test_builtin_archive_plan(cache, plan, /usr/bin/cc, "aarch64-linux-gnu", [], [], [])?
      let compact_parallel = test_builtin_archive_plan_with_workers(
        cache,
        plan,
        /usr/bin/cc,
        "aarch64-linux-gnu",
        [],
        [],
        [],
        2,
        xsh_bin,
        worker,
      )?
      assert compact_parallel.archives == compact_serial.archives
      assert compact_parallel.link_inputs == compact_serial.link_inputs
      assert compact_parallel.generated_objects == compact_serial.generated_objects
      assert compact_parallel.missing_sources == compact_serial.missing_sources
      assert compact_parallel.task_count == compact_serial.task_count
      assert compact_parallel.task_specs == compact_serial.task_specs
      assert compact_parallel.tasks.is_empty()
      assert compact_serial.tasks.is_empty()
      assert ! compact_parallel.task_specs.is_empty()
    }
  }
}

test test_kbuild_adds_x86_kvm_local_include [fs, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-x86-kvm-include")?
  let cache = test.temp_dir(ctx, name: "linux-kvm-cache")?
  fp"{root}/arch/x86/kvm/mmu".mkdir()

  fp"{root}/arch/x86/kvm/mmu/mmu.c".write(
    """#include "irq.h"
int mmu(void) { return 0; }
""",
  )

  let plan: kbuild.KbuildPlan = kbuild.KbuildPlan(
    dirs: [
      p"arch/x86/kvm",
    ],
    objects: [
      p"arch/x86/kvm/kvm.o",
    ],
    lib_objects: [],
    archive_owners: [],
    composites: [
      {
        object: p"arch/x86/kvm/kvm.o",
        members: [
          p"arch/x86/kvm/mmu/mmu.o",
        ],
      },
    ],
    unsupported: [],
  )

  cd root {
    let archive_plan = test_builtin_archive_plan(cache, plan, /usr/bin/cc, "x86_64-linux-gnu", [], [], [])?
    var saw_mmu = false

    for task in archive_plan.tasks {
      if task.name == ".xsh-kbuild/obj/arch/x86/kvm/mmu/mmu.o" {
        saw_mmu = true
        assert "-I./arch/x86/kvm" in task.argv
      }
    }

    assert saw_mmu
  }
}

test test_kbuild_applies_object_and_subdir_cflags [fs, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-cflags")?
  let cache = test.temp_dir(ctx, name: "linux-cflags-cache")?
  fp"{root}/sound/hda/common".mkdir()
  fp"{root}/sound/hda/controllers".mkdir()
  fp"{root}/.config".write("")

  fp"{root}/sound/hda/common/Makefile".write(
    """CFLAGS_controller.o := -I$(src)
""",
  )

  fp"{root}/sound/hda/controllers/Makefile".write(
    """subdir-ccflags-y += -I$(src)/../common
CFLAGS_intel.o := -I$(src)
""",
  )

  fp"{root}/sound/hda/common/controller.c".write(
    """int controller(void) { return 0; }
""",
  )

  fp"{root}/sound/hda/controllers/intel.c".write(
    """int intel(void) { return 0; }
""",
  )

  let plan: kbuild.KbuildPlan = kbuild.KbuildPlan(
    dirs: [
      p"sound/hda/common",
      p"sound/hda/controllers",
    ],
    objects: [
      p"sound/hda/common/controller.o",
      p"sound/hda/controllers/intel.o",
    ],
    lib_objects: [],
    archive_owners: [],
    composites: [],
    unsupported: [],
  )

  cd root {
    let archive_plan = test_builtin_archive_plan(cache, plan, /usr/bin/cc, "x86_64-linux-gnu", [], [], [])?
    var saw_controller = false
    var saw_intel = false

    for task in archive_plan.tasks {
      if task.name == ".xsh-kbuild/obj/sound/hda/common/controller.o" {
        saw_controller = true
        assert "-I./sound/hda/common" in task.argv
      }

      if task.name == ".xsh-kbuild/obj/sound/hda/controllers/intel.o" {
        saw_intel = true
        assert "-I./sound/hda/controllers" in task.argv
        assert "-I./sound/hda/controllers/../common" in task.argv
      }
    }

    assert saw_controller
    assert saw_intel
  }
}

test test_kbuild_defined_empty_flags_reject_conditional_defaults [fs, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-empty-flags")?
  let cache = test.temp_dir(ctx, name: "linux-empty-flags-cache")?
  fp"{root}/.config".write("")
  fp"{root}/foo.c".write("int foo(void) { return 0; }\n")
  fp"{root}/Kbuild".write("""empty-y :=
empty-y ?= unwanted
ccflags-y :=
ccflags-y ?= -DUNEXPECTED_DIR
subdir-ccflags-y :=
subdir-ccflags-y ?= -DUNEXPECTED_SUBDIR
CFLAGS_foo.o :=
CFLAGS_foo.o ?= -DUNEXPECTED_OBJECT
CFLAGS_foo.o += -DVALUE=$(empty-y)
""")
  let plan: kbuild.KbuildPlan = kbuild.KbuildPlan(
    dirs: [p"."], objects: [p"foo.o"], lib_objects: [], archive_owners: [], composites: [], unsupported: [],
  )
  cd root {
    let archive_plan = test_builtin_archive_plan(cache, plan, /usr/bin/cc, "x86_64-linux-gnu", [], [], [])?
    let tasks = [task for task in archive_plan.tasks if task.name == ".xsh-kbuild/obj/foo.o"]
    assert tasks.len() == 1
    assert "-DVALUE=" in tasks[0].argv
    assert "-DUNEXPECTED_DIR" not in tasks[0].argv
    assert "-DUNEXPECTED_SUBDIR" not in tasks[0].argv
    assert "-DUNEXPECTED_OBJECT" not in tasks[0].argv
  }
}

test test_kbuild_rebuilds_legacy_compile_flags_cache [fs, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-legacy-flags")?
  let cache = test.temp_dir(ctx, name: "linux-legacy-flags-cache")?
  fp"{root}/.config".write("")
  fp"{root}/foo.c".write("int foo(void) { return 0; }\n")
  fp"{root}/Kbuild".write("CFLAGS_include.o := flags.include\ninclude $(CFLAGS_include.o)\n")
  fp"{root}/flags.include".write("CFLAGS_foo.o := -DVALID\n")
  let plan: kbuild.KbuildPlan = kbuild.KbuildPlan(
    dirs: [p"."], objects: [p"foo.o"], lib_objects: [], archive_owners: [], composites: [], unsupported: [],
  )
  cd root {
    let _ = test_builtin_archive_plan(cache, plan, /usr/bin/cc, "x86_64-linux-gnu", [], [], [])?
    let local = p".xsh-kbuild-compile-flags.json"
    let stable = fp"{cache}/linux-x86.compile-flags.json"
    for cache_file in [local, stable] {
      let original = cache_file.read_text()?
      let stale = original.replace("-DVALID", with: "-DSTALE").replace("linux-kbuild-compile-flags-v3", with: "linux-kbuild-compile-flags-v2")
      assert stale != original
      cache_file.write(stale)
    }
    let refreshed = test_builtin_archive_plan(cache, plan, /usr/bin/cc, "x86_64-linux-gnu", [], [], [])?
    let tasks = [task for task in refreshed.tasks if task.name == ".xsh-kbuild/obj/foo.o"]
    assert tasks.len() == 1
    assert "-DVALID" in tasks[0].argv
    assert "-DSTALE" not in tasks[0].argv
    assert "linux-kbuild-compile-flags-v3" in local.read_text()?
    p"flags.include".write("CFLAGS_foo.o := -DUPDATED\n")
    let updated = test_builtin_archive_plan(cache, plan, /usr/bin/cc, "x86_64-linux-gnu", [], [], [])?
    let updated_tasks = [task for task in updated.tasks if task.name == ".xsh-kbuild/obj/foo.o"]
    assert updated_tasks.len() == 1
    assert "-DUPDATED" in updated_tasks[0].argv
    assert "-DVALID" not in updated_tasks[0].argv
  }
}

test test_kbuild_applies_composite_makefile_cflags_to_subdir_members [fs, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-composite-cflags")?
  let cache = test.temp_dir(ctx, name: "linux-composite-cache")?
  fp"{root}/lib/xor/x86".mkdir()
  fp"{root}/.config".write("")

  fp"{root}/lib/xor/Makefile".write(
    """ccflags-y += -I $(src)
obj-y += xor.o
xor-y += core.o x86/avx.o
CFLAGS_x86/avx.o += -DXOR_MEMBER_FLAG
""",
  )

  fp"{root}/lib/xor/core.c".write("int core(void) { return 0; }\n")
  fp"{root}/lib/xor/x86/avx.c".write("int avx(void) { return 0; }\n")

  let plan: kbuild.KbuildPlan = kbuild.KbuildPlan(
    dirs: [p"lib/xor"],
    objects: [p"lib/xor/xor.o"],
    lib_objects: [],
    archive_owners: [],
    composites: [kbuild.CompositeObject(p"lib/xor/xor.o", [p"lib/xor/core.o", p"lib/xor/x86/avx.o"])],
    unsupported: [],
  )

  cd root {
    let archive_plan = test_builtin_archive_plan(cache, plan, /usr/bin/cc, "x86_64-linux-gnu", [], [], [])?
    var saw_member = false

    for task in archive_plan.tasks {
      if task.name == ".xsh-kbuild/obj/lib/xor/x86/avx.o" {
        saw_member = true
        assert "./lib/xor" in task.argv
        assert "-DXOR_MEMBER_FLAG" in task.argv
      }
    }

    assert saw_member
  }
}

test test_kbuild_generates_config_headers [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-config-headers")?
  let config = fp"{root}/.config"

  config.write(
    """CONFIG_ALPHA=y
CONFIG_NUMBER=12
CONFIG_TEXT="value"
""",
  )

  kbuild.write_config_headers(config, root, "7.0.5", "arm64")
  let autoconf = fp"{root}/include/generated/autoconf.h".read_text()?
  let auto_conf = fp"{root}/include/config/auto.conf".read_text()?
  assert "#define CONFIG_ALPHA 1" in autoconf
  assert "#define CONFIG_NUMBER 12" in autoconf
  assert "#define CONFIG_TEXT \"value\"" in autoconf
  assert "CONFIG_ALPHA=y" in auto_conf
  assert "CONFIG_NUMBER=12" in auto_conf
}

test test_kbuild_generates_syscall_table [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-syscalls")?
  let table = fp"{root}/syscall.tbl"
  let out = fp"{root}/syscall_table.h"
  let numbers = fp"{root}/unistd.h"

  table.write(
    """0 common read sys_read
2 common open sys_open compat_sys_open
3 64 exit sys_exit - noreturn
4 32 skip32 sys_skip32
""",
  )

  kbuild.generate_syscall_table(table, out, ["common", "64"])

  assert out.read_text()? == """__SYSCALL(0, sys_read)
__SYSCALL(1, sys_ni_syscall)
__SYSCALL_WITH_COMPAT(2, sys_open, compat_sys_open)
__SYSCALL_NORETURN(3, sys_exit)
"""

  kbuild.generate_syscall_numbers(table, numbers, "_ASM_UNISTD_H", "__NR_syscalls", "", ["common", "64"])
  let observed_output_1 = numbers.read_text()?
  assert "#define __NR_read 0" in observed_output_1
  let observed_output_2 = numbers.read_text()?
  assert "#define __NR_exit 3" in observed_output_2
  let observed_output_3 = numbers.read_text()?
  assert "#define __NR_syscalls 4" in observed_output_3
}

test test_kbuild_generates_offsets_header [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-offsets")?
  let asm_path = fp"{root}/asm-offsets.s"
  let out = fp"{root}/include/generated/asm-offsets.h"

  asm_path.write(
    """.ascii "->FOO 8 offsetof(struct demo, foo)"
.ascii "->"
.ascii "->BAR 16 sizeof(struct demo)"
""",
  )

  kbuild.generate_offsets_header(asm_path, out, "__ASM_OFFSETS_H__")

  assert out.read_text()? == """#ifndef __ASM_OFFSETS_H__
#define __ASM_OFFSETS_H__
/*
 * DO NOT MODIFY.
 *
 * This file was generated by Kbuild
 */

#define FOO 8 /* offsetof(struct demo, foo) */

#define BAR 16 /* sizeof(struct demo) */

#endif
"""
}

test test_kbuild_config_keeps_string_values_that_contain_equals_signs [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-config-strings")?
  fp"{root}/.config".write("""CONFIG_CMDLINE_BOOL=y
CONFIG_CMDLINE="root=PARTLABEL=LAPUTA_ROOT rw console=ttyS0"
""")
  let config = kbuild.load_config(fp"{root}/.config")?
  assert (config.values.get("CMDLINE") ?? "") == "root=PARTLABEL=LAPUTA_ROOT rw console=ttyS0"
  kbuild.write_config_headers(fp"{root}/.config", root, "7.0.5", "x86")
  assert "#define CONFIG_CMDLINE \"root=PARTLABEL=LAPUTA_ROOT rw console=ttyS0\"" in fp"{root}/include/generated/autoconf.h".read_text()?
}

test test_kbuild_x86_vmlinux_archive_leaves_out_efi_stub [error] {
  let inputs = [
    p".xsh-kbuild/obj/lib/cmdline.o",
    p".xsh-kbuild/obj/drivers/firmware/efi/libstub/lib-cmdline.o",
    p".xsh-kbuild/obj/drivers/firmware/efi/efi.o",
  ]
  test.eq(
    kbuild.vmlinux_x86_archive_inputs(inputs),
    [p".xsh-kbuild/obj/lib/cmdline.o", p".xsh-kbuild/obj/drivers/firmware/efi/efi.o"],
  )
}

test test_kbuild_models_final_link_tasks [fs, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-link-tasks")?
  let ar = /usr/bin/ar
  let ld = /usr/bin/ld
  let objcopy = /usr/bin/objcopy
  let built_in = fp"{root}/built-in.a"
  let arch_lib = fp"{root}/arch/arm64/lib/lib.a"
  let efi_lib = fp"{root}/drivers/firmware/efi/libstub/lib.a"
  let vmlinux_a = fp"{root}/vmlinux.a"
  let vmlinux_o = fp"{root}/vmlinux.o"
  let script = fp"{root}/arch/arm64/kernel/vmlinux.lds"
  let export_obj = fp"{root}/.vmlinux.export.o"
  let version_obj = fp"{root}/init/version-timestamp.o"
  let unstripped = fp"{root}/vmlinux.unstripped"
  let vmlinux = fp"{root}/vmlinux"
  let image = fp"{root}/arch/arm64/boot/Image"
  let archive_task = kbuild.vmlinux_archive_task(ar, [built_in, arch_lib], vmlinux_a)
  let expected_archive_argv = ["/usr/bin/ar", "cDPrST", vmlinux_a.display(), built_in.display(), arch_lib.display()]
  assert archive_task.argv.len() == expected_archive_argv.len()
  for index in range(expected_archive_argv.len()) {
    assert archive_task.argv[index] == expected_archive_argv[index]
  }
  let reloc = kbuild.vmlinux_o_task(ld, ["-EL", "-maarch64elf"], vmlinux_a, [efi_lib], vmlinux_o)
  assert "--whole-archive" in reloc.argv
  assert "--start-group" in reloc.argv
  assert efi_lib in reloc.inputs

  let linked = kbuild.vmlinux_unstripped_task(
    ld,
    ["-EL", "-maarch64elf"],
    ["--no-undefined", "-X", "--pic-veneer"],
    script,
    vmlinux_a,
    [efi_lib],
    export_obj,
    version_obj,
    unstripped,
  )

  assert "--script" in linked.argv
  assert version_obj in linked.inputs
  let stripped = kbuild.vmlinux_strip_task(objcopy, unstripped, vmlinux)
  assert "--remove-section=.modinfo" in stripped.argv
  let image_task = kbuild.image_task(objcopy, vmlinux, image)
  assert image_task.argv.get(1)? == "-O"
  assert image_task.argv.get(2)? == "binary"
  let llvm_image_task = kbuild.image_argv_task(["llvm-objcopy"], vmlinux, image)
  assert llvm_image_task.argv.get(0)? == "llvm-objcopy"
  let nonrel_config: kbuild.Kconfig = kbuild.Kconfig(enabled: map.empty(), values: {["RELR"]: "y"})
  let nonrel_flags = kbuild.arm64_vmlinux_ldflags(nonrel_config)
  assert "-shared" in nonrel_flags == false
  assert "--pack-dyn-relocs=relr" in nonrel_flags
  let rel_config: kbuild.Kconfig = kbuild.Kconfig(
    enabled: map.empty(),
    values: {["RELOCATABLE"]: "y", ["RELR"]: "y"},
  )
  let rel_flags = kbuild.arm64_vmlinux_ldflags(rel_config)
  assert "-shared" in rel_flags
  assert "--no-apply-dynamic-relocs" in rel_flags
}

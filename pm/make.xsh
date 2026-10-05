##! PM make operations and shared package-manager policy.
use pm.env as pm_env

## Exported PM declaration `MakeError`.
export error MakeError = InvalidJobs(message: Str) : InvalidData | InvalidTask(message: Str) : InvalidData | DuplicateTask(message: Str) : Conflict | DuplicateOutput(message: Str) : Conflict | MissingDependency(message: Str) : Dependency | DependencyCycle(message: Str) : Dependency | CommandFailed(message: Str) : ProcessFailure

## Exported PM declaration `MakeTask`.
export type MakeTask = {
  name: Str,
  outputs: List[Path],
  inputs: List[Path],
  deps: List[Str],
  argv: List[Any],
  cwd: Path,
  env: Record,
  depfile: Path,
  stamp: Path,
}

type RunningTask = {task: MakeTask, handle: ProcessHandle}

## Exported PM declaration `CompileTasks`.
export type CompileTasks = {
  tasks: List[MakeTask],
  objects: List[Path],
  deps: List[Str],
}

## Exported PM declaration `CTarget`.
export type CTarget = {
  tasks: List[MakeTask],
  objects: List[Path],
  deps: List[Str],
  output: Path,
}

## Exported PM declaration `CProgram`.
export type CProgram = {
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  root: Path,
  sources: List[Path],
  out_dir: Path,
  out: Path,
  libs: List[Path],
  ldflags: List[Str],
  deps: List[Str],
}

## Exported PM declaration `CSharedLibrary`.
export type CSharedLibrary = {
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  root: Path,
  sources: List[Path],
  out_dir: Path,
  out: Path,
  soname: Str,
  ldflags: List[Str],
  deps: List[Str],
}

## Exported PM declaration `CStaticLibrary`.
export type CStaticLibrary = {
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  root: Path,
  sources: List[Path],
  out_dir: Path,
  out: Path,
  deps: List[Str],
}

## Exported PM declaration `CSourceGroup`.
export type CSourceGroup = {
  name: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  root: Path,
  sources: List[Path],
  out_dir: Path,
  deps: List[Str],
}

## Exported PM declaration `CExecutableTarget`.
export type CExecutableTarget = {
  name: Str,
  groups: List[Str],
  sources: List[Path],
  libs: List[Path],
  ldflags: List[Str],
  out: Path,
  deps: List[Str],
}

## Exported PM declaration `CMultiProgram`.
export type CMultiProgram = {
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  root: Path,
  out_dir: Path,
  groups: List[CSourceGroup],
  targets: List[CExecutableTarget],
}

## Exported PM declaration `CMultiTarget`.
export type CMultiTarget = {
  tasks: List[MakeTask],
  groups: Map[CompileTasks],
  outputs: Map[Path],
  deps: List[Str],
}

pure has_path(path_value: Path) -> Bool {
  path_value != ""
}

pure stamp_path(out: Path) -> Path {
  fp"{out}.cmd"
}

pure depfile_path(out: Path) -> Path {
  fp"{out}.d"
}

## Task argv is `List[Any]` because it mixes `Str` flags with `Path` operands
## and lists are invariant. Words are validated here, once, as they become
## process text; any other value is a malformed task.
export pure argv_text(argv: List[Any]) -> Result[List[Str], Error] {
  [argv_word(arg)? for arg in argv]
}

pure argv_word(arg: Any) -> Result[Str] {
  match arg {
    word is Str => Ok(word)
    operand is Path => Ok(f"{operand}")
    else => Err(MakeError.InvalidTask("make task argv words must be Str or Path"))
  }
}

pure object_name_for_source(src: Path, ext: Str) -> Str {
  src.display()
    .replace("/", "_")
    .replace(".cxx", ext)
    .replace(".cpp", ext)
    .replace(".cc", ext)
    .replace(".c", ext)
    .replace(".S", ext)
    .replace(".s", ext)
}

pure object_path_for_source(src: Path, out_dir: Path, ext: Str) -> Path {
  fp"{out_dir}/{object_name_for_source(src, ext)}"
}

pure source_is_cxx(src: Path) -> Bool {
  src.ext == "cxx" or src.ext == "cpp" or src.ext == "cc"
}

pure source_path(root: Path, src: Path) -> Path {
  return src when root == "" or root == "."

  fp"{root}/{src}"
}

## Exported PM declaration `task_deps`.
export pure task_deps(tasks: List[MakeTask], outputs: List[Path]) -> List[Str] {
  var wanted = {[output.display()]: true for output in outputs}
  [task.name for task in tasks if ! task.outputs.is_empty() and (wanted.get(task.outputs[0].display()) ?? false)]
}

proc pkg_config_words(
  pc: pm_env.PkgConfigContext,
  mode: Str,
  packages: List[Str],
) [process, env, error] -> Result[List[Str]] {
  let {pkg_config_path, pkg_config_libdir, pkg_config_sysroot, ld_library_path, ..} = pc
  let pkg_config = pc.pkg_config.display()
  let out = run.text LD_LIBRARY_PATH=$ld_library_path PKG_CONFIG=$pkg_config PKG_CONFIG_LIBDIR=$pkg_config_libdir PKG_CONFIG_PATH=$pkg_config_path PKG_CONFIG_SYSROOT_DIR=$pkg_config_sysroot $pc.pkg_config $mode @packages
  out.words()
}

## Compiler and linker arguments returned by pkg-config.
export type PkgConfigFlags = {cflags: List[Str], libs: List[Str]}

## Exported PM declaration `pkg_config_flags`.
export proc pkg_config_flags(packages: List[Str]) [process, env, error] -> Result[PkgConfigFlags, Error] {
  let pc = pm_env.pkg_config_context()?

  {
    cflags: pkg_config_words(pc, "--cflags", packages)?,
    libs: pkg_config_words(pc, "--libs", packages)?,
  }
}

pure path_in_list(path_value: Path, paths: List[Path]) -> Bool {
  let text = path_value.display()

  for candidate in paths {
    return true when candidate.display() == text
  }

  false
}

## Exported PM declaration `discover_sources`.
export proc discover_sources(
  root: Path,
  extensions: List[Str],
  exclude: List[Path] = [],
) [fs, error] -> Result[List[Path], Error] {
  let source_root = path.absolute(root)?
  var sources = []

  for entry in fs.walk(source_root, gitignore: false)? |> sort-by .path {
    continue unless entry.kind == "file"
    continue unless entry.ext in extensions
    let rel = entry.path.relative_to(source_root)
    continue when path_in_list(rel, exclude)
    sources += [rel]
  }

  sources
}

## Exported PM declaration `install_header_tree`.
export proc install_header_tree(src_dir: Path, dest_dir: Path, exclude: List[Path] = []) [fs, error] {
  let source_root = path.absolute(src_dir)?
  dest_dir.mkdir()

  for entry in fs.walk(source_root, gitignore: false)? {
    let rel = entry.path.relative_to(source_root)
    continue when path_in_list(rel, exclude)
    let target = fp"{dest_dir}/{rel}"

    if entry.kind == "dir" {
      target.mkdir()
    } else {
      fs.install(entry.path, target, 0o644, parents: true, overwrite: true)
    }
  }
}

pure parse_jobs(value: Str, source: Str) -> Result[Int] {
  let parsed = value as Int

  if parsed <= 0 {
    return Err(MakeError.InvalidJobs(f"{source} must be a positive integer"))
  }

  parsed
}

pure makeflags_jobs(flags: Str) -> Result[Int] {
  let words = flags.words()

  for index, word in words {
    if word.starts_with("-j") and word.count_chars() > 2 {
      return parse_jobs(word.replace("-j", ""), "MAKEFLAGS -j")?
    }

    if word == "-j" or word == "--jobs" {
      if index + 1 >= words.len() {
        return Err(MakeError.InvalidJobs(f"MAKEFLAGS {word} requires a job count"))
      }

      return parse_jobs(words[index + 1], f"MAKEFLAGS {word}")?
    }

    if word.starts_with("--jobs=") {
      return parse_jobs(word.replace("--jobs=", ""), "MAKEFLAGS --jobs")?
    }
  }

  cpu.count()
}

## Exported PM declaration `jobs`.
export proc jobs() [env, error] -> Result[Int, Error] {
  let value = e"MAKEFLAGS" ?? ""

  return cpu.count() when value == ""

  makeflags_jobs(value)?
}

## Exported PM declaration `effective_task_argv`.
export proc effective_task_argv(raw_argv: List[Any], _: Record) [error] -> Result[List[Str], Error] {
  argv_text(raw_argv)?
}

## Exported PM declaration `effective_task_env`.
export proc effective_task_env(_: List[Any], task_env: Record) [error] -> Result[Record, Error] {
  task_env
}

proc check_tasks(tasks: List[MakeTask], jobs_count: Int) [error] {
  guard jobs_count > 0 else {
    return Err(MakeError.InvalidJobs("job count must be positive"))
  }

  var names: Map[Bool] = {}
  var outputs: Map[Bool] = {}

  for task in tasks {
    if task.name == "" {
      return Err(MakeError.InvalidTask("make task name must not be empty"))
    }

    if names.get(task.name) ?? false {
      return Err(MakeError.DuplicateTask(f"duplicate make task '{task.name}'"))
    }

    if task.argv.is_empty() {
      return Err(MakeError.InvalidTask(f"make task '{task.name}' has empty argv"))
    }

    names[task.name] = true

    for output in task.outputs {
      let key = output.display()

      if key == "" {
        return Err(MakeError.InvalidTask(f"make task '{task.name}' has empty output path"))
      }

      if outputs.get(key) ?? false {
        return Err(MakeError.DuplicateOutput(f"duplicate make output '{key}'"))
      }

      outputs[key] = true
    }
  }

  for task in tasks {
    for dep in task.deps {
      guard names.get(dep) ?? false else {
        return Err(MakeError.MissingDependency(f"make task '{task.name}' depends on missing task '{dep}'"))
      }
    }
  }
}

pure dep_path(cwd: Path, dep: Str) -> Path {
  return fp"{dep}" when dep.starts_with("/")

  fp"{cwd}/{dep}"
}

proc depfile_inputs(depfile: Path, cwd: Path) -> Result[List[Path]] {
  guard depfile.exists() else {
    let deps = []
    return deps
  }

  let normalized = depfile.read_text()?.replace(
    """\\
""",
    " ",
  )

  let first = normalized.split("\n")[0]

  if ! (":" in first) {
    let deps = []
    return deps
  }

  let parts = first.split(":")
  let deps_text = parts[1]
  [dep_path(cwd, dep) for dep in deps_text.words() if dep != "\\"]
}

proc all_inputs(task: MakeTask) -> Result[List[Path]] {
  var inputs: List[Path] = task.inputs

  if has_path(task.depfile) {
    inputs += depfile_inputs(task.depfile, task.cwd)?
  }

  inputs
}

proc output_missing(task: MakeTask) -> Result[Bool] {
  for output in task.outputs {
    guard output.exists() else {
      return true
    }
  }

  false
}

proc oldest_output_mtime(outputs: List[Path]) -> Result[Int] {
  var oldest = outputs[0].metadata()?.modified

  for output in outputs {
    let modified = output.metadata()?.modified

    if modified < oldest {
      oldest = modified
    }
  }

  oldest
}

proc input_newer(task: MakeTask) -> Result[Bool] {
  return true when task.outputs.is_empty()

  let oldest_output = oldest_output_mtime(task.outputs)?

  for input in all_inputs(task)? {
    guard input.exists() else {
      return true
    }

    return true when input.metadata()?.modified > oldest_output
  }

  false
}

proc command_signature(task: MakeTask) [fs, env, error] -> Result[Str] {
  json.encode({
    argv: effective_task_argv(task.argv, task.env)?,
    cwd: task.cwd.display(),
    env: effective_task_env(task.argv, task.env)?,
  })?
}

proc stamp_changed(task: MakeTask) -> Result[Bool] {
  guard has_path(task.stamp) else {
    return false
  }

  return true unless task.stamp.exists()

  task.stamp.read_text()? != command_signature(task)?
}

proc should_run(task: MakeTask) -> Result[Bool] {
  return true when output_missing(task)

  return true when stamp_changed(task)

  return true when has_path(task.depfile) and ! task.depfile.exists()

  input_newer(task)?
}

proc prepare_task_dirs(task: MakeTask) {
  for output in task.outputs {
    output.parent.mkdir()
  }

  if has_path(task.depfile) {
    task.depfile.parent.mkdir()
  }

  if has_path(task.stamp) {
    task.stamp.parent.mkdir()
  }
}

proc spawn_task(task: MakeTask) [fs, process, env, error] -> Result[RunningTask] {
  prepare_task_dirs(task)

  for output in task.outputs {
    output.remove(missing_ok: true)
  }

  let task_argv = effective_task_argv(task.argv, task.env)?
  let task_env = effective_task_env(task.argv, task.env)?
  let handle = spawn process.command_argv(task_argv[0], task_argv, cwd: task.cwd, env: task_env)?
  {task: task, handle: handle}
}

pure completed_index_key(index: Int) -> Str {
  f"{index}"
}

proc remove_running_indices(running: List[RunningTask], completed_indices: Map[Bool]) -> List[RunningTask] {
  var next = []
  var index = 0

  for row in running {
    if ! (completed_indices.get(completed_index_key(index)) ?? false) {
      next += [row]
    }

    index += 1
  }

  next
}

proc cancel_running_uncompleted(running: List[RunningTask], completed_indices: Map[Bool]) {
  var index = 0

  for row in running {
    if ! (completed_indices.get(completed_index_key(index)) ?? false) {
      match row.handle.cancel() {
        Ok(_) => {}
        Err(_) => {}
      }
    }

    index += 1
  }
}

proc make_progress(message: Str) {
  if (e"XSH_MAKE_PROGRESS" ?? "") == "1" or (e"XSH_LINUX_KBUILD_PROGRESS" ?? "") == "1" {
    print $message
  }
}

proc emit_dynamic_state(
  event: Str,
  task_count: Int,
  completed_count: Int,
  ready_count: Int,
  running_count: Int,
  jobs_count: Int,
  peak_running: Int,
  idle_intervals: Int,
  task: Str = "",
) {
  let task_suffix = if task == "" { "" } else { f" task={task}" }
  make_progress(
    f"xsh-make-dynamic-state event={event} tasks={task_count} completed={completed_count} ready={ready_count} running={running_count} slots={jobs_count} peak-running={peak_running} idle-intervals={idle_intervals}{task_suffix}",
  )
}

pure should_log_dynamic_progress(tasks_count: Int, event_count: Int, running_count: Int, jobs_count: Int) -> Bool {
  guard tasks_count > 100 else {
    return true
  }

  return true when event_count % 100 == 0

  running_count < jobs_count
}

## Exported PM declaration `run_tasks`.
export proc run_tasks(tasks: List[MakeTask], jobs_count: Int) [fs, process, env, error] -> Result[Unit, Error] {
  check_tasks(tasks, jobs_count)
  var task_by_name: Map[MakeTask] = {}
  var dependents: Map[List[Str]] = {}
  var remaining_deps: Map[Int] = {}
  var ready = []
  var ready_index = 0
  var done: Map[Bool] = {}
  var scheduled: Map[Bool] = {}
  var running: List[RunningTask] = []
  var pending_stamps: List[RunningTask] = []
  let no_dependents = []
  var done_count = 0
  var spawn_count = 0
  var skip_count = 0
  var peak_running = 0
  var idle_intervals = 0

  for task in tasks {
    task_by_name[task.name] = task
    remaining_deps[task.name] = task.deps.len()

    if task.deps.is_empty() {
      ready += [task.name]
    }

    for dep in task.deps {
      dependents[dep] = (dependents.get(dep) ?? no_dependents).push(task.name)
    }
  }

  make_progress(f"xsh-make-dynamic-start tasks {tasks.len()} jobs {jobs_count}")

  while done_count < tasks.len() {
    while running.len() < jobs_count and ready_index < ready.len() {
      let task_name = ready[ready_index]
      ready_index += 1

      if ! (scheduled.get(task_name) ?? false) {
        let task = task_by_name.get(task_name)?
        scheduled[task.name] = true

        if should_run(task) {
          running += [spawn_task(task)?]
          spawn_count += 1
          if running.len() > peak_running {
            peak_running = running.len()
          }

          if should_log_dynamic_progress(tasks.len(), spawn_count, running.len(), jobs_count) {
            emit_dynamic_state(
              "spawn",
              tasks.len(),
              done_count,
              ready.len() - ready_index,
              running.len(),
              jobs_count,
              peak_running,
              idle_intervals,
              task.name,
            )
          }
        } else {
          done[task.name] = true
          done_count += 1
          skip_count += 1

          if should_log_dynamic_progress(tasks.len(), skip_count, running.len(), jobs_count) {
            emit_dynamic_state(
              "skip",
              tasks.len(),
              done_count,
              ready.len() - ready_index,
              running.len(),
              jobs_count,
              peak_running,
              idle_intervals,
              task.name,
            )
          }

          for dependent in dependents.get(task.name) ?? no_dependents {
            let remaining = (remaining_deps.get(dependent) ?? 0) - 1
            remaining_deps[dependent] = remaining

            if remaining == 0 {
              ready += [dependent]
            }
          }
        }
      }
    }

    break when done_count >= tasks.len()

    if running.is_empty() {
      return Err(MakeError.DependencyCycle("cycle in make task graph"))
    }

    let wait_is_idle = running.len() < jobs_count and ready_index >= ready.len()
    emit_dynamic_state(
      "wait",
      tasks.len(),
      done_count,
      ready.len() - ready_index,
      running.len(),
      jobs_count,
      peak_running,
      idle_intervals,
    )

    let completed_rows = process.wait_ready([row.handle for row in running])?
    if wait_is_idle {
      idle_intervals += 1
    }

    var completed_indices: Map[Bool] = {}
    var completed_tasks: List[RunningTask] = []

    for completed in completed_rows {
      let completed_index = completed.index
      let row = running[completed_index]
      completed_indices[completed_index_key(completed_index)] = true

      if ! completed.status.ok {
        cancel_running_uncompleted(running, completed_indices)
        return Err(MakeError.CommandFailed(f"make task '{row.task.name}' failed"))
      }

      completed_tasks += [row]
    }

    running = remove_running_indices(running, completed_indices)

    for row in completed_tasks {
      pending_stamps += [row]
      done[row.task.name] = true
      done_count += 1

      for dependent in dependents.get(row.task.name) ?? no_dependents {
        let remaining = (remaining_deps.get(dependent) ?? 0) - 1
        remaining_deps[dependent] = remaining

        if remaining == 0 {
          ready += [dependent]
        }
      }

      while running.len() < jobs_count and ready_index < ready.len() {
        let task_name = ready[ready_index]
        ready_index += 1

        if ! (scheduled.get(task_name) ?? false) {
          let task = task_by_name.get(task_name)?
          scheduled[task.name] = true

          if should_run(task) {
            running += [spawn_task(task)?]
            spawn_count += 1
            if running.len() > peak_running {
              peak_running = running.len()
            }

            if should_log_dynamic_progress(tasks.len(), spawn_count, running.len(), jobs_count) {
              emit_dynamic_state(
                "spawn",
                tasks.len(),
                done_count,
                ready.len() - ready_index,
                running.len(),
                jobs_count,
                peak_running,
                idle_intervals,
                task.name,
              )
            }
          } else {
            done[task.name] = true
            done_count += 1
            skip_count += 1

            if should_log_dynamic_progress(tasks.len(), skip_count, running.len(), jobs_count) {
              emit_dynamic_state(
                "skip",
                tasks.len(),
                done_count,
                ready.len() - ready_index,
                running.len(),
                jobs_count,
                peak_running,
                idle_intervals,
                task.name,
              )
            }

            for dependent in dependents.get(task.name) ?? no_dependents {
              let remaining = (remaining_deps.get(dependent) ?? 0) - 1
              remaining_deps[dependent] = remaining

              if remaining == 0 {
                ready += [dependent]
              }
            }
          }
        }
      }
    }

    if should_log_dynamic_progress(tasks.len(), done_count, running.len(), jobs_count) {
      emit_dynamic_state(
        "complete",
        tasks.len(),
        done_count,
        ready.len() - ready_index,
        running.len(),
        jobs_count,
        peak_running,
        idle_intervals,
      )
    }
  }

  emit_dynamic_state(
    "summary",
    tasks.len(),
    done_count,
    ready.len() - ready_index,
    running.len(),
    jobs_count,
    peak_running,
    idle_intervals,
  )

  for row in pending_stamps {
    if has_path(row.task.stamp) {
      match row.task.stamp.write_atomic(command_signature(row.task)?) {
        Ok(_) => {}
        Err(_) => {}
      }
    }
  }
}

## Exported PM declaration `compile_lo_task`.
export proc compile_lo_task(
  toolchain: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  src: Path,
  out: Path,
  deps: List[Str] = [],
) [] -> MakeTask {
  let depfile = depfile_path(out)
  var argv: List[Any] = [toolchain, "-target", triple, "-c", "-fPIC", "-DPIC"]
  argv = [@argv, @cflags, @defs, @includes]
  argv += [src, "-o", out, "-MMD", "-MP", "-MF", depfile]

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: [
      src,
    ],
    deps: deps,
    argv: argv,
    cwd: p".",
    env: {},
    depfile: depfile,
    stamp: stamp_path(out),
  }
}

## Exported PM declaration `compile_lo_tasks`.
export proc compile_lo_tasks(
  toolchain: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  root: Path,
  sources: List[Path],
  out_dir: Path,
  deps: List[Str] = [],
) [] -> CompileTasks {
  var tasks = []
  var objects = []

  for src in sources {
    let out = object_path_for_source(src, out_dir, ".lo")
    let task = compile_lo_task(toolchain, triple, cflags, defs, includes, source_path(root, src), out, deps)
    tasks += [task]
    objects += [out]
  }

  {tasks, objects, deps: [task.name for task in tasks]}
}

## Exported PM declaration `compile_asm_lo_task`.
export proc compile_asm_lo_task(
  toolchain: Path,
  triple: Str,
  includes: List[Str],
  src: Path,
  out: Path,
  deps: List[Str] = [],
) [] -> MakeTask {
  var argv: List[Any] = [toolchain, "-target", triple, "-c", "-fPIC", "-DPIC", "-Wa,--noexecstack"]
  argv = [@argv, @includes, src, "-o", out]

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: [
      src,
    ],
    deps: deps,
    argv: argv,
    cwd: p".",
    env: {},
    depfile: p"",
    stamp: stamp_path(out),
  }
}

## Exported PM declaration `compile_asm_lo_tasks`.
export proc compile_asm_lo_tasks(
  toolchain: Path,
  triple: Str,
  includes: List[Str],
  root: Path,
  sources: List[Path],
  out_dir: Path,
  deps: List[Str] = [],
) [] -> CompileTasks {
  var tasks = []
  var objects = []

  for src in sources {
    let out = object_path_for_source(src, out_dir, ".lo")
    let task = compile_asm_lo_task(toolchain, triple, includes, source_path(root, src), out, deps)
    tasks += [task]
    objects += [out]
  }

  {tasks, objects, deps: [task.name for task in tasks]}
}

## Exported PM declaration `compile_cxx_task`.
export proc compile_cxx_task(
  toolchain: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  src: Path,
  out: Path,
  deps: List[Str] = [],
) [] -> MakeTask {
  let _ = toolchain
  let depfile = depfile_path(out)
  var argv: List[Any] = ["c++", "-target", triple, "-c"]
  argv = [@argv, @cflags, @defs, @includes]
  argv += [src, "-o", out, "-MMD", "-MP", "-MF", depfile]

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: [
      src,
    ],
    deps: deps,
    argv: argv,
    cwd: p".",
    env: {},
    depfile: depfile,
    stamp: stamp_path(out),
  }
}

## Exported PM declaration `compile_cxx_tasks`.
export proc compile_cxx_tasks(
  toolchain: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  root: Path,
  sources: List[Path],
  out_dir: Path,
  deps: List[Str] = [],
) [] -> CompileTasks {
  var tasks = []
  var objects = []

  for src in sources {
    let out = object_path_for_source(src, out_dir, ".o")
    let task = compile_cxx_task(toolchain, triple, cflags, defs, includes, source_path(root, src), out, deps)
    tasks += [task]
    objects += [out]
  }

  {tasks, objects, deps: [task.name for task in tasks]}
}

## Exported PM declaration `compile_c_task`.
export proc compile_c_task(
  toolchain: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  src: Path,
  out: Path,
  deps: List[Str] = [],
) [] -> MakeTask {
  let depfile = depfile_path(out)
  var argv: List[Any] = [toolchain, "-target", triple, "-c"]
  argv = [@argv, @cflags, @defs, @includes]
  argv += [src, "-o", out, "-MMD", "-MP", "-MF", depfile]

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: [
      src,
    ],
    deps: deps,
    argv: argv,
    cwd: p".",
    env: {},
    depfile: depfile,
    stamp: stamp_path(out),
  }
}

## Exported PM declaration `compile_c_tasks`.
export proc compile_c_tasks(
  toolchain: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  root: Path,
  sources: List[Path],
  out_dir: Path,
  deps: List[Str] = [],
) [] -> CompileTasks {
  var tasks = []
  var objects = []

  for src in sources {
    let out = object_path_for_source(src, out_dir, ".o")
    let task = compile_c_task(toolchain, triple, cflags, defs, includes, source_path(root, src), out, deps)
    tasks += [task]
    objects += [out]
  }

  {tasks, objects, deps: [task.name for task in tasks]}
}

## Exported PM declaration `compile_mixed_tasks`.
export proc compile_mixed_tasks(
  toolchain: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  root: Path,
  sources: List[Path],
  out_dir: Path,
  deps: List[Str] = [],
) [] -> CompileTasks {
  var tasks = []
  var objects = []

  for src in sources {
    let out = object_path_for_source(src, out_dir, ".o")

    let task = if source_is_cxx(src) {
      compile_cxx_task(toolchain, triple, cflags, defs, includes, source_path(root, src), out, deps)
    } else {
      compile_c_task(toolchain, triple, cflags, defs, includes, source_path(root, src), out, deps)
    }

    tasks += [task]
    objects += [out]
  }

  {tasks, objects, deps: [task.name for task in tasks]}
}

## Exported PM declaration `c_program`.
export proc c_program(spec: CProgram) [] -> CTarget {
  let compiled = compile_c_tasks(
    spec.cc,
    spec.triple,
    spec.cflags,
    spec.defs,
    spec.includes,
    spec.root,
    spec.sources,
    spec.out_dir,
    spec.deps,
  )

  let link = link_executable_task(
    spec.cc,
    spec.triple,
    compiled.objects,
    spec.libs,
    spec.ldflags,
    spec.out,
    compiled.deps,
  )

  {
    tasks: compiled.tasks.push(link),
    objects: compiled.objects,
    deps: compiled.deps.push(link.name),
    output: spec.out,
  }
}

## Exported PM declaration `c_shared_library`.
export proc c_shared_library(spec: CSharedLibrary) [] -> CTarget {
  let compiled = compile_lo_tasks(
    spec.cc,
    spec.triple,
    spec.cflags,
    spec.defs,
    spec.includes,
    spec.root,
    spec.sources,
    spec.out_dir,
    spec.deps,
  )

  let link = link_shared_task(
    spec.cc,
    spec.triple,
    compiled.objects,
    spec.soname,
    spec.ldflags,
    spec.out,
    compiled.deps,
  )

  {
    tasks: compiled.tasks.push(link),
    objects: compiled.objects,
    deps: compiled.deps.push(link.name),
    output: spec.out,
  }
}

## Exported PM declaration `c_static_library`.
export proc c_static_library(spec: CStaticLibrary) [] -> CTarget {
  let compiled = compile_lo_tasks(
    spec.cc,
    spec.triple,
    spec.cflags,
    spec.defs,
    spec.includes,
    spec.root,
    spec.sources,
    spec.out_dir,
    spec.deps,
  )

  let archive_task = link_archive_task(spec.cc, compiled.objects, spec.out, compiled.deps)

  {
    tasks: compiled.tasks.push(archive_task),
    objects: compiled.objects,
    deps: compiled.deps.push(archive_task.name),
    output: spec.out,
  }
}

## Exported PM declaration `c_multi_program`.
export proc c_multi_program(spec: CMultiProgram) [] -> Result[CMultiTarget, Error] {
  var tasks = []
  var groups: Map[CompileTasks] = {}
  var cxx_groups: Map[Bool] = {}
  var outputs: Map[Path] = {}
  var deps = []

  for source_group in spec.groups {
    if source_group.name in groups {
      return Err(MakeError.DuplicateTask(f"duplicate source group '{source_group.name}'"))
    }

    let cflags = spec.cflags.extend(source_group.cflags)
    let defs = spec.defs.extend(source_group.defs)
    let includes = spec.includes.extend(source_group.includes)
    let root = if source_group.root == "" { spec.root } else { source_group.root }

    let out_dir = if source_group.out_dir == "" {
      fp"{spec.out_dir}/{source_group.name}"
    } else {
      source_group.out_dir
    }

    let compiled = compile_mixed_tasks(
      spec.cc,
      spec.triple,
      cflags,
      defs,
      includes,
      root,
      source_group.sources,
      out_dir,
      source_group.deps,
    )

    tasks += compiled.tasks
    groups[source_group.name] = compiled
    cxx_groups[source_group.name] = true in [source_is_cxx(src) for src in source_group.sources]
  }

  for target in spec.targets {
    var objects: List[Path] = []
    var target_deps: List[Str] = target.deps
    var needs_cxx_link = true in [source_is_cxx(src) for src in target.sources]

    for group_name in target.groups {
      guard group_name in groups else {
        return Err(
          MakeError.MissingDependency(
            f"target '{target.name}' references missing source group '{group_name}'",
          ),
        )
      }

      let compiled: CompileTasks = groups.get(group_name) ?? {tasks: [], objects: [], deps: []}
      objects += compiled.objects
      target_deps += compiled.deps
      needs_cxx_link = needs_cxx_link or (cxx_groups.get(group_name) ?? false)
    }

    if ! target.sources.is_empty() {
      let target_compile = compile_mixed_tasks(
        spec.cc,
        spec.triple,
        spec.cflags,
        spec.defs,
        spec.includes,
        spec.root,
        target.sources,
        fp"{spec.out_dir}/{target.name}",
      )

      tasks += target_compile.tasks
      objects += target_compile.objects
      target_deps += target_compile.deps
    }

    let link = if needs_cxx_link {
      link_executable_cxx_task(spec.cc, spec.triple, objects, target.libs, target.ldflags, target.out, target_deps)
    } else {
      link_executable_task(spec.cc, spec.triple, objects, target.libs, target.ldflags, target.out, target_deps)
    }

    tasks += [link]
    outputs[target.name] = target.out
    deps += [link.name]
  }

  {tasks, groups, outputs, deps}
}

## Exported PM declaration `link_shared_task`.
export proc link_shared_task(
  toolchain: Path,
  triple: Str,
  objs: List[Path],
  soname: Str,
  ldflags: List[Str],
  out: Path,
  deps: List[Str] = [],
) [] -> MakeTask {
  let _ = toolchain
  var argv: List[Any] = ["cc", "-target", triple, "-shared", f"-Wl,-soname,{soname}"]
  argv = [@argv, @ldflags, @objs, "-o", out]

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: objs,
    deps: deps,
    argv: argv,
    cwd: p".",
    env: {},
    depfile: p"",
    stamp: stamp_path(out),
  }
}

## Exported PM declaration `link_executable_cxx_task`.
export proc link_executable_cxx_task(
  toolchain: Path,
  triple: Str,
  objs: List[Path],
  libs: List[Path],
  ldflags: List[Str],
  out: Path,
  deps: List[Str] = [],
) [] -> MakeTask {
  let _ = toolchain
  var argv: List[Any] = ["c++", "-target", triple]
  argv = [@argv, @objs, @libs, @ldflags, "-o", out]

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: objs.extend(libs),
    deps: deps,
    argv: argv,
    cwd: p".",
    env: {},
    depfile: p"",
    stamp: stamp_path(out),
  }
}

# Link an executable from .o objects and shared library files.
# libs are full paths to .so files linked directly (SONAME comes from the library).
## Exported PM declaration `link_executable_task`.
export proc link_executable_task(
  toolchain: Path,
  triple: Str,
  objs: List[Path],
  libs: List[Path],
  ldflags: List[Str],
  out: Path,
  deps: List[Str] = [],
) [] -> MakeTask {
  let _ = toolchain
  var argv: List[Any] = ["cc", "-target", triple]
  argv = [@argv, @objs, @libs, @ldflags, "-o", out]

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: objs.extend(libs),
    deps: deps,
    argv: argv,
    cwd: p".",
    env: {},
    depfile: p"",
    stamp: stamp_path(out),
  }
}

## Exported PM declaration `link_archive_task`.
export proc link_archive_task(toolchain: Path, objs: List[Path], out: Path, deps: List[Str] = []) [] -> MakeTask {
  let _ = toolchain
  var argv: List[Any] = ["ar", "rcs", out]
  argv = [@argv, @objs]

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: objs,
    deps: deps,
    argv: argv,
    cwd: p".",
    env: {},
    depfile: p"",
    stamp: stamp_path(out),
  }
}

# Compile a .c file to a position-independent .lo object (for shared libraries).
# out is the full path of the output object file; parent directories are created.
## Exported PM declaration `compile_lo`.
export proc compile_lo(
  toolchain: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  src: Path,
  out: Path,
) [fs, process, env, error] -> Result[Unit, Error] {
  run_tasks([compile_lo_task(toolchain, triple, cflags, defs, includes, src, out)], 1)
}

# Compile a .cxx/.cpp file to a regular .o object using the C++ compiler.
## Exported PM declaration `compile_cxx`.
export proc compile_cxx(
  toolchain: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  src: Path,
  out: Path,
) [fs, process, env, error] -> Result[Unit, Error] {
  run_tasks([compile_cxx_task(toolchain, triple, cflags, defs, includes, src, out)], 1)
}

# Compile a .c file to a regular .o object (for executables).
## Exported PM declaration `compile_c`.
export proc compile_c(
  toolchain: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  src: Path,
  out: Path,
) [fs, process, env, error] -> Result[Unit, Error] {
  run_tasks([compile_c_task(toolchain, triple, cflags, defs, includes, src, out)], 1)
}

# Link a shared library from .lo objects with a given SONAME.
## Exported PM declaration `link_shared`.
export proc link_shared(
  toolchain: Path,
  triple: Str,
  objs: List[Path],
  soname: Str,
  ldflags: List[Str],
  out: Path,
) [fs, process, env, error] -> Result[Unit, Error] {
  run_tasks([link_shared_task(toolchain, triple, objs, soname, ldflags, out)], 1)
}

# Link a C++ executable using the C++ compiler driver.
## Exported PM declaration `link_executable_cxx`.
export proc link_executable_cxx(
  toolchain: Path,
  triple: Str,
  objs: List[Path],
  libs: List[Path],
  ldflags: List[Str],
  out: Path,
) [fs, process, env, error] -> Result[Unit, Error] {
  run_tasks([link_executable_cxx_task(toolchain, triple, objs, libs, ldflags, out)], 1)
}

## Exported PM declaration `link_executable`.
export proc link_executable(
  toolchain: Path,
  triple: Str,
  objs: List[Path],
  libs: List[Path],
  ldflags: List[Str],
  out: Path,
) [fs, process, env, error] -> Result[Unit, Error] {
  run_tasks([link_executable_task(toolchain, triple, objs, libs, ldflags, out)], 1)
}

# Create a static archive from .lo/.o objects.
## Exported PM declaration `link_archive`.
export proc link_archive(toolchain: Path, objs: List[Path], out: Path) [fs, process, env, error] -> Result[Unit, Error] {
  run_tasks([link_archive_task(toolchain, objs, out)], 1)
}

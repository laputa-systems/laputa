use pm.generation

if args[0] == "compose" {
  let value = generation.read_generation_plan(fp"{args[1]}")?
  match generation.compose(value, fp"{args[2]}", fp"{args[3]}", fp"{args[4]}") {
    Ok(_) => print "published"
    Err(_) => print "refused"
  }
  exit 0
}

unix.pid1_setup([], subreaper: true, allow_non_pid1: true)
let runner = fp"{args[0]}"
let script = fp"{args[1]}"
let saved_plan = fp"{args[2]}"
let store = fp"{args[3]}"
let parent = fp"{args[4]}"
let overlay = fp"{args[5]}"
let outside = fp"{args[6]}"
let evil = fp"{args[7]}"
let kind = args[8]
let log = fp"{args[9]}"
let published = fp"{parent}/failed"
let child = unix.spawn_process_group_log(process.command_argv(runner, ["xsh", script, "compose", saved_plan, store, published, overlay], env: {LAPUTA_MANUAL_INDEX_SENTINEL: fp"{outside}/sentinel"}), log)?
var groups = [child.pid]
defer {
  let cleanup = unix.shutdown_process_groups(groups, 0ms, 1s)?
  assert cleanup.remaining.is_empty()
}
var staging: List[Path] = []
var attempts = 0
while staging.is_empty() and attempts < 500 {
  for entry in fs.children(parent)? {
    if fp"{entry.path}/usr/share/man/.race-ready".exists() { staging = [entry.path] }
  }
  if staging.is_empty() { time.sleep(10ms) }
  attempts += 1
}
assert ! staging.is_empty(), f"index loader did not reach the gate: {log.read_text()?}"
let stage = staging[0]
let root = fs.open_root(stage)?
let manuals = root.open_root(p"usr/share/man")?
groups += [manuals.read_text(p".race-ready")?.parse_int()?]
if kind == "program" {
  root.remove(p"usr/bin/makewhatis")
  root.symlink(target: evil, path: p"usr/bin/makewhatis")
} else if kind == "library" {
  root.remove(p"usr/lib/libz.so.1")
  root.symlink(target: fp"{outside}/library", path: p"usr/lib/libz.so.1")
} else if kind == "manuals" {
  root.rename(from: p"usr/share/man", to: p"usr/share/retained-man")
  root.symlink(target: fp"{outside}/manuals", path: p"usr/share/man")
} else {
  let replacement = fp"{outside}/{stage.name}"
  fp"{replacement}/usr/bin".mkdir()
  evil.copy(to: fp"{replacement}/usr/bin/makewhatis")
  fp"{replacement}/usr/lib".mkdir()
  fp"{outside}/library".copy(to: fp"{replacement}/usr/lib/libz.so.1")
  fp"{replacement}/usr/share/man/man1".mkdir()
  fp"{outside}/manuals/man1/outside.1".copy(to: fp"{replacement}/usr/share/man/man1/outside.1")
  parent.rename(to: fp"{parent}.retained")
  parent.symlink(to: outside)
}
manuals.write(p".race-release", "go")
var exited = false
attempts = 0
while ! exited and attempts < 500 {
  for event in unix.reap_child_events()? {
    if event.pid == child.pid {
      assert event.status.exited_with(0), log.read_text()?
      exited = true
    }
  }
  if ! exited { time.sleep(10ms) }
  attempts += 1
}
assert exited, log.read_text()?
let observed = log.read_text()?
assert "OUTSIDE_" not in observed, observed
assert observed.trim().ends_with("refused"), observed
assert ! published.exists()?, "failed index published a generation"
assert ! fp"{parent}.retained/failed".exists()?, "failed index published through the retained parent"
assert fp"{outside}/sentinel".read_text()? == "outside unchanged\n"
assert fp"{outside}/manuals/mandoc.db".read_text()? == "outside database unchanged\n"
print f"{kind} confined"

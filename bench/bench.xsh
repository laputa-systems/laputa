use bench.registry

proc words(value: Str) -> List[Str] {
  [word for word in value.split(" ") if word != ""]
}

proc main(mode: Str, tier: Str, names: Str, areas: Str, skip: Str, full: Str, xsht: Str) [fs, process, env, time, error] {
  let all = registry.workloads(xsht)
  if mode == "list" {
    for item in all {
      let requirements = [requirement.display() for requirement in item.requires]
      print f"{item.name} tier={registry.tier_name(item.tier)} area={item.area} purpose={item.purpose} cost={item.cost} requires={requirements.join(",")} tools={item.tools.join(",")} command={item.argv.join(" ")} output=.work/bench/RUN/{item.name}.log"
    }
    return
  }
  let selected = registry.select(all, tier, words(names), words(areas), words(skip), full == "1")?
  let selected_names = [w.name for w in selected]
  for item in all {
    if item.name not in selected_names {
      print f"excluded {item.name}: selector or tier"
    }
  }
  if mode == "dry" {
    for item in selected { print f"would run: {item.argv.join(" ")}" }
    return
  }
  for item in selected {
    for requirement in item.requires {
      guard requirement.exists() else { fail f"preflight: missing {requirement}; restore or prepare the input, or set XSH_ROOT= to the checkout with built verification binaries; affected: {item.name}; nothing ran" }
    }
    for tool in item.tools {
      if process.which(tool) is Err(_) { fail f"preflight: missing tool {tool}; install or configure it; affected: {item.name}; nothing ran" }
    }
  }
  if process.which("perf-gate-ready") is Err(_) { fail f"preflight: missing perf-gate-ready; install the host gate; affected: {selected_names.join(", ")}; nothing ran" }
  let admission = process.run(process.command_argv("bash", ["bash", "bench/support.sh", "check", @selected_names]))?
  fail "preflight failed; nothing ran" when !admission.ok
  let space = fs.statvfs(p".")?
  fail f"preflight: less than 64 MiB free; free disk space; affected: {selected_names.join(", ")}; nothing ran" when space.blocks_available * space.fragment_size < 67108864
  let ready = process.run(process.command_argv("perf-gate-ready", ["perf-gate-ready"], stdout: p"/dev/null", stderr: p"/dev/null"))?
  print f"host readiness: {if ready.ok { "quiet" } else { "busy; timings inconclusive" }}"
  if mode == "check" { print f"preflight ok: {selected_names.join(", ")}"; return }
  let root = fp".work/bench/{time.format(time.now() * 1000000, "%Y%m%dT%H%M%SZ", utc: true)?}-{time.monotonic()?}"
  root.mkdir()
  var lines = ["# Benchmark run", "", "Completion is not a performance verdict; no budgets or baseline are established."]
  for item in all {
    if item.name not in [w.name for w in selected] { lines += [f"excluded {item.name}: selector or tier"] }
  }
  var failed = false
  for item in selected {
    let before = process.run(process.command_argv("perf-gate-ready", ["perf-gate-ready"], stdout: fp"{root}/{item.name}.before.ready", stderr: fp"{root}/{item.name}.before.ready", stderr_append: true))?
    let start = time.monotonic()?
    let argv = [arg.replace("@OUTPUT@", with: f"{root}/plan.json") for arg in item.argv]
    let result = process.run(process.command_argv("bash", ["bash", "bench/support.sh", "execute", root, item.name, @argv], p".", env: {XSH_PM_REPO: ""}, stdout: fp"{root}/{item.name}.log", stderr: fp"{root}/{item.name}.log", stdout_append: true, stderr_append: true))?
    let elapsed = (time.monotonic()? - start) / 1000000
    let after = process.run(process.command_argv("perf-gate-ready", ["perf-gate-ready", "-1"], stdout: fp"{root}/{item.name}.after.ready", stderr: fp"{root}/{item.name}.after.ready", stderr_append: true))?
    fp"{root}/{item.name}.ready-status".write_lines([f"{before.shell_code()?} {after.shell_code()?}"])
    let validity = if before.ok and after.ok { "observational; no comparison" } else { "inconclusive: host busy" }
    lines += [f"{item.name}: exit={result.shell_code()?} duration_ms={elapsed} timing={validity}"]
    if !result.ok { failed = true }
  }
  fp"{root}/summary.txt".write_lines(lines)
  let evidence = process.run(process.command_argv("bash", ["bash", "bench/support.sh", "report", root], stdout: fp"{root}/summary.txt", stderr: fp"{root}/summary.txt", stdout_append: true, stderr_append: true))?
  fail "benchmark evidence failed" when !evidence.ok
  print f"summary: {root}/summary.txt"
  for line in lines { print $line }
  for line in fp"{root}/summary.txt".read_lines()? {
    if line.starts_with("verdict ") { print $line }
  }
  fail "benchmark workload failed" when failed
}

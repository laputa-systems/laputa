##! perf proof: version, build options, the generated parsers, and a counted run.
use pm.proof
use pm.util as pm_util

const passed_suite = rx"(?m)^Passed (main tests|subtests) *: [1-9]"

const no_failures = rx"(?m)^Failed tests *: 0$"

const counted_task_clock = rx"(?m)^[0-9.]+,msec,task-clock"

proc recorded_version(rootfs: Path) -> Result[Str] {
  let metadata = json.read(fp"{rootfs}/var/lib/xsh-pm/packages/perf/metadata.json")?.require(Record)?
  metadata.get("ver")?.require(Str)
}

proc prove_perf(loader: Path, perf: Path, ver: Str) {
  let version = (run.text $loader $perf "--version" ?).trim()
  proof.ensure(version == f"perf version {ver}", "perf-version", f"perf --version printed '{version}'")

  # The minimal feature set links only musl: every optional library is off.
  let options = run.text $loader $perf "version" "--build-options" ?

  for feature in ["libelf", "libtraceevent", "libpython", "zlib", "libunwind"] {
    proof.ensure(
      regex.compile(f"(?m)^ *{feature}: \\[ OFF \\]")?.matches(options),
      "perf-build-options",
      f"perf reports {feature} enabled or missing: {options.trim()}",
    )
  }

  let software = run.text $loader $perf "list" "sw" ?

  for event in ["task-clock", "cpu-clock", "context-switches", "page-faults"] {
    proof.ensure(event in software, "perf-list", f"perf list sw lacks {event}")
  }

  # These built-in tests run the pregenerated expression, PMU, and
  # event-term parsers against perf's fake PMUs and sysfs trees; none opens a
  # perf event. `perf test` exits 0 whatever its tests do, so the proof reads
  # the summary, where a suite name that matches nothing passes zero tests.
  for suite in ["Simple expression parser", "Sysfs PMU tests", "PMU JSON event tests", "Tool PMU"] {
    let result = run.capture --text $loader $perf "test" $suite ?
    let report = f"{result.stdout}{result.stderr}"
    let passed = result.status.ok and passed_suite.matches(report) and no_failures.matches(report)
    proof.ensure(passed, "perf-test", f"perf test '{suite}' did not pass: {report.trim()}")
  }

  # A counted run needs perf_event_open. Docker's default seccomp profile
  # denies it without CAP_PERFMON or CAP_SYS_ADMIN, and perf then reports the
  # denial for the event it parsed; any other failure is a perf failure.
  let stat = run.capture --text $loader $perf "stat" "-x," "-e" "task-clock" "--" $loader $perf "--version" ?

  if stat.status.ok {
    proof.ensure(
      counted_task_clock.matches(stat.stderr),
      "perf-stat",
      f"perf stat did not count task-clock: {stat.stderr.trim()}",
    )

    print f"perf ok: {version}, parser tests, task-clock counted"
    return
  }

  proof.ensure(
    "No permission to enable task-clock" in stat.stderr,
    "perf-stat",
    f"perf stat failed for a reason other than a denied perf_event_open: {stat.stderr.trim()}",
  )

  print f"perf ok: {version}, parser tests; perf_event_open denied here, task-clock not counted"
}

proc main(rootfs: Path = /rootfs) [fs, process, env, error] {
  proof.target_elf(rootfs, p"usr/bin/perf", "perf")
  let target_arch = pm_util.target_arch()?

  if pm_util.build_arch()? != target_arch {
    print f"perf ok: cross-built {target_arch}"
    return
  }

  # perf runs on the proof root's musl loader and libraries, not the
  # container's.
  let os = system.uname()?
  let loader = fp"{rootfs}/usr/lib/ld-musl-{os.machine}.so.1"
  let ver = recorded_version(rootfs)?

  env ({LD_LIBRARY_PATH: fp"{rootfs}/usr/lib"}) {
    prove_perf(loader, fp"{rootfs}/usr/bin/perf", ver)
  }?
}

main(@args)

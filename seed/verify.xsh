#!/bin/xsh
##! `make verify`: the whole host proof from `make clean`, one step at a time, with a timing report.
# Every step is a make target run in order; the first failure stops the run.
# The mirror runs for the steps that need it and is stopped afterwards, so the
# run leaves no process behind. Each step's output is in .out/verify/STEP.log
# and the table in .out/verify/report.md. `make clean` deletes .out/, so the
# logs are written only after it.

type Step = {name: Str, argv: List[Str]}

type Timed = {name: Str, seconds: Int, ok: Bool}

pure make_step(name: Str, make_args: List[Str]) -> Step {
  {name, argv: ["make", @make_args]}
}

pure steps(arch: Str) -> List[Step] {
  [
    make_step("host-xsh", ["host-xsh"]),
    make_step("fetch", ["fetch", f"ARCH={arch}"]),
    make_step("seed", ["seed", f"ARCH={arch}"]),
    make_step("build", ["build", f"ARCH={arch}"]),
    make_step("publish", ["publish", f"ARCH={arch}"]),
    make_step("root", ["root", f"ARCH={arch}", "PKGS=baselayout xsh xinit musl"]),
    make_step("installer-image", ["installer-image", f"ARCH={arch}"]),
    make_step("installer-qemu-test", ["installer-qemu-test", f"ARCH={arch}"]),
    make_step("profile-build", ["profile-build"]),
    make_step("profile-test", ["profile-test"]),
    make_step("check", ["check"]),
    make_step("test", ["test"]),
    make_step("mirror-test", ["mirror-test"]),
    make_step("build-noop", ["build", f"ARCH={arch}"]),
  ]
}

proc run_step(root: Path, logs: Path, step: Step) [fs, process, time, error] -> Result[Timed] {
  let make = process.which("make")?
  let log = fp"{logs}/{step.name}.log"
  let started = time.now()
  let status = process.run(
    process.command_argv(make, step.argv, root, stdout: log, stderr: log, stdout_append: true, stderr_append: true),
  )?
  let timed = {name: step.name, seconds: (time.now() - started) / 1000, ok: status.ok}
  print f"verify {step.name}: {if timed.ok { "ok" } else { "FAILED" }} {timed.seconds}s"
  timed
}

proc mirror_ready(curl: Path) [process, error] -> Result[Bool] {
  let status = run.status $curl "-s" "-o" /dev/null "--fail" "http://127.0.0.1:3000/" > /dev/null 2> /dev/null
  status.ok
}

# Cancelling the `make mirror` handle signals its whole process group, the
# server included.
proc stop_mirror(mirror: ProcessHandle?) [process, error] {
  guard let handle = mirror else {
    return
  }
  handle.cancel(signal: "TERM", kill_after: 5s)
}

proc write_report(logs: Path, arch: Str, timed: List[Timed]) [fs, error] {
  var lines = [f"# make verify ({arch})", "", "| Step | Seconds | Result |", "|---|---|---|"]

  for entry in timed {
    lines += [f"| `{entry.name}` | {entry.seconds} | {if entry.ok { "ok" } else { "FAILED" }} |"]
  }

  fp"{logs}/report.md".write(lines.join("\n") + "\n")
}

proc main(arch: Str) [fs, process, env, time, error] {
  let root = fs.cwd()?
  let make = process.which("make")?
  let curl = process.which("curl")?

  # `clean` removes .out/, so its output goes to the console only.
  let started = time.now()
  let cleaned = process.run(process.command_argv(make, ["make", "clean"], root))?
  fail "make clean failed" unless cleaned.ok

  var timed: List[Timed] = [{name: "clean", seconds: (time.now() - started) / 1000, ok: true}]
  let logs = fp"{root}/.out/verify"
  logs.mkdir()
  var mirror = null

  for step in steps(arch) {
    if step.name == "publish" {
      # Started after the world build, so its own first-run build does not
      # overlap the heaviest step.
      let handle = spawn process.command_argv(
        make,
        ["make", "mirror"],
        root,
        stdout: fp"{logs}/mirror.log",
        stderr: fp"{logs}/mirror.log",
      )?
      mirror = handle
      var waited = 0

      while ! mirror_ready(curl) {
        if waited >= 600 {
          fail "the mirror did not start; see .out/verify/mirror.log"
        }

        time.sleep(1s)
        waited += 1
      }
    }

    let result = run_step(root, logs, step)?
    timed += [result]
    write_report(logs, arch, timed)

    if ! result.ok {
      stop_mirror(mirror)

      fail f"{step.name} failed; see .out/verify/{step.name}.log"
    }

    if step.name == "installer-qemu-test" {
      stop_mirror(mirror)

      mirror = null
    }
  }

  print (fp"{logs}/report.md".read_text()?)
}

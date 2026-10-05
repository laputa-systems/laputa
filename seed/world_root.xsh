##! In-container `make root` step: compose a runtime root from an imported store, inspect it, and run it.
#!/bin/xsh
# `world_cli.xsh root` runs this in package-tools with `--network none` after the
# host imported the plan's artifacts from the local mirror into the store.
# The root is composed on the container's filesystem; only its receipt and an
# inspection report reach /output.

# Alpine's chroot lives in /usr/sbin, which package-tools leaves off PATH.
const chroot = "/usr/sbin/chroot"

## Errors that fail the root inspection.
error WorldRootError = Failed : ProcessFailure

type ElfReport = {path: Str, interpreter: Str, needed: List[Str]}

pure elf_interpreter(program_headers: Str) -> Str {
  for line in program_headers.lines() {
    let marker = "[Requesting program interpreter: "
    let start = line.find(marker) ?? -1
    continue unless start >= 0
    let rest = line.byte_slice(start + marker.byte_len())
    return rest.replace("]", with: "").trim()
  }

  ""
}

pure elf_needed(dynamic: Str) -> List[Str] {
  let needed = collect {
    for line in dynamic.lines() {
      continue unless "(NEEDED)" in line
      let start = line.find("[") ?? -1
      continue unless start >= 0
      yield line.byte_slice(start + 1).replace("]", with: "").trim()
    }
  }

  needed
}

pure needed_sonames(elves: List[ElfReport]) -> List[Str] {
  var seen = {
    soname: true
    for report in elves
    for soname in report.needed
  }
  seen.keys() |> sort
}

# readelf rejects anything that is not ELF, so its status classifies the file.
proc elf_report(root: Path, file: Path) [fs, process, error] -> Result[ElfReport?] {
  let status = run.status readelf -h $file > /dev/null 2> /dev/null
  return null unless status.ok

  let headers = run.text readelf -lW $file
  let dynamic = run.text readelf -dW $file
  let report: ElfReport = ElfReport(
    path: f"/{file.strip_prefix(root)?.display()}",
    interpreter: elf_interpreter(headers),
    needed: elf_needed(dynamic),
  )
  report
}

proc main(arch: Str, plan: Str, store: Str, output: Str, ...runtime_roots: List[Str]) [fs, process, env, error] {
  # Every dynamic ELF in a Laputa root must name musl's loader.
  let musl_interpreter = f"/lib/ld-musl-{arch}.so.1"
  let handle = fs.tempdir()?
  defer handle.close()
  let root = fp"{handle.host_path()?}/root"
  let loader_err = fp"{handle.host_path()?}/loader.err"
  var compose_args = ["root", "compose", plan, "--store", store, "--output", root.display()]

  for name in runtime_roots {
    compose_args += ["--runtime-root", name]
  }

  run /bin/xsh /src/laputa/pm.xsh -- @compose_args
  run /bin/xsh /src/laputa/pm.xsh -- root inspect $root

  var files = []
  var elves: List[ElfReport] = []
  var failures = []

  for entry in fs.files(root, hidden: true)? {
    files += [f"/{entry.path.strip_prefix(root)?.display()}"]
    continue unless entry.kind == "file"
    let found = elf_report(root, entry.path)?
    guard let report: ElfReport = found else { continue }
    elves += [report]

    if report.interpreter != "" and report.interpreter != musl_interpreter {
      failures += [f"{report.path} requests interpreter {report.interpreter}"]
    }

    # musl's loader resolves every NEEDED soname inside the root, as at boot.
    if report.interpreter != "" or ! report.needed.is_empty() {
      let listed = run.status $chroot $root $musl_interpreter --list $report.path > /dev/null 2> $loader_err

      if ! listed.ok {
        failures += [f"{report.path}: {loader_err.read_text()?.trim()}"]
      }
    }
  }

  let dynamic = [report for report in elves if report.interpreter != ""]
  json.write(
    fp"{output}/inspection.json",
    {
      runtime_roots,
      files: files.len(),
      elf: elves.len(),
      dynamic: dynamic.len(),
      sonames: needed_sonames(elves),
      failures,
    },
  )
  fp"{output}/files.txt".write_lines(if files.is_empty() { [""] } else { files |> sort })
  fp"{root}/var/lib/laputa/generation.json".copy(to: fp"{output}/generation.json", overwrite: true)

  # The root's own xsh must run a script from inside it. The probe lands after
  # the receipt was copied; the throwaway root is never used again.
  fp"{root}/tmp".mkdir()
  fp"{root}/tmp/world-root-probe.xsh".write(
    "print f\"xsh runs in the root on {system.uname()?.sysname} {system.uname()?.machine}\"\n",
  )
  let greeting = run.text $chroot $root /bin/xsh /tmp/world-root-probe.xsh
  print greeting.trim()
  print f"root files={files.len()} elf={elves.len()} dynamic={dynamic.len()} failures={failures.len()}"

  for failure in failures {
    print f"root failure {failure}"
  }

  if ! failures.is_empty() {
    return Err(WorldRootError.Failed(f"{failures.len()} ELF files in the composed root do not load"))
  }
}

##! Census gate for zlib: interface parity and a differential corpus between the shipped C library and the zlib-rs candidate.
use pm.proof

const oracle_missing_in_candidate = [
  {symbol: "FUNC gzprintf", why: "gzprintf is variadic; zlib-rs defines variadic functions only behind its nightly-only gzprintf feature, and the distribution builds with the pinned stable Rust toolchain"},
  {symbol: "FUNC gzvprintf@@ZLIB_1.2.7.1", why: "gzvprintf is built on the same nightly-only feature in zlib-rs"},
]

proc exported_symbols(readelf: Path, library: Path) [fs, process, env, error] -> Result[List[Str], Error] {
  let listing = run.text $readelf "--dyn-syms" "-W" $library
  let names = collect {
    for line in listing.lines() {
      let fields = line.fields()

      if fields.len() == 8 and fields[4] == "GLOBAL" and fields[6] != "UND" {
        yield f"{fields[3]} {fields[7]}"
      }
    }
  }

  names |> sort
}

proc dynamic_entries(readelf: Path, library: Path, tag: Str) [fs, process, env, error] -> Result[List[Str], Error] {
  let listing = run.text $readelf "-d" "-W" $library
  let entries = collect {
    for line in listing.lines() {
      if f"({tag})" in line {
        yield line.split("[")[1].replace("]", with: "")
      }
    }
  }

  entries |> sort
}

proc compare_interface(root: Path, oracle: Path, candidate: Path) [fs, process, env, error] {
  let readelf = proof.readelf_tool()?
  let oracle_soname = dynamic_entries(readelf, oracle, "SONAME")?
  let candidate_soname = dynamic_entries(readelf, candidate, "SONAME")?
  print f"interface: SONAME oracle {oracle_soname.join(",")} candidate {candidate_soname.join(",")}"
  proof.ensure(oracle_soname == candidate_soname and oracle_soname == ["libz.so.1"], "zlib-rs-qualify", "SONAME differs from the shipped libz.so.1")

  let oracle_needed = dynamic_entries(readelf, oracle, "NEEDED")?
  let candidate_needed = dynamic_entries(readelf, candidate, "NEEDED")?
  print f"interface: DT_NEEDED oracle {oracle_needed.join(",")} candidate {candidate_needed.join(",")}"
  proof.ensure(oracle_needed == candidate_needed, "zlib-rs-qualify", "DT_NEEDED sets differ")
  proof.ensure(dynamic_entries(readelf, candidate, "RUNPATH")?.is_empty() and dynamic_entries(readelf, candidate, "RPATH")?.is_empty(), "zlib-rs-qualify", "candidate carries a private search path")

  let oracle_symbols = exported_symbols(readelf, oracle)?
  let candidate_symbols = exported_symbols(readelf, candidate)?
  let missing = [name for name in oracle_symbols if name not in candidate_symbols]
  let extra = [name for name in candidate_symbols if name not in oracle_symbols]
  print f"interface: exported symbols oracle {oracle_symbols.len()} candidate {candidate_symbols.len()}, versions included"

  for name in missing {
    let known = [entry.why for entry in oracle_missing_in_candidate if entry.symbol == name]
    if known.is_empty() {
      print f"interface: MISSING {name} (unjustified)"
    } else {
      print f"interface: missing {name}: {known[0]}"
    }
  }
  for name in extra {
    print f"interface: EXTRA {name} (unjustified)"
  }

  let unjustified = [name for name in missing if [entry for entry in oracle_missing_in_candidate if entry.symbol == name].is_empty()]
  proof.ensure(unjustified.is_empty() and extra.is_empty(), "zlib-rs-qualify", f"exported symbol sets differ beyond the justified list: missing {unjustified.join(" ")} extra {extra.join(" ")}")
  print f"interface: ok, {missing.len()} justified differences"
}

proc compile(cc: Path, root: Path, args: List[Str]) [fs, process, env, error] {
  env ({LAPUTA_ROOT: root.display()}) {
    run $cc @args
  }
}

proc compare_abi(root: Path, sources: Path, work: Path, cc: Path) [fs, process, env, error] {
  var reports: List[Str] = []

  for header_dir in [fp"{root}/usr/include", fp"{root}/usr/include/zlib-rs"] {
    let probe = fp"{work}/abi-{reports.len()}"
    compile(cc, root, [fp"{sources}/abi.c".display(), f"-I{header_dir}", "-o", probe.display()])
    let text = run.text $probe
    reports = reports.push(text)
  }

  let only_oracle = [line for line in reports[0].lines() if line not in reports[1].lines()]
  let only_candidate = [line for line in reports[1].lines() if line not in reports[0].lines()]
  for line in only_oracle {
    print f"abi: oracle header only: {line}"
  }
  for line in only_candidate {
    print f"abi: candidate header only: {line}"
  }
  proof.ensure(only_oracle.is_empty() and only_candidate.is_empty(), "zlib-rs-qualify", "z_stream, gz_header or constant layout differs between the two zlib.h files")
  print f"abi: ok, {reports[0].lines().len()} layout and constant lines identical"
}

proc main(root = p"/rootfs") [fs, process, env, error] {
  let oracle = fp"{root}/usr/lib/libz.so.1"
  let candidate = fp"{root}/usr/lib/zlib-rs/libz.so.1"
  proof.ensure(oracle.exists()? and candidate.exists()?, "zlib-rs-qualify", "root needs usr/lib/libz.so.1 and usr/lib/zlib-rs/libz.so.1")
  let sources = fp"{fs.cwd()?}/qualification/zlib-rs"
  let cc = process.which("cc")?
  compare_interface(root, oracle, candidate)

  tempdir work at fp"{e"TMPDIR" ?? "/tmp"}/zlib-rs-qualify" {
    compare_abi(root, sources, work, cc)
    let driver = fp"{work}/differential"
    compile(cc, root, ["-O1", fp"{sources}/differential.c".display(), f"-I{root}/usr/include", "-o", driver.display(), "-ldl"])
    fp"{work}/gz".mkdir()

    env ({
      LD_LIBRARY_PATH: fp"{root}/usr/lib".display(),
    }) {
      run $driver $oracle $candidate fp"{work}/gz"
    }
  }

  print "zlib-rs qualification: interface, ABI and differential gates passed"
}

#!/bin/xsh
use kbuild

proc main(...argv: List[Str]) [fs, error] {
  let input_path = fp"{argv[0]}"
  let output_path = fp"{argv[1]}"
  let input = json.read(input_path)?.require(kbuild.ArchiveAnalysisInput)?
  let results = kbuild.analyze_prepared_archive_items(
    input.items,
    fp"{input.cc}",
    input.triple,
    input.cflags,
    input.defs,
    input.includes,
    input.emit_task_specs,
  )?
  json.write(output_path, results)
}

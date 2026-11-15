#!/bin/xsh
proc main(manifest: Str) [fs, error] {
  let value = json.read(fp"{manifest}")?.require(Record)?
  let commit: Str = value.get("xsh_commit")?.require()?
  print $commit
}

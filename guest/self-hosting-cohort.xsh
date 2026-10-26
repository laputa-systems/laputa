use pm.build

proc main(repository: Path) [fs, process, env, error] -> Result[Unit, Error] {
  let executor = build.executor_provenance()?
  assert executor.xsh_sha256 == hash.sha256(/bin/xsh)?.hex()
  assert executor.xsht_sha256 == hash.sha256(/bin/xsht)?.hex()
  json.write(/output/executor.json, executor)?
  if repository == p"/checkout-two" {
    for file in ["test_printf_long_double", "test_seq_arbitrary_precision_and_hex"] {
      let log = fp"/output/{file}.log"
      let tests = process.run(process.command_argv(/bin/xsht, ["/bin/xsht", "test", file, "--jobs", "1"], /inputs/xsh, stdout: log))?
      let text = log.read_text()?
      print $text
      assert ! ("running 0 tests" in text)
      fail f"replacement runner failed {file}" unless tests.ok
    }
  }
  let command = process.command_argv(/bin/xsh, ["/bin/xsh", "/cohort/build.xsh", "--", repository.display()])
  let status = process.run(command)?
  fail "closed cohort build failed" unless status.ok
  var artifacts = 0
  for entry in fs.walk(p"/output/store", hidden: true)? {
    continue unless entry.kind == "file" and entry.path.name == "metadata.json"
    let metadata = json.read(entry.path)?.require(Record)?
    let actual = metadata.get("executor")?.require(Record)?
    assert actual.get("xsh_sha256")?.require(Str)? == executor.xsh_sha256
    assert actual.get("xsht_sha256")?.require(Str)? == executor.xsht_sha256
    artifacts += 1
  }
  assert artifacts == 3
}

main(@args)?

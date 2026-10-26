proc main(root: Path) [fs, process, error] {
  let output = run.text fp"{root}/usr/bin/cohort-c"
  assert output.trim() == "declared C payload"
}

main(@args)?

proc main(root: Path) [fs, process, error] {
  let output = run.text fp"{root}/usr/bin/cohort-rust"
  assert output.trim() == "declared Rust payload"
}

main(@args)?

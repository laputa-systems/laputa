proc main(root: Path) [fs, process, error] {
  assert fp"{root}/usr/share/cohort-xsh".read_text()? == "declared XSH payload\n"
}

main(@args)?

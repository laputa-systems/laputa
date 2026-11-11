proc main(root: Path) [fs, error] {
  assert fp"{root}/usr/share/cohort-hostile-read".exists()?
}

main(@args)?

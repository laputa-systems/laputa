proc main(root: Path) [fs, error] {
  assert fp"{root}/usr/share/cohort-hostile-tcp".exists()?
}

main(@args)?

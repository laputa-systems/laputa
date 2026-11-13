use pm.generation

proc main(root: Path) [fs, error] -> Result[Unit, Error] {
  let expected = generation.read_generation_receipt_file(fp"{root}/inputs/generation-B.json")?
  assert generation.read_generation_receipt(p"/")? == expected
  fail "deliberate self-hosting candidate health failure"
}

main(@args)?

##! Executor fixture that writes the first payload contract.
## Writes the first payload contract to the destination.
export proc build(dest: Path) [fs, error] -> Result[Unit, Error] {
  fp"{dest}/payload.bin".write("laputa payload v1\n")?
}

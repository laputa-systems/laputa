##! Executor fixture with a separate implementation for the first payload contract.
## Writes the first payload contract through another implementation.
export proc build(dest: Path) [fs, error] -> Result[Unit, Error] {
  let family = "laputa payload "
  let version = "v1"
  fp"{dest}/payload.bin".write(f"{family}{version}\n")?
}

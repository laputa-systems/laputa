##! Executor fixture that writes the changed payload contract.
## Writes the changed payload contract to the destination.
export proc build(dest: Path) [fs, error] -> Result[Unit, Error] {
  let family = "laputa payload "
  let version = "v2"
  fp"{dest}/payload.bin".write(f"{family}{version}\n")?
}

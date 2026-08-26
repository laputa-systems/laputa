##! Atomic publication of final profile artifacts from container-local Linux staging to the host output bind mount.

## Publication failures at the local-container to host-output boundary.
export error ContainerOutputError = Failed(message: Str) : InvalidData

## Copy one fully produced regular file to its durable host-output destination without exposing a partial final.
export proc publish_final_file(source: Path, output: Path) [fs, error] {
  if ! fs.exists(source)? or fs.metadata(source)?.kind != "file" or fs.metadata(source)?.size <= 0 {
    return Err(ContainerOutputError.Failed(f"final publication source is missing or empty: ${source}"))
  }

  let temporary = fp"${output}.tmp"
  fs.mkdir(output.parent)?
  fs.remove(temporary, missing_ok: true)?
  defer fs.remove(temporary, missing_ok: true)?
  fs.copy(source, temporary)?

  if hash.sha256(source)?.hex() != hash.sha256(temporary)?.hex() {
    return Err(ContainerOutputError.Failed(f"final publication copy does not match ${source}"))
  }

  fs.fsync(temporary)?
  fs.rename(temporary, output, overwrite: true)?
}

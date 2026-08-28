##! Atomic publication of final profile artifacts from container-local Linux staging to the host output bind mount.

## Publication failures at the local-container to host-output boundary.
export error ContainerOutputError = Failed(message: Str) : InvalidData

## One verified file copied into an atomic system bundle.
export type BundleFile = {name: Str, source: Path}

pure bundle_key_is_valid(value: Str) -> Bool {
  value.count_chars() == 64 and value == value.lower() and value.delete("0123456789abcdef") == ""
}

proc bundle_verify_file(source: Path, output: Path) [fs, error] {
  if ! fs.exists(source)? or fs.metadata(source)?.kind != "file" or fs.metadata(source)?.size <= 0 {
    return Err(ContainerOutputError.Failed(f"bundle source is missing or empty: ${source}"))
  }
  if ! fs.exists(output)? or fs.metadata(output)?.kind != "file" or hash.sha256(source)?.hex() != hash.sha256(output)?.hex() {
    return Err(ContainerOutputError.Failed(f"bundle output does not match ${source}"))
  }
}

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

## Publishes a complete immutable system bundle before atomically selecting it
## as `current`. Existing completed bundles are reused only when every file
## exactly matches the newly verified local output.
export proc publish_bundle(output_root: Path, key: Str, files: List[BundleFile]) [fs, error] {
  if ! bundle_key_is_valid(key) {
    return Err(ContainerOutputError.Failed("system bundle key must be a lowercase SHA-256 digest"))
  }
  if files.len() == 0 {
    return Err(ContainerOutputError.Failed("system bundle must contain files"))
  }
  var names: Map[Bool] = {}
  for item in files {
    if item.name == "" or item.name.contains("/") or names.has(item.name) {
      return Err(ContainerOutputError.Failed(f"invalid system bundle file name ${item.name}"))
    }
    names[item.name] = true
    if ! fs.exists(item.source)? or fs.metadata(item.source)?.kind != "file" or fs.metadata(item.source)?.size <= 0 {
      return Err(ContainerOutputError.Failed(f"bundle source is missing or empty: ${item.source}"))
    }
  }

  let builds = fp"${output_root}/builds"
  let final_dir = fp"${builds}/${key}"
  let temporary = fp"${builds}/.${key}.tmp"
  fs.mkdir(builds)?
  if fs.exists(final_dir)? {
    if fs.metadata(final_dir)?.kind != "dir" {
      return Err(ContainerOutputError.Failed(f"completed bundle path is not a directory: ${final_dir}"))
    }
    for item in files { bundle_verify_file(item.source, fp"${final_dir}/${item.name}")? }
  } else {
    fs.remove(temporary, missing_ok: true)?
    defer fs.remove(temporary, missing_ok: true)?
    fs.mkdir(temporary)?
    for item in files {
      let destination = fp"${temporary}/${item.name}"
      fs.copy(item.source, destination)?
      bundle_verify_file(item.source, destination)?
      fs.fsync(destination)?
    }
    fs.rename(temporary, final_dir)?
  }

  let current = fp"${output_root}/current"
  let current_temporary = fp"${output_root}/.current.tmp"
  fs.remove(current_temporary, missing_ok: true)?
  defer fs.remove(current_temporary, missing_ok: true)?
  fs.symlink(fp"builds/${key}", current_temporary)?
  fs.rename(current_temporary, current, overwrite: true)?
}

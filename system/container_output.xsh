##! Atomic publication of final profile artifacts from container-local Linux staging to the host output bind mount.
## Publication failures at the local-container to host-output boundary.
export error ContainerOutputError = Failed(message: Str) : InvalidData

## One verified file copied into an atomic system bundle.
export type BundleFile = {name: Str, source: Path}

pure bundle_key_is_valid(value: Str) -> Bool {
  value.count_chars() == 64 and value == value.lower() and value.delete("0123456789abcdef") == ""
}

proc bundle_verify_file(source: Path, output: Path) {
  if ! source.exists() or ! source.is_file() or source.metadata()?.size <= 0 {
    return Err(ContainerOutputError.Failed(f"bundle source is missing or empty: {source}"))
  }

  if ! output.exists() or ! output.is_file() or hash.sha256(source)?.hex() != hash.sha256(output)?.hex() {
    return Err(ContainerOutputError.Failed(f"bundle output does not match {source}"))
  }
}

## Copy one fully produced regular file to its durable host-output destination without exposing a partial final.
export proc publish_final_file(source: Path, output: Path) [fs, error] {
  if ! source.exists() or ! source.is_file() or source.metadata()?.size <= 0 {
    return Err(ContainerOutputError.Failed(f"final publication source is missing or empty: {source}"))
  }

  output.parent.mkdir()
  atomically replace output as temporary {
    source.copy(temporary)

    if hash.sha256(source)?.hex() != hash.sha256(temporary)?.hex() {
      return Err(ContainerOutputError.Failed(f"final publication copy does not match {source}"))
    }

    fs.fsync(temporary)
  }
}

## Publishes a complete immutable system bundle before atomically selecting it
## as `current`. Existing completed bundles are reused only when every file
## exactly matches the newly verified local output.
export proc publish_bundle(output_root: Path, key: Str, files: List[BundleFile]) [fs, error] {
  guard bundle_key_is_valid(key) else {
    return Err(ContainerOutputError.Failed("system bundle key must be a lowercase SHA-256 digest"))
  }

  if files.len() == 0 {
    return Err(ContainerOutputError.Failed("system bundle must contain files"))
  }

  var names: Map[Bool] = {}
  for item in files {
    if item.name == "" or "/" in item.name or item.name in names {
      return Err(ContainerOutputError.Failed(f"invalid system bundle file name {item.name}"))
    }

    names[item.name] = true
    if ! item.source.exists() or ! item.source.is_file() or item.source.metadata()?.size <= 0 {
      return Err(ContainerOutputError.Failed(f"bundle source is missing or empty: {item.source}"))
    }
  }

  let builds = fp"{output_root}/builds"
  let final_dir = fp"{builds}/{key}"
  let temporary = fp"{builds}/.{key}.tmp"
  builds.mkdir()
  if final_dir.exists() {
    guard final_dir.is_dir() else {
      return Err(ContainerOutputError.Failed(f"completed bundle path is not a directory: {final_dir}"))
    }

    for item in files {
      bundle_verify_file(item.source, fp"{final_dir}/{item.name}")
    }
  } else {
    temporary.remove(missing_ok: true)
    defer temporary.remove(missing_ok: true)?
    temporary.mkdir()
    for item in files {
      let destination = fp"{temporary}/{item.name}"
      item.source.copy(destination)
      bundle_verify_file(item.source, destination)
      fs.fsync(destination)
    }

    temporary.rename(final_dir)
  }

  let current = fp"{output_root}/current"
  let current_temporary = fp"{output_root}/.current.tmp"
  current_temporary.remove(missing_ok: true)
  defer current_temporary.remove(missing_ok: true)?
  fs.symlink(fp"builds/{key}", current_temporary)
  current_temporary.rename(current, overwrite: true)
}

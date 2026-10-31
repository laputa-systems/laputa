##! Filesystem-backed HostOps for native tests; production never imports this module.

use xinfra.host
use xinfra.model

const ROOT_ENV = "XINFRA_FAKE_ROOT"

proc root() [env, error] -> Result[Path, Error] {
  match env.path(ROOT_ENV) {
    Ok(value) => Ok(value),
    Err(_) => Err(error.failure(f"{ROOT_ENV} is not set")),
  }
}

proc real(host_path: Path) [env, error] -> Result[Path, Error] {
  let base = root()?
  let relative = host_path.strip_prefix(p"/")?
  Ok(fp"{base}/{relative}")
}

proc flag(name: Str) [env] -> Bool {
  match env.get(name) {
    Ok(value) => value == "1",
    Err(_) => false,
  }
}

pure fake_name() -> Str {
  "fake"
}

proc inspect_path(host_path: Path) [fs, env, error] -> Result[host.Inspection, Error] {
  let target = real(host_path)?
  let stat = match fs.stat(target, follow_symlinks: false) {
    Ok(value) => value,
    Err(_) => {
      return Ok(host.Missing)
    },
  }

  let digest = if stat.kind == "file" {
    match hash.sha256(target) {
      Ok(value) => value.hex(),
      Err(_) => null,
    }
  } else {
    null
  }
  let link = if stat.kind == "symlink" {
    match target.readlink() {
      Ok(value) => value,
      Err(_) => null,
    }
  } else {
    null
  }
  let empty = if stat.kind == "dir" {
    let children = fs.children(target, stat: false, ordered: true)?.collect()
    children.is_empty()
  } else {
    true
  }
  Ok(host.Found(host.PathStat(
    kind: stat.kind,
    mode: stat.mode.bit_and(0o7777),
    uid: 0,
    gid: 0,
    owner: "root",
    group: "root",
    size: stat.size,
    mtime_ns: stat.mtime_ns,
    digest: digest,
    target: link,
    empty: empty,
  )))
}

proc fake_parent_secure(host_path: Path, expected_owner: Str?) [fs, env, error] -> Result[Bool, Error] {
  Ok(! flag("XINFRA_FAKE_INSECURE_PARENT"))
}

proc fake_mkdir(host_path: Path, mode: Int) [fs, env, error] -> Result[Unit, Error] {
  let target = real(host_path)?
  target.mkdir(false)?
  target.chmod(mode)?
  Ok()
}

proc fake_remove_dir(host_path: Path) [fs, env, error] -> Result[Unit, Error] {
  let target = real(host_path)?
  target.remove_dir()?
  Ok()
}

proc fake_reserve_staging(destination: Path) [fs, env, error] -> Result[Path, Error] {
  fs.temp_sibling(destination)
}

proc fake_write_staging(staged: Path, data: Bytes) [fs, env, error] -> Result[Unit, Error] {
  let target = real(staged)?
  let partial = flag("XINFRA_FAKE_STAGE_FAILURE")
  let payload = if partial { data.slice(0, data.len() / 2) } else { data }
  target.write(payload, 0o600)?
  if partial {
    return Err(error.failure("simulated partial transfer"))
  }

  Ok()
}

proc fake_set_metadata(host_path: Path, mode: Int, owner: Str?, group_name: Str?) [fs, env, error] -> Result[Unit, Error] {
  let target = real(host_path)?
  target.chmod(mode)?
  Ok()
}

proc fake_digest(host_path: Path) [fs, env, error] -> Result[Str, Error] {
  let target = real(host_path)?
  Ok(hash.sha256(target)?.hex())
}

proc fake_validate(argv: List[Str], staged: Path) [fs, env, error] -> Result[Unit, Error] {
  if flag("XINFRA_FAKE_VALIDATION_FAILURE") {
    return Err(error.failure("simulated validator rejection"))
  }

  let target = real(staged)?
  if ! target.is_file()? {
    return Err(error.failure(f"staged path {staged.display()} is not a file"))
  }

  Ok()
}

proc fake_promote(staged: Path, destination: Path) [fs, env, error] -> Result[Unit, Error] {
  let source = real(staged)?
  let target = real(destination)?
  source.rename(to: target, overwrite: true)?
  Ok()
}

proc fake_remove(host_path: Path) [fs, env, error] -> Result[Unit, Error] {
  let target = real(host_path)?
  target.remove(true)?
  Ok()
}

proc fake_symlink(target: Path, link_path: Path) [fs, env, error] -> Result[Unit, Error] {
  let link = real(link_path)?
  link.symlink(to: target)?
  Ok()
}

proc fake_read_file(host_path: Path) [fs, env, error] -> Result[Bytes, Error] {
  let target = real(host_path)?
  target.read_bytes()
}

proc fake_resolve_secret(reference: model.SecretRef) [fs, env, error] -> Result[Bytes, Error] {
  match reference {
    model.FromEnv(name) => Ok(bytes.from_text(env.get(name)?)),
    model.FromFile(secret_path) => fake_read_file(secret_path),
  }
}

proc fake_mtime(host_path: Path) [fs, env, error] -> Result[Int, Error] {
  let target = real(host_path)?
  let stat = fs.stat(target, follow_symlinks: false)?
  Ok(stat.mtime_ns)
}

## Clears the fake root and recreates it empty.
export proc reset() [fs, env, error] {
  let base = root()?
  base.remove(true)?
  base.mkdir(true)?
}

## Returns the fake HostOps handle.
export pure host() -> host.HostOps {
  host.HostOps(
    name: fake_name,
    inspect_path: inspect_path,
    parent_secure: fake_parent_secure,
    mkdir_path: fake_mkdir,
    remove_dir_path: fake_remove_dir,
    reserve_staging: fake_reserve_staging,
    write_staging: fake_write_staging,
    set_metadata: fake_set_metadata,
    digest_path: fake_digest,
    validate: fake_validate,
    promote: fake_promote,
    remove_path: fake_remove,
    symlink: fake_symlink,
    read_file_path: fake_read_file,
    resolve_secret: fake_resolve_secret,
  )
}

## Returns a managed path's fake modification time.
export proc mtime(target: Path) [fs, env, error] -> Result[Int, Error] {
  fake_mtime(target)
}

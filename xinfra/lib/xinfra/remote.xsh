##! Remote host operations over one native SSH session.

use xinfra.host as host
use xinfra.model as model
use xinfra.transport as transport

pure text(value: Bytes) -> Str {
  match value.utf8() {
    Ok(text) => text,
    Err(_) => "",
  }
}

pure octal(value: Int) -> Str {
  if value == 0 {
    return "0"
  }

  var digits = ""
  var remaining = value
  while remaining > 0 {
    digits = f"{remaining % 8}{digits}"
    remaining = remaining / 8
  }
  digits
}

pure parse_octal(text: Str) -> Int {
  var value = 0
  for index in range(text.byte_len()) {
    let byte = text.byte_at(index) ?? 48
    value = value * 8 + (byte - 48)
  }
  value
}

proc remote_path(host_path: Path) -> Result[Str, Error] {
  let text = match host_path.bytes().utf8() {
    Ok(value) => value,
    Err(_) => { return Err(error.failure("managed path is not UTF-8")) },
  }
  if "\0" in text {
    return Err(error.failure("managed path contains NUL"))
  }
  for part in text.split("/") {
    if part == ".." {
      return Err(error.failure(f"managed path escapes its root: {text}"))
    }
  }
  Ok(text)
}

proc execute(session: transport.Session, argv: List[Str], elevate: List[Str] = []) -> Result[transport.ExecResult, Error] {
  match transport.exec(session, elevate + argv) {
    Ok(value) => Ok(value),
    Err(message) => Err(error.failure(message)),
  }
}

## Inspect one remote path.
export proc inspect_path(session: transport.Session, host_path: Path, elevate: List[Str] = []) -> Result[host.Inspection, Error] {
  let location = remote_path(host_path)?
  let result = execute(session, ["stat", "-c", "%F|%a|%u|%g|%s|%Y", location], elevate)?
  if result.exit_code != 0 {
    let message = text(result.stderr)
    return Ok(host.Missing) when "No such file" in message
    return Err(error.failure(message.trim()))
  }

  let parts = text(result.stdout).trim().split("|")
  if parts.len() < 6 {
    return Err(error.failure("malformed stat output"))
  }

  let kind = match parts[0] {
    "regular file" => "file",
    "directory" => "dir",
    "symbolic link" => "symlink",
    other => other,
  }
  let uid = parts[2].parse_int()?
  let gid = parts[3].parse_int()?
  let owner = name_for(session, "passwd", parts[2])?
  let group_name = name_for(session, "group", parts[3])?
  let digest = if kind == "file" {
    let hashed = execute(session, ["sha256sum", location], elevate)?
    if hashed.exit_code == 0 {
      let first = match text(hashed.stdout).fields().get(0) {
        Ok(value) => value,
        Err(_) => "",
      }
      if first == "" { null } else { first }
    } else {
      null
    }
  } else {
    null
  }
  let target = if kind == "symlink" {
    let linked = execute(session, ["readlink", location], elevate)?
    if linked.exit_code == 0 { fp"{text(linked.stdout).trim()}" } else { null }
  } else {
    null
  }
  let empty = if kind == "dir" {
    let listed = execute(session, ["ls", "-A", location], elevate)?
    text(listed.stdout).is_empty()
  } else {
    true
  }
  Ok(host.Found(host.PathStat(
    kind: kind,
    mode: parse_octal(parts[1]),
    uid: uid,
    gid: gid,
    owner: owner,
    group: group_name,
    size: parts[4].parse_int()?,
    mtime_ns: parts[5].parse_int()? * 1000000000,
    digest: digest,
    target: target,
    empty: empty,
  )))
}

proc name_for(session: transport.Session, database: Str, id: Str) -> Result[Str?, Error] {
  let result = execute(session, ["getent", database, id])?
  if result.exit_code != 0 {
    return Ok(null)
  }
  let line = text(result.stdout).trim().lines().get(0) ?? ""
  let name = line.split(":").get(0) ?? ""
  Ok(if name == "" { null } else { name })
}

## Check that a remote parent directory is trusted.
export proc parent_secure(session: transport.Session, host_path: Path, expected_owner: Str?, elevate: List[Str] = []) -> Result[Bool, Error] {
  let inspection = inspect_path(session, host_path, elevate)?
  match inspection {
    host.Missing => Ok(false),
    host.Found(stat) => {
      if stat.kind != "dir" {
        return Ok(false)
      }
      if stat.mode.bit_and(0o022) != 0 {
        if stat.mode.bit_and(0o1000) == 0 or stat.owner != expected_owner {
          return Ok(false)
        }
      }
      Ok(true)
    },
  }
}

## Create one remote directory and set its mode.
export proc mkdir_path(session: transport.Session, host_path: Path, mode: Int, elevate: List[Str] = []) -> Result[Unit, Error] {
  let location = remote_path(host_path)?
  let result = execute(session, ["mkdir", "-m", octal(mode), location], elevate)?
  return Err(error.failure(text(result.stderr).trim())) when result.exit_code != 0
  Ok()
}

## Remove one empty remote directory.
export proc remove_dir_path(session: transport.Session, host_path: Path, elevate: List[Str] = []) -> Result[Unit, Error] {
  let location = remote_path(host_path)?
  let result = execute(session, ["rmdir", location], elevate)?
  return Err(error.failure(text(result.stderr).trim())) when result.exit_code != 0
  Ok()
}

## Reserve a private staging name in the destination parent.
export proc reserve_staging(session: transport.Session, destination: Path, elevate: List[Str] = []) -> Result[Path, Error] {
  let parent = remote_path(destination.parent())?
  let created = execute(session, ["mktemp", "-p", parent, ".xinfra.XXXXXX"], elevate)?
  return Err(error.failure(text(created.stderr).trim())) when created.exit_code != 0
  let staging = text(created.stdout).trim()
  Ok(fp"{staging}")
}

## Set a remote path mode and optional ownership.
export proc set_metadata(session: transport.Session, host_path: Path, mode: Int, owner: Str?, group_name: Str?, elevate: List[Str] = []) -> Result[Unit, Error] {
  let location = remote_path(host_path)?
  let changed = execute(session, ["chmod", octal(mode), location], elevate)?
  return Err(error.failure(text(changed.stderr).trim())) when changed.exit_code != 0
  if owner != null {
    let chowned = execute(session, ["chown", owner ?? "", location], elevate)?
    return Err(error.failure(text(chowned.stderr).trim())) when chowned.exit_code != 0
  }
  if group_name != null {
    let chgrped = execute(session, ["chgrp", group_name ?? "", location], elevate)?
    return Err(error.failure(text(chgrped.stderr).trim())) when chgrped.exit_code != 0
  }
  Ok()
}

## Hash one remote file.
export proc digest_path(session: transport.Session, host_path: Path, elevate: List[Str] = []) -> Result[Str, Error] {
  let location = remote_path(host_path)?
  let result = execute(session, ["sha256sum", location], elevate)?
  return Err(error.failure(text(result.stderr).trim())) when result.exit_code != 0
  let first = match text(result.stdout).fields().get(0) {
    Ok(value) => value,
    Err(_) => "",
  }
  Ok(first)
}

## Promote a staged remote object with mv -T.
export proc promote(session: transport.Session, staged: Path, destination: Path, elevate: List[Str] = []) -> Result[Unit, Error] {
  let source = remote_path(staged)?
  let target = remote_path(destination)?
  let result = execute(session, ["mv", "-T", source, target], elevate)?
  return Err(error.failure(text(result.stderr).trim())) when result.exit_code != 0
  Ok()
}

## Remove one remote path.
export proc remove_path(session: transport.Session, host_path: Path, elevate: List[Str] = []) -> Result[Unit, Error] {
  let location = remote_path(host_path)?
  let result = execute(session, ["rm", "-f", location], elevate)?
  return Err(error.failure(text(result.stderr).trim())) when result.exit_code != 0
  Ok()
}

proc symlink_target(target: Path) -> Result[Str, Error] {
  let text_value = match target.bytes().utf8() {
    Ok(value) => value,
    Err(_) => { return Err(error.failure("symlink target is not UTF-8")) },
  }
  if "\0" in text_value {
    return Err(error.failure("symlink target contains NUL"))
  }
  Ok(text_value)
}

## Create one remote symbolic link.
export proc symlink(session: transport.Session, target: Path, link_path: Path, elevate: List[Str] = []) -> Result[Unit, Error] {
  let link_target = symlink_target(target)?
  let link = remote_path(link_path)?
  let result = execute(session, ["ln", "-s", "--", link_target, link], elevate)?
  return Err(error.failure(text(result.stderr).trim())) when result.exit_code != 0
  Ok()
}

## Read one remote file.
export proc read_file_path(session: transport.Session, host_path: Path, elevate: List[Str] = []) -> Result[Bytes, Error] {
  let location = remote_path(host_path)?
  let result = execute(session, ["cat", location], elevate)?
  return Err(error.failure(text(result.stderr).trim())) when result.exit_code != 0
  Ok(result.stdout)
}


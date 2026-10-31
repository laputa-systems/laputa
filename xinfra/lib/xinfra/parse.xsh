##! Machine-readable remote fact parsers.

## One parsed fact; fields carry the values the caller can use.
export type Fact = {kind: Str, fields: Map[Str, Str]}

pure fact(kind: Str, fields: Map[Str, Str]) -> Fact {
  {kind: kind, fields: fields}
}

## A fact that a probe could not establish.
export pure unknown(detail: Str) -> Fact {
  fact("unknown", {"detail": detail})
}

## A fact for a missing object.
export pure absent() -> Fact {
  fact("absent", map.empty())
}

## Parse `stat -c '%F|%a|%u|%g|%s|%Y'` output.
export pure file_stat(text: Str) -> Fact {
  let parts = text.trim().split("|")
  if parts.len() < 6 {
    return fact("malformed", map.empty())
  }

  fact("present", {
    "type": parts[0],
    "mode": parts[1],
    "uid": parts[2],
    "gid": parts[3],
    "size": parts[4],
    "mtime": parts[5],
  })
}

## Parse one `getent passwd` row.
export pure passwd_row(text: Str) -> Fact {
  let line = text.trim().lines().get(0) ?? ""
  let parts = line.split(":")
  if parts.len() < 7 {
    return fact("malformed", map.empty())
  }

  fact("present", {
    "name": parts[0],
    "uid": parts[2],
    "gid": parts[3],
    "home": parts[5],
    "shell": parts[6],
  })
}

## Parse one `getent group` row.
export pure group_row(text: Str) -> Fact {
  let line = text.trim().lines().get(0) ?? ""
  let parts = line.split(":")
  if parts.len() < 4 {
    return fact("malformed", map.empty())
  }

  fact("present", {
    "name": parts[0],
    "gid": parts[2],
    "members": parts[3],
  })
}

## Parse `apk list -I NAME` output.
export pure package(text: Str, name: Str) -> Fact {
  let prefix = f"{name}-"
  for line in text.lines() {
    let token = line.fields().get(0) ?? ""
    if token.starts_with(prefix) {
      return fact("present", {
        "name": name,
        "version": token.byte_slice(prefix.byte_len()),
      })
    }
  }
  fact("absent", map.empty())
}

## Map an OpenRC status exit code to a fact.
export pure service_status(code: Int) -> Fact {
  if code == 0 {
    return fact("present", {"status": "started"})
  }

  if code == 3 {
    return fact("present", {"status": "stopped"})
  }

  fact("unknown", map.empty())
}

## Parse `rc-update show` for one service.
export pure rc_update(text: Str, name: Str) -> Fact {
  for line in text.lines() {
    let words = line.words()
    if ! words.is_empty() and words[0] == name {
      return fact("present", {"enabled": "yes"})
    }
  }
  fact("present", {"enabled": "no"})
}

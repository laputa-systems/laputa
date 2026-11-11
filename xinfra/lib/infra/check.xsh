##! Pure validation of the values a declaration accepts.

const identifier = rx"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
const account_name = rx"^[a-z_][a-z0-9_.-]{0,31}$"
const numeric_id = rx"^[0-9]{1,10}$"
const package_name = rx"^[a-z0-9][a-z0-9._+-]{0,127}$"
const version_text = rx"^[0-9][A-Za-z0-9._+~-]{0,127}$"
const service_name = rx"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
const environment_name = rx"^[A-Za-z_][A-Za-z0-9_]{0,127}$"
const nul = "\0"
const max_path_bytes = 4096

## Reject a resource identifier that is empty, too long, or uses characters
## outside letters, digits, dot, underscore and hyphen.
export pure identifier_ok(id: Str) -> Result[Unit, Error] {
  guard identifier.matches(id) else {
    fail f"invalid resource id {id}: use letters, digits, dot, underscore and hyphen, starting with a letter or digit"
  }
}

## Reject a path that is not absolute, contains NUL, or has an empty, `.` or
## `..` component. Paths are compared lexically and never normalized.
export pure path_ok(what: Str, location: Str) -> Result[Unit, Error] {
  guard location.starts_with("/") else {
    fail f"{what} must be an absolute path: {location}"
  }

  guard location.find(nul) == null else {
    fail f"{what} contains a NUL byte"
  }

  guard location.byte_len() <= max_path_bytes else {
    fail f"{what} is longer than {max_path_bytes} bytes"
  }

  if location == "/" {
    return
  }

  guard ! location.ends_with("/") else {
    fail f"{what} must not end with a slash: {location}"
  }

  for part in location.byte_slice(1).split("/") {
    guard part != "" and part != "." and part != ".." else {
      fail f"{what} has an empty, `.` or `..` component: {location}"
    }
  }
}

## Reject a path that names the filesystem root, which no resource may manage.
export pure not_root(what: Str, location: Str) -> Result[Unit, Error] {
  guard location != "/" else {
    fail f"{what} must not be the filesystem root"
  }
}

## Accept an owner or group as an account name or a numeric id.
export pure principal_ok(what: Str, value: Str) -> Result[Unit, Error] {
  guard account_name.matches(value) or numeric_id.matches(value) else {
    fail f"invalid {what} {value}"
  }
}

## Accept a lowercase account name.
export pure account_ok(what: Str, value: Str) -> Result[Unit, Error] {
  guard account_name.matches(value) else {
    fail f"invalid {what} {value}"
  }
}

## Accept an Alpine package name.
export pure package_ok(name: Str) -> Result[Unit, Error] {
  guard package_name.matches(name) else {
    fail f"invalid package name {name}"
  }
}

## Accept an apk version string.
export pure version_ok(version: Str) -> Result[Unit, Error] {
  guard version_text.matches(version) else {
    fail f"invalid package version {version}"
  }
}

## Accept an init-script name.
export pure service_ok(name: Str) -> Result[Unit, Error] {
  guard service_name.matches(name) else {
    fail f"invalid service name {name}"
  }
}

## Accept a name suitable for an environment variable.
export pure environment_ok(name: Str) -> Result[Unit, Error] {
  guard environment_name.matches(name) else {
    fail f"invalid environment variable name {name}"
  }
}

## Accept a permission mode between 0 and 0o7777.
export pure mode_ok(mode: Int) -> Result[Unit, Error] {
  guard mode >= 0 and mode <= 0o7777 else {
    fail f"mode out of range: {mode}"
  }
}

## Accept a nonempty argv with no NUL byte in any word.
export pure argv_ok(what: Str, argv: List[Str]) -> Result[Unit, Error] {
  guard ! argv.is_empty() else {
    fail f"{what} needs at least one word"
  }

  for word in argv {
    guard word.find(nul) == null else {
      fail f"{what} contains a NUL byte"
    }
  }
}

## Accept a shell string with no NUL byte.
export pure shell_ok(what: Str, text: Str) -> Result[Unit, Error] {
  guard text != "" and text.find(nul) == null else {
    fail f"{what} must be nonempty text without a NUL byte"
  }
}

## Accept a numeric id in the range accounts use.
export pure id_number_ok(what: Str, value: Int) -> Result[Unit, Error] {
  guard value >= 0 and value <= 4294967294 else {
    fail f"{what} out of range: {value}"
  }
}

## Accept the identifier list of dependencies.
export pure needs_ok(needs: List[Str]) -> Result[Unit, Error] {
  for id in needs {
    identifier_ok(id)?
  }
}

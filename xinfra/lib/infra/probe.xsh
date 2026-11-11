##! Pure parsers for the output of the observation scripts. They turn a host's
##! report into typed facts and never guess: output they cannot read becomes an
##! unreadable fact.

use infra.fact

const hex_digits = "0123456789abcdef"

pure malformed(detail: Str) -> fact.Unreadable {
  fact.Unreadable(cause: .Malformed, detail:)
}

pure hex_value(digit: Str) -> Result[Int, Error] {
  let found = hex_digits.find(digit.lower())
  guard let value = found else {
    fail f"not a hex digit: {digit}"
  }

  Ok(value)
}

## Decode lowercase or uppercase hex into the UTF-8 text it spells. Odd
## length, non-hex digits and invalid UTF-8 are errors.
export pure decode_hex(text: Str) -> Result[Str, Error] {
  guard text.byte_len() % 2 == 0 else {
    fail "odd number of hex digits"
  }

  var values: List[Int] = []
  var offset = 0
  while offset < text.byte_len() {
    let high = hex_value(text.byte_slice(offset, 1))?
    let low = hex_value(text.byte_slice(offset + 1, 1))?
    values += [high * 16 + low]
    offset += 2
  }

  bytes.from_ints(values)?.utf8()
}

pure fields(stdout: Str) -> Map[Str, Str] {
  var table: Map[Str, Str] = {}
  for line in stdout.lines() {
    let split = line.find(" ")
    if split == null {
      table[line] = ""
    } else {
      table[line.byte_slice(0, split)] = line.byte_slice(split + 1)
    }
  }

  table
}

pure octal(text: Str) -> Result[Int, Error] {
  f"0o{text}".parse_int()
}

pure number(table: Map[Str, Str], key: Str) -> Result[Int, Error] {
  let text = table.get(key)?
  text.parse_int()
}

pure text_field(table: Map[Str, Str], key: Str) -> Result[Str, Error] {
  decode_hex(table.get(key)?)
}

pure detail_of(table: Map[Str, Str]) -> Str {
  let raw = table.get("detail") ?? ""
  decode_hex(raw) ?? raw
}

pure path_info(table: Map[Str, Str]) -> Result[fact.PathInfo, Error] {
  let kind: fact.PathKind = match table.get("kind")? {
    "dir" => .Directory
    "file" => .Regular
    "link" => .Symlink
    "other" => .Other
    else => {
      fail "unknown path kind"
    }
  }

  let digest_text = table.get("digest") ?? ""
  let digest = if digest_text == "" or digest_text == "unreadable" { null } else { digest_text }
  let target_hex = table.get("target") ?? ""
  let link_target = if kind == .Symlink { decode_hex(target_hex)? } else { null }
  Ok(fact.PathInfo(
    kind:,
    mode: octal(table.get("mode")?)?,
    uid: number(table, "uid")?,
    gid: number(table, "gid")?,
    owner: text_field(table, "owner")?,
    group: text_field(table, "group")?,
    size: number(table, "size")?,
    digest:,
    link_target:,
  ))
}

## Parse the `path_state` script output into the state of one path.
export pure path_fact(stdout: Str) -> fact.PathState {
  let table = fields(stdout)
  match table.get("state") ?? "" {
    "missing" => fact.Missing
    "found" => {
      match path_info(table) {
        Ok(info) => fact.Found(info)
        Err(error) => fact.Unseen(malformed(f"path report: {error.message}"))
      }
    }
    "blocked" => fact.Blocked(fact.Unreadable(cause: .Conflict, detail: detail_of(table)))
    "denied" => fact.Unseen(fact.Unreadable(cause: .Denied, detail: detail_of(table)))
    "error" => fact.Unseen(fact.Unreadable(cause: .Unavailable, detail: detail_of(table)))
    else => fact.Unseen(malformed(f"path report has no state: {stdout}"))
  }
}

## Parse the `package_state` script output into the state of one package.
export pure package_fact(stdout: Str) -> fact.PackageState {
  let table = fields(stdout)
  match table.get("state") ?? "" {
    "absent" => fact.NotInstalled
    "installed" => {
      let ordering: fact.Ordering? = match table.get("ordering") ?? "" {
        "lt" => .Older
        "eq" => .Same
        "gt" => .Newer
        else => null
      }
      match table.get("version") {
        Ok(version) => {
          if table.get("ordering") is Ok("unknown") {
            fact.PackageUnseen(malformed(f"apk could not order version {version}"))
          } else {
            fact.Installed(fact.InstalledPackage(version:, ordering:))
          }
        }
        Err(_) => fact.PackageUnseen(malformed("package report has no version"))
      }
    }
    "unavailable" => fact.PackageUnseen(fact.Unreadable(cause: .Unavailable, detail: "apk database is not readable"))
    else => fact.PackageUnseen(malformed(f"package report has no state: {stdout}"))
  }
}

## The passwd and group databases of a host, parsed once.
export type Accounts = {users: List[fact.UserInfo], groups: List[fact.GroupInfo]}

pure group_line(line: Str) -> Result[fact.GroupInfo, Error] {
  let parts = line.split(":")
  guard parts.len() == 4 else {
    fail f"group line has {parts.len()} fields: {line}"
  }

  let members = if parts[3] == "" { [] } else { parts[3].split(",") }
  Ok(fact.GroupInfo(name: parts[0], gid: parts[2].parse_int()?, members:))
}

pure passwd_line(line: Str, groups: List[fact.GroupInfo]) -> Result[fact.UserInfo, Error] {
  let parts = line.split(":")
  guard parts.len() == 7 else {
    fail f"passwd line has {parts.len()} fields: {line}"
  }

  let name = parts[0]
  let gid = parts[3].parse_int()?
  let owners = groups |> where { |entry| entry.gid == gid } |> map { |entry| entry.name } |> collect()
  let primary: Str? = if owners.is_empty() { null } else { owners[0] }
  let memberships = groups |> where { |entry| name in entry.members } |> map { |entry| entry.name } |> collect()
  Ok(fact.UserInfo(
    name:,
    uid: parts[2].parse_int()?,
    gid:,
    group: primary,
    home: parts[5],
    shell: parts[6],
    memberships:,
  ))
}

pure section_lines(stdout: Str, marker: Str, next: Str?) -> List[Str] {
  var inside = false
  var lines: List[Str] = []
  for line in stdout.lines() {
    if line == marker {
      inside = true
    } else if next != null and line == next {
      inside = false
    } else if inside and line != "" {
      lines += [line]
    }
  }

  lines
}

## The account databases, or why they could not be read.
export enum AccountsState { AccountsFound(Accounts), AccountsUnseen(fact.Unreadable) }

## Parse the `accounts_state` script output. A report that is not readable or
## has a malformed line is unseen, never an empty database.
export pure accounts(stdout: Str) -> AccountsState {
  let table = fields((stdout.lines() |> first()) ?? "")
  if table.get("state") is Ok("denied") {
    return AccountsUnseen(fact.Unreadable(cause: .Denied, detail: "the account databases are not readable"))
  }

  guard stdout.starts_with("state ok\n") else {
    return AccountsUnseen(malformed(f"account report has no state: {stdout}"))
  }

  var groups: List[fact.GroupInfo] = []
  for line in section_lines(stdout, "@@group@@", null) {
    match group_line(line) {
      Ok(entry) => groups += [entry]
      Err(error) => return AccountsUnseen(malformed(error.message))
    }
  }

  var users: List[fact.UserInfo] = []
  for line in section_lines(stdout, "@@passwd@@", "@@group@@") {
    match passwd_line(line, groups) {
      Ok(entry) => users += [entry]
      Err(error) => return AccountsUnseen(malformed(error.message))
    }
  }

  AccountsFound(Accounts(users:, groups:))
}

## The state of the named group in a parsed account database.
export pure group_fact(accounts: Accounts, name: Str) -> fact.GroupState {
  let found = accounts.groups |> where { |entry| entry.name == name } |> collect()
  if found.is_empty() { fact.NoGroup } else { fact.GroupFound(found[0]) }
}

## The state of the named user in a parsed account database.
export pure user_fact(accounts: Accounts, name: Str) -> fact.UserState {
  let found = accounts.users |> where { |entry| entry.name == name } |> collect()
  if found.is_empty() { fact.NoUser } else { fact.UserFound(found[0]) }
}

## Parse the `service_state` script output into the state of one service.
export pure service_fact(stdout: Str) -> fact.ServiceState {
  let table = fields(stdout)
  match table.get("state") ?? "" {
    "missing" => fact.NoService
    "unavailable" => fact.ServiceUnseen(fact.Unreadable(cause: .Unavailable, detail: "rc-service is not installed"))
    "found" => {
      let running: fact.Running = match table.get("status") ?? "" {
        "0" => .Started
        "3" => .Stopped
        "1" => .Crashed
        else => .Indeterminate
      }
      let enabled = table.get("enabled") ?? ""
      if enabled == "yes" or enabled == "no" {
        fact.ServiceFound(fact.ServiceInfo(enabled: enabled == "yes", running:, ready: null))
      } else {
        fact.ServiceUnseen(malformed("service report has no enablement"))
      }
    }
    else => fact.ServiceUnseen(malformed(f"service report has no state: {stdout}"))
  }
}

## Parse the `xinit_service_state` script output into the state of one xinit
## service. Existence comes from the scanned service directory; running and
## ready come from the `xinit status` line.
export pure xinit_service_fact(stdout: Str) -> fact.ServiceState {
  let table = fields(stdout)
  match table.get("state") ?? "" {
    "missing" => fact.NoService
    "unavailable" => fact.ServiceUnseen(fact.Unreadable(cause: .Unavailable, detail: "xinit is not installed"))
    "denied" => fact.ServiceUnseen(fact.Unreadable(cause: .Denied, detail: detail_of(table)))
    "error" => fact.ServiceUnseen(fact.Unreadable(cause: .Unavailable, detail: detail_of(table)))
    "found" => {
      let running: fact.Running = match table.get("running") ?? "" {
        "running" => .Started
        "starting" => .Started
        "dead" => .Crashed
        "down" => .Stopped
        "stopped" => .Stopped
        "pending" => .Stopped
        "finishing" => .Stopped
        else => .Indeterminate
      }
      let readiness = table.get("ready") ?? ""
      guard readiness == "true" or readiness == "false" else {
        return fact.ServiceUnseen(malformed("xinit status report has no readiness"))
      }

      fact.ServiceFound(fact.ServiceInfo(enabled: null, running:, ready: readiness == "true"))
    }
    else => fact.ServiceUnseen(malformed(f"xinit service report has no state: {stdout}"))
  }
}

## The utilities a host reported present and absent, and the uid it runs as.
export type Capabilities = {present: List[Str], absent: List[Str], uid: Int}

## Parse the `capabilities` script output.
export pure capabilities(stdout: Str) -> Result[Capabilities, Error] {
  var present: List[Str] = []
  var absent: List[Str] = []
  var uid: Int? = null
  var shell_ok = false
  for line in stdout.lines() {
    if line == "shell ok" {
      shell_ok = true
    } else if line.starts_with("have ") {
      present += [line.byte_slice(5)]
    } else if line.starts_with("lack ") {
      absent += [line.byte_slice(5)]
    } else if line.starts_with("uid ") {
      uid = line.byte_slice(4).parse_int()?
    }
  }

  guard shell_ok else {
    fail "the remote shell did not run the probe"
  }

  guard let found_uid = uid else {
    fail "the remote shell did not report its uid"
  }

  Ok(Capabilities(present:, absent:, uid: found_uid))
}

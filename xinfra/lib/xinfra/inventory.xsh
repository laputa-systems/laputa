##! Inventory loading and host selection.

use xinfra.error as errors

## A TCP port accepted for an inventory host.
export type Port = Int range 1..=65535

## A validated inventory host with its key path resolved beneath the inventory root.
export type Host = {
  name: Str,
  groups: List[Str],
  address: Str,
  port: Port,
  user: Str,
  key: Path,
  host_key: Str,
}

## The declared groups and validated hosts of one inventory file.
export type Inventory = {groups: List[Str], hosts: List[Host]}

type RawHost = {
  name: Str,
  groups: List[Str],
  address: Str,
  port: Port,
  user: Str,
  key: Str,
  host_key: Str,
}

type RawInventory = {groups: List[Str], hosts: List[RawHost]}

pure ascii_alnum(byte: Int) -> Bool {
  if byte >= 48 and byte <= 57 {
    return true
  }

  if byte >= 65 and byte <= 90 {
    return true
  }

  byte >= 97 and byte <= 122
}

pure ascii_control(byte: Int) -> Bool {
  byte < 32 or byte == 127
}

pure valid_name(text: Str) -> Bool {
  if text.is_empty() {
    return false
  }

  let first = text.byte_at(0)
  if first == null {
    return false
  }

  if ! ascii_alnum(first ?? 0) {
    return false
  }

  for index in range(1, text.byte_len()) {
    let byte = text.byte_at(index)
    if byte == null {
      return false
    }

    let value = byte ?? 0
    if ! (ascii_alnum(value) or value == 45 or value == 46 or value == 95) {
      return false
    }
  }

  true
}

pure valid_endpoint_text(text: Str) -> Bool {
  if text.is_empty() or text.trim() != text or text.fields().len() != 1 {
    return false
  }

  for index in range(text.byte_len()) {
    let byte = text.byte_at(index)
    if byte == null or ascii_control(byte ?? 0) {
      return false
    }
  }

  true
}

pure valid_host_key_pin(text: Str) -> Bool {
  if ! text.starts_with("SHA256:") {
    return false
  }

  let body = text.byte_slice(7)
  if body.byte_len() != 43 {
    return false
  }

  for index in range(43) {
    let byte = body.byte_at(index)
    if byte == null {
      return false
    }

    let value = byte ?? 0
    if ! (ascii_alnum(value) or value == 43 or value == 47) {
      return false
    }
  }

  true
}

pure with_control(text: Str) -> Bool {
  for index in range(text.byte_len()) {
    let byte = text.byte_at(index)
    if byte == null or ascii_control(byte ?? 0) {
      return true
    }
  }

  false
}

pure require_utf8(field: Str, target: Path) -> Result[Unit, errors.InventoryError] {
  match target.bytes().utf8() {
    Ok(_) => Ok(),
    Err(_) => Err(errors.InventoryError.NonUtf8Path(field:, path: target)),
  }
}

proc key_path(
  host: Str,
  root: Path,
  resolved_root: Path,
  raw_key: Str,
) [fs, error] -> Result[Path, errors.InventoryError] {
  if with_control(raw_key) {
    return Err(errors.InventoryError.KeyPathEscape(host:, path: raw_key))
  }

  let parsed = match Path.parse_bytes(bytes.from_text(raw_key)) {
    Ok(value) => value,
    Err(_) => { return Err(errors.InventoryError.KeyPathEscape(host:, path: raw_key)) },
  }

  let relative = match parsed.require(RelPath) {
    Ok(value) => value,
    Err(_) => { return Err(errors.InventoryError.KeyPathEscape(host:, path: raw_key)) },
  }

  let candidate = fp"{root}/{relative}"
  let resolved = match candidate.resolve() {
    Ok(value) => value,
    Err(_) => { return Err(errors.InventoryError.MissingKey(host:, path: candidate)) },
  }

  if ! resolved.starts_with(resolved_root) {
    return Err(errors.InventoryError.KeyPathEscape(host:, path: raw_key))
  }

  require_utf8(f"hosts[{host}].key", resolved)?
  let metadata = match resolved.metadata() {
    Ok(value) => value,
    Err(_) => { return Err(errors.InventoryError.MissingKey(host:, path: resolved)) },
  }

  if metadata.kind != "file" {
    return Err(errors.InventoryError.KeyNotFile(host:, path: resolved, kind: metadata.kind))
  }

  if metadata.mode.bit_and(0o077) != 0 {
    return Err(errors.InventoryError.UnsafeKey(host:, path: resolved, mode: metadata.mode.bit_and(0o777)))
  }

  resolved
}

## Loads and validates an inventory file. Key paths resolve beneath its directory.
export proc load(file: Path) [fs, error] -> Result[Inventory, errors.InventoryError] {
  let absolute = match path.absolute(file) {
    Ok(value) => value,
    Err(error) => { return Err(errors.InventoryError.Invalid(path: file, message: error.message)) },
  }

  require_utf8("inventory", absolute)?
  let root = absolute.parent()
  let resolved_root = match root.resolve() {
    Ok(value) => value,
    Err(error) => { return Err(errors.InventoryError.Invalid(path: absolute, message: error.message)) },
  }

  let document = match toml.read(absolute) {
    Ok(value) => value,
    Err(error) => { return Err(errors.InventoryError.Invalid(path: absolute, message: error.message)) },
  }

  let raw = match document.require_exact(RawInventory) {
    Ok(value) => value,
    Err(error) => { return Err(errors.InventoryError.Invalid(path: absolute, message: error.message)) },
  }

  var declared: List[Str] = []
  for group_name in raw.groups {
    if ! valid_name(group_name) {
      return Err(
        errors.InventoryError.InvalidGroup(
          name: group_name,
          message: "group names start with a letter or digit and use only letters, digits, '.', '-', or '_'",
        ),
      )
    }

    if group_name in declared {
      return Err(errors.InventoryError.DuplicateGroup(name: group_name))
    }

    declared += [group_name]
  }

  var names: List[Str] = []
  var hosts: List[Host] = []
  for index, raw_host in raw.hosts {
    if ! valid_name(raw_host.name) {
      return Err(
        errors.InventoryError.InvalidHost(
          host: raw_host.name,
          field: f"hosts[{index}].name",
          message: "host names start with a letter or digit and use only letters, digits, '.', '-', or '_'",
        ),
      )
    }

    if raw_host.name in names {
      return Err(errors.InventoryError.DuplicateHost(name: raw_host.name))
    }

    names += [raw_host.name]
    for group_name in raw_host.groups {
      if ! valid_name(group_name) {
        return Err(
          errors.InventoryError.InvalidHost(
            host: raw_host.name,
            field: f"hosts[{index}].groups",
            message: f"invalid group reference {group_name}",
          ),
        )
      }

      if ! (group_name in declared) {
        return Err(errors.InventoryError.UnknownGroup(host: raw_host.name, group: group_name))
      }
    }

    if ! valid_endpoint_text(raw_host.address) {
      return Err(
        errors.InventoryError.InvalidHost(
          host: raw_host.name,
          field: f"hosts[{index}].address",
          message: "address must be non-empty with no whitespace or control characters",
        ),
      )
    }

    if ! valid_endpoint_text(raw_host.user) {
      return Err(
        errors.InventoryError.InvalidHost(
          host: raw_host.name,
          field: f"hosts[{index}].user",
          message: "user must be non-empty with no whitespace or control characters",
        ),
      )
    }

    if ! valid_host_key_pin(raw_host.host_key) {
      return Err(errors.InventoryError.InvalidHostKey(host: raw_host.name, pin: raw_host.host_key))
    }

    let key = key_path(raw_host.name, root, resolved_root, raw_host.key)?
    hosts += [
      Host(
        name: raw_host.name,
        groups: raw_host.groups,
        address: raw_host.address,
        port: raw_host.port,
        user: raw_host.user,
        key: key,
        host_key: raw_host.host_key,
      ),
    ]
  }

  Inventory(groups: declared, hosts: hosts)
}

## Selects hosts by name or group. Empty selectors select every host.
export pure select(inventory: Inventory, selectors: List[Str]) -> Result[List[Host], errors.InventoryError] {
  if selectors.is_empty() {
    return Ok(inventory.hosts)
  }

  for selector in selectors {
    if ! (selector in inventory.groups) and ! (inventory.hosts |> any .name == selector) {
      return Err(errors.InventoryError.UnknownSelector(selector:))
    }
  }

  var chosen: List[Str] = []
  var hosts: List[Host] = []
  for host in inventory.hosts {
    var selected = false
    for selector in selectors {
      if host.name == selector or selector in host.groups {
        selected = true
      }
    }

    if selected and ! (host.name in chosen) {
      chosen += [host.name]
      hosts += [host]
    }
  }

  hosts
}

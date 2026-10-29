##! Apply a validated first-boot identity under a caller root without writing secrets.
const hostname_re = rx"^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"
const operator_re = rx"^[a-z_][a-z0-9_-]{0,31}$"
const digits_re = rx"^[0-9]+$"
const host_key_path: RelPath = p"etc/dropbear/dropbear_ed25519_host_key"

## How the operator wants the Dropbear host key to be treated. Apply never generates one.
export enum BootIdentity { New, Restore, Clone }

## dhcp, or a static address and gateway that are both required.
export enum BootNetwork { Dhcp, Static(Str, Str) }

## One ssh-ed25519 public key from the first-boot document.
export type AuthorizedKey = {material: Str, comment: Str}

## The validated document. `trust_key` is the raw 32-byte public key, or null.
export type FirstBoot = {
  hostname: Str,
  operator: Str,
  keys: List[AuthorizedKey],
  network: BootNetwork,
  trust_key: Bytes?,
  trust_text: Str,
  tailscale: Bool,
  identity: BootIdentity,
}

proc decimal(text: Str) -> Result[Int] {
  guard digits_re.matches(text) else {
    fail f"not a decimal integer: {text}"
  }

  guard text == "0" or ! text.starts_with("0") else {
    fail f"leading zero: {text}"
  }

  text as Int
}

proc ipv4(text: Str) -> Result[Bool] {
  let parts = text.split(".")

  guard parts.len() == 4 else {
    return false
  }

  for part in parts {
    let value = decimal(part)?

    guard value >= 0 and value <= 255 else {
      return false
    }
  }

  true
}

proc cidr(text: Str) {
  let parts = text.split("/")

  guard parts.len() == 2 else {
    fail "address must be an IPv4 CIDR"
  }

  guard ipv4(parts[0]) else {
    fail "address must be an IPv4 CIDR"
  }

  let prefix = decimal(parts[1])?

  guard prefix <= 32 else {
    fail "address prefix out of range"
  }
}

proc gateway_ip(text: Str) {
  guard ! ("/" in text) else {
    fail "gateway must be an IPv4 address"
  }

  guard ipv4(text) else {
    fail "gateway must be an IPv4 address"
  }
}

proc authorized_key(value: Str) -> Result[AuthorizedKey] {
  let tokens = value.words()

  guard tokens.len() >= 2 else {
    fail "malformed authorized-key"
  }

  guard tokens[0] == "ssh-ed25519" else {
    fail "authorized-key must be ssh-ed25519"
  }

  let material = tokens[1]
  let raw = material.base64_decode()?

  guard ! raw.is_empty() else {
    fail "malformed authorized-key"
  }

  var index = 2
  let comment = collect {
    while index < tokens.len() {
      yield tokens[index]
      index += 1
    }
  }

  {material, comment: comment.join(" ")}
}

proc trust_bytes(value: Str) -> Result[Bytes] {
  let raw = value.base64_decode()?

  guard raw.len() == 32 else {
    fail "trust-key must decode to 32 bytes"
  }

  raw
}

proc take_field(seen: Map[Bool], name: Str) -> Result[Map[Bool]] {
  guard ! (seen.get(name) ?? false) else {
    fail f"duplicate field {name}"
  }

  {...seen, [name]: true}
}

## Parse and validate a first-boot document. This does not touch the filesystem.
export proc parse(document: Str) [error] -> Result[FirstBoot, Error] {
  var hostname = ""
  var operator = ""
  var network = ""
  var address = ""
  var gateway = ""
  var trust = null
  var trust_text = ""
  var tailscale = ""
  var identity = ""
  var seen: Map[Bool] = {}
  let key_lines = collect {
    for line in document.lines() {
      let trimmed = line.trim()

      if trimmed != "" {
        let parts = trimmed.split(" ", 1)
        let name = parts[0]
        let value = if parts.len() == 2 { parts[1].trim() } else { "" }

        guard value != "" else {
          fail f"missing value for {name}"
        }

        if name == "authorized-key" {
          yield value
        } else if name == "hostname" {
          seen = take_field(seen, name)?
          hostname = value
        } else if name == "operator" {
          seen = take_field(seen, name)?
          operator = value
        } else if name == "network" {
          seen = take_field(seen, name)?
          network = value
        } else if name == "address" {
          seen = take_field(seen, name)?
          address = value
        } else if name == "gateway" {
          seen = take_field(seen, name)?
          gateway = value
        } else if name == "trust-key" {
          seen = take_field(seen, name)?
          trust = trust_bytes(value)?
          trust_text = value
        } else if name == "tailscale" {
          seen = take_field(seen, name)?
          tailscale = value
        } else if name == "identity" {
          seen = take_field(seen, name)?
          identity = value
        } else {
          fail f"unknown field {name}"
        }
      }
    }
  }

  let keys = [authorized_key(value)? for value in key_lines]

  guard seen.get("hostname") ?? false else {
    fail "missing hostname"
  }

  guard hostname_re.matches(hostname) else {
    fail "invalid hostname"
  }

  guard seen.get("operator") ?? false else {
    fail "missing operator"
  }

  guard operator_re.matches(operator) and operator != "root" else {
    fail "invalid operator"
  }

  guard ! keys.is_empty() else {
    fail "at least one ssh-ed25519 authorized-key is required"
  }

  guard network == "dhcp" or network == "static" else {
    fail "network must be dhcp or static"
  }

  if network == "dhcp" {
    guard address == "" and gateway == "" else {
      fail "address and gateway are only valid for a static network"
    }
  }

  if network == "static" {
    guard address != "" else {
      fail "static network requires address"
    }

    guard gateway != "" else {
      fail "static network requires gateway"
    }

    cidr(address)
    gateway_ip(gateway)
  }

  guard tailscale == "yes" or tailscale == "no" else {
    fail "tailscale must be yes or no"
  }

  guard identity == "new" or identity == "restore" or identity == "clone" else {
    fail "identity must be new, restore, or clone"
  }

  let parsed_network = if network == "dhcp" { Dhcp } else { Static(address, gateway) }
  let parsed_identity = if identity == "new" {
    New
  } else if identity == "restore" {
    Restore
  } else {
    Clone
  }

  {
    hostname,
    operator,
    keys,
    network: parsed_network,
    trust_key: trust,
    trust_text,
    tailscale: tailscale == "yes",
    identity: parsed_identity,
  }
}

pure key_record(key: AuthorizedKey) -> Str {
  if key.comment == "" {
    f"authorized-key ssh-ed25519 {key.material}"
  } else {
    f"authorized-key ssh-ed25519 {key.material} {key.comment}"
  }
}

pure installed_key(key: AuthorizedKey) -> Str {
  if key.comment == "" {
    f"ssh-ed25519 {key.material}"
  } else {
    f"ssh-ed25519 {key.material} {key.comment}"
  }
}

pure identity_text(identity: BootIdentity) -> Str {
  match identity {
    New => "new"
    Restore => "restore"
    Clone => "clone"
  }
}

pure network_lines(network: BootNetwork) -> List[Str] {
  match network {
    Dhcp => ["network dhcp"]
    Static(address, gateway) => ["network static", f"address {address}", f"gateway {gateway}"]
  }
}

pure record_text(config: FirstBoot) -> Str {
  let keys = [key_record(key) for key in config.keys]
  let tailscale = if config.tailscale { "yes" } else { "no" }
  var lines = [f"hostname {config.hostname}", f"operator {config.operator}", @keys, @network_lines(config.network)]

  if config.trust_text != "" {
    lines += [f"trust-key {config.trust_text}"]
  }

  lines += [f"tailscale {tailscale}", f"identity {identity_text(config.identity)}"]
  lines.join("\n") + "\n"
}

pure network_text(network: BootNetwork) -> Str {
  match network {
    Dhcp => "dhcp\n"
    Static(address, gateway) => f"address {address}\ngateway {gateway}\n"
  }
}

pure passwd_has_name(body: Str, name: Str) -> Bool {
  for line in body.lines() {
    let trimmed = line.trim()

    if trimmed != "" and ! trimmed.starts_with("#") {
      let fields = trimmed.split(":")

      return true when ! fields.is_empty() and fields[0] == name
    }
  }

  false
}

pure passwd_with_operator(body: Str, name: Str) -> Str {
  let line = f"{name}:x:1000:1000::/home/{name}:/usr/bin/xsh"
  if body == "" {
    f"{line}\n"
  } else if body.ends_with("\n") {
    f"{body}{line}\n"
  } else {
    f"{body}\n{line}\n"
  }
}

proc ensure_dir(rootfs: FsRoot, rel: RelPath, mode: Int) {
  if ! rootfs.exists(rel) {
    rootfs.mkdir(rel, mode:)
    rootfs.chmod(rel, mode)
  }
}

proc write_text(rootfs: FsRoot, rel: RelPath, body: Str, mode: Int) {
  rootfs.write_atomic(rel, body)
  rootfs.chmod(rel, mode)
}

proc write_bytes(rootfs: FsRoot, rel: RelPath, body: Bytes, mode: Int) {
  rootfs.write_atomic(rel, body)
  rootfs.chmod(rel, mode)
}

proc read_optional(rootfs: FsRoot, rel: RelPath) -> Result[Str] {
  if rootfs.exists(rel) {
    rootfs.read_text(rel)?
  } else {
    ""
  }
}

proc require_identity(rootfs: FsRoot, identity: BootIdentity) {
  let present = rootfs.exists(host_key_path)?

  match identity {
    New => {}
    Restore => {
      guard present else {
        fail "restore requires the dropbear host key"
      }
    }
    Clone => {
      guard ! present else {
        fail "clone refuses an existing dropbear host key"
      }
    }
  }
}

proc write_tree(rootfs: FsRoot, config: FirstBoot) {
  let home: RelPath = fp"home/{config.operator}".require()?
  let ssh: RelPath = fp"home/{config.operator}/.ssh".require()?
  let authorized: RelPath = fp"home/{config.operator}/.ssh/authorized_keys".require()?
  ensure_dir(rootfs, p"etc", 0o755)
  ensure_dir(rootfs, p"etc/laputa", 0o755)
  ensure_dir(rootfs, p"etc/laputa/first-boot", 0o755)
  ensure_dir(rootfs, p"home", 0o755)
  ensure_dir(rootfs, home, 0o755)
  ensure_dir(rootfs, ssh, 0o700)
  write_text(rootfs, p"etc/hostname", f"{config.hostname}\n", 0o644)
  write_text(rootfs, p"etc/laputa/first-boot/applied", record_text(config), 0o644)
  write_text(rootfs, p"etc/laputa/first-boot/network", network_text(config.network), 0o644)
  let tailscale = if config.tailscale { "yes" } else { "no" }
  write_text(rootfs, p"etc/laputa/first-boot/tailscale", f"{tailscale}\n", 0o644)
  let key_text = [installed_key(key) for key in config.keys].join("\n") + "\n"
  write_text(rootfs, authorized, key_text, 0o600)
  let passwd: RelPath = p"etc/passwd"
  let existing = read_optional(rootfs, passwd)?

  if ! passwd_has_name(existing, config.operator) {
    write_text(rootfs, passwd, passwd_with_operator(existing, config.operator), 0o644)
  }

  if config.trust_key != null {
    write_bytes(rootfs, p"etc/laputa/trust-update-key", config.trust_key, 0o444)
  }
}

## Validate the document, then write only the non-secret operator files under `root`.
export proc apply(root: Path, document: Str) [fs, error] -> Result[Unit, Error] {
  let config = parse(document)?
  let rootfs = fs.open_root(root)?
  require_identity(rootfs, config.identity)
  write_tree(rootfs, config)
}

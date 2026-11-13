##! Apply a validated first-boot identity under a caller root without writing secrets.
const hostname_re = rx"^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"
const operator_re = rx"^[a-z_][a-z0-9_-]{0,31}$"
const digits_re = rx"^[0-9]+$"
## The OxiSH host key `oxish-hostkey` creates at boot and `identity` policy governs.
export const host_key_path: RelPath = p"etc/oxish/host_ed25519_key"
## The OxiSH login-mode accounts file, derived from the document's operator and authorized keys.
export const accounts_path: RelPath = p"etc/oxish/accounts"
const ed25519_blob_prefix = "AAAAC3NzaC1lZDI1NTE5AAAAI"
const operator_shell = "/usr/bin/xsh-login"
const first_account_id = 1000
const account_id_limit = 60000
const repo_key_limit = 4

## How the operator wants the OxiSH host key to be treated. Apply never generates one.
export enum BootIdentity { New, Restore, Clone }

## dhcp, or a static address and gateway that are both required.
export enum BootNetwork { Dhcp, Static(Str, Str) }

## One ssh-ed25519 public key from the first-boot document.
export type AuthorizedKey = {material: Str, comment: Str}

## The validated document. `trust_key` is the raw 32-byte public key, or null.
## `repo_keys` is the repository snapshot verification key set, empty when the
## document provisions none.
export type FirstBoot = {
  hostname: Str,
  operator: Str,
  keys: List[AuthorizedKey],
  network: BootNetwork,
  trust_key: Bytes?,
  trust_text: Str,
  repo_keys: List[Bytes],
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

  # oxish-server refuses to start on a key that is not one canonical ssh-ed25519
  # blob (4 + 11 + 4 + 32 bytes), so refuse it here, before any state is written.
  guard raw.len() == 51 and material.starts_with(ed25519_blob_prefix) and raw.base64() == material else {
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

proc ed25519_public_key(value: Str, field: Str) -> Result[Bytes] {
  let raw = value.base64_decode()?

  guard raw.len() == 32 else {
    fail f"{field} must decode to 32 bytes"
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
  var repo_keys = []
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
          trust = ed25519_public_key(value, "trust-key")?
          trust_text = value
        } else if name == "repo-key" {
          let key = ed25519_public_key(value, "repo-key")?

          guard key not in repo_keys else {
            fail "duplicate repo-key"
          }

          guard repo_keys.len() < repo_key_limit else {
            fail f"at most {repo_key_limit} repo-key fields are allowed"
          }

          repo_keys += [key]
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

  var seen_keys = []

  for key in keys {
    guard key.material not in seen_keys else {
      fail "duplicate authorized-key"
    }

    seen_keys += [key.material]
  }

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
    repo_keys,
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

# The OxiSH accounts file: one `name key` line per authorized key of the operator.
pure accounts_text(config: FirstBoot) -> Str {
  let lines = [f"{config.operator} {installed_key(key)}" for key in config.keys]
  ["# account  key", @lines].join("\n") + "\n"
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

  for key in config.repo_keys {
    lines += [f"repo-key {key.base64()}"]
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

pure append_record(body: Str, line: Str) -> Str {
  if body == "" {
    f"{line}\n"
  } else if body.ends_with("\n") {
    f"{body}{line}\n"
  } else {
    f"{body}\n{line}\n"
  }
}

pure passwd_with_operator(body: Str, name: Str, id: Int) -> Str {
  append_record(body, f"{name}:x:{id}:{id}::/home/{name}:{operator_shell}")
}

proc account_ids(body: Str, index: Int) -> Result[List[Int]] {
  collect {
    for line in body.lines() {
      let trimmed = line.trim()

      if trimmed != "" and ! trimmed.starts_with("#") {
        let fields = trimmed.split(":")

        if fields.len() > index {
          let text = fields[index]

          if digits_re.matches(text) and (text == "0" or ! text.starts_with("0")) {
            yield text as Int
          }
        }
      }
    }
  }
}

proc account_id(body: Str, name: Str) -> Result[Int] {
  for line in body.lines() {
    let trimmed = line.trim()

    if trimmed != "" and ! trimmed.starts_with("#") {
      let fields = trimmed.split(":")

      if ! fields.is_empty() and fields[0] == name {
        guard fields.len() > 2 else {
          fail "account is missing an id"
        }

        return decimal(fields[2])?
      }
    }
  }

  fail "account is missing"
}

proc next_account_id(passwd: Str, group_text: Str) -> Result[Int] {
  let used = account_ids(passwd, 2)?.extend(account_ids(group_text, 2)?)
  var id = first_account_id

  while id < account_id_limit {
    return id when ! (id in used)

    id += 1
  }

  fail "no free account id"
}

proc ensure_dir(rootfs: FsRoot, rel: RelPath, mode: Int) {
  if ! rootfs.exists(rel) {
    rootfs.mkdir(rel, mode:)
    rootfs.chmod(rel, mode)
  }
}

proc withhold_group_and_world_write(rootfs: FsRoot, rel: RelPath) {
  let mode = rootfs.stat(rel, follow_symlinks: false)?.mode.bit_and(0o7777)
  rootfs.chmod(rel, mode.bit_and(0o7755))
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

proc ensure_line(rootfs: FsRoot, rel: RelPath, line: Str, mode: Int) {
  return when ! rootfs.exists(rel)

  let body = rootfs.read_text(rel)?
  let current = rootfs.stat(rel, follow_symlinks: false)?.mode.bit_and(0o7777)

  if ! (line in body.lines()) {
    write_text(rootfs, rel, append_record(body, line), mode)
  } else if current != mode {
    rootfs.chmod(rel, mode)
  }
}

proc ensure_group_member(rootfs: FsRoot, group_name: Str, member: Str) {
  let group_rel: RelPath = p"etc/group"
  let body = read_optional(rootfs, group_rel)?
  var found = false
  var lines = []

  for line in body.lines() {
    let fields = line.split(":")

    if fields.len() == 4 and fields[0] == group_name {
      found = true
      var members = if fields[3] == "" { [] } else { fields[3].split(",") }

      if ! (member in members) {
        members += [member]
      }

      lines += [f"{fields[0]}:{fields[1]}:{fields[2]}:{members.join(",")}"]
    } else {
      lines += [line]
    }
  }

  guard found else {
    fail f"group {group_name} is missing"
  }

  let rendered = lines.join("\n") + "\n"

  if rendered != body {
    write_text(rootfs, group_rel, rendered, 0o644)
  }
}

proc ensure_account(rootfs: FsRoot, name: Str) {
  let passwd_rel: RelPath = p"etc/passwd"
  let group_rel: RelPath = p"etc/group"
  let shadow_rel: RelPath = p"etc/shadow"
  let existing = read_optional(rootfs, passwd_rel)?
  let group_body = read_optional(rootfs, group_rel)?
  let id = if passwd_has_name(existing, name) {
    account_id(existing, name)?
  } else {
    let allocated = next_account_id(existing, group_body)?
    write_text(rootfs, passwd_rel, passwd_with_operator(existing, name, allocated), 0o644)
    allocated
  }

  if rootfs.exists(group_rel) {
    ensure_line(rootfs, group_rel, f"{name}:x:{id}:", 0o644)
    ensure_group_member(rootfs, "xinit-admin", name)
  }

  if rootfs.exists(shadow_rel) {
    ensure_line(rootfs, shadow_rel, f"{name}:*:0:0:99999:7:::", 0o600)
  }

  ensure_line(rootfs, p"etc/shells", operator_shell, 0o644)
}

proc identity_ok(key_present: Bool, identity: BootIdentity) {
  match identity {
    New => {}
    Restore => {
      guard key_present else {
        fail "restore requires the oxish host key"
      }
    }
    Clone => {
      guard ! key_present else {
        fail "clone refuses an existing oxish host key"
      }
    }
  }
}

proc write_tree(rootfs: FsRoot, config: FirstBoot) {
  let home: RelPath = fp"home/{config.operator}".require()?
  ensure_dir(rootfs, p"etc", 0o755)
  ensure_dir(rootfs, p"etc/oxish", 0o755)
  ensure_dir(rootfs, p"etc/laputa", 0o755)
  ensure_dir(rootfs, p"etc/laputa/first-boot", 0o755)
  ensure_dir(rootfs, p"home", 0o755)
  ensure_dir(rootfs, home, 0o755)
  withhold_group_and_world_write(rootfs, home)
  write_text(rootfs, p"etc/hostname", f"{config.hostname}\n", 0o644)
  write_text(rootfs, p"etc/laputa/first-boot/network", network_text(config.network), 0o644)
  let tailscale = if config.tailscale { "yes" } else { "no" }
  write_text(rootfs, p"etc/laputa/first-boot/tailscale", f"{tailscale}\n", 0o644)
  write_text(rootfs, accounts_path, accounts_text(config), 0o644)
  ensure_account(rootfs, config.operator)

  if config.trust_key != null {
    write_bytes(rootfs, p"etc/laputa/trust-update-key", config.trust_key, 0o444)
  }

  if ! config.repo_keys.is_empty() {
    write_bytes(rootfs, p"etc/laputa/repo-snapshot-keys", bytes.concat(config.repo_keys), 0o444)
  }

  write_text(rootfs, p"etc/laputa/first-boot/applied", record_text(config), 0o644)
}

## Validate the document, then stage a complete replacement tree and publish
## it with one atomic rename. A writer killed before publication leaves the
## live root untouched; only uniquely named staging siblings are abandoned.
## Passing "stage" as `crash_at` fails after staging but before publication
## to exercise that path; production callers omit it.
export proc apply(root: Path, document: Str, crash_at: Str = "") [fs, error] -> Result[Unit, Error] {
  let config = parse(document)?
  let live_present = root.exists()?
  let key_present = if live_present {
    let live = fs.open_root(root)?
    live.exists(host_key_path)?
  } else {
    false
  }

  identity_ok(key_present, config.identity)

  let staging = fs.temp_sibling(root)?
  defer staging.remove(missing_ok: true)
  if live_present {
    let _ = fs.copy_tree(root, staging)?
  } else {
    staging.mkdir()
  }
  let staged = fs.open_root(staging)?
  write_tree(staged, config)
  fs.fsync(staging)?

  if crash_at == "stage" {
    fail "injected first-boot crash before publication"
  }

  if live_present {
    fs.rename_exchange(staging, root)?
  } else {
    staging.rename(to: root)?
  }
  fs.fsync(root.parent)?
}

## One explicit inode owner for a maintained state image.
export type StateInodeOwner = {path: Str, uid: Int, gid: Int}

## Derive the operator's state-image ownership from the applied document and account.
export proc state_ownership(root: Path) [fs, error] -> Result[List[StateInodeOwner], Error] {
  with tree = fs.open_root(root)? {
    guard tree.read_text(p"format")? == "laputa-maintained-state-1\n" else { fail "unsupported maintained state format" }
    let config = parse(tree.read_text(p"etc/laputa/first-boot/applied")?)?
    let accounts = [line.split(":") for line in tree.read_text(p"etc/passwd")?.lines() if line.starts_with(f"{config.operator}:")]
    guard accounts.len() == 1 and accounts[0].len() == 7 else { fail "operator account is missing or ambiguous" }
    let fields = accounts[0]
    let uid = decimal(fields[2])?
    let gid = decimal(fields[3])?
    guard uid > 0 and uid <= 65535 and gid >= 0 and gid <= 65535 else {
      fail "operator account ids are outside the supported range"
    }
    guard fields[5] == f"/home/{config.operator}" else { fail "operator home does not match the applied document" }
    let home = f"home/{config.operator}"
    for entry in ["home", home] {
      let info = tree.stat(fp"{entry}".require(RelPath)?, follow_symlinks: false)?
      guard info.kind == "dir" else { fail f"operator state path is not a dir: {entry}" }
      if entry == home { guard info.mode.bit_and(0o022) == 0 else { fail "operator home must not be group or world writable" } }
    }
    # The accounts file stays root-owned: oxish-server refuses one that is not,
    # so it is validated here but never handed to the operator.
    let oxish_accounts = tree.stat(accounts_path, follow_symlinks: false)?
    guard oxish_accounts.kind == "file" else { fail "oxish accounts is not a file" }
    guard oxish_accounts.mode.bit_and(0o022) == 0 else { fail "oxish accounts must not be group or world writable" }
    [{path: home, uid, gid}]
  }
}

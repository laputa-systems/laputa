##! TOML inventory: hosts, groups, defaults and variables, validated before
##! anything connects.

use infra.check
use infra.model

const host_name = rx"^[a-z0-9][a-z0-9._-]{0,62}$"
const host_key_pin = rx"^SHA256:[A-Za-z0-9+/]{43}$"
const host_fields = ["address", "port", "user", "key", "host_key", "privilege", "transport", "groups", "vars", "timeout_ms", "transfer_timeout_ms", "escalate_reads"]
const group_fields = ["vars"]
const default_fields = ["port", "user", "key", "host_key", "privilege", "transport", "timeout_ms", "transfer_timeout_ms", "escalate_reads", "vars"]
const top_fields = ["defaults", "hosts", "groups"]

## The hosts of an inventory in name order.
export type Inventory = {hosts: List[model.Host]}

pure table(value: Any, what: Str) -> Result[Map[Str, Any], Error] {
  ctx what { value.require(Map[Str, Any])? }
}

pure only_fields(what: Str, entries: Map[Str, Any], allowed: List[Str]) -> Result[Unit, Error] {
  for key in entries.keys() {
    guard key in allowed else {
      fail f"{what}: unknown field {key}"
    }
  }
}

pure text_of(what: Str, entries: Map[Str, Any], key: Str) -> Result[Str?, Error] {
  ctx f"{what}.{key}" { Ok(json.get(entries, [key], null).require(Str?)?) }
}

pure int_of(what: Str, entries: Map[Str, Any], key: Str) -> Result[Int?, Error] {
  ctx f"{what}.{key}" { Ok(json.get(entries, [key], null).require(Int?)?) }
}

pure bool_of(what: Str, entries: Map[Str, Any], key: Str) -> Result[Bool?, Error] {
  ctx f"{what}.{key}" { Ok(json.get(entries, [key], null).require(Bool?)?) }
}

pure list_of(what: Str, entries: Map[Str, Any], key: Str) -> Result[List[Str], Error] {
  if key not in entries.keys() {
    return Ok([])
  }

  ctx f"{what}.{key}" { Ok(entries.get(key)?.require(List[Str])?) }
}

pure vars_of(what: Str, entries: Map[Str, Any]) -> Result[Map[Str, Any], Error] {
  if "vars" not in entries.keys() {
    return Ok({})
  }

  table(entries.get("vars")?, f"{what}.vars")
}

pure privilege_of(what: Str, text: Str?) -> Result[model.Privilege, Error] {
  match text ?? "plain" {
    "plain" => Ok(model.Plain)
    "root" => Ok(model.Root)
    "doas" => Ok(model.Doas)
    else => {
      fail f"{what}.privilege must be plain, root or doas"
    }
  }
}

pure transport_of(what: Str, text: Str?) -> Result[model.TransportKind, Error] {
  match text ?? "ssh" {
    "ssh" => Ok(model.Ssh)
    "local" => Ok(model.Local)
    else => {
      fail f"{what}.transport must be ssh or local"
    }
  }
}

pure merged(base: Map[Str, Any], over: Map[Str, Any]) -> Map[Str, Any] {
  var result = base
  for {key, value} in over {
    result[key] = value
  }

  result
}

pure pick_text(own: Str?, fallback: Str?) -> Str? {
  if own != null { own } else { fallback }
}

pure pick_int(own: Int?, fallback: Int?) -> Int? {
  if own != null { own } else { fallback }
}

pure build_host(
  name: Str,
  entries: Map[Str, Any],
  defaults: Map[Str, Any],
  group_vars: Map[Str, Map[Str, Any]],
  base: Path,
) -> Result[model.Host, Error] {
  let what = f"hosts.{name}"
  guard host_name.matches(name) else {
    fail f"{what}: host names are lowercase letters, digits, dot, underscore and hyphen"
  }

  only_fields(what, entries, host_fields)?
  let transport = transport_of(what, pick_text(text_of(what, entries, "transport")?, text_of("defaults", defaults, "transport")?))?
  let address = text_of(what, entries, "address")?
  let login = pick_text(text_of(what, entries, "user")?, text_of("defaults", defaults, "user")?)
  let port = pick_int(int_of(what, entries, "port")?, int_of("defaults", defaults, "port")?)
  let key_text = pick_text(text_of(what, entries, "key")?, text_of("defaults", defaults, "key")?)
  let host_key = pick_text(text_of(what, entries, "host_key")?, text_of("defaults", defaults, "host_key")?)
  let privilege = privilege_of(what, pick_text(text_of(what, entries, "privilege")?, text_of("defaults", defaults, "privilege")?))?
  let timeout = pick_int(int_of(what, entries, "timeout_ms")?, int_of("defaults", defaults, "timeout_ms")?) ?? 10000
  let transfer = pick_int(int_of(what, entries, "transfer_timeout_ms")?, int_of("defaults", defaults, "transfer_timeout_ms")?) ?? 600000
  let reads = bool_of(what, entries, "escalate_reads")? ?? bool_of("defaults", defaults, "escalate_reads")? ?? privilege == model.Doas
  let groups = list_of(what, entries, "groups")?
  guard timeout > 0 and transfer > 0 else {
    fail f"{what}.timeout_ms and transfer_timeout_ms must be positive"
  }

  var vars = vars_of("defaults", defaults)?
  for group_name in groups {
    guard group_name in group_vars.keys() else {
      fail f"{what}: unknown group {group_name}"
    }

    vars = merged(vars, group_vars.get(group_name)?)
  }

  vars = merged(vars, vars_of(what, entries)?)
  if transport == model.Local {
    return Ok(model.Host(
      name:,
      transport:,
      address: "localhost",
      port: 0,
      user: login ?? "local",
      key: null,
      host_key: null,
      privilege:,
      groups:,
      vars:,
      timeout_ms: timeout,
      transfer_timeout_ms: transfer,
      escalate_reads: reads,
    ))
  }

  guard let wanted_address = address else {
    fail f"{what}.address is required for an ssh host"
  }

  guard let wanted_user = login else {
    fail f"{what}.user is required for an ssh host"
  }

  guard let wanted_key = key_text else {
    fail f"{what}.key is required for an ssh host"
  }

  guard let wanted_pin = host_key else {
    fail f"{what}.host_key is required for an ssh host: a SHA256 fingerprint pin"
  }

  guard host_key_pin.matches(wanted_pin) else {
    fail f"{what}.host_key must be a SHA256:<base64> fingerprint without padding"
  }

  let wanted_port = port ?? 22
  guard wanted_port >= 1 and wanted_port <= 65535 else {
    fail f"{what}.port must be 1..65535"
  }

  check.account_ok(f"{what}.user", wanted_user)?
  let key = if wanted_key.starts_with("/") { fp"{wanted_key}" } else { fp"{base}/{wanted_key}" }
  Ok(model.Host(
    name:,
    transport:,
    address: wanted_address,
    port: wanted_port,
    user: wanted_user,
    key:,
    host_key: wanted_pin,
    privilege:,
    groups:,
    vars:,
    timeout_ms: timeout,
    transfer_timeout_ms: transfer,
    escalate_reads: reads,
  ))
}

## Parse and validate inventory text. `base` is the directory relative key
## paths resolve against. Unknown fields, unknown groups, malformed pins and
## missing connection details are errors; nothing is connected.
export pure parse(text: Str, base: Path) -> Result[Inventory, Error] {
  let document = table(toml.decode(text)?, "inventory")?
  only_fields("inventory", document, top_fields)?
  let defaults = table(json.get(document, ["defaults"], {}), "defaults")?
  only_fields("defaults", defaults, default_fields)?
  var group_vars: Map[Str, Map[Str, Any]] = {}
  if "groups" in document.keys() {
    let groups = table(document.get("groups")?, "groups")?
    for key in groups.keys() {
      let entries = table(groups.get(key)?, f"groups.{key}")?
      only_fields(f"groups.{key}", entries, group_fields)?
      group_vars[key] = vars_of(f"groups.{key}", entries)?
    }
  }

  guard "hosts" in document.keys() else {
    fail "inventory has no hosts"
  }

  let hosts_table = table(document.get("hosts")?, "hosts")?
  var hosts: List[model.Host] = []
  for key in hosts_table.keys() {
    let entries = table(hosts_table.get(key)?, f"hosts.{key}")?
    hosts += [build_host(key, entries, defaults, group_vars, base)?]
  }

  guard ! hosts.is_empty() else {
    fail "inventory has no hosts"
  }

  Ok(Inventory(hosts:))
}

## Read and parse an inventory file; relative key paths resolve against its
## directory.
export proc load(file: Path) [fs, error] -> Result[Inventory, Error] {
  ctx f"loading inventory {file}" { parse(file.read_text()?, file.parent())? }
}

## Choose hosts by name or group. Every limit must name a host or a group;
## the result keeps inventory order without repeats. No limit selects all.
export pure select(inventory: Inventory, limit: List[Str]) -> Result[List[model.Host], Error] {
  if limit.is_empty() {
    return Ok(inventory.hosts)
  }

  for item in limit {
    let known = inventory.hosts |> any { |host| host.name == item or item in host.groups }
    guard known else {
      fail f"--limit {item} matches no host or group"
    }
  }

  Ok(inventory.hosts |> where { |host| limit |> any { |item| host.name == item or item in host.groups } } |> collect())
}

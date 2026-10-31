use xinfra.inventory
use xinfra.error as errors

type CaseContext = {core_dir: Path, file: Path, name: Str, temp_root: Path, xsh_bin: Path}

const PIN = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
const WEB_GROUPS = """["web"]"""

const HOST_BLOCK = """name = "web-1"
groups = ["web"]
address = "192.0.2.10"
port = 22
user = "xinfra"
key = "keys/deploy"
host_key = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
"""

pure document(groups: Str, body: Str) -> Str {
  f"""groups = {groups}

[[hosts]]
{body}"""
}

proc fixture(ctx: CaseContext, name: Str) [fs, error] -> Result[Path] {
  let root = test.temp_dir(ctx, name:)?
  let key = fp"{root}/keys/deploy"
  key.parent().mkdir(parents: true)?
  key.write("test-key\n", 0o600)?
  root
}

proc write_inventory(root: Path, text: Str) [fs, error] -> Result[Path] {
  let file = fp"{root}/inventory.toml"
  file.write(text)?
  file
}

proc rejection(root: Path, text: Str) [fs, error] -> Result[errors.InventoryError] {
  let file = write_inventory(root, text)?
  match inventory.load(file) {
    Ok(_) => Err(error.failure("inventory unexpectedly loaded")),
    Err(error) => Ok(error),
  }
}

proc expect_invalid(result: Result[errors.InventoryError], fragment: Str) [error] {
  match result? {
    errors.InventoryError.Invalid {message} => {
      test.ok(fragment in message, f"expected {fragment} in {message}")?
    }
    error => test.fail(f"expected a schema error containing {fragment}, found {error.message}")?,
  }
}

test test_loads_and_resolves_inventory_relative_key_paths { |ctx|
  let root = fixture(ctx, "inventory-load")?
  let file = write_inventory(root, document(WEB_GROUPS, HOST_BLOCK))?
  let loaded = inventory.load(file)?

  test.eq(loaded.groups, ["web"])?
  test.eq(loaded.hosts.len(), 1)?
  let host = loaded.hosts[0]
  test.eq(host.name, "web-1")?
  test.eq(host.groups, ["web"])?
  test.eq(host.address, "192.0.2.10")?
  test.eq(host.port, 22)?
  test.eq(host.user, "xinfra")?
  test.eq(host.host_key, PIN)?
  test.eq(host.key, fp"{root}/keys/deploy".resolve()?)?
}

test test_rejects_duplicate_host_names { |ctx|
  let root = fixture(ctx, "inventory-duplicate")?
  let second = "\n[[hosts]]\n" + HOST_BLOCK.replace("192.0.2.10", with: "192.0.2.11")
  let result = rejection(root, document(WEB_GROUPS, HOST_BLOCK + second))?
  match result {
    errors.InventoryError.DuplicateHost {name} => test.eq(name, "web-1")?,
    error => test.fail(f"expected duplicate host rejection, found {error.message}")?,
  }
}

test test_rejects_unknown_fields { |ctx|
  let root = fixture(ctx, "inventory-unknown-field")?
  let body = HOST_BLOCK.replace("port = 22", with: "port = 22\nfuture = true")
  expect_invalid(rejection(root, document(WEB_GROUPS, body)), "unexpected field future")

  let top = document(WEB_GROUPS, HOST_BLOCK)
    .replace("groups = [\"web\"]\n", with: "groups = [\"web\"]\nextra = true\n")
  expect_invalid(rejection(root, top), "unexpected field extra")
}

test test_rejects_bad_ports { |ctx|
  let root = fixture(ctx, "inventory-port")?
  for port in ["0", "65536", "70000", "\"22\"", "22.5"] {
    let body = HOST_BLOCK.replace("port = 22", with: f"port = {port}")
    expect_invalid(rejection(root, document(WEB_GROUPS, body)), "hosts[0].port")
  }
}

test test_rejects_missing_required_fields { |ctx|
  let root = fixture(ctx, "inventory-missing")?
  let removals = [
    {line: "address = \"192.0.2.10\"\n", field: "address"},
    {line: "port = 22\n", field: "port"},
    {line: "user = \"xinfra\"\n", field: "user"},
    {line: "key = \"keys/deploy\"\n", field: "key"},
    {line: "host_key = \"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"\n", field: "host_key"},
  ]
  for removal in removals {
    let body = HOST_BLOCK.replace(removal.line, with: "")
    expect_invalid(rejection(root, document(WEB_GROUPS, body)), f"missing required field {removal.field}")
  }
}

test test_rejects_missing_host_key_pin { |ctx|
  let root = fixture(ctx, "inventory-missing-pin")?
  let body = HOST_BLOCK.replace(
    "host_key = \"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"\n",
    with: "",
  )
  expect_invalid(rejection(root, document(WEB_GROUPS, body)), "missing required field host_key")
}

test test_rejects_malformed_host_key_pins { |ctx|
  let root = fixture(ctx, "inventory-pin")?
  let body42 = PIN.byte_slice(7, 42)
  let body44 = PIN + "A"
  let malformed = [
    "sha256:" + PIN.byte_slice(7),
    "SHA256:",
    "SHA256:short",
    "SHA256:" + body42,
    "SHA256:" + body44,
    "SHA256:" + PIN.byte_slice(7).replace("A", with: "!"),
    "SHA256:" + body42 + "=",
    "MD5:" + PIN.byte_slice(7),
  ]
  for pin in malformed {
    let body = HOST_BLOCK.replace(PIN, with: pin)
    let result = rejection(root, document(WEB_GROUPS, body))?
    match result {
      errors.InventoryError.InvalidHostKey {host: host, pin: actual} => {
        test.eq(host, "web-1")?
        test.eq(actual, pin)?
      }
      error => test.fail(f"expected malformed pin rejection, found {error.message}")?,
    }
  }
}

test test_rejects_unknown_group_references { |ctx|
  let root = fixture(ctx, "inventory-group")?
  let body = HOST_BLOCK.replace("groups = [\"web\"]\naddress", with: "groups = [\"db\"]\naddress")
  let result = rejection(root, document(WEB_GROUPS, body))?
  match result {
    errors.InventoryError.UnknownGroup {host: host, group: group_name} => {
      test.eq(host, "web-1")?
      test.eq(group_name, "db")?
    }
    error => test.fail(f"expected unknown group rejection, found {error.message}")?,
  }
}

test test_rejects_duplicate_and_invalid_group_declarations { |ctx|
  let root = fixture(ctx, "inventory-groups")?
  let duplicate = rejection(root, document("""["web", "web"]""", HOST_BLOCK))?
  match duplicate {
    errors.InventoryError.DuplicateGroup {name} => test.eq(name, "web")?,
    error => test.fail(f"expected duplicate group rejection, found {error.message}")?,
  }

  let invalid = rejection(root, document("""["web", "bad group"]""", HOST_BLOCK))?
  match invalid {
    errors.InventoryError.InvalidGroup {name} => test.eq(name, "bad group")?,
    error => test.fail(f"expected invalid group rejection, found {error.message}")?,
  }
}

test test_rejects_key_paths_that_escape_the_inventory_root { |ctx|
  let root = fixture(ctx, "inventory-escape")?
  let escapes = ["../outside", "keys/../../outside", "/etc/passwd", ""]
  for key in escapes {
    let body = HOST_BLOCK.replace("key = \"keys/deploy\"", with: f"key = \"{key}\"")
    let result = rejection(root, document(WEB_GROUPS, body))?
    match result {
      errors.InventoryError.KeyPathEscape {path: actual_path} => test.eq(actual_path, key)?,
      error => test.fail(f"expected key path escape rejection for {key}, found {error.message}")?,
    }
  }

  let control = HOST_BLOCK.replace("key = \"keys/deploy\"", with: "key = \"keys/\\tother\"")
  let result = rejection(root, document(WEB_GROUPS, control))?
  match result {
    errors.InventoryError.KeyPathEscape {path: actual_path} => test.eq(actual_path, "keys/\tother")?,
    error => test.fail(f"expected key control character rejection, found {error.message}")?,
  }
}

test test_rejects_missing_and_non_file_keys { |ctx|
  let root = fixture(ctx, "inventory-key-shape")?
  let missing = rejection(
    root,
    document(WEB_GROUPS, HOST_BLOCK.replace("keys/deploy", with: "keys/absent")),
  )?
  match missing {
    errors.InventoryError.MissingKey {host: host} => test.eq(host, "web-1")?,
    error => test.fail(f"expected missing key rejection, found {error.message}")?,
  }

  let directory = rejection(
    root,
    document(WEB_GROUPS, HOST_BLOCK.replace("keys/deploy", with: "keys")),
  )?
  match directory {
    errors.InventoryError.KeyNotFile {host: host, kind: kind} => {
      test.eq(host, "web-1")?
      test.eq(kind, "dir")?
    }
    error => test.fail(f"expected non-file key rejection, found {error.message}")?,
  }
}

test test_rejects_group_or_world_readable_keys { |ctx|
  let root = fixture(ctx, "inventory-key-mode")?
  for mode in [0o640, 0o604, 0o660, 0o666] {
    let name = f"keys/open-{mode}"
    let key = fp"{root}/{name}"
    key.write("test-key\n", mode)?
    let body = HOST_BLOCK.replace("keys/deploy", with: name)
    let result = rejection(root, document(WEB_GROUPS, body))?
    match result {
      errors.InventoryError.UnsafeKey {host: host, mode: actual} => {
        test.eq(host, "web-1")?
        test.eq(actual, mode)?
      }
      error => test.fail(f"expected unsafe key rejection for mode {mode}, found {error.message}")?,
    }
  }
}

test test_accepts_keys_without_group_or_world_access { |ctx|
  let root = fixture(ctx, "inventory-key-safe")?
  for mode in [0o600, 0o400, 0o700] {
    let name = f"keys/safe-{mode}"
    let key = fp"{root}/{name}"
    key.write("test-key\n", mode)?
    let body = HOST_BLOCK.replace("keys/deploy", with: name)
    let loaded = inventory.load(write_inventory(root, document(WEB_GROUPS, body))?)?
    test.eq(loaded.hosts[0].key, key.resolve()?)?
  }
}

test test_rejects_key_symlinks_that_leave_the_inventory_root { |ctx|
  let root = fixture(ctx, "inventory-key-symlink")?
  let outside = fp"{root}/../outside-key"
  outside.write("test-key\n", 0o600)?
  let link = fp"{root}/keys/outside"
  link.symlink(to: outside.resolve()?)?
  let body = HOST_BLOCK.replace("keys/deploy", with: "keys/outside")
  let result = rejection(root, document(WEB_GROUPS, body))?
  match result {
    errors.InventoryError.KeyPathEscape {path: actual_path} => test.eq(actual_path, "keys/outside")?,
    error => test.fail(f"expected key escape rejection, found {error.message}")?,
  }
}

test test_rejects_non_utf8_inventory_paths { |ctx|
  let root = test.temp_dir(ctx, name: "inventory-non-utf8")?
  let component = Path.parse_bytes(bytes.from_ints([98, 97, 100, 255])?)?
  let file = fp"{root}/{component}/inventory.toml"
  match inventory.load(file) {
    Ok(_) => test.fail("non-UTF-8 inventory path unexpectedly loaded")?,
    Err(errors.InventoryError.NonUtf8Path {field: field}) => test.eq(field, "inventory")?,
    Err(error) => test.fail(f"expected non-UTF-8 path rejection, found {error.message}")?,
  }
}

test test_rejects_invalid_host_names_addresses_and_users { |ctx|
  let root = fixture(ctx, "inventory-fields")?
  let cases = [
    {label: "name", text: HOST_BLOCK.replace("name = \"web-1\"", with: "name = \"web 1\""), field: "name"},
    {label: "empty name", text: HOST_BLOCK.replace("name = \"web-1\"", with: "name = \"\""), field: "name"},
    {label: "address", text: HOST_BLOCK.replace("192.0.2.10", with: "192.0.2.10 extra"), field: "address"},
    {label: "user", text: HOST_BLOCK.replace("user = \"xinfra\"", with: "user = \"two users\""), field: "user"},
  ]
  for case in cases {
    let result = rejection(root, document(WEB_GROUPS, case.text))?
    match result {
      errors.InventoryError.InvalidHost {field: actual} => test.eq(actual, f"hosts[0].{case.field}")?,
      error => test.fail(f"expected invalid {case.label} rejection, found {error.message}")?,
    }
  }
}

test test_rejects_malformed_toml { |ctx|
  let root = fixture(ctx, "inventory-toml")?
  expect_invalid(rejection(root, "groups = [\n"), "expected")
}

test test_selects_hosts_by_name_and_group { |ctx|
  let root = fixture(ctx, "inventory-select")?
  let second = HOST_BLOCK
    .replace("web-1", with: "db-1")
    .replace("groups = [\"web\"]", with: "groups = [\"db\"]")
    .replace("192.0.2.10", with: "192.0.2.11")
  let text = f"""groups = ["web", "db"]

[[hosts]]
{HOST_BLOCK}
[[hosts]]
{second}"""
  let loaded = inventory.load(write_inventory(root, text)?)?

  test.eq(inventory.select(loaded, [])?.len(), 2)?
  test.eq(inventory.select(loaded, ["web"])?.len(), 1)?
  test.eq(inventory.select(loaded, ["web"])?[0].name, "web-1")?
  test.eq(inventory.select(loaded, ["db-1"])?[0].name, "db-1")?
  test.eq(inventory.select(loaded, ["web", "web"])?.len(), 1)?
  let both = inventory.select(loaded, ["db", "web"])?
  test.eq(both.len(), 2)?
  test.eq(both[0].name, "web-1")?
  test.eq(both[1].name, "db-1")?

  match inventory.select(loaded, ["absent"]) {
    Ok(_) => test.fail("unknown selector unexpectedly resolved")?,
    Err(errors.InventoryError.UnknownSelector {selector: selector}) => test.eq(selector, "absent")?,
    Err(error) => test.fail(f"expected unknown selector rejection, found {error.message}")?,
  }
}

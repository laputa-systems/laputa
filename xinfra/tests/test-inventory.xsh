use infra.inventory
use infra.model

const pin = "SHA256:aBQj3QAmCCdKKRQpB/xpoi4aeSOjR5GkDQiWxZCPq6U"

pure names(hosts: List[model.Host]) -> List[Str] {
  hosts |> map { |host| host.name } |> collect()
}

pure refused(result: Result[inventory.Inventory, Error], needle: Str) -> Bool {
  match result {
    Ok(_) => false
    Err(error) => needle in error.message
  }
}

const complete = """
[defaults]
user = "deploy"
port = 2222
privilege = "doas"
key = "keys/id"
timeout_ms = 5000

[defaults.vars]
region = "lab"
tier = "default"

[groups.web.vars]
tier = "web"

[hosts.web-1]
address = "10.0.0.11"
host_key = "SHA256:aBQj3QAmCCdKKRQpB/xpoi4aeSOjR5GkDQiWxZCPq6U"
groups = ["web"]

[hosts.web-1.vars]
index = 1

[hosts.db-1]
address = "10.0.0.21"
port = 22
user = "root"
privilege = "root"
key = "/abs/key"
host_key = "SHA256:aBQj3QAmCCdKKRQpB/xpoi4aeSOjR5GkDQiWxZCPq6U"
escalate_reads = true
"""

test hosts_inherit_defaults_and_override_them {
  let loaded = inventory.parse(complete, p"/etc/xinfra")?
  assert names(loaded.hosts) == ["db-1", "web-1"]
  let web = loaded.hosts[1]
  assert web.address == "10.0.0.11"
  assert web.port == 2222
  assert web.user == "deploy"
  assert web.privilege == model.Doas
  assert web.timeout_ms == 5000
  assert web.key == p"/etc/xinfra/keys/id"
  assert web.groups == ["web"]
  assert web.escalate_reads
  let db = loaded.hosts[0]
  assert db.port == 22
  assert db.user == "root"
  assert db.privilege == model.Root
  assert db.key == p"/abs/key"
  assert db.escalate_reads
}

test variables_merge_defaults_then_groups_then_the_host {
  let loaded = inventory.parse(complete, p"/etc/xinfra")?
  let web = loaded.hosts[1]
  assert web.vars.get("region")?.require(Str)? == "lab"
  assert web.vars.get("tier")?.require(Str)? == "web"
  assert web.vars.get("index")?.require(Int)? == 1
  let db = loaded.hosts[0]
  assert db.vars.get("tier")?.require(Str)? == "default"
}

test an_ssh_host_must_pin_its_key_and_name_its_login {
  let base = "[hosts.a]\naddress = \"1.2.3.4\"\nuser = \"deploy\"\nkey = \"k\"\n"
  assert refused(inventory.parse(base, p"/x"), "host_key is required")
  assert refused(inventory.parse(base + "host_key = \"SHA256:short\"\n", p"/x"), "fingerprint")
  assert refused(inventory.parse(f"[hosts.a]\nuser = \"deploy\"\nkey = \"k\"\nhost_key = \"{pin}\"\n", p"/x"), "address is required")
  assert refused(inventory.parse(base.replace("user = \"deploy\"\n", with: "") + f"host_key = \"{pin}\"\n", p"/x"), "user is required")
  assert inventory.parse(base + "host_key = \"" + pin + "\"\n", p"/x") is Ok(_)
}

test unknown_fields_groups_and_values_are_errors {
  let pinned = "address = \"1.2.3.4\"\nuser = \"deploy\"\nkey = \"k\"\nhost_key = \"" + pin + "\"\n"
  assert refused(inventory.parse("[hosts.a]\n" + pinned + "bogus = 1\n", p"/x"), "unknown field bogus")
  assert refused(inventory.parse("[hosts.a]\n" + pinned + "groups = [\"ghost\"]\n", p"/x"), "unknown group ghost")
  assert refused(inventory.parse("[hosts.a]\n" + pinned + "port = 70000\n", p"/x"), "port must be")
  assert refused(inventory.parse("[hosts.a]\n" + pinned + "privilege = \"sudo\"\n", p"/x"), "privilege must be")
  assert refused(inventory.parse("[hosts.a]\n" + pinned + "port = \"22\"\n", p"/x"), "hosts.a.port")
  assert refused(inventory.parse("[hosts.A]\n" + pinned, p"/x"), "host names are")
  assert refused(inventory.parse("[extra]\n[hosts.a]\n" + pinned, p"/x"), "unknown field extra")
  assert refused(inventory.parse("", p"/x"), "no hosts")
}

test a_local_host_needs_no_connection_details {
  let loaded = inventory.parse("[hosts.here]\ntransport = \"local\"\n", p"/x")?
  assert loaded.hosts[0].transport == model.Local
  assert loaded.hosts[0].key == null
}

test limits_select_hosts_or_groups_and_reject_unknown_names {
  let loaded = inventory.parse(complete, p"/etc/xinfra")?
  let all = inventory.select(loaded, [])?
  assert all.len() == 2
  let by_group = inventory.select(loaded, ["web"])?
  assert names(by_group) == ["web-1"]
  let both = inventory.select(loaded, ["web-1", "db-1", "web"])?
  assert names(both) == ["db-1", "web-1"]
  assert inventory.select(loaded, ["ghost"]) is Err(_)
}

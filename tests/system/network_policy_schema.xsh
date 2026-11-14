use packages.laputa-net.network_plan as policy

type NetworkSchemaCommand = {code: Int, stdout: Str, stderr: Str}

const base_intent = r"""{"ifindex":7,"name":"veth-test","address":{"local":"192.0.2.3","prefix":24},"gateway":"192.0.2.1","metric":100}"""
const base_owned = r"""{"ifindex":7,"name":"veth-test","addresses":[{"local":"192.0.2.2","prefix":24}],"routes":[{"gateway":"192.0.2.1","metric":100}]}"""
const base_observed = r"""{"sequence":1,"ifindex":7,"name":"veth-test","kind":"veth","up":true,"addresses":[{"local":"192.0.2.2","prefix":24}],"routes":[{"gateway":"192.0.2.1","metric":100}]}"""

pure document(intent: Str, owned: Str, observed: Str) -> Str {
  f"""{{"intent":{intent},"owned":{owned},"observed":{observed}}}"""
}

pure base_document() -> Str {
  document(base_intent, base_owned, base_observed)
}

pure with_intent(intent: Str) -> Str {
  document(intent, base_owned, base_observed)
}

pure with_owned(owned: Str) -> Str {
  document(base_intent, owned, base_observed)
}

pure with_observed(observed: Str) -> Str {
  document(base_intent, base_owned, observed)
}

pure intent_with(address: Str, metric: Int, ifindex: Int) -> Str {
  f"""{{"ifindex":{ifindex},"name":"veth-test","address":{address},"gateway":"192.0.2.1","metric":{metric}}}"""
}

pure with_top_level_field(field: Str) -> Str {
  let base = base_document()
  base.byte_slice(0, base.byte_len() - 1) + "," + field + "}"
}

pure without_owned() -> Str {
  base_document().replace(f""","owned":{base_owned}""", with: "")
}

proc run_planner(ctx: TestContext, text: Str) -> Result[NetworkSchemaCommand, Error] {
  let root = test.temp_dir(ctx, name: "network-schema")?
  let input = fp"{root}/input.json"
  let stdout = fp"{root}/stdout"
  let stderr = fp"{root}/stderr"
  input.write(text)
  let script = p"packages/laputa-net/network_plan.xsh".resolve()?
  let argv = [ctx.xsh_bin.display(), script.display(), input.display()]
  let status = process.run(process.command_argv(ctx.xsh_bin, argv, stdout:, stderr:, timeout: 5s))?
  Ok({code: status.shell_code()?, stdout: stdout.read_text()?, stderr: stderr.read_text()?})
}

test test_valid_input_decodes_and_plans_the_same_changes [fs, process, error] { |ctx|
  let text = base_document()
  let data = policy.network_decode_input(text)?
  let plan = policy.network_plan(data.intent, data.owned, data.observed)?
  assert plan.operations == [
    policy.NetworkAddAddress({local: "192.0.2.3", prefix: 24}),
    policy.NetworkRemoveAddress({local: "192.0.2.2", prefix: 24}),
  ]
  let ran = run_planner(ctx, text)?
  assert ran.code == 0, ran.stderr
  assert "add address 192.0.2.3/24" in ran.stdout, ran.stdout
}

test test_ipv6_fixture_plans_through_the_command_and_rejects_a_noncanonical_address [fs, process, error] { |ctx|
  let text = policy.network_read_input(p"tests/system/fixtures/network-policy-ipv6.json")?
  let ran = run_planner(ctx, text)?
  assert ran.code == 0, ran.stderr
  assert "add address 2001:db8:1::3/64" in ran.stdout, ran.stdout
  assert "add default via fe80::1 metric 1024" in ran.stdout, ran.stdout
  assert "remove owned default via 2001:db8:1::1 metric 300" in ran.stdout, ran.stdout
  assert "2001:db8:ff::2" not in ran.stdout and "2001:db8:ff::1" not in ran.stdout, ran.stdout
  let upper = text.replace("2001:db8:1::3", with: "2001:DB8:1::3")
  let refused = run_planner(ctx, upper)?
  assert refused.code != 0
  assert refused.stdout == "", refused.stdout
  assert "invalid IPv6 intent" in refused.stderr, refused.stderr
}

test test_unknown_fields_are_rejected_at_every_depth_with_their_path [fs, process, error] { |ctx|
  let cases = [
    {text: with_top_level_field("\"extra\":1"), field: "extra"},
    {text: with_intent(r"""{"ifindex":7,"name":"veth-test","address":{"local":"192.0.2.3","prefix":24},"gateway":"192.0.2.1","metric":100,"mtu":1500}"""), field: "intent.mtu"},
    {text: with_observed(r"""{"sequence":1,"ifindex":7,"name":"veth-test","kind":"veth","up":true,"addresses":[{"local":"192.0.2.2","prefix":24,"label":"eth0"}],"routes":[]}"""), field: "observed.addresses[0].label"},
    {text: with_owned(r"""{"ifindex":7,"name":"veth-test","addresses":[],"routes":[{"gateway":"192.0.2.1","metric":100,"table":254}]}"""), field: "owned.routes[0].table"},
  ]
  for {text, field} in cases {
    match policy.network_decode_input(text) {
      Ok(_) => assert false, f"accepted unknown field at {field}"
      Err(problem) => {
        test.error_kind(problem, "schema")
        assert f"at {field}: unexpected field" in problem.message, problem.message
      }
    }
    let ran = run_planner(ctx, text)?
    assert ran.code != 0
    assert ran.stdout == "", ran.stdout
    assert f"at {field}: unexpected field" in ran.stderr, ran.stderr
  }
}

test test_duplicate_fields_are_rejected_before_schema_validation [error] {
  let cases = [
    with_top_level_field(r"""  "intent":{}"""),
    with_intent(r"""{"ifindex":7,"ifindex":8,"name":"veth-test","address":{"local":"192.0.2.3","prefix":24},"gateway":"192.0.2.1","metric":100}"""),
    with_observed(r"""{"sequence":1,"ifindex":7,"name":"veth-test","kind":"veth","up":true,"addresses":[{"local":"192.0.2.2","local":"192.0.2.9","prefix":24}],"routes":[]}"""),
  ]
  for text in cases {
    match policy.network_decode_input(text) {
      Ok(_) => assert false, "accepted a duplicate field"
      Err(problem) => {
        test.error_kind(problem, "CodecError.DuplicateKey")
        assert "duplicate key" in problem.message, problem.message
      }
    }
  }
}

test test_missing_fields_differ_from_null_fields [error] {
  let missing = [
    {text: with_intent(r"""{"ifindex":7,"name":"veth-test","address":{"local":"192.0.2.3","prefix":24},"metric":100}"""), message: "at intent: missing required field gateway"},
    {text: with_observed(r"""{"sequence":1,"ifindex":7,"name":"veth-test","kind":"veth","addresses":[],"routes":[]}"""), message: "at observed: missing required field up"},
    {text: without_owned(), message: "at $: missing required field owned"},
  ]
  for {text, message} in missing {
    match policy.network_decode_input(text) {
      Ok(_) => assert false, f"accepted a missing field: {message}"
      Err(problem) => {
        test.error_kind(problem, "schema")
        assert message in problem.message, problem.message
      }
    }
  }
  let nulls = [
    {text: with_intent(r"""{"ifindex":7,"name":"veth-test","address":{"local":"192.0.2.3","prefix":24},"gateway":null,"metric":100}"""), message: "at intent.gateway: expected Str, found Null"},
    {text: with_observed(r"""{"sequence":1,"ifindex":7,"name":"veth-test","kind":"veth","up":null,"addresses":[],"routes":[]}"""), message: "at observed.up: expected Bool, found Null"},
    {text: with_owned("null"), message: "at owned"},
  ]
  for {text, message} in nulls {
    match policy.network_decode_input(text) {
      Ok(_) => assert false, f"accepted a null field: {message}"
      Err(problem) => {
        test.error_kind(problem, "schema")
        assert message in problem.message, problem.message
        assert "missing required field" not in problem.message, problem.message
      }
    }
  }
}

test test_unsupported_representations_never_coerce [error] {
  let cases = [
    {text: with_intent(r"""{"ifindex":"7","name":"veth-test","address":{"local":"192.0.2.3","prefix":24},"gateway":"192.0.2.1","metric":100}"""), message: "at intent.ifindex: expected Int, found Str"},
    {text: with_intent(r"""{"ifindex":7,"name":"veth-test","address":{"local":"192.0.2.3","prefix":24.5},"gateway":"192.0.2.1","metric":100}"""), message: "at intent.address.prefix: expected Int"},
    {text: with_intent(r"""{"ifindex":7,"name":"veth-test","address":{"local":"192.0.2.3","prefix":true},"gateway":"192.0.2.1","metric":100}"""), message: "at intent.address.prefix: expected Int, found Bool"},
    {text: with_intent(r"""{"ifindex":7,"name":7,"address":{"local":"192.0.2.3","prefix":24},"gateway":"192.0.2.1","metric":100}"""), message: "at intent.name: expected Str, found Int"},
    {text: with_observed(r"""{"sequence":1,"ifindex":7,"name":"veth-test","kind":"veth","up":1,"addresses":[],"routes":[]}"""), message: "at observed.up: expected Bool, found Int"},
    {text: with_observed(r"""{"sequence":1,"ifindex":7,"name":"veth-test","kind":"veth","up":true,"addresses":{"local":"192.0.2.2","prefix":24},"routes":[]}"""), message: "at observed.addresses"},
  ]
  for {text, message} in cases {
    match policy.network_decode_input(text) {
      Ok(_) => assert false, f"accepted an unsupported representation: {message}"
      Err(problem) => {
        test.error_kind(problem, "schema")
        assert message in problem.message, problem.message
      }
    }
  }
  match policy.network_decode_input(with_intent(r"""{"ifindex":99999999999999999999,"name":"veth-test","address":{"local":"192.0.2.3","prefix":24},"gateway":"192.0.2.1","metric":100}""")) {
    Ok(_) => assert false, "accepted an integer beyond i64"
    Err(problem) => test.error_kind(problem, "CodecError.Overflow")
  }
}

test test_invalid_ranges_and_variants_fail_before_any_operation_is_planned [fs, process, error] { |ctx|
  let cases = [
    {text: with_observed(r"""{"sequence":1,"ifindex":7,"name":"veth-test","kind":"bridge","up":true,"addresses":[],"routes":[]}"""), message: "only veth and dummy"},
    {text: with_observed(r"""{"sequence":-1,"ifindex":7,"name":"veth-test","kind":"veth","up":true,"addresses":[],"routes":[]}"""), message: "invalid IPv4 intent"},
    {text: with_intent(intent_with(r"""{"local":"192.0.2.3","prefix":33}""", 100, 7)), message: "invalid IPv4 intent"},
    {text: with_intent(intent_with(r"""{"local":"192.0.2.3","prefix":0}""", 100, 7)), message: "invalid IPv4 intent"},
    {text: with_intent(intent_with(r"""{"local":"192.0.2.256","prefix":24}""", 100, 7)), message: "invalid IPv4 intent"},
    {text: with_intent(intent_with(r"""{"local":"192.0.02.3","prefix":24}""", 100, 7)), message: "invalid IPv4 intent"},
    {text: with_intent(intent_with(r"""{"local":"192.0.2.3","prefix":24}""", -1, 7)), message: "invalid IPv4 intent"},
    {text: with_intent(intent_with(r"""{"local":"192.0.2.3","prefix":24}""", 100, 0)), message: "link identity mismatch"},
  ]
  for {text, message} in cases {
    let data = policy.network_decode_input(text)?
    match policy.network_plan(data.intent, data.owned, data.observed) {
      Ok(plan) => assert false, f"planned {plan.operations.len()} operations for: {message}"
      Err(problem) => assert message in problem.message, problem.message
    }
    let ran = run_planner(ctx, text)?
    assert ran.code != 0
    assert ran.stdout == "", ran.stdout
    assert message in ran.stderr, ran.stderr
  }
}

test test_self_describing_formats_normalize_to_the_json_value [fs, error] {
  let expected = policy.network_decode_input(p"tests/system/fixtures/network-policy-conflict.json".read_text()?)?
  let yaml_text = """
intent:
  ifindex: 7
  name: veth-test
  address: {local: 192.0.2.3, prefix: 24}
  gateway: 192.0.2.1
  metric: 100
owned:
  ifindex: 7
  name: veth-test
  addresses: [{local: 192.0.2.2, prefix: 24}]
  routes: [{gateway: 192.0.2.1, metric: 100}]
observed:
  sequence: 1
  ifindex: 7
  name: veth-test
  kind: veth
  up: true
  addresses:
    - {local: 192.0.2.2, prefix: 24}
    - {local: 198.51.100.2, prefix: 24}
  routes:
    - {gateway: 192.0.2.1, metric: 100}
    - {gateway: 198.51.100.1, metric: 200}
"""
  let toml_text = """
[intent]
ifindex = 7
name = "veth-test"
gateway = "192.0.2.1"
metric = 100
[intent.address]
local = "192.0.2.3"
prefix = 24
[owned]
ifindex = 7
name = "veth-test"
addresses = [{local = "192.0.2.2", prefix = 24}]
routes = [{gateway = "192.0.2.1", metric = 100}]
[observed]
sequence = 1
ifindex = 7
name = "veth-test"
kind = "veth"
up = true
addresses = [{local = "192.0.2.2", prefix = 24}, {local = "198.51.100.2", prefix = 24}]
routes = [{gateway = "192.0.2.1", metric = 100}, {gateway = "198.51.100.1", metric = 200}]
"""
  for {format, text} in [{format: "yaml", text: yaml_text}, {format: "toml", text: toml_text}] {
    let decoded: policy.NetworkPlanInput = codec.decode(format, text)?.require_exact()?
    assert decoded == expected, format
  }
  let quoted = yaml_text.replace("prefix: 24}\n  gateway", with: "prefix: '24'}\n  gateway")
  match codec.decode("yaml", quoted)?.require_exact(policy.NetworkPlanInput) {
    Ok(_) => assert false, "YAML quoted number became an Int"
    Err(problem) => assert "at intent.address.prefix: expected Int, found Str" in problem.message, problem.message
  }
  match codec.decode("yaml", yaml_text + "\nextra: 1\n")?.require_exact(policy.NetworkPlanInput) {
    Ok(_) => assert false, "YAML unknown field accepted"
    Err(problem) => assert "at extra: unexpected field" in problem.message, problem.message
  }
  match codec.decode("toml", toml_text.replace("up = true", with: "up = 1979-05-27T07:32:00Z")) {
    Ok(_) => assert false, "TOML calendar value accepted"
    Err(problem) => test.error_kind(problem, "CodecError.UnsupportedValue")
  }
}

test test_lexical_formats_convert_only_through_an_explicit_schema [error] {
  let expected = policy.NetworkAddress("192.0.2.3", 24)
  let decoded: policy.NetworkAddress = codec.decode_as("ini", "local=192.0.2.3\nprefix=24\n", policy.NetworkAddress)?
  assert decoded == expected
  match codec.decode("ini", "local=192.0.2.3\nprefix=24\n")?.require_exact(policy.NetworkAddress) {
    Ok(_) => assert false, "INI text became an Int without an explicit schema"
    Err(problem) => assert "at prefix: expected Int, found Str" in problem.message, problem.message
  }
  for text in ["local=192.0.2.3\nprefix=24x\n", "local=192.0.2.3\nprefix=0x18\n", "local=192.0.2.3\nprefix=\n"] {
    match codec.decode_as("ini", text, policy.NetworkAddress) {
      Ok(_) => assert false, f"lexical admission accepted {text}"
      Err(problem) => test.error_kind(problem, "CodecError.Schema")
    }
  }
  let table: List[policy.NetworkAddress] = codec.decode_as("csv", "local,prefix\n192.0.2.3,24\n192.0.2.2,24\n", List[policy.NetworkAddress])?
  assert table == [expected, {local: "192.0.2.2", prefix: 24}]
}

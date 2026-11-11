const deploy_source = r"""
##! A deployment driven by host variables.

use infra.declare
use infra.model

## The resources one host should have.
export proc resources(host: model.Host) [fs, error] -> Result[List[model.Resource], Error] {
  let root = host.vars.get("root")?.require(Str)?
  [
    declare.directory(id: "root", at: root)?,
    declare.file(id: "motd", at: f"{root}/motd", text: "hello\n", needs: ["root"])?,
  ]
}
"""

const broken_source = r"""
##! A deployment with a dependency cycle.

use infra.declare
use infra.model

## The resources one host should have.
export proc resources(host: model.Host) [fs, error] -> Result[List[model.Resource], Error] {
  [
    declare.directory(id: "a", at: "/tmp/xinfra-never-a", needs: ["b"])?,
    declare.directory(id: "b", at: "/tmp/xinfra-never-b", needs: ["a"])?,
  ]
}
"""

proc inventory_for(dir: Path) [fs, error] -> Result[Path, Error] {
  let file = fp"{dir}/inventory.toml"
  file.write(f"[hosts.here]\ntransport = \"local\"\n[hosts.here.vars]\nroot = \"{dir}/target\"\n")
  Ok(file)
}

proc deploy_in(dir: Path, source: Str) [fs, error] -> Result[Path, Error] {
  let file = fp"{dir}/deploy.xsh"
  file.write(source)
  Ok(file)
}

type Invocation = {status: Status, stdout: Str, stderr: Str}

proc xinfra(...args: List[Str]) [process, error] -> Result[Invocation, Error] {
  let out = run.capture --text xsh bin/xinfra.xsh @args
  Ok(Invocation(status: out.status, stdout: out.stdout, stderr: out.stderr))
}

test a_plan_changes_nothing_and_check_exits_one_on_drift { |ctx|
  let dir = test.temp_dir(ctx)?
  let inventory = inventory_for(dir)?
  let deploy = deploy_in(dir, deploy_source)?
  let lock = f"{dir}/lock-{{host}}"
  let planned = xinfra("plan", f"{inventory}", f"{deploy}", "--lock-path", lock)?
  assert planned.status.exit_code()? == 0
  assert "drift: create" in planned.stdout
  assert ! fp"{dir}/target".exists()?
  let checked = xinfra("check", f"{inventory}", f"{deploy}", "--lock-path", lock)?
  assert checked.status.exit_code()? == 1
  let applied = xinfra("apply", f"{inventory}", f"{deploy}", "--lock-path", lock)?
  assert applied.status.exit_code()? == 0
  assert fp"{dir}/target/motd".read_text()? == "hello\n"
  let compliant = xinfra("check", f"{inventory}", f"{deploy}", "--lock-path", lock)?
  assert compliant.status.exit_code()? == 0
}

test reports_come_as_a_json_document_or_json_lines { |ctx|
  let dir = test.temp_dir(ctx)?
  let inventory = inventory_for(dir)?
  let deploy = deploy_in(dir, deploy_source)?
  let lock = f"{dir}/lock-{{host}}"
  let document = xinfra("plan", f"{inventory}", f"{deploy}", "--lock-path", lock, "--format", "json")?
  let parsed = json.decode(document.stdout)?.require(Record)?
  assert parsed.get("mode")?.require(Str)? == "plan"
  let lines = xinfra("apply", f"{inventory}", f"{deploy}", "--lock-path", lock, "--format", "jsonl")?.stdout.lines()
  assert lines.len() == 3
  for line in lines {
    assert "type" in json.decode(line)?.require(Record)?.keys()
  }
  let summary = json.decode(lines[2])?.require(Record)?
  assert summary.get("exit")?.require(Int)? == 0
}

test invalid_input_exits_two_before_any_host_is_touched { |ctx|
  let dir = test.temp_dir(ctx)?
  let inventory = inventory_for(dir)?
  let deploy = deploy_in(dir, deploy_source)?
  let broken = fp"{dir}/broken.xsh"
  broken.write(broken_source)
  let lock = f"{dir}/lock-{{host}}"
  let cycle = xinfra("apply", f"{inventory}", f"{broken}", "--lock-path", lock)?
  assert cycle.status.exit_code()? == 2
  assert "dependency cycle" in cycle.stderr
  assert ! fp"/tmp/xinfra-never-a".exists()?
  let unknown = xinfra("apply", f"{inventory}", f"{deploy}", "--limit", "nowhere", "--lock-path", lock)?
  assert unknown.status.exit_code()? == 2
  assert "matches no host or group" in unknown.stderr
  let format = xinfra("plan", f"{inventory}", f"{deploy}", "--format", "xml")?
  assert format.status.exit_code()? == 2
  let missing = xinfra("plan", f"{dir}/nope.toml", f"{deploy}")?
  assert missing.status.exit_code()? == 2
  assert ! fp"{dir}/target".exists()?
}

test a_deployment_that_is_not_a_module_with_resources_is_refused { |ctx|
  let dir = test.temp_dir(ctx)?
  let inventory = inventory_for(dir)?
  let empty = deploy_in(dir, "##! nothing here\n")?
  let refused = xinfra("plan", f"{inventory}", f"{empty}")?
  assert refused.status.exit_code()? == 2
  assert "resources" in refused.stderr
}

use support.fake_host as fake
use xinfra.cli as command_line
use xinfra.host
use xinfra.model
use xinfra.outcome
use xinfra.plan
use xinfra.redact
use xinfra.report

const PIN = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

type HostSeed = {name: Str, groups: List[Str], address: Str}

type DeploymentFixture = {root: Path, file: Path}

type CaseContext = {core_dir: Path, file: Path, name: Str, temp_root: Path, xsh_bin: Path}

type JsonSummary = {
  schema_version: Int,
  kind: Str,
  run_id: Str,
  hosts: List[Str],
  unchanged: Int,
  changed: Int,
  skipped: Int,
  blocked: Int,
  failed: Int,
  unknown: Int,
  partial: Int,
  exit: Int,
}

type JsonReport = {
  schema_version: Int,
  kind: Str,
  run_id: Str,
  results: List[Any],
  summary: JsonSummary,
}

type JsonKind = {schema_version: Int, kind: Str}

type JsonPlan = {schema_version: Int, kind: Str, xsh_pin: Str}

proc parse_ok(argv: List[Str]) -> Result[command_line.Options, Error] {
  match command_line.parse(argv) {
    Ok(value) => Ok(value),
    Err(problem) => Err(error.failure(problem.message)),
  }
}

proc expect_parse_error(argv: List[Str], kind: Str = "usage") [error] {
  match command_line.parse(argv) {
    Ok(_) => test.fail("arguments unexpectedly parsed")?,
    Err(problem) => test.eq(problem.kind, kind)?,
  }
}

proc write_inventory(ctx: CaseContext, name: Str, hosts: List[HostSeed]) [fs, error] -> Result[Path] {
  let root = test.temp_dir(ctx, name)?
  let key = fp"{root}/keys/deploy"
  key.parent().mkdir(parents: true)?
  key.write("test-key\n", 0o600)?

  var groups: List[Str] = []
  for host in hosts {
    for group_name in host.groups {
      if ! (group_name in groups) {
        groups += [group_name]
      }
    }
  }

  var text = f"groups = {json.encode(groups)?}\n"
  for host in hosts {
    text += f"""
[[hosts]]
name = "{host.name}"
groups = {json.encode(host.groups)?}
address = "{host.address}"
port = 22
user = "xinfra"
key = "keys/deploy"
host_key = "{PIN}"
"""
    text += "\n"
  }

  let file = fp"{root}/inventory.toml"
  file.write(text)?
  Ok(file)
}

proc deployment(ctx: CaseContext, name: Str, resources: Str) [fs, error] -> Result[DeploymentFixture] {
  let root = test.temp_dir(ctx, name)?
  let file = fp"{root}/deploy.xsh"
  file.write(
    f"""##! Test deployment.
use xinfra.model

## Returns the declared resources.
export pure resources() -> List[model.Resource] {{
{resources}
}}
""",
  )?
  Ok(DeploymentFixture(root: root, file: file))
}

proc invoke(
  argv: List[Str],
  ops: host.HostOps?,
  root: Path,
  run_id: Str = "run-test",
) -> command_line.Execution {
  command_line.execute(argv, ops, root, run_id)
}

proc decoded_report(execution: command_line.Execution) -> Result[JsonReport, Error] {
  json.decode(execution.stdout)?.require(JsonReport)
}

proc decoded_lines(execution: command_line.Execution) -> Result[List[JsonKind], Error] {
  var decoded: List[JsonKind] = []
  for line in execution.stdout.lines() {
    if ! line.is_empty() {
      decoded += [json.decode(line)?.require(JsonKind)?]
    }
  }

  Ok(decoded)
}

proc tree(root: Path) [fs, error] -> Result[List[Str]] {
  var names: List[Str] = []
  for entry in fs.walk(root, hidden: true)?.collect() {
    names += [entry.path.relative_to(root).display()]
  }

  Ok(names)
}

test test_parse_defaults_and_bounds { |ctx|
  let options = parse_ok(["apply", "--inventory", "inv.toml", "--deploy", "deploy.xsh"])?
  test.eq(options.jobs, 8)?
  test.eq(options.on_error, command_line.Isolate)?
  test.eq(options.style, report.Human)?
  test.eq(options.limit, [])?
  test.eq(options.exclude, [])?

  let wide = parse_ok(
    [
      "apply",
      "--inventory",
      "inv.toml",
      "--deploy",
      "deploy.xsh",
      "--jobs",
      "64",
      "--on-error",
      "abort",
      "--format",
      "jsonl",
      "--limit",
      "web,db",
      "--exclude",
      "db-1",
    ],
  )?
  test.eq(wide.jobs, 64)?
  test.eq(wide.on_error, command_line.Abort)?
  test.eq(wide.style, report.Jsonl)?
  test.eq(wide.limit, ["web", "db"])?
  test.eq(wide.exclude, ["db-1"])?

  expect_parse_error(["apply", "--inventory", "i", "--deploy", "d", "--jobs", "65"])
  expect_parse_error(["apply", "--inventory", "i", "--deploy", "d", "--jobs", "0"])
  expect_parse_error(["apply", "--inventory", "i", "--deploy", "d", "--jobs", "many"])
  expect_parse_error(["apply", "--inventory", "i", "--deploy", "d", "--on-error", "retry"])
  expect_parse_error(["apply", "--inventory", "i", "--deploy", "d", "--format", "yaml"])
  expect_parse_error(["plan", "--inventory", "i"])
  expect_parse_error(["doctor"])
}

test test_help_for_every_command { |ctx|
  let general = invoke(["--help"], null, p".")
  test.eq(general.exit, 0)?
  test.ok("Usage:" in general.stdout)?
  test.ok("doctor" in general.stdout)?
  test.ok("unlock" in general.stdout)?

  for command in ["doctor", "plan", "apply", "check", "unlock"] {
    let result = invoke([command, "--help"], null, p".")
    test.eq(result.exit, 0)?
    test.ok("Usage:" in result.stdout)?
    test.ok(command in result.stdout)?
  }

  let named = invoke(["help", "apply"], null, p".")
  test.eq(named.exit, 0)?
  test.ok("xinfra apply" in named.stdout)?
}

test test_plan_computes_and_reports_hosts { |ctx|
  let inventory_file = write_inventory(
    ctx,
    "cli-plan-inv",
    [
      HostSeed(name: "web-1", groups: ["web"], address: "192.0.2.10"),
      HostSeed(name: "db-1", groups: ["db"], address: "192.0.2.11"),
    ],
  )?
  let fixture = deployment(
    ctx,
    "cli-plan-deploy",
    """[
  model.Directory(model.DirectorySpec(id: "srv", path: p"/srv")),
]""",
  )?
  let result = invoke(
    ["plan", "--inventory", inventory_file.display(), "--deploy", fixture.file.display(), "--format", "json"],
    null,
    fixture.root,
  )
  test.eq(result.exit, 0, result.stderr)?
  let report = decoded_report(result)?
  test.eq(report.kind, "report")?
  test.eq(report.schema_version, 1)?
  test.eq(report.summary.exit, 0)?
  test.eq(report.summary.unknown, 2)?
  test.eq(report.summary.hosts, ["web-1", "db-1"])?

  let limited = invoke(
    [
      "plan",
      "--inventory",
      inventory_file.display(),
      "--deploy",
      fixture.file.display(),
      "--limit",
      "web-1",
      "--format",
      "json",
    ],
    null,
    fixture.root,
  )
  test.eq((decoded_report(limited)?).summary.hosts, ["web-1"])?

  let excluded = invoke(
    [
      "plan",
      "--inventory",
      inventory_file.display(),
      "--deploy",
      fixture.file.display(),
      "--exclude",
      "web",
      "--format",
      "json",
    ],
    null,
    fixture.root,
  )
  test.eq((decoded_report(excluded)?).summary.hosts, ["db-1"])?

  let unknown = invoke(
    [
      "plan",
      "--inventory",
      inventory_file.display(),
      "--deploy",
      fixture.file.display(),
      "--limit",
      "absent",
      "--format",
      "json",
    ],
    null,
    fixture.root,
  )
  test.eq(unknown.exit, 2)?

}

test test_check_exit_codes_and_no_mutation { |ctx|
  let inventory_file = write_inventory(
    ctx,
    "cli-check-inv",
    [HostSeed(name: "web-1", groups: ["web"], address: "192.0.2.10")],
  )?
  let fixture = deployment(
    ctx,
    "cli-check-deploy",
    """[
  model.Directory(model.DirectorySpec(id: "srv", path: p"/srv")),
]""",
  )?
  let fake_root = test.temp_dir(ctx, "cli-check-root")?
  env XINFRA_FAKE_ROOT=f"{fake_root}" {
    fake.reset()?
    let ops = fake.host()
    let args = [
      "check",
      "--inventory",
      inventory_file.display(),
      "--deploy",
      fixture.file.display(),
      "--format",
      "json",
    ]

    let before = tree(fake_root)?
    let drift = invoke(args, ops, fixture.root, "run-check-drift")
    test.eq(drift.exit, 1, drift.stderr)?
    test.eq((decoded_report(drift)?).summary.changed, 1)?
    test.eq(tree(fake_root)?, before)?

    let apply = invoke(
      [
        "apply",
        "--inventory",
        inventory_file.display(),
        "--deploy",
        fixture.file.display(),
        "--format",
        "json",
      ],
      ops,
      fixture.root,
      "run-check-apply",
    )
    test.eq(apply.exit, 0)?

    let clean = invoke(args, ops, fixture.root, "run-check-clean")
    test.eq(clean.exit, 0)?
    test.eq((decoded_report(clean)?).summary.unchanged, 1)?

    let no_ops = invoke(args, null, fixture.root, "run-check-unknown")
    test.eq(no_ops.exit, 2)?
    test.eq((decoded_report(no_ops)?).summary.unknown, 1)?
  }
}

test test_apply_is_idempotent_and_uses_fake_ops { |ctx|
  let inventory_file = write_inventory(
    ctx,
    "cli-apply-inv",
    [HostSeed(name: "web-1", groups: ["web"], address: "192.0.2.10")],
  )?
  let fixture = deployment(
    ctx,
    "cli-apply-deploy",
    """[
  model.Directory(model.DirectorySpec(id: "srv", path: p"/srv")),
  model.File(
    model.FileSpec(
      id: "motd",
      path: p"/srv/motd",
      source: model.Content("hello\\n"),
      requires: ["srv"],
    ),
  ),
]""",
  )?
  let fake_root = test.temp_dir(ctx, "cli-apply-root")?
  env XINFRA_FAKE_ROOT=f"{fake_root}" {
    fake.reset()?
    let ops = fake.host()
    let args = [
      "apply",
      "--inventory",
      inventory_file.display(),
      "--deploy",
      fixture.file.display(),
      "--format",
      "json",
    ]
    let first = invoke(args, ops, fixture.root, "run-apply-first")
    test.eq(first.exit, 0)?
    let report = decoded_report(first)?
    test.eq(report.summary.changed, 2)?
    test.eq(report.summary.failed, 0)?
    test.eq(fp"{fake_root}/srv/motd".read_text()?, "hello\n")?

    let second = invoke(args, ops, fixture.root, "run-apply-second")
    test.eq(second.exit, 0)?
    test.eq((decoded_report(second)?).summary.unchanged, 2)?
  }
}

test test_apply_failures_are_data_and_policy_isolates { |ctx|
  let inventory_file = write_inventory(
    ctx,
    "cli-fail-inv",
    [HostSeed(name: "web-1", groups: ["web"], address: "192.0.2.10")],
  )?
  let fixture = deployment(
    ctx,
    "cli-fail-deploy",
    """[
  model.Directory(model.DirectorySpec(id: "missing-a", path: p"/missing/a")),
  model.Directory(model.DirectorySpec(id: "missing-b", path: p"/missing/b")),
]""",
  )?
  let fake_root = test.temp_dir(ctx, "cli-fail-root")?
  env XINFRA_FAKE_ROOT=f"{fake_root}" {
    fake.reset()?
    let result = invoke(
      [
        "apply",
        "--inventory",
        inventory_file.display(),
        "--deploy",
        fixture.file.display(),
        "--format",
        "json",
      ],
      fake.host(),
      fixture.root,
      "run-apply-fail",
    )
    test.eq(result.exit, 1)?
    let report = decoded_report(result)?
    test.eq(report.summary.failed, 1)?
    test.eq(report.summary.skipped, 1)?
  }
}

test test_apply_abort_and_continue_policies { |ctx|
  let inventory_file = write_inventory(
    ctx,
    "cli-policy-inv",
    [
      HostSeed(name: "web-1", groups: ["web"], address: "192.0.2.10"),
      HostSeed(name: "db-1", groups: ["db"], address: "192.0.2.11"),
    ],
  )?
  let fixture = deployment(
    ctx,
    "cli-policy-deploy",
    """[
  model.Directory(model.DirectorySpec(id: "missing", path: p"/missing/child", hosts: ["web"])),
  model.Directory(model.DirectorySpec(id: "srv", path: p"/srv", hosts: ["db"])),
]""",
  )?
  let fake_root = test.temp_dir(ctx, "cli-policy-root")?
  env XINFRA_FAKE_ROOT=f"{fake_root}" {
    fake.reset()?
    let abort = invoke(
      [
        "apply",
        "--inventory",
        inventory_file.display(),
        "--deploy",
        fixture.file.display(),
        "--on-error",
        "abort",
        "--format",
        "json",
      ],
      fake.host(),
      fixture.root,
      "run-abort",
    )
    test.eq(abort.exit, 1, abort.stderr)?
    test.eq((decoded_report(abort)?).summary.failed, 1)?
    test.eq((decoded_report(abort)?).summary.skipped, 1)?

    let continued = invoke(
      [
        "apply",
        "--inventory",
        inventory_file.display(),
        "--deploy",
        fixture.file.display(),
        "--on-error",
        "continue",
        "--format",
        "json",
      ],
      fake.host(),
      fixture.root,
      "run-continue",
    )
    test.eq(continued.exit, 1, continued.stderr)?
    test.eq((decoded_report(continued)?).summary.failed, 1)?
    test.eq((decoded_report(continued)?).summary.changed, 1)?
  }
}

test test_blocked_dependencies_do_not_run { |ctx|
  let inventory_file = write_inventory(
    ctx,
    "cli-dependency-inv",
    [HostSeed(name: "web-1", groups: ["web"], address: "192.0.2.10")],
  )?
  let fixture = deployment(
    ctx,
    "cli-dependency-deploy",
    """[
  model.Directory(model.DirectorySpec(id: "parent", path: p"/missing/child")),
  model.Directory(model.DirectorySpec(id: "dependent", path: p"/srv/dependent", requires: ["parent"])),
  model.Directory(model.DirectorySpec(id: "last", path: p"/srv/last", requires: ["dependent"])),
]""",
  )?
  let fake_root = test.temp_dir(ctx, "cli-dependency-root")?
  env XINFRA_FAKE_ROOT=f"{fake_root}" {
    fake.reset()?
    let result = invoke(
      [
        "apply",
        "--inventory",
        inventory_file.display(),
        "--deploy",
        fixture.file.display(),
        "--on-error",
        "continue",
        "--format",
        "json",
      ],
      fake.host(),
      fixture.root,
      "run-dependency",
    )
    test.eq(result.exit, 1, result.stderr)?
    let decoded = decoded_report(result)?
    test.eq(decoded.summary.failed, 1)?
    test.eq(decoded.summary.blocked, 2)?
    test.eq(decoded.summary.changed, 0)?
  }
}

test test_saved_plan_round_trip_and_stale_rejection { |ctx|
  let inventory_file = write_inventory(
    ctx,
    "cli-save-inv",
    [HostSeed(name: "web-1", groups: ["web"], address: "192.0.2.10")],
  )?
  let fixture = deployment(
    ctx,
    "cli-save-deploy",
    """[
  model.Directory(model.DirectorySpec(id: "srv", path: p"/srv")),
]""",
  )?
  let fake_root = test.temp_dir(ctx, "cli-save-root")?
  let plan_file = fp"{fake_root}/saved-plan.json"
  env XINFRA_FAKE_ROOT=f"{fake_root}" XSH_PIN="pin-a" {
    fake.reset()?
    let ops = fake.host()
    let saved = invoke(
      [
        "plan",
        "--inventory",
        inventory_file.display(),
        "--deploy",
        fixture.file.display(),
        "--save-plan",
        plan_file.display(),
        "--format",
        "json",
      ],
      ops,
      fixture.root,
      "run-save",
    )
    test.eq(saved.exit, 0, "save: " + saved.stderr)?
    test.ok(plan_file.is_file()?)?
    let artifact = json.decode(plan_file.read_text()?)?.require(JsonPlan)?
    test.eq(artifact.kind, "plan")?
    test.eq(artifact.xsh_pin, "pin-a")?
    test.ok("canary" not in plan_file.read_text()?)?

    let applied = invoke(
      [
        "apply",
        "--inventory",
        inventory_file.display(),
        "--plan",
        plan_file.display(),
        "--format",
        "json",
      ],
      ops,
      fixture.root,
      "run-saved-apply",
    )
    test.eq(applied.exit, 0, "plan-apply: " + applied.stderr)?
    test.eq((decoded_report(applied)?).summary.changed, 1)?

    env XSH_PIN="pin-b" {
      let pinned = invoke(
        [
          "apply",
          "--inventory",
          inventory_file.display(),
          "--plan",
          plan_file.display(),
          "--format",
          "json",
        ],
        ops,
        fixture.root,
        "run-pin",
      )
      test.eq(pinned.exit, 2, "pin: " + pinned.stderr)?
      test.ok("XSH pin changed" in pinned.stderr)?
    }

    fixture.file.write(
      """##! Test deployment.
use xinfra.model

## Returns the declared resources.
export pure resources() -> List[model.Resource] {
  [
    model.Directory(model.DirectorySpec(id: "srv", path: p"/srv")),
    model.Directory(model.DirectorySpec(id: "extra", path: p"/extra")),
  ]
}
""",
    )?
    let stale = invoke(
      [
        "apply",
        "--inventory",
        inventory_file.display(),
        "--plan",
        plan_file.display(),
        "--format",
        "json",
      ],
      ops,
      fixture.root,
      "run-stale",
    )
    test.eq(stale.exit, 2, "stale: " + stale.stderr)?
    test.ok("changed" in stale.stderr)?
  }
}

test test_unknown_actions_cannot_be_saved { |ctx|
  let inventory_file = write_inventory(
    ctx,
    "cli-unknown-inv",
    [HostSeed(name: "web-1", groups: ["web"], address: "192.0.2.10")],
  )?
  let fixture = deployment(
    ctx,
    "cli-unknown-deploy",
    """[
  model.Package(model.PackageSpec(id: "nginx", name: "nginx")),
]""",
  )?
  let plan_file = test.temp_path(ctx, "unknown-plan.json")
  let result = invoke(
    [
      "plan",
      "--inventory",
      inventory_file.display(),
      "--deploy",
      fixture.file.display(),
      "--save-plan",
      plan_file.display(),
    ],
    null,
    fixture.root,
    "run-unknown",
  )
  test.eq(result.exit, 2)?
  test.ok("cannot be saved" in result.stderr)?
  test.ok(! plan_file.exists()?)?
}

test test_unlock_and_doctor_exit_codes { |ctx|
  let valid = write_inventory(
    ctx,
    "cli-doctor-inv",
    [HostSeed(name: "web-1", groups: ["web"], address: "192.0.2.10")],
  )?
  let healthy = invoke(["doctor", "--inventory", valid.display()], null, p".", "run-doctor")
  test.eq(healthy.exit, 0)?
  test.ok("web-1" in healthy.stdout)?

  let bad = fp"{valid.parent()}/bad.toml"
  bad.write("groups = [\"web\"]\n\n[[hosts]]\nname = \"web-1\"\n")?
  let unhealthy = invoke(["doctor", "--inventory", bad.display()], null, p".", "run-doctor-bad")
  test.eq(unhealthy.exit, 1)?

  let usage = invoke(["doctor"], null, p".")
  test.eq(usage.exit, 2)?

  let unlocked = invoke(["unlock", "--host", "web-1", "--force", "--format", "json"], null, p".")
  test.eq(unlocked.exit, 0)?
  test.eq((decoded_report(unlocked)?).summary.exit, 0)?
  test.eq(invoke(["unlock", "--host", "web-1"], null, p".").exit, 2)?
  test.eq(invoke(["unlock", "--force"], null, p".").exit, 2)?
}

test test_jsonl_emits_results_then_summary { |ctx|
  let inventory_file = write_inventory(
    ctx,
    "cli-jsonl-inv",
    [HostSeed(name: "web-1", groups: ["web"], address: "192.0.2.10")],
  )?
  let fixture = deployment(
    ctx,
    "cli-jsonl-deploy",
    """[
  model.Directory(model.DirectorySpec(id: "srv", path: p"/srv")),
]""",
  )?
  let fake_root = test.temp_dir(ctx, "cli-jsonl-root")?
  env XINFRA_FAKE_ROOT=f"{fake_root}" {
    fake.reset()?
    let result = invoke(
      [
        "apply",
        "--inventory",
        inventory_file.display(),
        "--deploy",
        fixture.file.display(),
        "--format",
        "jsonl",
      ],
      fake.host(),
      fixture.root,
      "run-jsonl",
    )
    test.eq(result.exit, 0)?
    let lines = decoded_lines(result)?
    test.eq(lines.len(), 2)?
    test.eq(lines[0].kind, "result")?
    test.eq(lines[1].kind, "summary")?
    test.eq(lines[0].schema_version, 1)?
    test.eq(lines[1].schema_version, 1)?
  }
}

test test_redaction_is_applied_to_cli_output { |ctx|
  let inventory_file = write_inventory(
    ctx,
    "cli-redact-inv",
    [HostSeed(name: "web-1", groups: ["web"], address: "192.0.2.10")],
  )?
  let fixture = deployment(
    ctx,
    "cli-redact-deploy",
    """[
  model.Directory(model.DirectorySpec(id: "srv", path: p"/srv")),
]""",
  )?
  let fake_root = test.temp_dir(ctx, "cli-redact-root")?
  env XINFRA_FAKE_ROOT=f"{fake_root}" {
    fake.reset()?
    let result = command_line.execute(
      [
        "apply",
        "--inventory",
        inventory_file.display(),
        "--deploy",
        fixture.file.display(),
        "--format",
        "json",
      ],
      fake.host(),
      fixture.root,
      "run-redact",
      redact.with_secret(redact.empty(), "canary-value"),
    )
    test.eq(result.exit, 0)?
    test.ok("canary-value" not in result.stdout)?
  }
}

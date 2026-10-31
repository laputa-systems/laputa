use xinfra.inventory
use xinfra.model
use xinfra.validate

const PIN = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

proc host_inventory() -> inventory.Inventory {
  inventory.Inventory(
    groups: ["web"],
    hosts: [
      inventory.Host(
        name: "web-1",
        groups: ["web"],
        address: "192.0.2.10",
        port: 22,
        user: "xinfra",
        key: p"/keys/deploy",
        host_key: PIN,
      ),
    ],
  )
}

proc module_source(resources: Str) -> Str {
  f"""##! Test deployment.
use xinfra.model

## Returns the declared resources.
export pure resources() -> List[model.Resource] {{
  {resources}
}}
"""
}

proc write_deployment(root: Path, name: Str, source: Str) [fs, error] -> Result[Path] {
  let file = fp"{root}/{name}.xsh"
  file.write(source)?
  Ok(file)
}

proc write_artifact(target: Path, source: Str) [fs, error] -> Result[Unit] {
  target.parent().mkdir(parents: true)?
  target.write(source)?
  Ok()
}

proc expect_failure(result: Result[validate.Deployment, model.Problem], kind: Str, field: Str = "") [error] {
  match result {
    Ok(_) => test.fail(f"expected {kind} failure")?,
    Err(problem) => {
      test.eq(problem.kind, kind)?
      if ! field.is_empty() {
        test.eq(problem.field ?? "", field)?
      }
    },
  }
}

proc load_ok(result: Result[validate.Deployment, model.Problem]) -> Result[validate.Deployment, Error] {
  match result {
    Ok(value) => Ok(value),
    Err(problem) => Err(error.failure(problem.message)),
  }
}

test test_loads_and_renders_the_alpine_example { |ctx|
  let deployment = load_ok(
    validate.load(p"examples/alpine-web/deploy.xsh", host_inventory(), p"."),
  )?
  test.eq(deployment.resources.len(), 6)?
  test.eq(deployment.sources.len(), 2)?
  test.eq(model.identity(deployment.resources[0]), "nginx-package")?
  test.eq(model.identity(deployment.resources[5]), "nginx-service")?

  let config = deployment.sources.get("nginx-config")?
  let rendered = validate.text(config) ?? ""
  test.ok("server_name alpine-web;" in rendered)?
  test.ok("root /var/www/localhost/htdocs;" in rendered)?
  test.eq(validate.digest(config) ?? "", hash.sha256(bytes.from_text(rendered)).hex())?

  let motd = deployment.sources.get("motd")?
  test.eq(validate.text(motd), "Welcome to Alpine Web\n")?
}

test test_loads_a_module_through_the_documented_contract { |ctx|
  let root = test.temp_dir(ctx, "deploy-contract")?
  let file = write_deployment(
    root,
    "deploy",
    module_source(
      """[
  model.File(
    model.FileSpec(
      id: "motd",
      path: p"/etc/motd",
      source: model.Content("hello\\n"),
    ),
  ),
]""",
    ),
  )?
  let deployment = load_ok(validate.load(file, host_inventory(), root))?
  test.eq(deployment.resources.len(), 1)?
  let source = deployment.sources.get("motd")?
  test.eq(validate.text(source), "hello\n")?
  test.eq(validate.digest(source) ?? "", hash.sha256(bytes.from_text("hello\n")).hex())?
}

test test_rejects_modules_that_do_not_satisfy_the_contract { |ctx|
  let root = test.temp_dir(ctx, "deploy-contract-bad")?
  let value_export = write_deployment(
    root,
    "value",
    """##! Test deployment.
use xinfra.model

## The resources.
export let resources: List[model.Resource] = []
""",
  )?
  expect_failure(validate.load(value_export, host_inventory(), root), "module-contract")

  let impure = write_deployment(
    root,
    "impure",
    """##! Test deployment.
use xinfra.model

## The resources.
export proc resources() [fs] -> List[model.Resource] { [] }
""",
  )?
  expect_failure(validate.load(impure, host_inventory(), root), "module-contract")

  let undocumented = write_deployment(
    root,
    "undocumented",
    """use xinfra.model
export pure resources() -> List[model.Resource] { [] }
""",
  )?
  expect_failure(validate.load(undocumented, host_inventory(), root), "module-load")
}

test test_rejects_missing_directory_and_escaping_artifacts { |ctx|
  let repo = test.temp_dir(ctx, "deploy-artifacts")?
  write_artifact(fp"{repo.parent()}/outside-secret", "outside\n")?

  let missing = write_deployment(
    repo,
    "missing",
    module_source(
      """[
  model.File(
    model.FileSpec(
      id: "file",
      path: p"/etc/file",
      source: model.Source(p"absent-file"),
    ),
  ),
]""",
    ),
  )?
  expect_failure(validate.load(missing, host_inventory(), repo), "missing-artifact", "source")

  let escape = write_deployment(
    repo,
    "escape",
    module_source(
      """[
  model.File(
    model.FileSpec(
      id: "file",
      path: p"/etc/file",
      source: model.Source(p"../outside-secret"),
    ),
  ),
]""",
    ),
  )?
  expect_failure(validate.load(escape, host_inventory(), repo), "artifact-escape", "source")

  let directory = write_deployment(
    repo,
    "directory",
    module_source(
      """[
  model.File(
    model.FileSpec(
      id: "file",
      path: p"/etc/file",
      source: model.Source(p"artifacts"),
    ),
  ),
]""",
    ),
  )?
  fp"{repo}/artifacts".mkdir()?
  expect_failure(validate.load(directory, host_inventory(), repo), "artifact-not-file", "source")
}

test test_rejects_template_syntax_render_encoding_and_size { |ctx|
  let root = test.temp_dir(ctx, "deploy-templates")?
  write_artifact(fp"{root}/templates/syntax.tmpl", "{{")?
  write_artifact(fp"{root}/templates/missing.tmpl", "{{.absent}}\n")?
  fp"{root}/templates/binary.tmpl".write(bytes.from_ints([255, 254])?)?
  fp"{root}/templates/large.tmpl".write(bytes.zero(16 * 1024 * 1024 + 1)?)?

  let deploy = write_deployment(
    root,
    "templates",
    module_source(
      """[
  model.File(
    model.FileSpec(
      id: "syntax",
      path: p"/etc/syntax",
      source: model.Templated(model.Template(path: p"templates/syntax.tmpl")),
    ),
  ),
]""",
    ),
  )?
  expect_failure(validate.load(deploy, host_inventory(), root), "template-render", "template")

  for name in ["missing", "binary", "large"] {
    let source = module_source(
      f"""[
  model.File(
    model.FileSpec(
      id: "file",
      path: p"/etc/file",
      source: model.Templated(model.Template(path: p"templates/{name}.tmpl")),
    ),
  ),
]""",
    )
    let file = write_deployment(root, name, source)?
    let expected_kind = if name == "missing" { "template-render" } else if name == "binary" {
      "template-encoding"
    } else {
      "template-too-large"
    }
    expect_failure(validate.load(file, host_inventory(), root), expected_kind)
  }
}

test test_rejects_a_rendered_template_over_the_bound { |ctx|
  let root = test.temp_dir(ctx, "deploy-render-large")?
  fp"{root}/templates".mkdir(parents: true)?
  let filler = bytes.zero(16 * 1024 * 1024 - 6)?
  let source = bytes.concat([filler, bytes.from_text("{{.v}}")])
  fp"{root}/templates/render-large.tmpl".write(source)?
  let file = write_deployment(
    root,
    "render-large",
    module_source(
      """[
  model.File(
    model.FileSpec(
      id: "large-render",
      path: p"/etc/large-render",
      source: model.Templated(model.Template(
        path: p"templates/render-large.tmpl",
        vars: {"v": "xxxxxxx"},
      )),
    ),
  ),
]""",
    ),
  )?
  expect_failure(validate.load(file, host_inventory(), root), "template-too-large", "template")
}

test test_rejects_unknown_host_selectors { |ctx|
  let root = test.temp_dir(ctx, "deploy-selector")?
  let file = write_deployment(
    root,
    "selector",
    module_source(
      """[
  model.Directory(
    model.DirectorySpec(id: "app", path: p"/etc/app", hosts: ["db"]),
  ),
]""",
    ),
  )?
  expect_failure(validate.load(file, host_inventory(), root), "unknown-selector", "hosts")
}

test test_rejects_unknown_and_non_service_notifications { |ctx|
  let root = test.temp_dir(ctx, "deploy-notify")?
  let unknown = write_deployment(
    root,
    "unknown",
    module_source(
      """[
  model.File(
    model.FileSpec(
      id: "file",
      path: p"/etc/file",
      source: model.Content("x"),
      notify: ["absent-service"],
    ),
  ),
]""",
    ),
  )?
  expect_failure(validate.load(unknown, host_inventory(), root), "unknown-notify", "notify")

  let non_service = write_deployment(
    root,
    "non-service",
    module_source(
      """[
  model.Package(model.PackageSpec(id: "nginx", name: "nginx")),
  model.File(
    model.FileSpec(
      id: "file",
      path: p"/etc/file",
      source: model.Content("x"),
      notify: ["nginx"],
    ),
  ),
]""",
    ),
  )?
  expect_failure(validate.load(non_service, host_inventory(), root), "notify-not-service", "notify")
}

test test_rejects_graph_problems_through_the_loader { |ctx|
  let root = test.temp_dir(ctx, "deploy-graph")?
  let duplicate = write_deployment(
    root,
    "duplicate",
    module_source(
      """[
  model.Directory(model.DirectorySpec(id: "same", path: p"/etc/a")),
  model.Directory(model.DirectorySpec(id: "same", path: p"/etc/b")),
]""",
    ),
  )?
  expect_failure(validate.load(duplicate, host_inventory(), root), "duplicate-id")

  let unknown = write_deployment(
    root,
    "unknown-requirement",
    module_source(
      """[
  model.Directory(
    model.DirectorySpec(id: "app", path: p"/etc/app", requires: ["absent"]),
  ),
]""",
    ),
  )?
  expect_failure(validate.load(unknown, host_inventory(), root), "unknown-requirement")

  let cycle = write_deployment(
    root,
    "cycle",
    module_source(
      """[
  model.Directory(model.DirectorySpec(id: "left", path: p"/etc/left", requires: ["right"])),
  model.Directory(model.DirectorySpec(id: "right", path: p"/etc/right", requires: ["left"])),
]""",
    ),
  )?
  expect_failure(validate.load(cycle, host_inventory(), root), "dependency-cycle")
}

test test_rejects_invalid_resource_variants_through_the_loader { |ctx|
  let root = test.temp_dir(ctx, "deploy-invalid")?
  let absent_source = write_deployment(
    root,
    "absent-source",
    module_source(
      """[
  model.File(
    model.FileSpec(
      id: "file",
      path: p"/etc/file",
      state: model.Absent,
      source: model.Content("x"),
    ),
  ),
]""",
    ),
  )?
  expect_failure(validate.load(absent_source, host_inventory(), root), "invalid-field", "source")

  let unguarded = write_deployment(
    root,
    "unguarded",
    module_source(
      """[
  model.CommandResource(model.CommandSpec(id: "run", argv: ["true"])),
]""",
    ),
  )?
  expect_failure(validate.load(unguarded, host_inventory(), root), "invalid-field", "always_run")
}

test test_rejects_a_deployment_outside_the_repository_root { |ctx|
  let repo = test.temp_dir(ctx, "deploy-root")?
  let outside = test.temp_dir(ctx, "deploy-root-outside")?
  let file = write_deployment(
    outside,
    "deploy",
    module_source("[]"),
  )?
  expect_failure(validate.load(file, host_inventory(), repo), "deployment-escape")
}

test test_rejects_non_utf8_deployment_paths { |ctx|
  let root = test.temp_dir(ctx, "deploy-non-utf8")?
  let component = Path.parse_bytes(bytes.from_ints([100, 101, 112, 108, 111, 121, 255])?)?
  let file = Path.parse_bytes(
    bytes.concat([root.bytes(), bytes.from_text("/"), component.bytes()]),
  )?
  expect_failure(validate.load(file, host_inventory(), root), "non-utf8-path")
}

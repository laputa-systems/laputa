##! Deployment module loading, artifact resolution, and pre-host validation.

use xinfra.inventory
use xinfra.model
use xinfra.order

const MAX_TEMPLATE_BYTES = 16 * 1024 * 1024

## A prepared local artifact and its digest.
export type LocalSource = {path: Path, digest: Str}

## Prepared inline content and its digest.
export type ContentSource = {text: Str, digest: Str}

## A rendered template and its digest.
export type TemplateSource = {text: Str, digest: Str}

## Exactly one content variant prepared for a local file resource.
export enum PreparedSource {
  Local(LocalSource),
  Content(ContentSource),
  Templated(TemplateSource),
  Secret(model.SecretRef),
}

## A deployment after module loading, validation, and local artifact preparation.
export type Deployment = {
  file: Path,
  root: Path,
  resources: List[model.Resource],
  sources: Map[Str, PreparedSource],
}

## The documented export contract every deployment module must satisfy.
export type DeploymentModule = module {
  export pure resources() -> List[model.Resource]
}

pure problem(
  kind: Str,
  message: Str,
  id: Str? = null,
  field: Str? = null,
) -> model.Problem {
  model.Problem(kind:, id:, field:, message:)
}

pure utf8_path(target: Path) -> Bool {
  match target.bytes().utf8() {
    Ok(_) => true,
    Err(_) => false,
  }
}

## Returns the digest a prepared source declares, or null for a secret.
export pure digest(source: PreparedSource) -> Str? {
  match source {
    Local(value) => value.digest,
    Content(value) => value.digest,
    Templated(value) => value.digest,
    Secret(_) => null,
  }
}

## Returns rendered text for a content or template source.
export pure text(source: PreparedSource) -> Str? {
  match source {
    Content(value) => value.text,
    Templated(value) => value.text,
    _ => null,
  }
}

## Returns the local artifact path for a file source, if it has one.
export pure local_path(source: PreparedSource) -> Path? {
  match source {
    Local(value) => value.path,
    _ => null,
  }
}

## Returns the secret reference for a secret source.
export pure secret_reference(source: PreparedSource) -> model.SecretRef? {
  match source {
    Secret(reference) => reference,
    _ => null,
  }
}

proc resolve_artifact(
  id: Str,
  field: Str,
  base: Path,
  root: Path,
  relative: Path,
) [fs, error] -> Result[Path, model.Problem] {
  if ! utf8_path(relative) {
    return Err(problem("non-utf8-path", "artifact path is not UTF-8", id: id, field: field))
  }

  let candidate = fp"{base}/{relative}"
  let resolved = match candidate.resolve() {
    Ok(value) => value,
    Err(_) => {
      return Err(problem("missing-artifact", f"missing artifact {candidate.display()}", id: id, field: field))
    },
  }

  if ! resolved.starts_with(root) {
    return Err(
      problem("artifact-escape", f"artifact {resolved.display()} escapes the repository root", id: id, field: field),
    )
  }

  if ! utf8_path(resolved) {
    return Err(problem("non-utf8-path", "artifact path is not UTF-8", id: id, field: field))
  }

  let metadata = match resolved.metadata() {
    Ok(value) => value,
    Err(_) => {
      return Err(problem("missing-artifact", f"missing artifact {resolved.display()}", id: id, field: field))
    },
  }

  if metadata.kind != "file" {
    return Err(
      problem(
        "artifact-not-file",
        f"artifact {resolved.display()} is a {metadata.kind}",
        id: id,
        field: field,
      ),
    )
  }

  Ok(resolved)
}

proc digest_file(id: Str, field: Str, target: Path) [fs] -> Result[Str, model.Problem] {
  match hash.sha256(target) {
    Ok(value) => Ok(value.hex()),
    Err(failure) => Err(problem("artifact-read", failure.message, id: id, field: field)),
  }
}

proc prepare_template(
  id: Str,
  target: Path,
  render_spec: model.Template,
) [fs] -> Result[PreparedSource, model.Problem] {
  let metadata = match target.metadata() {
    Ok(value) => value,
    Err(failure) => {
      return Err(problem("artifact-read", failure.message, id: id, field: "template"))
    },
  }

  if metadata.size > MAX_TEMPLATE_BYTES {
    return Err(
      problem(
        "template-too-large",
        f"template is {metadata.size} bytes, over the {MAX_TEMPLATE_BYTES} byte bound",
        id: id,
        field: "template",
      ),
    )
  }

  let raw = match target.read_bytes() {
    Ok(value) => value,
    Err(failure) => {
      return Err(problem("artifact-read", failure.message, id: id, field: "template"))
    },
  }

  let source = match raw.utf8() {
    Ok(value) => value,
    Err(_) => {
      return Err(problem("template-encoding", "template is not UTF-8", id: id, field: "template"))
    },
  }

  let rendered = match template.render(source, render_spec.vars) {
    Ok(value) => value,
    Err(failure) => {
      return Err(problem("template-render", failure.message, id: id, field: "template"))
    },
  }

  if rendered.byte_len() > MAX_TEMPLATE_BYTES {
    return Err(
      problem(
        "template-too-large",
        f"rendered template is {rendered.byte_len()} bytes, over the {MAX_TEMPLATE_BYTES} byte bound",
        id: id,
        field: "template",
      ),
    )
  }

  let digest_value = hash.sha256(bytes.from_text(rendered)).hex()
  Ok(Templated(TemplateSource(text: rendered, digest: digest_value)))
}

proc prepare_source(
  id: Str,
  base: Path,
  root: Path,
  source: model.FileSource,
) [fs, error] -> Result[PreparedSource, model.Problem] {
  match source {
    model.Source(relative) => {
      let target = resolve_artifact(id, "source", base, root, relative)?
      let digest_value = digest_file(id, "source", target)?
      Ok(Local(LocalSource(path: target, digest: digest_value)))
    }
    model.Content(value) => {
      let digest_value = hash.sha256(bytes.from_text(value)).hex()
      Ok(Content(ContentSource(text: value, digest: digest_value)))
    }
    model.Secret(reference) => Ok(Secret(reference)),
    model.Templated(render_spec) => {
      let target = resolve_artifact(id, "template", base, root, render_spec.path)?
      prepare_template(id, target, render_spec)
    }
  }
}

pure selector_known(inventory: inventory.Inventory, selector: Str) -> Bool {
  if selector in inventory.groups {
    return true
  }

  for host in inventory.hosts {
    if host.name == selector {
      return true
    }
  }

  false
}

pure resource_by_id(resources: List[model.Resource], id: Str) -> model.Resource? {
  for resource in resources {
    if model.identity(resource) == id {
      return resource
    }
  }

  null
}

pure check_selectors(resource: model.Resource, inventory: inventory.Inventory) -> Result[Unit, model.Problem] {
  let id = model.identity(resource)
  for selector in model.host_selectors(resource) {
    if ! selector_known(inventory, selector) {
      return Err(
        problem("unknown-selector", f"host selector {selector} does not resolve", id: id, field: "hosts"),
      )
    }
  }

  Ok()
}

pure check_notifications(
  resource: model.Resource,
  resources: List[model.Resource],
) -> Result[Unit, model.Problem] {
  let id = model.identity(resource)
  for notification in model.notifications(resource) {
    let found = resource_by_id(resources, notification)
    if found == null {
      return Err(
        problem("unknown-notify", f"notification target {notification} does not exist", id: id, field: "notify"),
      )
    }

    let target = found
    if ! model.is_service(target) {
      return Err(
        problem("notify-not-service", f"notification target {notification} is not a service", id: id, field: "notify"),
      )
    }
  }

  Ok()
}

proc prepare_resources(
  resources: List[model.Resource],
  base: Path,
  root: Path,
  inventory: inventory.Inventory,
) [fs, error] -> Result[Map[Str, PreparedSource], model.Problem] {
  var sources: Map[Str, PreparedSource] = map.empty()
  for resource in resources {
    check_selectors(resource, inventory)?
    check_notifications(resource, resources)?
    match resource {
      model.File(spec) => {
        if let source = spec.source {
          sources = sources.set(spec.id, prepare_source(spec.id, base, root, source)?)
        }
      }
      _ => {}
    }
  }

  Ok(sources)
}

## Loads a deployment module and validates it before any host call.
export proc load(
  file: Path,
  inventory: inventory.Inventory,
  repository_root: Path,
) [fs, error] -> Result[Deployment, model.Problem] {
  let absolute = match path.absolute(file) {
    Ok(value) => value,
    Err(failure) => {
      return Err(problem("deployment-path", failure.message, field: "deploy"))
    },
  }

  if ! utf8_path(absolute) {
    return Err(problem("non-utf8-path", "deployment path is not UTF-8", field: "deploy"))
  }

  let base = match absolute.parent().resolve() {
    Ok(value) => value,
    Err(failure) => {
      return Err(problem("deployment-path", failure.message, field: "deploy"))
    },
  }

  let root = match repository_root.resolve() {
    Ok(value) => value,
    Err(failure) => {
      return Err(problem("repository-root", failure.message, field: "root"))
    },
  }

  if ! base.starts_with(root) {
    return Err(
      problem("deployment-escape", "deployment directory is outside the repository root", field: "deploy"),
    )
  }

  let loaded = match module.load(absolute) {
    Ok(value) => value,
    Err(failure) => {
      return Err(problem("module-load", failure.message, field: "deploy"))
    },
  }

  let deployment_module = match loaded.require(DeploymentModule) {
    Ok(value) => value,
    Err(failure) => {
      return Err(problem("module-contract", failure.message, field: "deploy"))
    },
  }

  let resources = deployment_module.resources()
  model.validate_all(resources)?
  let ordered = order.sort(resources)?
  let sources = prepare_resources(ordered, base, root, inventory)?
  Ok(Deployment(file: absolute, root: root, resources: ordered, sources: sources))
}

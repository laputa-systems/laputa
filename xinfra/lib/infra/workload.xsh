##! What each host is asked to become, validated before anything connects:
##! resource order, dependencies, one operation sequence across hosts, local
##! content that can be read, and secrets that are set.

use infra.compare
use infra.content
use infra.graph
use infra.model
use infra.scripts

## The resources declared for one host, in dependency order after `prepare`.
export type Workload = {host: model.Host, resources: List[model.Resource]}

## A validated run: per-host resources in order, the operation sequence all
## hosts follow, the local content measured once, and the secret values to
## redact from every message.
export type Prepared = {
  workloads: List[Workload],
  operations: List[Str],
  materials: Map[Str, compare.Material],
  secrets: List[Str],
}

const minimum_secret_bytes = 4

## The key a host's resource has in `Prepared.materials`.
export pure material_key(host: Str, id: Str) -> Str {
  f"{host}/{id}"
}

proc measure_file(host: Str, resource: model.Resource, spec: model.FileSpec) [fs, env, error] -> Result[compare.Material?, Error] {
  guard spec.presence == .Present else {
    return Ok(null)
  }

  guard let source = spec.content else {
    fail f"{host}: file {resource.id} has no content"
  }

  let measured = ctx f"{host}: file {resource.id}" { content.measure(source)? }
  Ok(measured)
}

pure dialect_refusal(host: model.Host, resource: model.Resource, operation: scripts.Operation) -> Str {
  f"{host.name}: {resource.id}: the {host.dialect} dialect has no script for {operation}; a {model.kind(resource.spec)} resource cannot run on this host"
}

proc check_dialect(host: model.Host, resources: List[model.Resource]) -> Result[Unit, Error] {
  for resource in resources {
    for operation in scripts.operations(resource.spec) {
      guard scripts.supports(host.dialect, operation) else {
        fail dialect_refusal(host, resource, operation)
      }
    }
  }
}

proc secret_values(host: Str, resource: model.Resource) [env, error] -> Result[List[Str], Error] {
  var names: List[Str] = []
  match resource.spec {
    model.File(spec) => {
      if let source = spec.content {
        match source {
          model.SecretEnv(name) => names += [name]
          else => {}
        }
      }
    }
    model.Exec(spec) => {
      if spec.stdin_env != null {
        names += [spec.stdin_env]
      }
    }
    else => {}
  }

  var values: List[Str] = []
  for name in names {
    let value = ctx f"{host}: {resource.id}" { env.get(name)? }
    guard value.byte_len() >= minimum_secret_bytes else {
      fail f"{host}: {resource.id}: secret {name} is shorter than {minimum_secret_bytes} bytes and cannot be redacted reliably"
    }

    values += [value]
  }

  Ok(values)
}

## Validate declared work for every selected host. Nothing connects and
## nothing mutates: duplicate ids, unknown or cyclic dependencies, hosts that
## order shared operations differently, unreadable local sources and unset
## secrets are all refused here.
export proc prepare(declared: List[Workload]) [fs, env, error] -> Result[Prepared, Error] {
  var ordered: List[Workload] = []
  var materials: Map[Str, compare.Material] = {}
  var secrets: List[Str] = []
  for entry in declared {
    let resources = ctx f"host {entry.host.name}" { graph.order(entry.resources)? }
    ctx f"host {entry.host.name}" { check_dialect(entry.host, resources)? }
    ordered += [Workload(host: entry.host, resources:)]
    for resource in resources {
      match resource.spec {
        model.File(spec) => {
          if let found = measure_file(entry.host.name, resource, spec)? {
            materials[material_key(entry.host.name, resource.id)] = found
          }
        }
        else => {}
      }

      for value in secret_values(entry.host.name, resource)? {
        if value not in secrets {
          secrets += [value]
        }
      }
    }
  }

  let lists = ordered |> map { |entry| entry.resources |> map { |resource| resource.id } |> collect() } |> collect()
  let operations = graph.merge_order(lists)?
  Ok(Prepared(workloads: ordered, operations:, materials:, secrets:))
}

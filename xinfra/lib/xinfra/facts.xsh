##! Remote facts over the native SSH transport.

use xinfra.cache as cache
use xinfra.parse as parse
use xinfra.transport as transport

## One fact query.
export type Query = {kind: Str, name: Str}

## A fact together with its cache state.
export type CachedFact = {fact: parse.Fact, cache: cache.Cache, hit: Bool}

## Read one fact field, or the empty string when it is absent.
export pure field(fields: Map[Str, Str], name: Str) -> Str {
  match fields.get(name) {
    Ok(value) => value,
    Err(_) => "",
  }
}

pure text(value: Bytes) -> Str {
  match value.utf8() {
    Ok(value) => value,
    Err(_) => "",
  }
}

pure query_key(query: Query) -> Str {
  f"{query.kind}:{query.name}"
}

## Read one file fact.
export proc file_fact(session: transport.Session, target: Str) -> Result[parse.Fact, Str] {
  let result = transport.exec(session, ["stat", "-c", "%F|%a|%u|%g|%s|%Y", target])?
  if result.exit_code == 0 {
    return Ok(parse.file_stat(text(result.stdout)))
  }

  let error = text(result.stderr)
  return Ok(parse.absent()) when "No such file" in error
  return Ok(parse.unknown("permission denied")) when "Permission denied" in error
  Ok(parse.unknown(error.trim()))
}

## Read one passwd fact.
export proc user_fact(session: transport.Session, name: Str) -> Result[parse.Fact, Str] {
  let result = transport.exec(session, ["getent", "passwd", name])?
  if result.exit_code == 0 {
    return Ok(parse.passwd_row(text(result.stdout)))
  }

  return Ok(parse.absent()) when result.stdout.is_empty()
  Ok(parse.unknown(text(result.stderr)))
}

## Read one group fact.
export proc group_fact(session: transport.Session, name: Str) -> Result[parse.Fact, Str] {
  let result = transport.exec(session, ["getent", "group", name])?
  if result.exit_code == 0 {
    return Ok(parse.group_row(text(result.stdout)))
  }

  return Ok(parse.absent()) when result.stdout.is_empty()
  Ok(parse.unknown(text(result.stderr)))
}

## Read one apk package fact.
export proc package_fact(session: transport.Session, name: Str) -> Result[parse.Fact, Str] {
  let result = transport.exec(session, ["apk", "list", "-I", name])?
  if result.exit_code != 0 {
    return Ok(parse.unknown(text(result.stderr)))
  }

  Ok(parse.package(text(result.stdout), name))
}

## Read one OpenRC service fact.
export proc service_fact(session: transport.Session, name: Str) -> Result[parse.Fact, Str] {
  let status = transport.exec(session, ["rc-service", name, "status"])?
  let update = transport.exec(session, ["rc-update", "show"])?
  let status_fact = parse.service_status(status.exit_code)
  let update_fact = parse.rc_update(text(update.stdout), name)
  let current = status_fact.fields.get("status") ?? "unknown"
  let enabled = update_fact.fields.get("enabled") ?? "no"
  return Ok(parse.unknown(current)) when current == "unknown"
  Ok({kind: "present", fields: {"status": current, "enabled": enabled}})
}

## Read one query, dispatching by kind.
export proc read(session: transport.Session, query: Query) -> Result[parse.Fact, Str] {
  if query.kind == "file" {
    return file_fact(session, query.name)
  }

  if query.kind == "user" {
    return user_fact(session, query.name)
  }

  if query.kind == "group" {
    return group_fact(session, query.name)
  }

  if query.kind == "package" {
    return package_fact(session, query.name)
  }

  if query.kind == "service" {
    return service_fact(session, query.name)
  }

  Ok(parse.unknown(f"unsupported fact kind {query.kind}"))
}

## Read a batch of queries on one session.
export proc batch(session: transport.Session, queries: List[Query]) -> Result[List[parse.Fact], Str] {
  var facts = []
  for query in queries {
    facts += [read(session, query)?]
  }
  Ok(facts)
}

## Read a query through the cache, storing a miss.
export proc read_cached(
  current: cache.Cache,
  session: transport.Session,
  host: Str,
  privilege: Str,
  query: Query,
) -> Result[CachedFact, Str] {
  let key = query_key(query)
  match cache.lookup(current, host, privilege, key) {
    Err(_) => {
      let value = read(session, query)?
      Ok({fact: value, cache: cache.store(current, host, privilege, key, value), hit: false})
    }
    Ok(cached) => Ok({fact: cached, cache: current, hit: true}),
  }
}

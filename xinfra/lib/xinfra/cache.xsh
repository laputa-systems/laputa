##! Query-scoped fact cache.

use xinfra.parse as parse

## Cached facts with an invalidation generation.
export type Cache = {generation: Int, entries: Map[Str, parse.Fact]}

## An empty cache at generation zero.
export pure empty() -> Cache {
  let entries: Map[Str, parse.Fact] = {}
  {generation: 0, entries: entries}
}

pure key(host: Str, privilege: Str, generation: Int, query: Str) -> Str {
  f"{host}|{privilege}|{generation}|{query}"
}

## Look up one fact for a host, privilege, and query.
export pure lookup(cache: Cache, host: Str, privilege: Str, query: Str) -> Result[parse.Fact, Str] {
  match cache.entries.get(key(host, privilege, cache.generation, query)) {
    Ok(value) => Ok(value),
    Err(_) => Err("cache miss"),
  }
}

## Store one fact and return the updated cache.
export pure store(cache: Cache, host: Str, privilege: Str, query: Str, value: parse.Fact) -> Cache {
  var entries = cache.entries
  entries[key(host, privilege, cache.generation, query)] = value
  {generation: cache.generation, entries: entries}
}

## Invalidate every cached fact and advance the generation.
export pure invalidate(cache: Cache) -> Cache {
  let entries: Map[Str, parse.Fact] = {}
  {generation: cache.generation + 1, entries: entries}
}

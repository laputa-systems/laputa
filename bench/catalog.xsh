use pm.catalog
use pm.types

proc main() [fs, env, error] {
  let value = catalog.load_for_target(p".", types.X86_64LinuxMusl)?
  let names = catalog.package_names(value)
  fail "catalog omitted baselayout" when "baselayout" not in names
  print f"validated {names.len()} packages including baselayout"
}

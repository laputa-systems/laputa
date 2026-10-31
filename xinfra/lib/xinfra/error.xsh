##! Shared xinfra failure families.

## Failures raised while loading or selecting an inventory.
export error InventoryError {
  Invalid(path: Path, message: Str)
  InvalidHost(host: Str, field: Str, message: Str)
  InvalidGroup(name: Str, message: Str)
  DuplicateHost(name: Str)
  DuplicateGroup(name: Str)
  UnknownGroup(host: Str, group: Str)
  UnknownSelector(selector: Str)
  InvalidHostKey(host: Str, pin: Str)
  KeyPathEscape(host: Str, path: Str)
  NonUtf8Path(field: Str, path: Path)
  MissingKey(host: Str, path: Path)
  KeyNotFile(host: Str, path: Path, kind: Str)
  UnsafeKey(host: Str, path: Path, mode: Int)
}

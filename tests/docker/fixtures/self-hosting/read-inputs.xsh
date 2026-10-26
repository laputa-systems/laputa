let identity = unix.id()?
assert identity.uid == 65534 and identity.gid == 65534
var files = 0
for entry in fs.walk(/declared, hidden: true)? {
  if entry.kind == "file" {
    let count = if entry.path.metadata()?.size == 0 { 0 } else { 1 }
    assert bytes.read_at(entry.path, 0, count)?.len() == count
    files += 1
  }
}
for root in [/output, /scratch] {
  let file = fp"{root}/permission-probe"
  file.write("declared writable directory\n")?
  assert file.read_text()? == "declared writable directory\n"
  file.remove()?
}
assert p"/dev/null".read_bytes()?.len() == 0
p"/dev/null".write("discarded device probe\n")?
print "declared input permission contract passed" $files "regular files"

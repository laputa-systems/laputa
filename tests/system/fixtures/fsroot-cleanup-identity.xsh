let sandbox = fs.tempdir()?
let base = sandbox.host_path()?
let owned = fs.tempdir_in(base)?
let cached = owned.host_path()?
owned.write(p"owned-marker", "original owned tree")
let detached = fp"{base}/detached-owned-tree"
fs.rename_noreplace(cached, detached)
cached.mkdir()
fp"{cached}/unowned-sentinel".write("replacement tree")
match owned.close() {
  Ok(_) => assert false, "temp-root close succeeded after its tree was moved and replaced"
  Err(problem) => assert "moved or replaced" in problem.message
}
assert fp"{cached}/unowned-sentinel".read_text()? == "replacement tree"
assert fp"{detached}/owned-marker".read_text()? == "original owned tree"
print "temp-root close failed closed; replacement tree and original moved tree both remained"

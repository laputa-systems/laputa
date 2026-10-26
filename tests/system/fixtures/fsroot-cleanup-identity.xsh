let sandbox = fs.tempdir()?
let base = sandbox.host_path()?
let owned = fs.tempdir_in(base)?
let cached = owned.host_path()?
owned.write(p"owned-marker", "original owned tree")
let detached = fp"{base}/detached-owned-tree"
fs.rename_noreplace(cached, detached)
cached.mkdir()
fp"{cached}/unowned-sentinel".write("replacement tree")
owned.close()
assert ! cached.exists()?
assert fp"{detached}/owned-marker".read_text()? == "original owned tree"
print "temp-root close removed replacement tree at saved pathname; original moved tree remained"

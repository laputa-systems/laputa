##! Publish one offline-signed snapshot directory to a repository URL through PM.
use pm.repo
use pm.repo_snapshot

proc main(url: Str, snapshot_dir: Str, key_file: Str, work: Str) {
  let keys = repo_snapshot.snapshot_load_keys(Path(key_file))?
  repo.publish_snapshot(url, "", Path(work), Path(snapshot_dir), keys)
  print "published"
}

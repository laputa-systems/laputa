##! Staging and no-replace publication beneath retained FsRoot capabilities, shared by the Store, roots and generations.
use types

## Converts canonical relative path text into a RelPath for rooted operations.
export proc rel(text: Str) [error] -> Result[RelPath, Error] {
  let value: RelPath = fp"{text}".require()?
  value
}

pure joined(parent: Str, name: Str) -> Str {
  if parent == "" { name } else { f"{parent}/{name}" }
}

## Creates an empty mode-0700 staging directory for `name` inside `parent` ("" for the
## publication root itself) and returns its path relative to `publication`. Creation is
## exclusive and resolves beneath the retained descriptor, so a replaced ancestor path cannot
## relocate it.
export proc create_staging(publication: FsRoot, parent: Str, name: Str) [fs, error] -> Result[Str, Error] {
  let staging = joined(parent, fs.temp_sibling(fp"{name}")?.name)
  publication.mkdir(rel(staging)?, mode: 0o700)
  staging
}

## Creates every missing directory of canonical relative `path_value` beneath `root` with mode
## 0755, since a rooted `mkdir` ignores the umask; each existing component must already be a
## directory, never a symlink.
export proc ensure_dir(root: FsRoot, path_value: Str) [fs, error] {
  var prefix = ""

  for component in path_value.split("/") {
    prefix = joined(prefix, component)
    let relative = rel(prefix)?

    match root.mkdir(relative, mode: 0o755) {
      Ok(_) => {}
      Err(problem) => guard root.stat(relative)?.kind == "dir" else {
        return Err(types.PmError.PackageConflict(f"{prefix} is not a directory: {problem.message}"))
      }
    }
  }
}

type TreeLeaf = {path: Str, kind: Str}

type Tree = {directories: List[Str], leaves: List[TreeLeaf]}

proc complete_children(root: FsRoot, directory: Str) -> Result[List[Str]] {
  let listing = root.children(rel(directory)?)?

  guard listing.state == "complete" else {
    return Err(types.PmError.PackageContract(f"cannot enumerate staged directory {directory}"))
  }

  [child.display() for child in listing.children]
}

proc tree_entries(root: FsRoot) -> Result[Tree] {
  var pending = ["."]
  var directories = []
  var leaves: List[TreeLeaf] = []

  while ! pending.is_empty() {
    let directory = pending[0]
    pending = pending |> drop(1)
    directories = [directory, @directories]

    for child in complete_children(root, directory)? {
      let kind = root.stat(rel(child)?)?.kind

      if kind == "dir" {
        pending += [child]
      } else {
        leaves += [{path: child, kind}]
      }
    }
  }

  {directories, leaves}
}

## Flushes every regular file and directory beneath `root`, children before their parents.
## A symlink is recorded by its directory's flush; any other special file is refused.
export proc sync_tree(root: FsRoot) [fs, error] {
  let tree = tree_entries(root)?

  for leaf in tree.leaves {
    if leaf.kind == "file" {
      root.fsync(rel(leaf.path)?)
    } else if leaf.kind != "symlink" {
      return Err(types.PmError.PackageContract(f"cannot synchronize special file {leaf.path}"))
    }
  }

  for directory in tree.directories {
    root.fsync(rel(directory)?)
  }
}

## Empties `staging` through its own descriptor, then unlinks its now-empty entry `staging_rel`
## beneath `publication`. A non-empty replacement at that name fails instead of being removed.
export proc remove_staging(publication: FsRoot, staging_rel: Str, staging: FsRoot) [fs, error] {
  let tree = tree_entries(staging)?

  for leaf in tree.leaves {
    staging.remove(rel(leaf.path)?)
  }

  for directory in tree.directories {
    if directory != "." {
      staging.remove(rel(directory)?, dir: true)
    }
  }

  publication.remove(rel(staging_rel)?, dir: true)
}

## Removes an unpublished staging directory after `problem` and returns the error to report;
## a cleanup failure is reported together with `problem`.
export proc discard(publication: FsRoot, staging_rel: Str, staging: FsRoot, problem: Error) [fs, error] -> Error {
  match remove_staging(publication, staging_rel, staging) {
    Ok(_) => problem
    Err(cleanup) => types.PmError.PackageConflict(
      f"{problem.message}; staging {staging_rel} was left in place: {cleanup.message}",
    )
  }
}

proc publish_staged(publication: FsRoot, staging_rel: Str, staging: FsRoot, name: Str, mode: Int) {
  publication.chmod(rel(staging_rel)?, mode)
  sync_tree(staging)
  publication.rename(from: rel(staging_rel)?, to: rel(name)?)
  let parent = fp"{name}".parent.display()
  publication.fsync(rel(if parent == "" { "." } else { parent })?)
}

## Publishes `staging` (at `staging_rel` beneath `publication`) as `name` with `mode`. Every
## staged file and directory is flushed before the no-replace rename makes the tree visible,
## and `name`'s parent after it: the rename is the atomic-visibility point and the parent flush
## the durability point. An existing `name`, including a dangling symlink, fails with EEXIST and
## is left untouched; a failure before the rename removes the staging directory.
export proc publish(publication: FsRoot, staging_rel: Str, staging: FsRoot, name: Str, mode: Int) [fs, error] {
  match publish_staged(publication, staging_rel, staging, name, mode) {
    Ok(_) => {}
    Err(problem) => {
      if publication.exists(rel(staging_rel)?) {
        return Err(discard(publication, staging_rel, staging, problem))
      }

      return Err(problem)
    }
  }
}

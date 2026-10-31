##! Build the source tarball without test or controller assets.

use xinfra.version

const FORBIDDEN = [
  "pyinfra",
  "python",
  "site-packages",
  ".venv",
  "id_ed25519",
  "target/",
  "/keys/",
  "/tests/",
  "/dev/",
  ".work/",
  ".git/",
]

proc require(condition: Bool, message: Str) -> Result[Unit, Error] {
  if condition { Ok() } else { Err(error.failure(message)) }
}

proc build() [fs, process, error, io] -> Result[Path, Error] {
  let root = fs.gitroot()?
  let stage_root = fp"{root}/.work/tmp/package"
  let name = f"xinfra-{version.VERSION}"
  let stage = fp"{stage_root}/{name}"
  let dist = fp"{root}/.work/dist"
  let tarball = fp"{dist}/{name}.tar.gz"

  stage.remove()?
  dist.mkdir(parents: true)?
  stage.mkdir(parents: true)?

  for directory in ["bin", "lib", "docs", "examples"] {
    let _ = fs.copy_tree(fp"{root}/{directory}", fp"{stage}/{directory}", true, true)?
  }
  for file in ["xsht-config.ini", "README.md", "NOTICE", "LICENSE", "install.sh"] {
    fp"{root}/{file}".copy(to: fp"{stage}/{file}", overwrite: true)?
  }

  let archived = run.capture --text tar -czf $tarball -C $stage_root $name
  require(archived.status.ok, f"tar failed: {archived.stderr.trim()}")?

  let listed = run.capture --text tar -tzf $tarball
  require(listed.status.ok, f"tar listing failed: {listed.stderr.trim()}")?
  for line in listed.stdout.lines() {
    for term in FORBIDDEN {
      require(! (term in line), f"forbidden package entry {line} contains {term}")?
    }
  }
  print f"package: {tarball}"
  Ok(tarball)
}

let _ = build()?

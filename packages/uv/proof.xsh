##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

# Package builds and proofs have no network and no Python interpreter, so the
# proof sticks to project-metadata commands that need neither: `uv init
# --bare` writes pyproject.toml from an explicit `--python` request, and `uv
# version` reads and bumps it without resolving or syncing. Every uv state
# directory points into the scratch tree so the proof neither reads nor
# writes the container's home or caches.
const expected_pyproject = """[project]
name = "laputa-proof"
version = "0.2.0"
requires-python = ">=3.13"
dependencies = []
"""

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "uv")
  proof.target_elf(root, p"usr/bin/uv", "uv")
  proof.target_elf(root, p"usr/bin/uvx", "uv")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"uv ok: {pm_util.target_arch()?} binaries"
    return
  }

  let arch = pm_util.target_arch()?
  let uv = fp"{root}/usr/bin/uv"
  let uvx = fp"{root}/usr/bin/uvx"
  tempdir tmp at fp"{root}/var/tmp/proof-uv" {

    let uv_version = run.text $uv "--version"
    proof.ensure(
      uv_version.trim() == f"uv 0.12.23 ({arch}-unknown-linux-musl)",
      "uv-version",
      f"unexpected uv --version: {uv_version.trim()}",
    )
    let uvx_version = run.text $uvx "--version"
    proof.ensure(
      uvx_version.trim() == f"uvx 0.12.23 ({arch}-unknown-linux-musl)",
      "uvx-version",
      f"unexpected uvx --version: {uvx_version.trim()}",
    )

    let project = fp"{tmp}/laputa-proof"

    env ({
      HOME: fp"{tmp}/home".display(),
      XDG_CACHE_HOME: fp"{tmp}/cache".display(),
      XDG_CONFIG_HOME: fp"{tmp}/config".display(),
      XDG_DATA_HOME: fp"{tmp}/data".display(),
      UV_CACHE_DIR: fp"{tmp}/uv-cache".display(),
      UV_PYTHON_INSTALL_DIR: fp"{tmp}/uv-python".display(),
      UV_NO_CONFIG: "1",
      UV_OFFLINE: "1",
      UV_PYTHON_DOWNLOADS: "never",
    }) {
      cd $tmp {
        run $uv "init" "--bare" "--no-workspace" "--vcs" "none" "--name" "laputa-proof" "--python" "3.13" $project
      }

      cd $project {
        let current = run.text $uv "version"
        proof.ensure(
          current.trim() == "laputa-proof 0.1.0",
          "uv-version-read",
          f"unexpected uv version: {current.trim()}",
        )
        let bumped = run.text $uv "version" "--short" "--bump" "minor" "--frozen"
        proof.ensure(bumped.trim() == "0.2.0", "uv-version-bump", f"unexpected bumped version: {bumped.trim()}")
      }
    }

    let pyproject = fp"{project}/pyproject.toml".read_text()?
    proof.ensure(pyproject == expected_pyproject, "uv-init", f"unexpected pyproject.toml:\n{pyproject}")
    print "uv ok: uv/uvx --version, offline init --bare, version read and bump"
  }
}

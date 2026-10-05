##! Isolated package payload construction for the immutable plan executor.
use fingerprint
use local
use pm.env as pm_env
use recipe
use types
use util

# The PM tree is the monorepo root (pm.xsh beside pm/) in a checkout and
# /usr/lib/pm on an installed system.
## The directory holding this PM's pm.xsh and pm/ tree.
export proc pm_source_root() [fs, env, error] -> Result[Path, Error] {
  for entry in (e"XSH_MODULE_PATH" ?? "/usr/lib/pm").split(":") {
    let root = fp"{entry}"

    return root when fp"{root}/pm.xsh".exists()? and fp"{root}/pm".exists()?
  }

  return path.absolute(p".")? when p"pm.xsh".exists()? and p"pm".exists()?

  /usr/lib/pm
}

pure seeded_shell_script() -> Str {
  r"""#!/bin/xsh
error ShError = Failed(message: Str)

proc build_shell_run_argv(argv: List[Str]) [process, error] {
  if argv.len() == 0 {
    return
  }

  let status = process.run(process.command_argv(argv[0], argv))?

  if ! status.ok {
    let rendered = argv.join(" ")
    Err(ShError.Failed(message: f"command failed: {rendered}"))?
  }
}

proc build_shell_run_command_list(script: Str) [process, error] {
  for part in script.split("&&") {
    let command = part.trim()
    continue when command == "" or command == ":"
    build_shell_run_argv(process.argv_words(command)?)?
  }
}

proc build_shell_run_xshi(argv: List[Str]) [process, error] {
  let xshi_argv = ["/bin/xshi"].extend(argv)
  let status = process.run(process.command_argv("/bin/xshi", xshi_argv))?

  if ! status.ok {
    Err(ShError.Failed(message: "xshi failed"))?
  }
}

proc main(...argv: List[Str]) [process, error] {
  if argv.len() >= 2 and argv[0] == "-c" {
    build_shell_run_command_list(argv[1])?
  } else {
    build_shell_run_xshi(argv)?
  }
}

main(@args)?
"""
}

proc xsh_runner() -> Result[Path] {
  let host = (e"XSH_HOST" ?? "").trim()

  if host != "" {
    let host_path = fp"{host}"

    return host_path when host_path.exists()?
  }

  return /bin/xsh when p"/bin/xsh".exists()?

  process.which("xsh")?
}

proc regular_xsh_source(xsh: Path) -> Result[Path] {
  var source = xsh
  var depth = 0

  while depth < 16 {
    let metadata = source.metadata()?

    return source when metadata.kind != "symlink"

    let target = source.readlink()?
    source = if target.starts_with(p"/") { target } else { fp"{source.parent}/{target}" }
    depth += 1
  }

  Err(types.PmError.PackageContract(f"{xsh} has too many symlink levels"))
}

proc direct_xsh_source(xsh: Path, name: Str) -> Result[Path] {
  return regular_xsh_source(xsh) when name == "xsh"

  let sibling = fp"{xsh.parent}/{name}"
  if ! sibling.exists()? {
    return Err(types.PmError.PackageContract(f"missing direct XSH release binary {sibling}"))
  }

  regular_xsh_source(sibling)
}

proc seed_xsh_runners(root: Path, xsh: Path) {
  let bin = fp"{root}/bin"
  bin.mkdir()

  for name in ["xsh", "xshi", "xsht"] {
    let source = direct_xsh_source(xsh, name)?
    let dest = fp"{bin}/{name}"
    dest.remove(missing_ok: true)
    fs.install(source, dest, 0o755, parents: true, overwrite: true)
  }
}

## Seeds the explicitly selected XSH/PM substrate into an executor-local mutable work root.
## Completed package roots remain immutable; this function never targets a generation root.
export proc seed_executor_substrate(root: Path) [fs, process, env, error] {
  let xsh = xsh_runner()?
  seed_xsh_runners(root, xsh)

  if p"/usr/lib/xsh".exists()? {
    let _ = fs.copy_tree(/usr/lib/xsh, fp"{root}/usr/lib/xsh", parents: true, overwrite: true)?
  }

  let pm_root = pm_source_root()?
  fs.install(fp"{pm_root}/pm.xsh", fp"{root}/usr/lib/pm/pm.xsh", 0o644, parents: true, overwrite: true)
  fp"{root}/usr/lib/pm/pm".remove(missing_ok: true)
  let _ = fs.copy_tree(fp"{pm_root}/pm", fp"{root}/usr/lib/pm/pm", parents: true, overwrite: true)?

  for sh in [fp"{root}/usr/bin/sh", fp"{root}/bin/sh"] {
    sh.parent.mkdir()
    sh.remove(missing_ok: true)
    sh.write(seeded_shell_script(), mode: 0o755)
  }

  for tmp in [fp"{root}/tmp", fp"{root}/var/tmp"] {
    tmp.mkdir()
    tmp.chmod(0o1777)
  }

  fp"{root}/proc".mkdir()

  for name in ["cpuinfo", "meminfo"] {
    let source = fp"/proc/{name}"
    let dest = fp"{root}/proc/{name}"

    match source.metadata() {
      Ok(metadata) if metadata.kind == "file" => source.copy(dest, overwrite: true)
      else => {
        if ! dest.exists()? {
          dest.write("")
        }
      }
    }
  }

  fp"{root}/etc".mkdir()

  for name in ["resolv.conf", "hosts", "nsswitch.conf"] {
    let source = fp"/etc/{name}"
    let dest = fp"{root}/etc/{name}"

    match source.metadata() {
      Ok(metadata) if metadata.kind == "file" => source.copy(dest, overwrite: true)
      Ok(metadata) if metadata.kind == "symlink" => dest.write(source.read_text()?)
      else => {}
    }
  }
}

## Records the XSH runners, PM tree, and core applets that `seed_executor_substrate`
## installs, as artifact provenance. Builds compute this once per execution.
export proc executor_provenance() [fs, process, env, error] -> Result[types.ExecutorProvenance, Error] {
  let xsh = xsh_runner()?
  let core = /usr/lib/xsh
  {
    format: "laputa-executor-provenance-1",
    xsh_sha256: hash.sha256(direct_xsh_source(xsh, "xsh")?)?.hex(),
    xshi_sha256: hash.sha256(direct_xsh_source(xsh, "xshi")?)?.hex(),
    xsht_sha256: hash.sha256(direct_xsh_source(xsh, "xsht")?)?.hex(),
    pm_sha256: fingerprint.pm_tree(pm_source_root()?)?,
    core_sha256: if core.exists()? { fingerprint.core_tree(core)? } else { null },
  }
}

proc xsht_runner() -> Result[Path] {
  let xsh = xsh_runner()?
  let sibling = fp"{xsh.parent}/xsht"

  return sibling when sibling.exists()?

  return /bin/xsht when p"/bin/xsht".exists()?

  process.which("xsht")?
}

## Builds one prepared recipe into a deterministic payload tarball in executor-owned work.
export proc build_prepared_package(pkg_dir: Path, src: Path, dest: Path, tarball: Path) [fs, process, env, error] {
  let packages = local.load_package_dirs([pkg_dir])?
  let pkg = packages[0]

  # A metapackage is a graph selector, never an installable payload.  Store
  # still requires a staged byte object, but it must not contain the legacy
  # package database that payload builds append before archiving.
  if pkg.kind == types.package_meta() {
    dest.remove(missing_ok: true)
    dest.mkdir()
    tarball.parent.mkdir()
    tarball.write("laputa metapackage payload marker\n")
    return
  }

  let makeflags = e"MAKEFLAGS" ?? f"-s -j{cpu.count()}"

  env ({
    DESTDIR: dest,
    LAPUTA_ROOT: e"LAPUTA_ROOT" ?? "/",
    XSH_PM_PREFIX: pm_env.prefix,
    XSH_PM_SYSCONFDIR: pm_env.sysconfdir,
    XSH_PM_LOCALSTATEDIR: pm_env.localstatedir,
    XSH_PM_LIBDIR: pm_env.libdir,
    XSH_PM_LIBDIR_NAME: pm_env.libdir_name,
    XSH_PM_BINDIR: pm_env.bindir,
    XSH_PM_INCLUDEDIR: pm_env.includedir,
    XSH_PM_MANDIR: pm_env.mandir,
    XSH_PM_NAME: pkg.name,
    XSH_PM_VERSION: pkg.ver,
    XSH_PM_RELEASE: pkg.rel,
    # Deferred dynamic builds run from the prepared source tree.  Preserve that
    # typed staging root so recipe inputs never depend on the process cwd.
    XSH_PM_SOURCE_DIR: src.display(),
    # Dynamic recipes cannot infer their copied checkout location from the
    # source-tree working directory.  Keep it explicit for deferred build
    # programs such as the Linux Kbuild runner.
    XSH_PM_RECIPE_DIR: pkg_dir.display(),
    XSH_PM_QUIET: "1",
    MAKEFLAGS: makeflags,
    SHELL: "/bin/xshi",
  }) {
    let runner = fp"{pkg_dir}/run-package-build.xsh"
    let runner_text = """use pm.recipe

proc main(pkg_dir: Path, src: Path, dest: Path) [fs, process, env, error] {
  let pkg = recipe.load_package(pkg_dir)?
  recipe.call_prepare(pkg, src)?
  fs.remove(dest, missing_ok: true)?
  fs.mkdir(dest)?
  recipe.call_build(pkg, src, dest)?
}

main(@args)?
"""

    runner.write(runner_text)
    let trace_path = fp"{pkg_dir.parent}/run-package-build.trace"
    let xsht = xsht_runner()?
    let status = process.run(
      process.command_argv(
        xsht,
        [
          xsht,
          "trace",
          "--trace-file",
          trace_path,
          runner,
          "--",
          pkg_dir,
          src,
          dest,
        ],
      ),
    )?

    if ! status.ok {
      if status.exited() {
        return Err(types.PmError.ExtensionFailed(f"package build for {pkg.name} exited with status {status.exit_code()?}"))
      }

      return Err(types.PmError.ExtensionFailed(f"package build for {pkg.name} was signaled"))
    }
  }

  let manifest = fs.walk(dest)
    |> where .kind == "file" or .kind == "symlink"
    |> map { .path.strip_prefix(dest)? }
    |> sort-by .display()

  local.validate_and_strip_package(pkg, dest, manifest)
  let etcsums = local.collect_etcsums(dest, manifest)?
  local.write_package_db(dest, pkg, manifest, etcsums)
  # Metadata and payload share one inventory. A recipe may remove a generated
  # child such as `usr/share/man` while leaving an otherwise undeclared empty
  # parent; that parent must be present in both the receipt and the archive.
  let archive_paths = local.collect_archive_paths(dest, pkg.filetree)?
  tarball.parent.mkdir()
  archive.tar_create(tarball, dest, archive_paths, compression: "gz", overwrite: true)
}

error ScriptError = Failed(kind: Str, message: Str)

proc write_file(file_path: Path, body: Str) [fs, error] {
  file_path.parent.mkdir()?
  fs.write(file_path, body)?
}

proc write_executable(file_path: Path, body: Str) [fs, error] {
  write_file(file_path, body)?
  fs.chmod(file_path, 0o755)?
}

proc copy_file(source: Path, dest: Path) [fs, error] {
  if ! fs.exists(source)? {
    return Err(ScriptError.Failed("proof-rootfs-missing", source.display()))
  }

  dest.parent.mkdir()?
  fs.copy(source, dest, overwrite: true)?
}

proc install_proof_stage_hook(root: Path) [fs, error] {
  write_executable(
    fp"${root}/usr/lib/init/rc.d/proof-stage.boot",
    """#!/bin/xsh
proc proof_marker(line: Str) [fs] {
  match fs.write(/dev/console, f"\${line}\\n") {
    Ok(_) => {}
    Err(_) => {}
  }
}

match env.get("XSH_XINIT_PROOF_STAGE") {
  Ok(value) => {
    if value.trim() == "1" and fs.exists(/usr/lib/xinit/proof-stage.xsh)? {
      let status = process.run(
        process.command_argv(
          /bin/xsh,
          ["xsh", "/usr/lib/xinit/proof-stage.xsh"],
          /,
          {XSH_UNIX_DRY_RUN: "0"},
        ),
      )?

      if ! status.ok {
        proof_marker("LAPUTA_BOOT_PROOF_FAILED")
        abort(3)
      }

      proof_marker("LAPUTA_BOOT_PROOF_OK")
    }
  }
  Err(_) => {}
}
""",
  )?
}

proc install_xinit_proof(root: Path) [fs, error] {
  copy_file(p"proof-stage.xsh", fp"${root}/usr/lib/xinit/proof-stage.xsh")?
  install_proof_stage_hook(root)?
}

proc canonical_inittab(root: Path) [fs, error] -> Result[Str] {
  return fs.read_text(fp"${root}/etc/inittab")?
}

proc write_dry_run_inittab(root: Path) [fs, error] {
  let base_inittab = canonical_inittab(root)?

  write_file(
    fp"${root}/etc/inittab",
    f"""${base_inittab}tty1::respawn:/bin/getty 38400 tty1
""",
  )?

  write_file(fp"${root}/etc/inittab.real", base_inittab.replace("/etc/inittab", "/etc/inittab.real"))?
}

proc copy_baseinit_reference(root: Path) [fs, error] {
  let dest = fp"${root}/usr/lib/init/baseinit-reference"

  write_file(
    fp"${dest}/README",
    """baseinit reference files are no longer checked into the integration repo
""",
  )?

  write_file(
    fp"${root}/etc/rc.conf",
    """# empty proof rc.conf
""",
  )?
}

proc require_installed(root: Path, rel: Path) [fs, error] {
  let required = fp"${root}/${rel}"

  if ! fs.exists(required)? {
    return Err(ScriptError.Failed("proof-rootfs-missing", required.display()))
  }
}

proc require_packaged_binaries(root: Path) [fs, error] {
  for rel in [
    p"bin/xsh",
    p"bin/xshi",
    p"bin/xsht",
    p"usr/bin/xinit",
    p"init",
    p"usr/bin/mdev",
    p"usr/bin/getty",
    p"usr/bin/login",
    p"usr/bin/nologin",
    p"usr/bin/passwd",
    p"usr/bin/su",
    p"usr/bin/sulogin",
  ] {
    require_installed(root, rel)?
  }
}

proc assemble_rootfs(root: Path) [fs, error] {
  # Packages are installed before this script runs (see Dockerfile / README).
  # This overlay adds only proof-specific files on top.
  for dir in [
    fp"${root}/etc/rc.d",
    fp"${root}/usr/bin",
    fp"${root}/usr/lib/init/rc.d",
    fp"${root}/usr/lib/xinit/services",
    fp"${root}/bin",
    fp"${root}/var/lib/init",
  ] {
    fs.mkdir(dir)?
  }

  require_packaged_binaries(root)?
  require_installed(root, p"usr/lib/init/rc.boot")?
  require_installed(root, p"usr/lib/init/rc.shutdown")?

  write_file(
    fp"${root}/etc/hostname",
    """laputa-xsh-proof
""",
  )?

  write_file(
    fp"${root}/etc/sysctl.conf",
    """# proof rootfs sysctl fallback
""",
  )?

  write_dry_run_inittab(root)?
  install_xinit_proof(root)?
  copy_baseinit_reference(root)?
}

proc main(root: Path = p"target/laputa-proof-rootfs") [fs, error] {
  assemble_rootfs(root)?
  print $root
}

main(@args)?

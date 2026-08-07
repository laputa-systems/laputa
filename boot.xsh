error ScriptError = Failed(kind: Str, message: Str)

let ROOTFS_CACHE_VERSION = "4"

proc require_file(candidate: Path) [fs, error] {
  if ! fs.exists(candidate)? {
    return Err(ScriptError.Failed("boot-missing-file", f"missing ${candidate}"))
  }
}

proc require_ok(status: Status, kind: Str, message: Str) [error] {
  if ! status.ok {
    return Err(ScriptError.Failed(kind, message))
  }
}

pure dotenv_lookup(body: Str, name: Str) -> Str {
  for raw in body.lines() {
    let stripped = raw.trim()
    continue when stripped == "" or stripped.starts_with("#")
    let line = if stripped.starts_with("export ") { stripped.split("export ").get(1, "").trim() } else { stripped }

    if line.starts_with(f"${name}=") {
      return line.split("=").get(1, "").trim().replace("\"", "").replace("'", "")
    }
  }

  return ""
}

proc require_dotenv_value(root: Path, name: Str) [fs, error] -> Result[Str] {
  let dotenv = fp"${root}/.env"

  if ! fs.exists(dotenv)? {
    return Err(ScriptError.Failed("boot-env", f"missing ${dotenv}; set ${name}=... there"))
  }

  let value = dotenv_lookup(fs.read_text(dotenv)?, name)

  if value == "" {
    return Err(ScriptError.Failed("boot-env", f"missing ${name} in ${dotenv}"))
  }

  return value
}

proc trace_line(trace: Path, message: Str) [fs, error] {
  print $message
  fs.mkdir(trace.parent)?
  let existing = if fs.exists(trace)? { fs.read_text(trace)? } else { "" }

  fs.write(
    trace,
    f"""${existing}${message}
""",
  )?
}

proc trace_file(trace: Path, label: Str, path_value: Path) [fs, error] {
  let meta = fs.metadata(path_value)?
  trace_line(trace, f"${label}: ${path_value} size=${meta.size} mode=${meta.mode} modified=${meta.modified}")?
}

proc trace_file_probe(trace: Path, file_tool: Path, label: Str, path_value: Path) [fs, process, error] {
  match run.text $file_tool $path_value {
    Ok(out) => trace_line(trace, f"${label}: ${out.trim()}")?
    Err(err) => trace_line(trace, f"${label}: file probe failed: ${err.message}")?
  }
}

proc trace_optional_file_probe(trace: Path, label: Str, path_value: Path) [fs, process, error] {
  match process.which("file") {
    Ok(file_tool) => trace_file_probe(trace, file_tool, label, path_value)?
    Err(_) => trace_line(trace, f"${label}: file(1) unavailable")?
  }
}

proc env_value(name: Str, fallback: Str) [env] -> Str {
  let value = env.get(name) ?? ""

  if value == "" {
    return fallback
  }

  return value
}

proc packages_root(root: Path) [fs, env, error] -> Result[Path] {
  let configured = env.get("LAPUTA_PACKAGES_ROOT") ?? ""

  if configured.trim() != "" {
    return fp"${configured}"
  }

  let home = env.get("HOME") ?? ""

  if home != "" {
    let home_root = fp"${home}/d/laputa-systems/packages"

    if fs.exists(home_root)? {
      return home_root
    }
  }

  let sibling = fp"${root.parent}/packages"

  if fs.exists(sibling)? {
    return sibling
  }

  if home != "" {
    return fp"${home}/d/laputa-systems/packages"
  }

  return sibling
}

proc package_arch() [env] -> Str {
  let arch = (env.get("LAPUTA_PACKAGE_ARCH") ?? "aarch64").trim()

  if arch == "amd64" {
    return "x86_64"
  }

  return arch
}

proc require_kernel_arch(trace: Path, kernel: Path, arch: Str) [fs, process, error] {
  match process.which("file") {
    Ok(file_tool) => {
      let desc = run.text $file_tool $kernel ?
      trace_line(trace, f"kernel file: ${desc.trim()}")?

      if arch == "x86_64" and ! ("Linux kernel x86" in desc or "bzImage" in desc) {
        return Err(ScriptError.Failed("boot-linux-kernel-arch", f"expected x86_64 kernel, got: ${desc.trim()}"))
      }

      if arch == "aarch64" and ! ("ARM64 boot executable" in desc) {
        return Err(ScriptError.Failed("boot-linux-kernel-arch", f"expected aarch64 kernel, got: ${desc.trim()}"))
      }
    }
    Err(_) => trace_line(trace, "kernel file: file(1) unavailable")?
  }
}

proc local_xsh_source_root(root: Path) [env, error] -> Result[Path] {
  let raw = env_value("XSH_SOURCE_ROOT", "")

  if raw != "" {
    return fp"${raw}"
  }

  return fp"${root.parent.parent}/laputa-systems/xsh"
}

proc local_xinit_source_root(root: Path) [env, error] -> Result[Path] {
  let raw = env_value("XINIT_SOURCE_ROOT", "")

  if raw != "" {
    return fp"${raw}"
  }

  return fp"${root.parent.parent}/laputa-systems/xinit"
}

proc host_xsh(root: Path) [fs, process, env, error] -> Result[Path] {
  let raw = env_value("XSH_HOST", "")

  if raw != "" {
    return fp"${raw}"
  }

  let candidate = fp"${local_xsh_source_root(root)?}/target/debug/xsh"

  if fs.exists(candidate)? {
    return candidate
  }

  return process.which("xsh")?
}

proc ensure_host_xsh(root: Path) [fs, process, env, error] -> Result[Path] {
  let xsh = host_xsh(root)?

  if fs.exists(xsh)? {
    return xsh
  }

  let source_root = local_xsh_source_root(root)?
  require_file(fp"${source_root}/Cargo.toml")?
  let cargo = process.which("cargo")?

  require_ok(
    process.run(process.command_argv(cargo, ["cargo", "build", "--bin", "xsh"], source_root))?,
    "boot-host-xsh",
    f"failed to build host xsh at ${source_root}",
  )?

  let built = fp"${source_root}/target/debug/xsh"
  require_file(built)?
  return built
}

proc repo_url_for(repo_url: Str, rel: Str) [] -> Str {
  if repo_url.ends_with("/") {
    return f"${repo_url}${rel}"
  }

  return f"${repo_url}/${rel}"
}

proc download_file(url: Str, dest: Path) [fs, net, error] {
  let tmp = fp"${dest.parent}/.${dest.name}.tmp"
  fs.mkdir(dest.parent)?
  fs.remove(tmp, missing_ok: true)?

  let response = net.download({
    url,
    dest: tmp,
    atomic: true,
    overwrite: true,
    connect_timeout: 10s,
    fail_status: true,
  })?

  fs.rename(tmp, dest, overwrite: true)?
  let _ = response
}

proc remove_tree(path_value: Path) [fs, error] {
  if ! fs.exists(path_value)? {
    return
  }

  let meta = path_value.metadata()?

  if meta.kind != "dir" {
    path_value.remove()?
    return
  }

  for child in fs.ls(path_value)? {
    if child.kind == "dir" {
      remove_tree(child.path)?
    } else {
      child.path.remove()?
    }
  }

  path_value.remove_dir()?
}

proc require_fresh_packaged_kernel(root: Path, package: Path) [fs, env, error] {
  let inputs = [
    fp"${packages_root(root)?}/repo/linux/PKGBUILD.xsh",
    fp"${packages_root(root)?}/repo/linux/kbuild.xsh",
    fp"${packages_root(root)?}/repo/linux/files/kernel.config",
    fp"${packages_root(root)?}/repo/linux/files/sysreg-defs.h",
    fp"${packages_root(root)?}/repo/linux/files/generated/timeconst.h",
    fp"${packages_root(root)?}/repo/linux/files/generated/bounds.h",
    fp"${packages_root(root)?}/repo/linux/files/generated/asm-offsets.h",
    fp"${packages_root(root)?}/repo/linux/files/generated/rq-offsets.h",
    fp"${packages_root(root)?}/repo/linux/files/generated/sha256-core.S",
    fp"${packages_root(root)?}/repo/linux/files/generated/sha512-core.S",
  ]

  let package_modified = fs.metadata(package)?.modified

  for input in inputs {
    require_file(input)?

    if fs.metadata(input)?.modified > package_modified {
      return Err(
        ScriptError.Failed(
          "boot-stale-kernel",
          f"packaged kernel ${package} is older than ${input}; rebuild it with `make proof-kernel` before `make boot`",
        ),
      )
    }
  }
}

proc packaged_kernel_package(root: Path) [fs, net, env, error] -> Result[Path] {
  let explicit = env_value("XSH_BOOT_KERNEL_PACKAGE", "")

  if explicit != "" {
    let explicit_package = fp"${explicit}"
    require_file(explicit_package)?
    return explicit_package
  }

  let arch = (env.get("LAPUTA_PACKAGE_ARCH") ?? "aarch64").trim()
  let package = fp"${root}/target/laputa-installer/linux-${arch}.tar.gz"

  if fs.exists(package)? {
    return package
  }

  let repo_url = env_value("LAPUTA_REPO_URL", "https://laputa.17166969.xyz")
  let index_path = fp"${root}/target/linux-vm/remote-index.json"
  download_file(repo_url_for(repo_url, "index.json"), index_path)?
  let rows: List[Record] = json.read(index_path)?

  for row in rows {
    let name: Str = row.get("name")?
    let row_arch: Str = row.get("arch")?

    if name == "linux" and row_arch == arch {
      let tarball_rel: Str = row.get("tarball")?
      download_file(repo_url_for(repo_url, tarball_rel), package)?
      return package
    }
  }

  return Err(ScriptError.Failed("boot-missing-file", f"linux package for ${arch} not found in ${repo_url}"))
}

proc ensure_packaged_kernel(root: Path, kernel: Path) [fs, net, env, error] {
  let package = packaged_kernel_package(root)?
  let staging = fp"${root}/target/linux-vm/package-extract"
  let extracted = fp"${staging}/boot/vmlinuz-7.0.5"

  if fs.exists(kernel)? and fs.metadata(kernel)?.modified >= fs.metadata(package)?.modified {
    return
  }

  kernel.parent().mkdir()?
  fs.remove(staging, missing_ok: true)?
  staging.mkdir()?
  archive.tar_extract(package, staging, 0, "auto", true)?
  require_file(extracted)?
  fs.copy(extracted, kernel, overwrite: true)?
  fs.remove(staging, missing_ok: true)?
}

proc image_exists(sh: Path, docker: Path, image: Str) [process, error] -> Result[Bool] {
  let status = process.run(
    process.command_argv(
      sh,
      [
        sh.display(),
        "-c",
        "docker_bin=$1; image=$2; \"$docker_bin\" image inspect \"$image\" >/dev/null 2>&1",
        "docker-image-exists",
        docker.display(),
        image,
      ],
    ),
  )?

  return status.ok
}

proc rootfs_image(sh: Path, docker: Path) [process, env, error] -> Result[Str] {
  let requested = (env.get("XSH_BOOT_ROOTFS_IMAGE") ?? "").trim()

  if requested != "" {
    if image_exists(sh, docker, requested)? {
      return requested
    }

    return Err(ScriptError.Failed("boot-rootfs-image", f"missing requested Docker image ${requested}"))
  }

  if image_exists(sh, docker, "laputa-xsh-proof")? {
    return "laputa-xsh-proof"
  }

  if image_exists(sh, docker, "laputa-scratch-build-env")? {
    return "laputa-scratch-build-env"
  }

  return Err(
    ScriptError.Failed("boot-rootfs-image", "missing Docker image laputa-xsh-proof or laputa-scratch-build-env"),
  )
}

proc docker_image_id(docker: Path, image: Str) [process, error] -> Result[Str] {
  return run.text $docker "image" "inspect" "--format" "{{.Id}}" $image ?
}

proc docker_quiet(sh: Path, docker: Path, script: Str, args: List[Str]) [process, error] {
  require_ok(
    process.run(process.command_argv(sh, [sh.display(), "-c", script, "docker-quiet", docker.display()].extend(args)))?,
    "boot-rootfs-docker",
    "Docker rootfs export command failed",
  )?
}

proc ensure_linux_sh(rootfs_dir: Path) [fs, error] {
  let sh_path = fp"${rootfs_dir}/usr/bin/sh"
  fs.remove(sh_path, missing_ok: true)?
  fs.symlink(../bin/xsh, sh_path)?
}

proc linux_loop_image_name() [env] -> Str {
  return (env.get("XSH_LINUX_LOOP_IMAGE") ?? "laputa-linux-loop-env").trim()
}

proc ensure_linux_loop_xinit(rootfs_dir: Path, work: Path, sh: Path, docker: Path) [fs, process, env, error] {
  let out = fp"${work}/xinit"

  docker_quiet(
    sh,
    docker,
    """docker_bin=$1
image=$2
out_dir=$3
container=$("$docker_bin" create "$image" /usr/bin/xinit)
cleanup() {
  "$docker_bin" rm "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT
"$docker_bin" cp "$container:/usr/bin/xinit" "$out_dir/xinit"
""",
    [linux_loop_image_name(), work.display()],
  )?

  require_file(out)?
  fs.copy(out, fp"${rootfs_dir}/init", overwrite: true)?
  fs.copy(out, fp"${rootfs_dir}/usr/bin/xinit", overwrite: true)?
  fs.chmod(fp"${rootfs_dir}/init", 0o755)?
  fs.chmod(fp"${rootfs_dir}/usr/bin/xinit", 0o755)?
}

proc install_linux_only_runtime(root: Path, work: Path, rootfs_dir: Path) [fs, process, env, error] {
  let xsh = ensure_host_xsh(root)?

  run_pm(
    root,
    xsh,
    [
      "install",
      rootfs_dir.display(),
      fp"${work}/runtime-work".display(),
      fp"${work}/runtime-out".display(),
      "baselayout",
      "xsh",
      "xinit",
    ],
  )?

  fs.remove(fp"${rootfs_dir}/init", missing_ok: true)?
  fs.symlink(p"usr/bin/xinit", fp"${rootfs_dir}/init")?
  ensure_linux_sh(rootfs_dir)?
}

proc write_linux_only_rootfs(root: Path, work: Path, rootfs: Path, sh: Path, _: Path) [fs, process, env, error] {
  let rootfs_dir = fp"${work}/linux-only-rootfs"
  fs.remove(rootfs_dir, missing_ok: true)?
  rootfs_dir.mkdir()?

  for dir in [
    fp"${rootfs_dir}/dev",
    fp"${rootfs_dir}/etc",
    fp"${rootfs_dir}/proc",
    fp"${rootfs_dir}/run",
    fp"${rootfs_dir}/sys",
    fp"${rootfs_dir}/tmp",
    fp"${rootfs_dir}/usr",
    fp"${rootfs_dir}/usr/bin",
  ] {
    dir.mkdir()?
  }

  fs.write(
    fp"${rootfs_dir}/etc/inittab",
    """# Intentionally empty. This loop exists to reach PID 1 with xinit only.
""",
  )?

  install_linux_only_runtime(root, work, rootfs_dir)?

  fs.write(
    fp"${rootfs_dir}/etc/inittab",
    """# Intentionally empty. This loop exists to reach PID 1 with xinit only.
""",
  )?

  fs.remove(rootfs, missing_ok: true)?
  write_rootfs_image(root, rootfs_dir, rootfs, "64M", sh)?
  require_file(rootfs)?
  trace_file(fp"${work}/boot.trace", "linux-only rootfs", rootfs)?
}

proc image_size_bytes(size: Str) [error] -> Result[Int] {
  if size.ends_with("M") {
    return size.replace("M", "").parse_int()? * 1024 * 1024
  }

  return size.parse_int()?
}

proc put(data: Bytes, offset: Int, replacement: Bytes) [error] -> Result[Bytes] {
  return bytes.concat(
    [
      data.slice(offset: 0, length: offset),
      replacement,
      data.slice(offset: offset + replacement.len(), length: data.len() - offset - replacement.len()),
    ],
  )
}

proc put_le(data: Bytes, offset: Int, value: Int, width: Int) [error] -> Result[Bytes] {
  return put(data, offset, bytes.pack_le(value, width)?)?
}

proc gpt_name(name: Str) [error] -> Result[Bytes] {
  let raw = bytes.from_text(name)
  var parts = [bytes.zero(0)?]
  var index = 0

  while index < raw.len() and index < 36 {
    parts = parts.push(bytes.from_ints([bytes.unpack_le(raw, 1, offset: index)?, 0])?)
    index += 1
  }

  let encoded = bytes.concat(parts)
  return bytes.concat([encoded, bytes.zero(72 - encoded.len())?])
}

proc gpt_entry(type_guid: Bytes, part_guid: Bytes, start_lba: Int, end_lba: Int, name: Str) [error] -> Result[Bytes] {
  var entry = bytes.zero(128)?
  entry = put(entry, 0, type_guid)?
  entry = put(entry, 16, part_guid)?
  entry = put_le(entry, 32, start_lba, 8)?
  entry = put_le(entry, 40, end_lba, 8)?
  entry = put(entry, 56, gpt_name(name)?)?
  return entry
}

proc protective_mbr(total_sectors: Int) [error] -> Result[Bytes] {
  var sector = bytes.zero(512)?
  sector = put(sector, 447, bytes.from_ints([0, 2, 0])?)?
  sector = put(sector, 450, bytes.from_ints([238])?)?
  sector = put(sector, 451, bytes.from_ints([255, 255, 255])?)?
  sector = put_le(sector, 454, 1, 4)?
  sector = put_le(sector, 458, total_sectors - 1, 4)?
  sector = put(sector, 510, bytes.from_ints([85, 170])?)?
  return sector
}

proc gpt_header(
  current_lba: Int,
  backup_lba: Int,
  first_usable: Int,
  last_usable: Int,
  disk_guid: Bytes,
  entries_lba: Int,
  entry_count: Int,
  entry_size: Int,
  entries_crc: Int,
) [error] -> Result[Bytes] {
  var header = bytes.zero(512)?
  header = put(header, 0, bytes.from_text("EFI PART"))?
  header = put_le(header, 8, 65536, 4)?
  header = put_le(header, 12, 92, 4)?
  header = put_le(header, 24, current_lba, 8)?
  header = put_le(header, 32, backup_lba, 8)?
  header = put_le(header, 40, first_usable, 8)?
  header = put_le(header, 48, last_usable, 8)?
  header = put(header, 56, disk_guid)?
  header = put_le(header, 72, entries_lba, 8)?
  header = put_le(header, 80, entry_count, 4)?
  header = put_le(header, 84, entry_size, 4)?
  header = put_le(header, 88, entries_crc, 4)?
  return put_le(header, 16, hash.crc32(header.slice(offset: 0, length: 92)), 4)?
}

proc write_rootfs_gpt(image: Path, rootfs: Path) [fs, error] {
  let sector_size = 512
  let rootfs_bytes = rootfs.metadata()?.size
  let rootfs_sectors = rootfs_bytes / sector_size
  let total_sectors = rootfs_sectors + 65536
  let entry_count = 128
  let entry_size = 128
  let entry_sectors = 32
  let first_usable = 2 + entry_sectors
  let last_usable = total_sectors - entry_sectors - 2
  let primary_entries_lba = 2
  let backup_entries_lba = total_sectors - entry_sectors - 1
  let root_start = 2048
  let root_end = root_start + rootfs_sectors - 1
  fs.remove(image, missing_ok: true)?
  fs.write(image, b"")?
  image.truncate(total_sectors * sector_size)?

  let root_type = bytes.from_ints(
    [
      175,
      61,
      198,
      15,
      131,
      132,
      114,
      71,
      142,
      121,
      61,
      105,
      216,
      71,
      125,
      228,
    ],
  )?

  let disk_guid = bytes.zero(16)?

  let root_guid = bytes.from_ints(
    [
      51,
      51,
      51,
      51,
      51,
      51,
      51,
      51,
      51,
      51,
      51,
      51,
      51,
      51,
      51,
      51,
    ],
  )?

  let entries = bytes.concat(
    [
      gpt_entry(root_type, root_guid, root_start, root_end, "LAPUTA_ROOT")?,
      bytes.zero(entry_count * entry_size - entry_size)?,
    ],
  )

  let entries_crc = hash.crc32(entries)

  let primary_header = gpt_header(
    1,
    total_sectors - 1,
    first_usable,
    last_usable,
    disk_guid,
    primary_entries_lba,
    entry_count,
    entry_size,
    entries_crc,
  )?

  let backup_header = gpt_header(
    total_sectors - 1,
    1,
    first_usable,
    last_usable,
    disk_guid,
    backup_entries_lba,
    entry_count,
    entry_size,
    entries_crc,
  )?

  let mbr_written = bytes.write_at(image, 0, protective_mbr(total_sectors)?)?
  let primary_entries_written = bytes.write_at(image, primary_entries_lba * sector_size, entries)?
  let primary_header_written = bytes.write_at(image, sector_size, primary_header)?
  let backup_entries_written = bytes.write_at(image, backup_entries_lba * sector_size, entries)?
  let backup_header_written = bytes.write_at(image, (total_sectors - 1) * sector_size, backup_header)?

  let root_copy = bytes.copy_file(
    rootfs,
    image,
    source_offset: 0,
    dest_offset: root_start * sector_size,
    length: rootfs_bytes,
    create: false,
    truncate: false,
  )?

  let _ = {
    mbr_written,
    primary_entries_written,
    primary_header_written,
    backup_entries_written,
    backup_header_written,
    root_copy,
  }
}

proc write_rootfs_image(
  root: Path,
  rootfs_dir: Path,
  rootfs: Path,
  rootfs_size: Str,
  sh: Path,
) [fs, process, env, error] {
  let _ = sh
  let xsh = ensure_host_xsh(root)?
  fs.remove(rootfs, missing_ok: true)?
  fs.write(rootfs, b"")?
  rootfs.truncate(image_size_bytes(rootfs_size)?)?

  require_ok(
    process.run(
      process.command_argv(
        xsh,
        [
          "xsh",
          fp"${packages_root(root)?}/repo/laputa-fs/files/mkfs.ext4.xsh".display(),
          "--",
          "-q",
          "-O",
          "^64bit,^metadata_csum",
          "-E",
          "no_copy_xattrs",
          "-L",
          "LAPUTA_ROOT",
          "-d",
          rootfs_dir.display(),
          rootfs.display(),
        ],
        root,
        {XSH_MODULE_PATH: fp"${root}/laputa".display()},
      ),
    )?,
    "boot-rootfs-image",
    "native XSH rootfs image creation failed",
  )?
}

proc ensure_tailscale_state_image(root: Path, state_image: Path, sh: Path) [fs, process, env, error] {
  if fs.exists(state_image)? {
    return
  }

  let state_seed = fp"${root}/target/linux-vm/tailscale-state-seed"
  fs.remove(state_seed, missing_ok: true)?
  state_seed.mkdir()?
  write_rootfs_image(root, state_seed, state_image, "64M", sh)?
  fs.remove(state_seed, missing_ok: true)?
}

proc run_pm(root: Path, xsh: Path, argv: List[Str]) [fs, process, env, error] {
  let repo_url = env_value("LAPUTA_REPO_URL", "https://laputa.17166969.xyz")
  let arch = env_value("LAPUTA_PACKAGE_ARCH", "aarch64")
  let host_xsh_path = env_value("XSH_HOST", xsh.display())

  require_ok(
    process.run(
      process.command_argv(
        xsh,
        ["xsh", fp"${packages_root(root)?}/pm.xsh".display(), "--"].extend(argv),
        root,
        {
          XSH_MODULE_PATH: packages_root(root)?.display(),
          XSH_PM_REPO: repo_url,
          XSH_PM_PUBLIC_REPO: repo_url,
          XSH_PM_ARCH: arch,
          XSH_PM_BUILD_ARCH: env.get("XSH_PM_BUILD_ARCH") ?? "",
          XSH_PM_TARGET_ARCH: env.get("XSH_PM_TARGET_ARCH") ?? arch,
          XSH_HOST: host_xsh_path,
          XSH_PM_BUILD_CHROOT: "0",
        },
      ),
    )?,
    "boot-pm",
    "PM command failed",
  )?
}

proc ensure_boot_runtime(root: Path, rootfs_dir: Path, _: Path) [fs, process, env, error] {
  let xsh = ensure_host_xsh(root)?

  run_pm(
    root,
    xsh,
    [
      "build-install",
      rootfs_dir.display(),
      fp"${root}/target/linux-vm/xsh-runtime-build-root".display(),
      fp"${root}/target/linux-vm/xsh-runtime-work".display(),
      fp"${root}/target/linux-vm/xsh-runtime-out".display(),
      fp"${packages_root(root)?}/repo/baselayout".display(),
      fp"${packages_root(root)?}/repo/xsh".display(),
      fp"${packages_root(root)?}/repo/xinit".display(),
    ],
  )?

  fs.remove(fp"${rootfs_dir}/init", missing_ok: true)?
  fs.symlink(p"usr/bin/xinit", fp"${rootfs_dir}/init")?
  ensure_linux_sh(rootfs_dir)?
  install_local_xinit(root, rootfs_dir)?
  ensure_boot_mdevd(root, rootfs_dir)?
  ensure_boot_sudo_rs(root, rootfs_dir)?
}

proc ensure_boot_runtime_if_missing(root: Path, rootfs_dir: Path, sh: Path) [fs, process, env, error] {
  if fs.exists(fp"${rootfs_dir}/init")? and fs.exists(fp"${rootfs_dir}/usr/bin/xinit")? and fs.exists(
    fp"${rootfs_dir}/bin/xsh",
  )? and fs.exists(fp"${rootfs_dir}/bin/xshi")? and fs.exists(fp"${rootfs_dir}/usr/bin/su")? and fs.exists(
    fp"${rootfs_dir}/usr/bin/cat",
  )? {
    return
  }

  ensure_boot_runtime(root, rootfs_dir, sh)?
}

proc ensure_boot_tailscale(root: Path, rootfs_dir: Path) [fs, process, env, error] {
  if fs.exists(fp"${rootfs_dir}/usr/bin/tailscale")? and fs.exists(fp"${rootfs_dir}/usr/bin/tailscaled")? {
    return
  }

  let xsh = ensure_host_xsh(root)?
  remove_tree(fp"${root}/target/linux-vm/sudo-rs-runtime-work")?
  remove_tree(fp"${root}/target/linux-vm/sudo-rs-runtime-out")?

  run_pm(
    root,
    xsh,
    [
      "install",
      rootfs_dir.display(),
      fp"${root}/target/linux-vm/tailscale-runtime-work".display(),
      fp"${root}/target/linux-vm/tailscale-runtime-out".display(),
      "tailscale",
    ],
  )?
}

proc ensure_boot_mdevd(root: Path, rootfs_dir: Path) [fs, process, env, error] {
  if fs.exists(fp"${rootfs_dir}/usr/bin/mdevd")? {
    return
  }

  let xsh = ensure_host_xsh(root)?
  remove_tree(fp"${root}/target/linux-vm/mdevd-runtime-work")?
  remove_tree(fp"${root}/target/linux-vm/mdevd-runtime-out")?

  run_pm(
    root,
    xsh,
    [
      "install",
      rootfs_dir.display(),
      fp"${root}/target/linux-vm/mdevd-runtime-work".display(),
      fp"${root}/target/linux-vm/mdevd-runtime-out".display(),
      "mdevd",
    ],
  )?
}

proc ensure_boot_sudo_rs(root: Path, rootfs_dir: Path) [fs, process, env, error] {
  if fs.exists(fp"${rootfs_dir}/usr/bin/sudo")? and fs.exists(fp"${rootfs_dir}/usr/bin/su")? and fs.exists(
    fp"${rootfs_dir}/etc/pam.d/su",
  )? and fs.exists(fp"${rootfs_dir}/usr/lib/libgcc_s.so.1")? {
    return
  }

  let xsh = ensure_host_xsh(root)?
  remove_tree(fp"${root}/target/linux-vm/sudo-rs-runtime-work")?
  remove_tree(fp"${root}/target/linux-vm/sudo-rs-runtime-out")?

  # llvm-toolchain previously shipped these stubs; gnu-stubs now owns them.
  # Remove the old copies so the PM can install gnu-stubs cleanly without
  # hitting the archive-extract symlink-overwrite limitation.
  for path_value in [
    fp"${rootfs_dir}/usr/lib/crtbeginS.o",
    fp"${rootfs_dir}/usr/lib/crtendS.o",
    fp"${rootfs_dir}/usr/lib/libgcc_s.so",
    fp"${rootfs_dir}/usr/lib/libgcc_s.so.1",
  ] {
    fs.remove(path_value, missing_ok: true)?
  }

  run_pm(
    root,
    xsh,
    [
      "install",
      rootfs_dir.display(),
      fp"${root}/target/linux-vm/sudo-rs-runtime-work".display(),
      fp"${root}/target/linux-vm/sudo-rs-runtime-out".display(),
      "linux-pam",
      "sudo-rs",
    ],
  )?

  print "ensuring sudo-rs runtime: checking files"
  require_file(fp"${rootfs_dir}/usr/bin/su")?
  require_file(fp"${rootfs_dir}/etc/pam.d/su")?
  require_file(fp"${rootfs_dir}/usr/lib/libgcc_s.so")?
  require_file(fp"${rootfs_dir}/usr/lib/libgcc_s.so.1")?
  print "ensuring sudo-rs runtime: ok"
}

proc sync_local_core_applets(root: Path, rootfs_dir: Path) [fs, env, error] {
  for command_name in ["xsh", "xshi", "xsht"] {
    require_file(fp"${rootfs_dir}/bin/${command_name}")?
  }

  # The xsh package ships core applets from a pinned upstream commit. For local
  # dev boots, sync the working-tree core applets (e.g. ifup's DHCP support).
  let core_src = fp"${local_xsh_source_root(root)?}/core"

  if fs.exists(core_src)? {
    let core_dest = fp"${rootfs_dir}/usr/lib/xsh/core"
    remove_tree(core_dest)?

    for entry in fs.walk(core_src, gitignore: false)? |> where .kind == "file" and .ext == "xsh" {
      let rel = entry.path.strip_prefix(core_src)?.display()

      if ! rel.starts_with("tests/") {
        let out = fp"${core_dest}/${rel.replace(".xsh", "")}"
        fs.mkdir(out.parent)?
        fs.copy(entry.path, out, overwrite: true)?
        let text = fs.read_text(out)?

        let normalized = text.replace("#!/usr/local/bin/xsh", "#!/bin/xsh").replace(
          "#!/usr/bin/env -S xsh",
          "#!/bin/xsh",
        )

        fs.write(out, normalized)?
        fs.chmod(out, 0o755)?
      }
    }

    for entry in fs.children(core_dest)? |> where .kind == "file" and .name != "su" {
      let link = fp"${rootfs_dir}/usr/bin/${entry.name}"
      fs.remove(link, missing_ok: true)?
      fs.symlink(fp"../lib/xsh/core/${entry.name}", link)?
    }
  }
}

proc install_local_xinit(root: Path, rootfs_dir: Path) [fs, env, error] {
  let source = fp"${local_xinit_source_root(root)?}/xinit.xsh"
  let dest = fp"${rootfs_dir}/usr/bin/xinit"
  require_file(source)?
  fs.install(source, dest, 0o755, parents: true, overwrite: true)?
  fs.write(dest, fs.read_text(dest)?.replace("#!/usr/local/bin/xsh", "#!/bin/xsh"))?
  fs.chmod(dest, 0o755)?
  fs.remove(fp"${rootfs_dir}/usr/bin/init", missing_ok: true)?
  fs.symlink(p"xinit", fp"${rootfs_dir}/usr/bin/init")?
  fs.remove(fp"${rootfs_dir}/init", missing_ok: true)?
  fs.symlink(p"usr/bin/xinit", fp"${rootfs_dir}/init")?
}

proc native_proof_rootfs_id(root: Path) [fs, env, error] -> Result[Str] {
  var body = """native-proof-rootfs
"""

  for path_value in [
    fp"${packages_root(root)?}/pm.xsh",
    fp"${packages_root(root)?}/pm/build.xsh",
    fp"${packages_root(root)?}/pm/buildroot.xsh",
    fp"${packages_root(root)?}/pm/cli.xsh",
    fp"${packages_root(root)?}/pm/extensions.xsh",
    fp"${packages_root(root)?}/pm/install.xsh",
    fp"${packages_root(root)?}/pm/local.xsh",
    fp"${packages_root(root)?}/pm/remote.xsh",
    fp"${packages_root(root)?}/pm/repo.xsh",
    fp"${packages_root(root)?}/pm/sources.xsh",
    fp"${packages_root(root)?}/pm/types.xsh",
    fp"${packages_root(root)?}/pm/util.xsh",
    fp"${packages_root(root)?}/pm/world.xsh",
    fp"${packages_root(root)?}/repo/baselayout/PKGBUILD.xsh",
    fp"${packages_root(root)?}/repo/xsh/PKGBUILD.xsh",
    fp"${packages_root(root)?}/repo/xinit/PKGBUILD.xsh",
    fp"${local_xinit_source_root(root)?}/xinit.xsh",
  ] {
    body = f"""${body}${path_value.display()} ${hash.sha256(path_value)?.hex()}
"""
  }

  return body
}

proc native_userspace_e2e_rootfs_id(root: Path) [fs, env, error] -> Result[Str] {
  var body = """native-userspace-e2e-rootfs
"""

  for path_value in [
    fp"${packages_root(root)?}/pm.xsh",
    fp"${packages_root(root)?}/pm/build.xsh",
    fp"${packages_root(root)?}/pm/buildroot.xsh",
    fp"${packages_root(root)?}/pm/cli.xsh",
    fp"${packages_root(root)?}/pm/extensions.xsh",
    fp"${packages_root(root)?}/pm/install.xsh",
    fp"${packages_root(root)?}/pm/local.xsh",
    fp"${packages_root(root)?}/pm/remote.xsh",
    fp"${packages_root(root)?}/pm/repo.xsh",
    fp"${packages_root(root)?}/pm/sources.xsh",
    fp"${packages_root(root)?}/pm/types.xsh",
    fp"${packages_root(root)?}/pm/util.xsh",
    fp"${packages_root(root)?}/pm/world.xsh",
    fp"${packages_root(root)?}/repo/baselayout/PKGBUILD.xsh",
    fp"${packages_root(root)?}/repo/xsh/PKGBUILD.xsh",
    fp"${packages_root(root)?}/repo/xinit/PKGBUILD.xsh",
    fp"${packages_root(root)?}/repo/mdevd/PKGBUILD.xsh",
    fp"${packages_root(root)?}/repo/linux-pam/PKGBUILD.xsh",
    fp"${packages_root(root)?}/repo/sudo-rs/PKGBUILD.xsh",
    fp"${packages_root(root)?}/repo/sudo-rs/proof.xsh",
    fp"${packages_root(root)?}/repo/mdevd/service.xsh",
    fp"${local_xinit_source_root(root)?}/xinit.xsh",
    fp"${root}/boot.xsh",
  ] {
    body = f"""${body}${path_value.display()} ${hash.sha256(path_value)?.hex()}
"""
  }

  return body
}

proc assemble_native_proof_rootfs(
  root: Path,
  rootfs_dir: Path,
  sh: Path,
  tailscale_probe: Bool,
) [fs, process, env, error] {
  let _ = sh
  let xsh = ensure_host_xsh(root)?
  remove_tree(fp"${root}/target/linux-vm/native-rootfs-build-root")?
  remove_tree(fp"${root}/target/linux-vm/native-rootfs-work")?
  remove_tree(fp"${root}/target/linux-vm/native-rootfs-out")?
  remove_tree(rootfs_dir)?
  fs.mkdir(rootfs_dir)?

  run_pm(
    root,
    xsh,
    [
      "build-install",
      rootfs_dir.display(),
      fp"${root}/target/linux-vm/native-rootfs-build-root".display(),
      fp"${root}/target/linux-vm/native-rootfs-work".display(),
      fp"${root}/target/linux-vm/native-rootfs-out".display(),
      fp"${packages_root(root)?}/repo/baselayout".display(),
      fp"${packages_root(root)?}/repo/xsh".display(),
      fp"${packages_root(root)?}/repo/xinit".display(),
    ],
  )?

  fs.remove(fp"${rootfs_dir}/init", missing_ok: true)?
  fs.symlink(p"usr/bin/xinit", fp"${rootfs_dir}/init")?
  ensure_linux_sh(rootfs_dir)?
  install_local_xinit(root, rootfs_dir)?
  install_rootfs_overlay(root, rootfs_dir, true, tailscale_probe, false)?
  write_rootfs_cache(root, rootfs_dir, "native-proof-rootfs", native_proof_rootfs_id(root)?, true)?
}

proc assemble_native_userspace_e2e_rootfs(root: Path, rootfs_dir: Path, sh: Path) [fs, process, env, error] {
  let _ = sh
  let xsh = ensure_host_xsh(root)?
  remove_tree(fp"${root}/target/linux-vm/native-userspace-e2e-build-root")?
  remove_tree(fp"${root}/target/linux-vm/native-userspace-e2e-work")?
  remove_tree(fp"${root}/target/linux-vm/native-userspace-e2e-out")?
  remove_tree(rootfs_dir)?
  fs.mkdir(rootfs_dir)?

  run_pm(
    root,
    xsh,
    [
      "build-install",
      rootfs_dir.display(),
      fp"${root}/target/linux-vm/native-userspace-e2e-build-root".display(),
      fp"${root}/target/linux-vm/native-userspace-e2e-work".display(),
      fp"${root}/target/linux-vm/native-userspace-e2e-out".display(),
      fp"${packages_root(root)?}/repo/baselayout".display(),
      fp"${packages_root(root)?}/repo/xsh".display(),
      fp"${packages_root(root)?}/repo/xinit".display(),
    ],
  )?

  fs.remove(fp"${rootfs_dir}/init", missing_ok: true)?
  fs.symlink(p"usr/bin/xinit", fp"${rootfs_dir}/init")?
  ensure_linux_sh(rootfs_dir)?
  ensure_boot_mdevd(root, rootfs_dir)?

  # mdevd is installed from the mirror to save a C cross-build; the published
  # package predates the service-file move into the mdevd package, so sync the
  # local service definition the supervisor needs (mirrors the local-xsh override).
  fs.install(
    fp"${packages_root(root)?}/repo/mdevd/service.xsh",
    fp"${rootfs_dir}/usr/lib/xinit/services/mdevd.xsh",
    0o644,
    parents: true,
    overwrite: true,
  )?

  ensure_boot_sudo_rs(root, rootfs_dir)?
  sync_local_core_applets(root, rootfs_dir)?
  install_local_xinit(root, rootfs_dir)?
  install_rootfs_overlay(root, rootfs_dir, false, false, true)?
  write_rootfs_cache(root, rootfs_dir, "native-userspace-e2e-rootfs", native_userspace_e2e_rootfs_id(root)?, false)?
}

proc native_interactive_rootfs_id(root: Path) [fs, env, error] -> Result[Str] {
  var body = """native-interactive-rootfs
"""

  for path_value in [
    fp"${packages_root(root)?}/pm.xsh",
    fp"${packages_root(root)?}/pm/build.xsh",
    fp"${packages_root(root)?}/pm/buildroot.xsh",
    fp"${packages_root(root)?}/pm/cli.xsh",
    fp"${packages_root(root)?}/pm/extensions.xsh",
    fp"${packages_root(root)?}/pm/install.xsh",
    fp"${packages_root(root)?}/pm/local.xsh",
    fp"${packages_root(root)?}/pm/remote.xsh",
    fp"${packages_root(root)?}/pm/repo.xsh",
    fp"${packages_root(root)?}/pm/sources.xsh",
    fp"${packages_root(root)?}/pm/types.xsh",
    fp"${packages_root(root)?}/pm/util.xsh",
    fp"${packages_root(root)?}/pm/world.xsh",
    fp"${packages_root(root)?}/repo/baselayout/PKGBUILD.xsh",
    fp"${packages_root(root)?}/repo/xsh/PKGBUILD.xsh",
    fp"${packages_root(root)?}/repo/xinit/PKGBUILD.xsh",
    fp"${packages_root(root)?}/repo/tailscale/service.xsh",
    fp"${packages_root(root)?}/repo/linux-pam/PKGBUILD.xsh",
    fp"${packages_root(root)?}/repo/sudo-rs/PKGBUILD.xsh",
    fp"${local_xinit_source_root(root)?}/xinit.xsh",
  ] {
    body = f"""${body}${path_value.display()} ${hash.sha256(path_value)?.hex()}
"""
  }

  return body
}

proc assemble_native_interactive_rootfs(
  root: Path,
  rootfs_dir: Path,
  sh: Path,
  tailscale_probe: Bool,
) [fs, process, env, error] {
  let _ = sh
  let xsh = ensure_host_xsh(root)?
  remove_tree(fp"${root}/target/linux-vm/native-interactive-build-root")?
  remove_tree(fp"${root}/target/linux-vm/native-interactive-work")?
  remove_tree(fp"${root}/target/linux-vm/native-interactive-out")?
  remove_tree(rootfs_dir)?
  fs.mkdir(rootfs_dir)?

  run_pm(
    root,
    xsh,
    [
      "build-install",
      rootfs_dir.display(),
      fp"${root}/target/linux-vm/native-interactive-build-root".display(),
      fp"${root}/target/linux-vm/native-interactive-work".display(),
      fp"${root}/target/linux-vm/native-interactive-out".display(),
      fp"${packages_root(root)?}/repo/baselayout".display(),
      fp"${packages_root(root)?}/repo/xsh".display(),
      fp"${packages_root(root)?}/repo/xinit".display(),
    ],
  )?

  fs.remove(fp"${rootfs_dir}/init", missing_ok: true)?
  fs.symlink(p"usr/bin/xinit", fp"${rootfs_dir}/init")?
  ensure_linux_sh(rootfs_dir)?
  install_local_xinit(root, rootfs_dir)?
  ensure_boot_tailscale(root, rootfs_dir)?
  install_rootfs_overlay(root, rootfs_dir, false, tailscale_probe, false)?
  ensure_boot_sudo_rs(root, rootfs_dir)?
  write_rootfs_cache(root, rootfs_dir, "native-interactive-rootfs", native_interactive_rootfs_id(root)?, false)?
}

proc write_executable(file_path: Path, body: Str) [fs, error] {
  file_path.parent().mkdir()?
  fs.write(file_path, body)?
  fs.chmod(file_path, 0o755)?
}

proc install_proof_stage_hook(rootfs_dir: Path) [fs, error] {
  write_executable(
    fp"${rootfs_dir}/usr/lib/init/rc.d/proof-stage.boot",
    """#!/bin/xsh
proc proof_marker(line: Str) [fs] {
  match fs.write(/dev/console, f"\${line}\\n") {
    Ok(_) => {}
    Err(_) => {}
  }
}

proc proof_flag(name: Str, cmdline: Str) [env] -> Str {
  let value = (env.get(name) ?? "0").trim()

  if value == "1" or value == "true" or value == "yes" or value == "on" {
    return "1"
  }

  if f"\${name}=1" in cmdline {
    return "1"
  }

  return "0"
}

let cmdline = if fs.exists(/proc/cmdline)? { fs.read_text(/proc/cmdline)? } else { "" }
let proof_stage = proof_flag("XSH_XINIT_PROOF_STAGE", cmdline)

if proof_stage == "1" and fs.exists(/usr/lib/xinit/proof-stage.xsh)? {
  let status = process.run(
    process.command_argv(
      /bin/xsh,
      ["xsh", "/usr/lib/xinit/proof-stage.xsh"],
      /,
      {
        XSH_UNIX_DRY_RUN: "0",
        XSH_WATERFOX_QEMU_AUDIO_PROOF: proof_flag("XSH_WATERFOX_QEMU_AUDIO_PROOF", cmdline),
        XSH_WATERFOX_QEMU_BROWSER_PROOF: proof_flag("XSH_WATERFOX_QEMU_BROWSER_PROOF", cmdline),
        XSH_WATERFOX_QEMU_CLIPBOARD_PROOF: proof_flag("XSH_WATERFOX_QEMU_CLIPBOARD_PROOF", cmdline),
        XSH_WATERFOX_QEMU_DEBUG: proof_flag("XSH_WATERFOX_QEMU_DEBUG", cmdline),
        XSH_WATERFOX_QEMU_FOOT_SHELL: proof_flag("XSH_WATERFOX_QEMU_FOOT_SHELL", cmdline),
        XSH_WATERFOX_QEMU_INPUT_PROOF: proof_flag("XSH_WATERFOX_QEMU_INPUT_PROOF", cmdline),
        XSH_WATERFOX_QEMU_MESA_PROOF: proof_flag("XSH_WATERFOX_QEMU_MESA_PROOF", cmdline),
        XSH_WATERFOX_QEMU_PROOF: proof_flag("XSH_WATERFOX_QEMU_PROOF", cmdline),
      },
    ),
  )?

  if ! status.ok {
    proof_marker("LAPUTA_BOOT_PROOF_FAILED")
    abort(3)
  }

  proof_marker("LAPUTA_BOOT_PROOF_OK")
}
""",
  )?
}

proc install_tailscale_probe_hook(_: Path, rootfs_dir: Path) [fs, error] {
  write_executable(
    fp"${rootfs_dir}/etc/rc.d/tailscaled-probe.boot",
    """#!/bin/xsh
error ScriptError = Failed(kind: Str, message: Str)

proc probe_marker(line: Str) [fs] {
  match fs.write(/dev/console, f"\${line}\\n") {
    Ok(_) => {}
    Err(_) => {}
  }
}

print "tailscaled probe: start"
print "tailscaled probe network begin"

match linux.interfaces() {
  Ok(interfaces) => {
    for iface in interfaces {
      print f"net iface \${iface.name} flags=\${iface.flags.join(",")} mac=\${iface.mac}"

      for addr in iface.addresses {
        print f"net addr \${iface.name} \${addr.family} \${addr.addr}/\${addr.prefix_len}"
      }
    }
  }
  Err(err) => print f"net interfaces failed: \${err.message}"
}

match linux.routes() {
  Ok(routes) => {
    for route in routes {
      print f"net route \${route.family} dst=\${route.dst}/\${route.prefix_len} gw=\${route.gateway} dev=\${route.dev} flags=\${route.flags.join(
        ",",
      )}"
    }
  }
  Err(err) => print f"net routes failed: \${err.message}"
}

print "tailscaled probe network end"

let started = run.text /usr/bin/xinit start tailscaled ?
print f"tailscaled probe start: \${started.trim()}"

time.sleep(10s)?

let status = run.text /usr/bin/xinit status tailscaled ?
print f"tailscaled probe status: \${status.trim()}"

let ip = run.text /usr/bin/tailscale "--socket" "/run/tailscale/tailscaled.sock" "ip" "-4" ?
let ip4 = ip.lines().collect().get(0, "").trim()

if ip4 == "" {
  return Err(ScriptError.Failed("tailscale-probe", "tailscale did not report an IPv4 address"))?
}

let status_json = run.text /usr/bin/tailscale "--socket" "/run/tailscale/tailscaled.sock" "status" "--json" ?
let status_compact = status_json.replace(" ", "").replace("\\n", "").replace("\\t", "")
let ssh_ok = "https://tailscale.com/cap/ssh" in status_compact

print f"tailscaled probe ssh: ip=\${ip4} capSSH=\${ssh_ok}"
print "tailscaled probe log begin"

match run.text /usr/bin/xinit logs tailscaled {
  Ok(body) => print \${body}
  Err(err) => print f"tailscaled probe logs failed: \${err.message}"
}

print "tailscaled probe log end"

if ssh_ok {
  probe_marker(f"LAPUTA_TAILSCALE_PROBE_OK ip=\${ip4}")
} else {
  print "tailscaled probe status json begin"
  print \${status_json}
  print "tailscaled probe status json end"
  probe_marker(f"LAPUTA_TAILSCALE_PROBE_FAILED ip=\${ip4}")
}
""",
  )?
}

proc install_tailscale_up_hook(_: Path, rootfs_dir: Path) [fs, error] {
  write_executable(
    fp"${rootfs_dir}/usr/lib/init/rc.d/tailscale-up.boot",
    """#!/bin/xsh
error ScriptError = Failed(kind: Str, message: Str)

proc fail(message: Str) [error] {
  Err(ScriptError.Failed("tailscale-up", message))?
}

proc backend_state() [process, error] -> Result[Str] {
  match run.text /usr/bin/tailscale "--socket" "/run/tailscale/tailscaled.sock" "status" "--json" {
    Ok(body) => {
      let status: Record = json.decode(body)?
      return status.get("BackendState")?
    }
    Err(_) => {}
  }

  return ""
}

proc tailscale_status_json() [process, error] -> Result[Str] {
  return run.text /usr/bin/tailscale "--socket" "/run/tailscale/tailscaled.sock" "status" "--json" ?
}

pure status_compact(body: Str) -> Str {
  return body.replace(" ", "").replace("\\n", "").replace("\\t", "")
}

proc tailscale_ip4() [process, error] -> Result[Str] {
  let out = run.text /usr/bin/tailscale "--socket" "/run/tailscale/tailscaled.sock" "ip" "-4" ?
  return out.lines().collect().get(0, "").trim()
}

proc wait_for_backend_running() [process, time, error] {
  var tries = 40

  while tries > 0 {
    break when backend_state()? == "Running"
    time.sleep(250ms)?
    tries -= 1
  }

  if backend_state()? != "Running" {
    fail(f"tailscale backend did not reach Running; state=\${backend_state()?}")?
  }
}

proc require_tailscale_ssh() [process, error] -> Result[Str] {
  let ip = tailscale_ip4()?

  if ip == "" {
    fail("tailscale did not report an IPv4 address")?
  }

  let status = tailscale_status_json()?
  let compact = status_compact(status)

  if ! ("https://tailscale.com/cap/ssh" in compact) {
    print "tailscale ssh warning: status does not report cap/ssh"
  }

  return ip
}

print "tailscale up: start"
run /usr/bin/xinit start tailscaled ?
var tries = 40

while tries > 0 {
  break when fs.exists(/run/tailscale/tailscaled.sock)?
  time.sleep(250ms)?
  tries -= 1
}

if ! fs.exists(/run/tailscale/tailscaled.sock)? {
  fail("tailscaled socket did not appear")?
}

let state = backend_state()?

if state == "Running" or state == "Stopped" {
  run /usr/bin/tailscale "--socket" "/run/tailscale/tailscaled.sock" "up" "--ssh" "--accept-dns=false" "--hostname=laputa" "--netfilter-mode=off" ?
} else {
  run /usr/bin/tailscale "--socket" "/run/tailscale/tailscaled.sock" "up" "--ssh" "--accept-dns=false" "--hostname=laputa" "--netfilter-mode=off" "--auth-key=file:/etc/tailscale/authkey" ?
}

wait_for_backend_running()?
let ip = require_tailscale_ssh()?
print f"tailscale ssh ready: ip=\${ip}"
print "tailscale up: ok"
""",
  )?
}

proc canonical_inittab(root: Path) [fs, env, error] -> Result[Str] {
  return fs.read_text(fp"${packages_root(root)?}/repo/baselayout/files/rootfs/etc/inittab")?
}

proc boot_proof_enabled() [env] -> Bool {
  return (env.get("XSH_BOOT_PROOF") ?? "0").trim() == "1"
}

proc tailscale_probe_enabled() [env] -> Bool {
  let value = (env.get("XSH_BOOT_TAILSCALE_PROBE") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc userspace_e2e_enabled() [env] -> Bool {
  let value = (env.get("XSH_BOOT_USERSPACE_E2E") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc ensure_dir(path_value: Path, mode: Int) [fs, error] {
  if ! fs.exists(path_value)? {
    path_value.mkdir()?
  }

  fs.chmod(path_value, mode)?
}

pure rootfs_cache_path(rootfs_dir: Path) -> Path {
  return fp"${rootfs_dir}/var/lib/xsh-boot/rootfs.cache"
}

proc append_tree_signature(root: Path, path_value: Path, body: Str) [fs, error] -> Result[Str] {
  let meta = path_value.metadata()?
  var updated = body

  if meta.kind == "dir" {
    updated = f"""${updated}${path_value.strip_prefix(root)?.display()} dir
"""

    for child in fs.ls(path_value)? |> sort-by .path {
      updated = append_tree_signature(root, child.path, updated)?
    }

    return updated
  }

  if meta.kind == "symlink" {
    return f"""${updated}${path_value.strip_prefix(root)?.display()} symlink ${path_value.readlink()?.display()}
"""
  }

  return f"""${updated}${path_value.strip_prefix(root)?.display()} ${hash.sha256(path_value)?.hex()}
"""
}

proc package_input_signature(root: Path, package_dir: Path) [fs, error] -> Result[Str] {
  var body = f"""package=${package_dir.strip_prefix(root)?.display()}
"""

  for path_value in [fp"${package_dir}/PKGBUILD.xsh", fp"${package_dir}/proof.xsh", fp"${package_dir}/files"] {
    if fs.exists(path_value)? {
      body = append_tree_signature(root, path_value, body)?
    }
  }

  return body
}

proc rootfs_cache_signature(
  root: Path,
  image: Str,
  image_id: Str,
  proof_enabled: Bool,
) [fs, env, error] -> Result[Str] {
  let package_root = packages_root(root)?
  var paths = [fp"${root}/boot.xsh"]

  if proof_enabled {
    paths = paths.push(fp"${root}/proof-stage.xsh")
  }

  var body = f"""version=${ROOTFS_CACHE_VERSION}
arch=${package_arch()}
image=${image}
image_id=${image_id}
proof=${proof_enabled}
"""

  for path_value in paths {
    body = f"""${body}${path_value.strip_prefix(root)?.display()} ${hash.sha256(path_value)?.hex()}
"""
  }

  let tailscale_boot = fp"${package_root}/repo/tailscale/service.xsh"

  body = f"""${body}${tailscale_boot.strip_prefix(package_root)?.display()} ${hash.sha256(tailscale_boot)?.hex()}
"""

  body = f"${body}${package_input_signature(package_root, fp"${package_root}/repo/baselayout")?}"
  return body
}

proc local_rootfs_id(rootfs_dir: Path, proof_enabled: Bool) [fs, error] -> Result[Str] {
  var paths = [fp"${rootfs_dir}/init", fp"${rootfs_dir}/usr/bin/xinit", fp"${rootfs_dir}/bin/xsh"]

  if ! proof_enabled {
    paths = paths.extend([fp"${rootfs_dir}/usr/bin/sudo", fp"${rootfs_dir}/usr/bin/visudo"])
  }

  var body = """local-rootfs
"""

  for path_value in paths {
    if fs.exists(path_value)? {
      body = f"""${body}${path_value.strip_prefix(rootfs_dir)?.display()} ${hash.sha256(path_value)?.hex()}
"""
    } else {
      body = f"""${body}${path_value.strip_prefix(rootfs_dir)?.display()} missing
"""
    }
  }

  return body
}

proc rootfs_cache_valid(
  root: Path,
  rootfs_dir: Path,
  image: Str,
  image_id: Str,
  proof_enabled: Bool,
) [fs, env, error] -> Result[Bool] {
  if ! fs.exists(fp"${rootfs_dir}/init")? {
    return false
  }

  let stamp = rootfs_cache_path(rootfs_dir)

  if ! fs.exists(stamp)? {
    return false
  }

  return fs.read_text(stamp)? == rootfs_cache_signature(root, image, image_id, proof_enabled)?
}

proc write_rootfs_cache(root: Path, rootfs_dir: Path, image: Str, image_id: Str, proof_enabled: Bool) [fs, env, error] {
  let stamp = rootfs_cache_path(rootfs_dir)
  stamp.parent.mkdir()?
  fs.write(stamp, rootfs_cache_signature(root, image, image_id, proof_enabled)?)?
}

proc ensure_baselayout(root: Path, rootfs_dir: Path) [fs, process, env, error] {
  if fs.exists(fp"${rootfs_dir}/var/lib/xsh-pm/packages/baselayout/metadata.json")? {
    return
  }

  let xsh = ensure_host_xsh(root)?

  run_pm(
    root,
    xsh,
    [
      "install",
      rootfs_dir.display(),
      fp"${root}/target/linux-vm/baselayout-work".display(),
      fp"${root}/target/linux-vm/baselayout-out".display(),
      fp"${packages_root(root)?}/repo/baselayout".display(),
    ],
  )?
}

# Bring up networking in userspace (replacing the kernel `ip=dhcp` arg): expose
# the ifup applet as a command, ship a DHCP /etc/network/interfaces, and run
# `ifup -a` from an rc.d boot hook. Used by the non-e2e boots; the e2e overlay
# sets up the equivalent plus its own marker hooks.
proc install_userspace_network(rootfs_dir: Path) [fs, error] {
  ensure_dir(fp"${rootfs_dir}/etc/network", 0o755)?
  ensure_dir(fp"${rootfs_dir}/etc/network/if-up.d", 0o755)?
  ensure_dir(fp"${rootfs_dir}/usr/lib/init/rc.d", 0o755)?

  fs.write(
    fp"${rootfs_dir}/etc/network/interfaces",
    """auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
""",
  )?

  write_executable(
    fp"${rootfs_dir}/usr/lib/init/rc.d/laputa-network.boot",
    """#!/bin/xsh
if fs.exists(/usr/bin/ifup)? {
  run /usr/bin/ifup "-a" ?
}
""",
  )?
}

proc install_userspace_e2e_overlay(rootfs_dir: Path) [fs, error] {
  ensure_dir(fp"${rootfs_dir}/etc/network", 0o755)?
  ensure_dir(fp"${rootfs_dir}/etc/network/if-up.d", 0o755)?
  ensure_dir(fp"${rootfs_dir}/home", 0o755)?
  ensure_dir(fp"${rootfs_dir}/home/laputa", 0o755)?

  fs.write(
    fp"${rootfs_dir}/etc/network/interfaces",
    """auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
""",
  )?

  write_executable(
    fp"${rootfs_dir}/usr/lib/init/rc.d/00-userspace-e2e-dev.boot",
    """#!/bin/xsh
if ! fs.exists(/dev/console)? {
  let console = linux.mknod(/dev/console, "char", 5, 1)
}
fs.chmod(/dev/console, 0o666)?
""",
  )?

  write_executable(
    fp"${rootfs_dir}/etc/network/if-up.d/userspace-e2e",
    """#!/bin/xsh
match fs.write(/dev/console, f"LAPUTA_USERSPACE_E2E_IFUP iface=\${env.get("IFACE") ?? ""} method=\${env.get("METHOD") ?? ""}\\n") {
  Ok(_) => {}
  Err(_) => {}
}
fs.write(/run/userspace-e2e-ifup, f"\${env.get("IFACE") ?? ""} \${env.get("METHOD") ?? ""}\\n")?
""",
  )?

  write_executable(
    fp"${rootfs_dir}/usr/lib/init/rc.d/laputa-network.boot",
    """#!/bin/xsh
if fs.exists(/usr/bin/ifup)? {
  run /usr/bin/ifup "-a" ?
}
""",
  )?

  write_executable(
    fp"${rootfs_dir}/usr/lib/init/userspace-e2e.late",
    """#!/bin/xsh
error E2eError = Failed(message: Str)

proc marker(line: Str) [fs] {
  match fs.write(/dev/console, f"\${line}\\n") {
    Ok(_) => {}
    Err(_) => {}
  }
}

proc fail(message: Str) [fs, error] {
  marker(f"LAPUTA_USERSPACE_E2E_FAILED \${message}")
  return Err(E2eError.Failed(message))?
}

proc require(condition: Bool, message: Str) [fs, error] {
  if ! condition {
    fail(message)?
  }
}

marker("LAPUTA_USERSPACE_E2E_LATE_START")

let mounts = fs.read_text(/proc/mounts)?
require(" /proc proc " in mounts, "proc not mounted")?
require(" /sys sysfs " in mounts, "sysfs not mounted")?
require(" /run tmpfs " in mounts, "run tmpfs not mounted")?
require(" /dev devtmpfs " in mounts, "devtmpfs not mounted")?
marker("LAPUTA_USERSPACE_E2E_MOUNTS_OK")

if fs.exists(/etc/xsh-boot-epoch-ms)? {
  let epoch = fs.read_text(/etc/xsh-boot-epoch-ms)?.trim().parse_int()?
  require(time.now() >= epoch, "system clock is older than boot epoch")?
}
marker("LAPUTA_USERSPACE_E2E_TIME_OK")

require(fs.exists(/run/network/ifstate)?, "ifup did not write ifstate")?
let ifstate = fs.read_text(/run/network/ifstate)?
require("lo=lo" in ifstate, "ifup did not configure lo")?
require("eth0=eth0" in ifstate, "ifup did not configure eth0")?
require(fs.exists(/run/userspace-e2e-ifup)?, "if-up hook did not run")?
require("eth0 dhcp" in fs.read_text(/run/userspace-e2e-ifup)?, "eth0 was not brought up via dhcp")?
var dhcp_addr = ""
for iface in linux.interfaces()? {
  if iface.name == "eth0" {
    for entry in iface.addresses {
      if entry.family == "inet" {
        dhcp_addr = entry.addr
      }
    }
  }
}
require(dhcp_addr != "", "dhcp client did not assign an IPv4 address to eth0")?
marker(f"LAPUTA_USERSPACE_E2E_DHCP addr=\${dhcp_addr}")
marker("LAPUTA_USERSPACE_E2E_NETWORK_OK")

let mounts_before_swap = fs.read_text(/proc/mounts)?
var swap = /dev/vda

if "/dev/vda1 / " in mounts_before_swap or "/dev/vda / " in mounts_before_swap {
  swap = /dev/vdb
}

var swap_tries = 80

while swap_tries > 0 {
  break when fs.exists(swap)?
  time.sleep(250ms)?
  swap_tries -= 1
}

require(fs.exists(swap)?, f"swap block device \${swap} did not appear")?
match linux.mkswap(swap) {
  Ok(_) => {}
  Err(err) => fail(f"mkswap failed: \${err.message}")?
}
match linux.swapon(swap, priority: 1) {
  Ok(_) => {}
  Err(err) => fail(f"swapon failed: \${err.message}")?
}
let swaps = fs.read_text(/proc/swaps)?
require(swap.display() in swaps, "swapon did not activate e2e swap device")?
match linux.swapoff(swap) {
  Ok(_) => {}
  Err(err) => fail(f"swapoff failed: \${err.message}")?
}
marker("LAPUTA_USERSPACE_E2E_SWAP_OK")

var mdevd_status = ""
var tries = 40

while tries > 0 {
  match run.text /usr/bin/xinit status mdevd {
    Ok(out) => {
      mdevd_status = out.trim()
      break when "running" in mdevd_status
    }
    Err(_) => {}
  }

  time.sleep(250ms)?
  tries -= 1
}

require("running" in mdevd_status, f"mdevd was not running; status=\${mdevd_status}")?
marker(f"LAPUTA_USERSPACE_E2E_MDEVD \${mdevd_status}")

let listed = run.text /usr/bin/xinit list ?
require("mdevd" in listed, "xinit list did not include mdevd")?
let graph = run.text /usr/bin/xinit graph boot ?
require("mdevd" in graph, "xinit graph boot did not include mdevd")?

marker("LAPUTA_USERSPACE_E2E_BOOT_OK")
run /usr/lib/init/userspace-e2e-login ?
""",
  )?

  write_executable(
    fp"${rootfs_dir}/usr/lib/init/userspace-e2e-login",
    """#!/bin/xsh
error E2eLoginError = Failed(message: Str)

match fs.write(/dev/console, "LAPUTA_USERSPACE_E2E_LOGIN_START\\n") {
  Ok(_) => {}
  Err(_) => {}
}
let status: Status = run.status --timeout=10s /usr/bin/su "--login" "--shell" "/usr/lib/init/userspace-e2e-shell" "laputa" > /dev/console 2> /dev/console
match fs.write(/dev/console, f"LAPUTA_USERSPACE_E2E_LOGIN_STATUS ok=\${status.ok}\\n") {
  Ok(_) => {}
  Err(_) => {}
}
if status.exited() {
  match fs.write(/dev/console, f"LAPUTA_USERSPACE_E2E_LOGIN_EXIT_CODE \${status.exit_code()?}\\n") {
    Ok(_) => {}
    Err(_) => {}
  }
}
if ! status.ok {
  return Err(E2eLoginError.Failed("su exited unsuccessfully"))?
}
match fs.write(/dev/console, "LAPUTA_USERSPACE_E2E_LOGIN_EXIT\\n") {
    Ok(_) => {}
    Err(_) => {}
  }
""",
  )?

  write_executable(
    fp"${rootfs_dir}/usr/lib/init/userspace-e2e-shell",
    """#!/bin/xsh
print "LAPUTA_USERSPACE_E2E_LOGIN_SHELL"
""",
  )?
}

proc install_rootfs_overlay(
  root: Path,
  rootfs_dir: Path,
  proof_enabled: Bool,
  tailscale_probe: Bool,
  userspace_e2e: Bool,
) [fs, process, env, error] {
  ensure_baselayout(root, rootfs_dir)?
  let base_inittab = canonical_inittab(root)?

  for dir in [p"dev", p"proc", p"run", p"sys", p"tmp"] {
    ensure_dir(fp"${rootfs_dir}/${dir}", 0o755)?
  }

  ensure_dir(fp"${rootfs_dir}/usr/lib/init", 0o755)?
  ensure_dir(fp"${rootfs_dir}/usr/lib/xinit", 0o755)?

  let inittab = if proof_enabled {
    base_inittab
  } else if userspace_e2e {
    f"""${base_inittab}::once:/usr/lib/init/userspace-e2e.late
"""
  } else {
    f"""${base_inittab}ttyAMA0::poweroff:/usr/bin/su --login laputa
"""
  }

  fs.write(fp"${rootfs_dir}/etc/inittab", inittab)?

  if userspace_e2e {
    install_userspace_e2e_overlay(rootfs_dir)?
  }

  # Non-e2e boots no longer get `ip=dhcp`; bring up the network from userspace.
  if ! userspace_e2e {
    install_userspace_network(rootfs_dir)?
  }

  if ! proof_enabled and ! userspace_e2e {
    ensure_dir(fp"${rootfs_dir}/home/laputa", 0o755)?
  }

  if ! proof_enabled and ! userspace_e2e {
    fs.remove(fp"${rootfs_dir}/usr/local/bin/autologin", missing_ok: true)?
    fs.remove(fp"${rootfs_dir}/usr/lib/xinit/services/tailscale.xsh", missing_ok: true)?
    fs.remove(fp"${rootfs_dir}/etc/rc.d/tailscaled-probe.boot", missing_ok: true)?

    if fs.exists(fp"${rootfs_dir}/usr/bin/tailscaled")? or fs.exists(
      fp"${rootfs_dir}/usr/lib/xinit/services/tailscaled.xsh",
    )? {
      fs.copy(
        fp"${packages_root(root)?}/repo/tailscale/service.xsh",
        fp"${rootfs_dir}/usr/lib/xinit/services/tailscaled.xsh",
        overwrite: true,
      )?

      install_tailscale_up_hook(root, rootfs_dir)?
    }

    if tailscale_probe {
      install_tailscale_probe_hook(root, rootfs_dir)?
    }
  }

  fs.write(
    fp"${rootfs_dir}/etc/hostname",
    """laputa
""",
  )?

  fs.write(
    fp"${rootfs_dir}/etc/rc.conf",
    """# empty proof rc.conf
""",
  )?

  if ! proof_enabled {
    return
  }

  fp"${rootfs_dir}/usr/lib/xinit/services".mkdir()?
  install_proof_stage_hook(rootfs_dir)?
  fs.copy(fp"${root}/proof-stage.xsh", fp"${rootfs_dir}/usr/lib/xinit/proof-stage.xsh", overwrite: true)?
}

proc ensure_interactive_rootfs(
  root: Path,
  rootfs_dir: Path,
  sh: Path,
  tar: Path,
  proof_enabled: Bool,
  tailscale_probe: Bool,
  userspace_e2e: Bool,
) [fs, net, process, env, error] {
  let requested_rootfs_image = (env.get("XSH_BOOT_ROOTFS_IMAGE") ?? "").trim()

  if userspace_e2e and requested_rootfs_image == "" {
    let image = "native-userspace-e2e-rootfs"
    let image_id = native_userspace_e2e_rootfs_id(root)?

    if rootfs_cache_valid(root, rootfs_dir, image, image_id, proof_enabled)? {
      install_rootfs_overlay(root, rootfs_dir, proof_enabled, tailscale_probe, userspace_e2e)?
      ensure_boot_runtime(root, rootfs_dir, sh)?
      ensure_boot_mdevd(root, rootfs_dir)?
      write_rootfs_cache(root, rootfs_dir, image, image_id, proof_enabled)?
      return
    }

    assemble_native_userspace_e2e_rootfs(root, rootfs_dir, sh)?
    return
  }

  if proof_enabled and requested_rootfs_image == "" {
    let image = "native-proof-rootfs"
    let image_id = native_proof_rootfs_id(root)?

    if rootfs_cache_valid(root, rootfs_dir, image, image_id, proof_enabled)? {
      install_rootfs_overlay(root, rootfs_dir, proof_enabled, tailscale_probe, userspace_e2e)?
      ensure_boot_runtime(root, rootfs_dir, sh)?
      write_rootfs_cache(root, rootfs_dir, image, image_id, proof_enabled)?
      return
    }

    assemble_native_proof_rootfs(root, rootfs_dir, sh, tailscale_probe)?
    return
  }

  if ! proof_enabled and requested_rootfs_image == "" {
    let image = "native-interactive-rootfs"
    let image_id = native_interactive_rootfs_id(root)?

    if rootfs_cache_valid(root, rootfs_dir, image, image_id, proof_enabled)? {
      ensure_boot_runtime(root, rootfs_dir, sh)?
      ensure_boot_tailscale(root, rootfs_dir)?
      install_rootfs_overlay(root, rootfs_dir, proof_enabled, tailscale_probe, userspace_e2e)?
      write_rootfs_cache(root, rootfs_dir, image, image_id, proof_enabled)?
      return
    }

    assemble_native_interactive_rootfs(root, rootfs_dir, sh, tailscale_probe)?
    return
  }

  let docker = process.which("docker")?
  var image = ""
  var image_id = ""
  var can_export = false

  match rootfs_image(sh, docker) {
    Ok(found) => {
      image = found
      image_id = f"${docker_image_id(docker, image)?.trim()} source=${rootfs_source_path()}"
      can_export = true
    }
    Err(err) => {
      if ! fs.exists(fp"${rootfs_dir}/init")? {
        return Err(err)
      }

      image = "local-rootfs"
      image_id = local_rootfs_id(rootfs_dir, proof_enabled)?
    }
  }

  if rootfs_cache_valid(root, rootfs_dir, image, image_id, proof_enabled)? {
    if proof_enabled {
      install_rootfs_overlay(root, rootfs_dir, proof_enabled, tailscale_probe, userspace_e2e)?
      ensure_boot_runtime(root, rootfs_dir, sh)?
    } else {
      ensure_boot_runtime(root, rootfs_dir, sh)?
      ensure_boot_tailscale(root, rootfs_dir)?
      install_rootfs_overlay(root, rootfs_dir, proof_enabled, tailscale_probe, userspace_e2e)?
    }

    if image == "local-rootfs" {
      image_id = local_rootfs_id(rootfs_dir, proof_enabled)?
    }

    write_rootfs_cache(root, rootfs_dir, image, image_id, proof_enabled)?
    return
  }

  if ! can_export {
    if proof_enabled {
      install_rootfs_overlay(root, rootfs_dir, proof_enabled, tailscale_probe, userspace_e2e)?
      ensure_boot_runtime(root, rootfs_dir, sh)?
    } else {
      ensure_boot_runtime(root, rootfs_dir, sh)?
      ensure_boot_tailscale(root, rootfs_dir)?
      install_rootfs_overlay(root, rootfs_dir, proof_enabled, tailscale_probe, userspace_e2e)?
    }

    image_id = local_rootfs_id(rootfs_dir, proof_enabled)?
    write_rootfs_cache(root, rootfs_dir, image, image_id, proof_enabled)?
    return
  }

  let container = "xsh-linux-rootfs-export"
  let export_tar = fp"${root}/target/linux-vm/rootfs-export.tar"
  let source_path = rootfs_source_path()

  docker_quiet(
    sh,
    docker,
    "docker_bin=$1; name=$2; \"$docker_bin\" rm -f \"$name\" >/dev/null 2>&1 || true",
    [container],
  )?

  fs.remove(rootfs_dir, missing_ok: true)?
  fs.remove(export_tar, missing_ok: true)?

  docker_quiet(
    sh,
    docker,
    "docker_bin=$1; name=$2; image=$3; \"$docker_bin\" create --name \"$name\" \"$image\" /bin/xsh >/dev/null",
    [container, image],
  )?

  rootfs_dir.mkdir()?

  if source_path == "/" {
    docker_quiet(
      sh,
      docker,
      "docker_bin=$1; name=$2; out=$3; \"$docker_bin\" export -o \"$out\" \"$name\" >/dev/null",
      [container, export_tar.display()],
    )?

    require_ok(
      process.run(
        process.command_argv(
          tar,
          [tar.display(), "--exclude", "dev/*", "-xf", export_tar.display(), "-C", rootfs_dir.display()],
        ),
      )?,
      "boot-rootfs-extract",
      f"failed to extract ${export_tar}",
    )?

    fs.remove(export_tar, missing_ok: true)?
  } else {
    docker_quiet(
      sh,
      docker,
      "docker_bin=$1; name=$2; source=$3; dest=$4; \"$docker_bin\" cp \"$name:$source/.\" \"$dest\" >/dev/null",
      [container, source_path, rootfs_dir.display()],
    )?
  }

  docker_quiet(sh, docker, "docker_bin=$1; name=$2; \"$docker_bin\" rm -f \"$name\" >/dev/null", [container])?

  if proof_enabled {
    install_rootfs_overlay(root, rootfs_dir, proof_enabled, tailscale_probe, userspace_e2e)?
    ensure_boot_runtime(root, rootfs_dir, sh)?
  } else {
    ensure_boot_runtime(root, rootfs_dir, sh)?
    ensure_boot_tailscale(root, rootfs_dir)?
    install_rootfs_overlay(root, rootfs_dir, proof_enabled, tailscale_probe, userspace_e2e)?
  }

  write_rootfs_cache(root, rootfs_dir, image, image_id, proof_enabled)?
}

proc console_has_panic(log: Path) [fs, error] -> Result[Bool] {
  if ! fs.exists(log)? {
    return false
  }

  let body = fs.read_text(log)?
  return "Kernel panic" in body or "not syncing" in body or "Attempted to kill init" in body
}

proc console_has_output(log: Path) [fs, error] -> Result[Bool] {
  if ! fs.exists(log)? {
    return false
  }

  return fs.metadata(log)?.size > 0
}

proc console_contains(log: Path, needle: Str) [fs, error] -> Result[Bool] {
  if ! fs.exists(log)? {
    return false
  }

  let text = fs.read_text(log)?
  return needle in text
}

proc console_timeout_seconds() [env, error] -> Result[Int] {
  let fallback = if waterfox_qemu_proof_enabled() { "75" } else { "5" }
  let raw = (env.get("XSH_BOOT_CONSOLE_TIMEOUT") ?? fallback).trim()

  if raw == "" {
    return 30
  }

  let seconds = raw.parse_int()?

  if seconds < 1 {
    return 1
  }

  return seconds
}

proc linux_loop_timeout_seconds() [env, error] -> Result[Int] {
  let raw = (env.get("XSH_LINUX_LOOP_TIMEOUT") ?? "12").trim()

  if raw == "" {
    return 12
  }

  let seconds = raw.parse_int()?

  if seconds < 1 {
    return 1
  }

  return seconds
}

proc boot_attach_enabled() [env] -> Bool {
  return (env.get("XSH_LINUX_LOOP_ATTACH") ?? env.get("XSH_BOOT_ATTACH") ?? "1").trim() != "0"
}

proc boot_kernel_path(default_kernel: Path) [env, error] -> Result[Path] {
  let raw = (env.get("XSH_BOOT_KERNEL") ?? "").trim()

  if raw == "" {
    return default_kernel
  }

  return fp"${raw}"
}

proc print_console_excerpt(trace: Path, console_log: Path, max_lines: Int) [fs, error] {
  if ! fs.exists(console_log)? {
    trace_line(trace, f"console excerpt: ${console_log} is missing")?
    return
  }

  var count = 0

  for line in console_log.lines()? {
    if count < max_lines {
      trace_line(trace, f"console> ${line}")?
    }

    count += 1
  }

  trace_line(trace, f"console excerpt: ${count} line(s), ${fs.metadata(console_log)?.size} byte(s)")?
}

proc verify_waterfox_qemu_visual_proof(
  trace: Path,
  console_log: Path,
  qemu_log: Path,
  screenshot: Path,
  sh: Path,
  debug_only: Bool,
  foot_shell: Bool,
  browser_proof: Bool,
  clipboard_proof: Bool,
  mesa_proof: Bool,
) [fs, process, error] {
  if clipboard_proof {
    for marker in [
      "waterfox-session mdevd ok",
      "waterfox-session seatd ok",
      "waterfox-session dwl start",
      "waterfox-session startup clipboard",
      "waterfox-qemu clipboard ok",
    ] {
      if ! console_contains(console_log, marker)? {
        return Err(
          ScriptError.Failed("waterfox-qemu-clipboard", f"missing clipboard proof marker '${marker}' in ${console_log}"),
        )
      }
    }

    for term in ["DBus", "dbus", "GTK", "gtk", "X11", "xcb"] {
      if console_contains(console_log, term)? {
        return Err(
          ScriptError.Failed("waterfox-qemu-forbidden-log", f"clipboard proof log contains rejected term ${term}"),
        )
      }
    }

    trace_line(trace, "waterfox qemu clipboard: ok")?
  }

  require_file(screenshot)?

  require_ok(
    process.run(
      process.command_argv(
        sh,
        [
          sh.display(),
          "-c",
          "shot=$1; test $(wc -c < \"$shot\") -gt 128 && dd if=\"$shot\" bs=1 skip=64 2>/dev/null | od -An -tu1 | awk '{ for (i = 1; i <= NF; i++) if ($i != 0) found = 1 } END { exit(found ? 0 : 1) }'",
          "waterfox-qemu-screenshot",
          screenshot.display(),
        ],
      ),
    )?,
    "waterfox-qemu-screenshot",
    f"screenshot was missing or blank: ${screenshot}",
  )?

  if debug_only {
    if ! console_contains(console_log, "waterfox-qemu debug done")? {
      return Err(ScriptError.Failed("waterfox-qemu-debug", f"missing debug completion proof in ${console_log}"))
    }

    trace_line(trace, f"waterfox qemu screenshot: ${screenshot}")?
    trace_line(trace, "waterfox qemu debug: ok")?
    return
  }

  if foot_shell {
    trace_line(trace, f"waterfox qemu screenshot: ${screenshot}")?
    trace_line(trace, "waterfox qemu foot shell: ok")?
    return
  }

  if mesa_proof {
    if ! console_contains(console_log, "waterfox-qemu mesa ok")? {
      return Err(ScriptError.Failed("waterfox-qemu-mesa", f"missing Mesa proof marker in ${console_log}"))
    }

    for term in ["libGLX", "libX11", "libxcb", "vulkan", "Vulkan", "DBus", "dbus"] {
      if console_contains(console_log, term)? {
        return Err(ScriptError.Failed("waterfox-qemu-forbidden-log", f"Mesa proof log contains rejected term ${term}"))
      }
    }

    trace_line(trace, f"waterfox qemu screenshot: ${screenshot}")?
    trace_line(trace, "waterfox qemu mesa: ok")?
  }

  if browser_proof {
    for marker in [
      "waterfox-session mdevd ok",
      "waterfox-session seatd ok",
      "waterfox-session dwl start",
      "waterfox-session startup waterfox about:blank",
      "waterfox-qemu browser-session-ready",
    ] {
      if ! console_contains(console_log, marker)? {
        return Err(
          ScriptError.Failed("waterfox-qemu-browser", f"missing browser proof marker '${marker}' in ${console_log}"),
        )
      }
    }

    if ! console_contains(qemu_log, "waterfox-qemu-browser-qmp-input ok")? {
      return Err(ScriptError.Failed("waterfox-qemu-browser-input", f"missing browser QMP input proof in ${qemu_log}"))
    }

    for term in [
      "libEGL",
      "libGLES",
      "libgbm",
      "vulkan",
      "Vulkan",
      "X11",
      "xcb",
      "DBus",
      "dbus",
      "PipeWire",
      "pipewire",
      "PulseAudio",
      "pulseaudio",
      "libva",
      "error[runtime.error]",
      "runtime traceback",
    ] {
      if console_contains(console_log, term)? {
        return Err(
          ScriptError.Failed("waterfox-qemu-forbidden-log", f"browser proof log contains rejected term ${term}"),
        )
      }
    }

    trace_line(trace, f"waterfox qemu screenshot: ${screenshot}")?
    trace_line(trace, "waterfox qemu browser: ok")?
  }

  if clipboard_proof or mesa_proof or browser_proof {
    return
  }

  if ! console_contains(console_log, "waterfox-qemu foot-input ok")? {
    return Err(ScriptError.Failed("waterfox-qemu-foot-input", f"missing foot input proof in ${console_log}"))
  }

  trace_line(trace, f"waterfox qemu screenshot: ${screenshot}")?
  trace_line(trace, "waterfox qemu foot input: ok")?
}

proc verify_waterfox_qemu_audio_proof(trace: Path, console_log: Path) [fs, error] {
  if ! console_contains(console_log, "waterfox-qemu audio ok")? {
    return Err(ScriptError.Failed("waterfox-qemu-audio", f"missing audio proof marker in ${console_log}"))
  }

  trace_line(trace, "waterfox qemu audio: ok")?
}

proc qemu_machine_arg() [env] -> Str {
  let accel = (env.get("XSH_LINUX_LOOP_QEMU_ACCEL") ?? env.get("XSH_BOOT_QEMU_ACCEL") ?? "hvf").trim()
  let arch = package_arch()

  if accel == "" or accel == "none" {
    if arch == "x86_64" {
      return "q35"
    }

    return "virt,highmem=off"
  }

  if arch == "x86_64" {
    return f"q35,accel=${accel}"
  }

  return f"virt,accel=${accel},highmem=off"
}

proc qemu_binary() [process, env, error] -> Result[Path] {
  let arch = package_arch()

  if arch == "x86_64" {
    return process.which("qemu-system-x86_64")?
  }

  return process.which("qemu-system-aarch64")?
}

proc qemu_cpu_arg() [env] -> Str {
  let raw = (env.get("XSH_LINUX_LOOP_QEMU_CPU") ?? env.get("XSH_BOOT_QEMU_CPU") ?? "host").trim()

  if raw == "" {
    return "host"
  }

  return raw
}

proc qemu_rtc_arg() [env] -> Str {
  let raw = (env.get("XSH_BOOT_QEMU_RTC") ?? "base=utc,clock=host").trim()

  if raw == "" {
    return "base=utc,clock=host"
  }

  return raw
}

proc waterfox_qemu_proof_enabled() [env] -> Bool {
  let value = (env.get("XSH_BOOT_WATERFOX_QEMU_PROOF") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc waterfox_qemu_debug_enabled() [env] -> Bool {
  let value = (env.get("XSH_BOOT_WATERFOX_QEMU_DEBUG") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc waterfox_qemu_foot_shell_enabled() [env] -> Bool {
  let value = (env.get("XSH_BOOT_WATERFOX_QEMU_FOOT_SHELL") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc waterfox_qemu_browser_proof_enabled() [env] -> Bool {
  let value = (env.get("XSH_BOOT_WATERFOX_QEMU_BROWSER_PROOF") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc waterfox_qemu_clipboard_proof_enabled() [env] -> Bool {
  let value = (env.get("XSH_BOOT_WATERFOX_QEMU_CLIPBOARD_PROOF") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc waterfox_qemu_audio_proof_enabled() [env] -> Bool {
  let value = (env.get("XSH_BOOT_WATERFOX_QEMU_AUDIO_PROOF") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc waterfox_qemu_mesa_proof_enabled() [env] -> Bool {
  let value = (env.get("XSH_BOOT_WATERFOX_QEMU_MESA_PROOF") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc waterfox_qemu_visual_proof_enabled() [env] -> Bool {
  if waterfox_qemu_debug_enabled() or waterfox_qemu_foot_shell_enabled() {
    return true
  }

  if ! waterfox_qemu_proof_enabled() {
    return false
  }

  if waterfox_qemu_browser_proof_enabled() or waterfox_qemu_clipboard_proof_enabled() or waterfox_qemu_mesa_proof_enabled() {
    return true
  }

  return ! waterfox_qemu_audio_proof_enabled()
}

proc qemu_input_enabled() [env] -> Bool {
  let value = (env.get("XSH_BOOT_QEMU_INPUT") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc qemu_gpu_enabled() [env] -> Bool {
  let value = (env.get("XSH_BOOT_QEMU_GPU") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc qemu_gpu_device_arg() [env] -> Str {
  let raw = (env.get("XSH_BOOT_QEMU_GPU_DEVICE") ?? "virtio").trim()

  if raw == "virtio-mmio" {
    return "virtio-gpu-device,xres=1280,yres=800"
  }

  if raw == "virtio-blob" {
    return "virtio-gpu-pci,xres=1280,yres=800,hostmem=512M,blob=true"
  }

  if raw.starts_with("virtio-gpu-") {
    return raw
  }

  return "virtio-gpu-pci,xres=1280,yres=800"
}

proc qemu_memory_arg() [env] -> Str {
  let raw = (env.get("XSH_BOOT_QEMU_MEMORY") ?? "").trim()

  if raw != "" {
    return raw
  }

  if waterfox_qemu_visual_proof_enabled() {
    return "1536M"
  }

  return "512M"
}

proc qemu_display_arg() [env] -> Str {
  let raw = (env.get("XSH_BOOT_QEMU_DISPLAY") ?? "none").trim()

  if raw == "" or raw == "none" {
    return "none"
  }

  if raw == "cocoa" {
    return "cocoa,zoom-to-fit=on,show-cursor=on"
  }

  return raw
}

proc rootfs_source_path() [env] -> Str {
  let raw = (env.get("XSH_BOOT_ROOTFS_SOURCE") ?? "/").trim()

  if raw == "" {
    if waterfox_qemu_proof_enabled() {
      return "/rootfs"
    }

    return "/"
  }

  if raw == "/" and waterfox_qemu_proof_enabled() {
    return "/rootfs"
  }

  return raw
}

proc kernel_cmdline(proof_enabled: Bool, userspace_e2e: Bool) [env] -> Str {
  let _ = userspace_e2e
  let override = (env.get("XSH_BOOT_KERNEL_CMDLINE") ?? "").trim()

  if override != "" {
    return override
  }

  let arch = package_arch()

  let console_args = if arch == "x86_64" {
    "earlyprintk=serial console=ttyS0"
  } else {
    "earlycon=pl011,mmio,0x09000000 keep_bootcon console=ttyAMA0"
  }

  # Networking is configured in userspace by ifup/the net service, not the
  # kernel command line. (See USERSPACE-TODO: no ip=dhcp on normal boots.)
  let network_arg = ""
  let base = f"${console_args} ignore_loglevel devtmpfs.mount=1 root=PARTUUID=33333333-3333-3333-3333-333333333333 rootfstype=ext4 rootwait rootdelay=2 rw init=/init loglevel=8${network_arg} XSH_LINUX_REAL=1 XSH_UNIX_REAL=1 XSH_INIT_FAST_SHUTDOWN=1 XSH_INIT_FINAL_CLEANUP=0"

  if proof_enabled {
    if waterfox_qemu_proof_enabled() {
      var flags = ["XSH_XINIT_PROOF_STAGE=1", "XSH_WATERFOX_QEMU_PROOF=1"]

      if waterfox_qemu_visual_proof_enabled() {
        flags = flags.push("video=Virtual-1:1280x800@60e")
      }

      if waterfox_qemu_clipboard_proof_enabled() {
        flags = flags.push("XSH_WATERFOX_QEMU_CLIPBOARD_PROOF=1")
      }

      if waterfox_qemu_audio_proof_enabled() {
        flags = flags.push("XSH_WATERFOX_QEMU_AUDIO_PROOF=1")
      }

      if waterfox_qemu_mesa_proof_enabled() {
        flags = flags.push("XSH_WATERFOX_QEMU_MESA_PROOF=1")
      }

      if waterfox_qemu_browser_proof_enabled() {
        flags = flags.push("XSH_WATERFOX_QEMU_BROWSER_PROOF=1")
      }

      if waterfox_qemu_foot_shell_enabled() {
        flags = flags.push("XSH_WATERFOX_QEMU_FOOT_SHELL=1")
      }

      if waterfox_qemu_debug_enabled() {
        flags = flags.push("XSH_WATERFOX_QEMU_DEBUG=1")
      }

      if ! waterfox_qemu_debug_enabled() and ! waterfox_qemu_foot_shell_enabled() and ! waterfox_qemu_browser_proof_enabled() and ! waterfox_qemu_clipboard_proof_enabled() and ! waterfox_qemu_audio_proof_enabled() and ! waterfox_qemu_mesa_proof_enabled() {
        flags = flags.push("XSH_WATERFOX_QEMU_INPUT_PROOF=1")
      }

      return f"${base} ${flags.join(" ")}"
    }

    return f"${base} XSH_XINIT_PROOF_STAGE=1"
  }

  return base
}

proc qemu_net_device_arg() [env] -> Str {
  let raw = (env.get("XSH_BOOT_QEMU_NET_DEVICE") ?? "virtio-net-pci,netdev=net0").trim()

  if raw == "" {
    return "virtio-net-pci,netdev=net0"
  }

  return raw
}

proc qemu_root_device_arg() [env] -> Str {
  let raw = (env.get("XSH_BOOT_QEMU_ROOT_DEVICE") ?? "").trim()

  if raw != "" {
    return raw
  }

  let arch = package_arch()

  if arch == "x86_64" {
    return "virtio-blk-pci,drive=root"
  }

  return "virtio-blk-device,drive=root"
}

proc qemu_block_device_arg(drive: Str) [env] -> Str {
  let arch = package_arch()

  if arch == "x86_64" {
    return f"virtio-blk-pci,drive=${drive}"
  }

  return f"virtio-blk-device,drive=${drive}"
}

proc run_linux_only() [fs, net, process, env, error] {
  let root = fs.cwd()?
  let sh = process.which("sh")?
  let docker = process.which("docker")?
  let qemu = qemu_binary()?
  let arch = package_arch()
  let work = fp"${root}/target/linux-loop-${arch}"
  let kernel = fp"${work}/vmlinuz"
  let rootfs = fp"${work}/linux-only-rootfs.ext4"
  let trace = fp"${work}/boot.trace"
  let qemu_log = fp"${work}/qemu.log"
  let console_log = fp"${work}/console.log"
  work.mkdir()?
  fs.remove(trace, missing_ok: true)?
  fs.remove(qemu_log, missing_ok: true)?
  fs.remove(console_log, missing_ok: true)?
  trace_line(trace, f"boot-linux root: ${root}")?
  trace_line(trace, f"boot-linux trace: ${trace}")?
  trace_line(trace, f"boot-linux image: ${linux_loop_image_name()}")?
  ensure_packaged_kernel(root, kernel)?
  require_kernel_arch(trace, kernel, arch)?
  write_linux_only_rootfs(root, work, rootfs, sh, docker)?
  trace_file(trace, "kernel", kernel)?

  let console_args = if arch == "x86_64" {
    "earlyprintk=serial console=ttyS0"
  } else {
    "earlycon=pl011,mmio,0x09000000 keep_bootcon console=ttyAMA0"
  }

  let cmdline = f"${console_args} ignore_loglevel root=/dev/vda rootfstype=ext4 rootwait rootdelay=2 rw init=/init loglevel=8 devtmpfs.mount=1 XSH_INIT_TEST_EXIT_WHEN_IDLE=1 XSH_INIT_FAST_SHUTDOWN=1"
  let timeout = linux_loop_timeout_seconds()?

  let argv = [
    qemu.display(),
    "-M",
    qemu_machine_arg(),
    "-cpu",
    qemu_cpu_arg(),
    "-smp",
    "1",
    "-m",
    "256M",
    "-kernel",
    kernel.display(),
    "-append",
    cmdline,
    "-drive",
    f"if=none,id=root,format=raw,file=${rootfs},snapshot=on",
    "-device",
    qemu_root_device_arg(),
    "-nographic",
    "-no-reboot",
  ]

  trace_line(trace, f"kernel cmdline: ${cmdline}")?
  trace_line(trace, f"qemu argv: ${argv.join(" ")}")?
  trace_line(trace, f"qemu log: ${qemu_log}")?
  trace_line(trace, f"console log: ${console_log}")?
  trace_line(trace, f"timeout: ${timeout}s")?

  let watch = [
    sh.display(),
    "-c",
    """console_log=$1
qemu_log=$2
timeout_seconds=$3
attach_enabled=$4
shift 4

: > "$console_log"
: > "$qemu_log"
"$@" > "$console_log" 2> "$qemu_log" &
qemu_pid=$!
tail_pid=

if [ "$attach_enabled" != "0" ]; then
  tail -n +1 -f "$console_log" &
  tail_pid=$!
fi

ticks=0
while :; do
  if [ -f "$console_log" ] && grep -Eq 'Kernel panic|not syncing|Attempted to kill init|Insufficient stack space' "$console_log"; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && kill -TERM "$tail_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && wait "$tail_pid" 2>/dev/null || true
    exit 2
  fi

  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    wait "$qemu_pid"
    status=$?
    [ -n "$tail_pid" ] && kill -TERM "$tail_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && wait "$tail_pid" 2>/dev/null || true
    exit "$status"
  fi

  ticks=$((ticks + 1))
  if [ "$ticks" -ge "$timeout_seconds" ]; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && kill -TERM "$tail_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && wait "$tail_pid" 2>/dev/null || true
    exit 0
  fi

  sleep 1
done
""",
    "qemu-watch",
    console_log.display(),
    qemu_log.display(),
    f"${timeout}",
    if boot_attach_enabled() { "1" } else { "0" },
  ].extend(argv)

  let status = process.run(process.command_argv(sh, watch))?
  trace_file(trace, "qemu log", qemu_log)?
  trace_file(trace, "console log", console_log)?
  print_console_excerpt(trace, console_log, 60)?

  if console_has_panic(console_log)? {
    return Err(ScriptError.Failed("boot-linux-kernel-panic", f"kernel panic reproduced; see ${console_log}"))
  }

  if ! status.ok {
    return Err(ScriptError.Failed("boot-linux-qemu-failed", f"qemu failed; see ${trace}"))
  }

  if ! console_contains(console_log, "Linux version")? {
    return Err(
      ScriptError.Failed("boot-linux-no-kernel-output", f"kernel did not reach the serial console; see ${console_log}"),
    )
  }

  trace_line(trace, "boot-linux completed without panic before timeout")?
}

proc main(...argv: List[Str]) [fs, net, process, env, time, error] {
  var userspace_e2e_arg = false

  for arg in argv {
    if arg == "--linux-only" {
      run_linux_only()?
      return
    }

    if arg == "--userspace-e2e" {
      userspace_e2e_arg = true
      continue
    }

    return Err(ScriptError.Failed("boot-usage", f"unknown boot.xsh argument ${arg}"))
  }

  let root = fs.cwd()?
  let sh = process.which("sh")?
  let qemu = qemu_binary()?
  let tar = process.which("tar")?
  let arch = package_arch()
  let userspace_e2e = userspace_e2e_arg or userspace_e2e_enabled()
  let vm_mode = if userspace_e2e { "linux-userspace-e2e" } else { "linux-vm" }
  let rootfs_mode = if userspace_e2e { "userspace-e2e" } else { "interactive" }
  let vm_target = fp"${root}/target/${vm_mode}-${arch}"
  let kernel = fp"${vm_target}/packaged-vmlinuz-7.0.5"
  let rootfs_dir = fp"${root}/target/linux-rootfs-${rootfs_mode}-${arch}"
  let rootfs = fp"${vm_target}/rootfs-${rootfs_mode}.ext4"
  let rootfs_disk = fp"${vm_target}/rootfs-${rootfs_mode}.img"
  let swap_disk = fp"${vm_target}/userspace-e2e-swap.raw"
  let log = fp"${vm_target}/qemu.log"
  let console_log = fp"${vm_target}/console.log"
  let qemu_monitor = fp"${vm_target}/qemu-monitor.sock"
  let qemu_audio_wav = fp"${vm_target}/waterfox-audio.wav"
  let waterfox_screenshot = fp"${vm_target}/waterfox.ppm"
  let qmp_proof = fp"${root}/boot/qmp-proof.py"
  let trace = fp"${vm_target}/boot.trace"
  let boot_kernel = boot_kernel_path(kernel)?
  let proof_enabled = boot_proof_enabled()
  let tailscale_probe = tailscale_probe_enabled()

  let tailscale_auth_key = if proof_enabled or userspace_e2e {
    ""
  } else {
    require_dotenv_value(root, "TAILSCALE_AUTH_KEY")?
  }

  fs.remove(trace, missing_ok: true)?
  trace_line(trace, f"boot root: ${root}")?
  trace_line(trace, f"boot attach: ${boot_attach_enabled()}")?
  trace_line(trace, f"boot proof: ${proof_enabled}")?
  trace_line(trace, f"boot userspace e2e: ${userspace_e2e}")?
  trace_line(trace, f"boot tailscale probe: ${tailscale_probe}")?
  trace_line(trace, f"boot trace: ${trace}")?

  if boot_kernel == kernel {
    trace_line(trace, "kernel: using packaged scratch artifact")?
    ensure_packaged_kernel(root, kernel)?
  } else {
    trace_line(trace, f"kernel: using override ${boot_kernel}")?
  }

  trace_file(trace, "kernel", boot_kernel)?
  trace_optional_file_probe(trace, "kernel file", boot_kernel)?
  ensure_interactive_rootfs(root, rootfs_dir, sh, tar, proof_enabled, tailscale_probe, userspace_e2e)?

  fs.write(
    fp"${rootfs_dir}/etc/xsh-boot-epoch-ms",
    f"""${time.now()}
""",
  )?

  fs.write(
    fp"${rootfs_dir}/etc/resolv.conf",
    """nameserver 10.0.2.3
""",
  )?

  if ! proof_enabled and ! userspace_e2e {
    fs.mkdir(fp"${rootfs_dir}/etc/tailscale")?
    fs.mkdir(fp"${rootfs_dir}/var/lib/tailscale")?

    fs.write(
      fp"${rootfs_dir}/etc/fstab",
      """# <file system> <dir> <type> <options> <dump> <pass>
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
""",
    )?

    fs.write(
      fp"${rootfs_dir}/etc/tailscale/authkey",
      f"""${tailscale_auth_key}
""",
    )?

    fs.chmod(fp"${rootfs_dir}/etc/tailscale/authkey", 0o600)?
  }

  require_file(boot_kernel)?
  require_file(fp"${rootfs_dir}/init")?
  require_file(fp"${rootfs_dir}/bin/xsh")?
  trace_file(trace, "rootfs init", fp"${rootfs_dir}/init")?
  trace_file(trace, "rootfs xsh", fp"${rootfs_dir}/bin/xsh")?

  if ! proof_enabled and ! userspace_e2e {
    trace_file(trace, "rootfs tailscaled", fp"${rootfs_dir}/usr/bin/tailscaled")?
  }

  let rootfs_size = if fs.exists(fp"${rootfs_dir}/usr/bin/rustc")? {
    "3072M"
  } else if fs.exists(fp"${rootfs_dir}/opt/waterfox/waterfox-bin")? {
    "3072M"
  } else if fs.exists(fp"${rootfs_dir}/usr/bin/clang")? {
    "1536M"
  } else {
    "256M"
  }

  trace_line(trace, f"rootfs image target: ${rootfs} size=${rootfs_size}")?
  fs.remove(rootfs, missing_ok: true)?
  trace_line(trace, "rootfs image: mke2fs ext4 from root-owned staged copy")?
  write_rootfs_image(root, rootfs_dir, rootfs, rootfs_size, sh)?
  fs.fsync(rootfs)?
  trace_file(trace, "rootfs image", rootfs)?
  trace_optional_file_probe(trace, "rootfs image file", rootfs)?
  write_rootfs_gpt(rootfs_disk, rootfs)?
  fs.fsync(rootfs_disk)?
  trace_file(trace, "rootfs disk", rootfs_disk)?
  trace_optional_file_probe(trace, "rootfs disk file", rootfs_disk)?

  if userspace_e2e {
    fs.remove(swap_disk, missing_ok: true)?
    fs.write(swap_disk, b"")?
    swap_disk.truncate(image_size_bytes("64M")?)?
    fs.fsync(swap_disk)?
    trace_file(trace, "userspace e2e swap disk", swap_disk)?
  }

  fs.remove(log, missing_ok: true)?
  fs.remove(console_log, missing_ok: true)?
  fs.remove(qemu_monitor, missing_ok: true)?
  fs.remove(qemu_audio_wav, missing_ok: true)?
  fs.remove(waterfox_screenshot, missing_ok: true)?
  let cmdline = kernel_cmdline(proof_enabled, userspace_e2e)
  trace_line(trace, f"kernel cmdline: ${cmdline}")?

  var qemu_argv = [
    qemu.display(),
    "-M",
    qemu_machine_arg(),
    "-cpu",
    qemu_cpu_arg(),
    "-smp",
    "2",
    "-m",
    qemu_memory_arg(),
    "-rtc",
    qemu_rtc_arg(),
    "-kernel",
    boot_kernel.display(),
    "-append",
    cmdline,
    "-drive",
    f"if=none,id=root,format=raw,file=${rootfs_disk},snapshot=on",
    "-device",
    qemu_root_device_arg(),
  ]

  if userspace_e2e {
    qemu_argv = qemu_argv.extend(
      ["-drive", f"if=none,id=swap,format=raw,file=${swap_disk},snapshot=on", "-device", qemu_block_device_arg("swap")],
    )
  }

  if qemu_input_enabled() or waterfox_qemu_visual_proof_enabled() {
    qemu_argv = qemu_argv.extend(
      ["-device", "virtio-keyboard-pci", "-device", "virtio-tablet-pci", "-device", "virtio-mouse-pci"],
    )
  }

  if qemu_gpu_enabled() or waterfox_qemu_visual_proof_enabled() {
    qemu_argv = qemu_argv.extend(["-device", qemu_gpu_device_arg()])
  }

  if waterfox_qemu_visual_proof_enabled() {
    qemu_argv = qemu_argv.extend(["-qmp", f"unix:${qemu_monitor},server,nowait"])
    require_file(qmp_proof)?
  }

  if waterfox_qemu_audio_proof_enabled() {
    qemu_argv = qemu_argv.extend(
      [
        "-audiodev",
        f"wav,id=xshaudio,path=${qemu_audio_wav}",
        "-device",
        "virtio-sound-pci,audiodev=xshaudio,streams=1",
      ],
    )

    trace_line(trace, f"qemu audio wav: ${qemu_audio_wav}")?
  }

  qemu_argv = qemu_argv.extend(["-netdev", "user,id=net0", "-device", qemu_net_device_arg()])

  if waterfox_qemu_visual_proof_enabled() {
    let display_arg = qemu_display_arg()
    qemu_argv = qemu_argv.extend(["-display", display_arg, "-serial", "stdio"])
  } else {
    qemu_argv = qemu_argv.push("-nographic")
  }

  qemu_argv = qemu_argv.push("-no-reboot")
  trace_line(trace, f"qemu argv: ${qemu_argv.join(" ")}")?
  trace_line(trace, f"qemu log: ${log}")?
  let console_timeout = console_timeout_seconds()?
  trace_line(trace, f"waiting up to ${console_timeout}s for console output")?

  let watch = [
    sh.display(),
    "-c",
    """console_log=$1
qemu_log=$2
timeout_seconds=$3
attach_enabled=$4
interactive_attach=$5
monitor_sock=$6
screenshot=$7
waterfox_visual_proof=$8
waterfox_input_proof=$9
shift 9
waterfox_browser_proof=$1
shift 1
waterfox_clipboard_proof=$1
shift 1
waterfox_audio_proof=$1
shift 1
waterfox_mesa_proof=$1
shift 1
qmp_proof=$1
shift 1
boot_proof=$1
shift 1
tailscale_probe=$1
shift 1
tailscale_host_ssh_probe=$1
shift 1
userspace_e2e=$1
shift 1

: > "$console_log"
: > "$qemu_log"

if [ "$interactive_attach" = "1" ]; then
  fifo="$console_log.fifo.$$"
  rm -f "$fifo"
  mkfifo "$fifo" || exit 1
  tee "$console_log" < "$fifo" &
  tee_pid=$!
  "$@" > "$fifo" 2> "$qemu_log"
  status=$?
  wait "$tee_pid" 2>/dev/null || true
  rm -f "$fifo"
  exit "$status"
fi

"$@" > "$console_log" 2> "$qemu_log" &
	qemu_pid=$!
	tail_pid=
	proof_attempts=0

if [ "$attach_enabled" != "0" ]; then
  tail -n +1 -f "$console_log" &
  tail_pid=$!
fi

write_qmp_input_proof() {
  sock=$1
  python3 "$qmp_proof" input "$sock"
}

capture_qmp_ppm() {
  sock=$1
  shot=$2
  python3 "$qmp_proof" screenshot "$sock" "$shot"
}

send_qmp_browser_proof() {
  sock=$1
  python3 "$qmp_proof" browser "$sock"
}

ticks=0
saw_output=0
input_attempts=0
browser_attempts=0
while :; do
  if [ -s "$console_log" ]; then
    saw_output=1
  fi

  if [ -f "$console_log" ] && grep -Eq 'Kernel panic|not syncing|Attempted to kill init' "$console_log"; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && kill -TERM "$tail_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && wait "$tail_pid" 2>/dev/null || true
    exit 2
  fi

  if [ -f "$console_log" ] && grep -q 'LAPUTA_BOOT_PROOF_FAILED' "$console_log"; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && kill -TERM "$tail_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && wait "$tail_pid" 2>/dev/null || true
    exit 2
  fi

  if [ -f "$console_log" ] && grep -q 'LAPUTA_BOOT_PROOF_OK' "$console_log"; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && kill -TERM "$tail_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && wait "$tail_pid" 2>/dev/null || true
    exit 0
  fi

  if [ -f "$console_log" ] && grep -q 'LAPUTA_TAILSCALE_PROBE_FAILED' "$console_log"; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && kill -TERM "$tail_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && wait "$tail_pid" 2>/dev/null || true
    exit 2
  fi

  if [ -f "$console_log" ] && grep -q 'LAPUTA_TAILSCALE_PROBE_OK' "$console_log"; then
    if [ "$tailscale_host_ssh_probe" = "1" ]; then
      tailscale_ip=$(sed -n 's/.*LAPUTA_TAILSCALE_PROBE_OK ip=\\([^ ]*\\).*/\\1/p' "$console_log" | tail -n 1 | tr -d '\r')

      if [ -z "$tailscale_ip" ]; then
        echo "tailscale-ssh-probe: missing probe ip" >> "$qemu_log"
        kill -TERM "$qemu_pid" 2>/dev/null || true
        [ -n "$tail_pid" ] && kill -TERM "$tail_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        [ -n "$tail_pid" ] && wait "$tail_pid" 2>/dev/null || true
        exit 2
      fi

      ssh_status=1
      ssh_attempt=1

      while [ "$ssh_attempt" -le 12 ]; do
        if command -v tailscale >/dev/null 2>&1; then
          tailscale ping --timeout=5s --c 1 "$tailscale_ip" >> "$qemu_log" 2>&1 || true
        fi

        echo "tailscale-ssh-probe: attempt $ssh_attempt ssh laputa@$tailscale_ip tailscale-ip" >> "$qemu_log"
        ssh -o ConnectTimeout=10 -o ConnectionAttempts=1 -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -- "laputa@$tailscale_ip" "/usr/bin/tailscale --socket /run/tailscale/tailscaled.sock ip -4" >> "$qemu_log" 2>&1
        ssh_status=$?

        if [ "$ssh_status" = "0" ]; then
          break
        fi

        sleep 5
        ssh_attempt=$((ssh_attempt + 1))
      done

      if [ "$ssh_status" != "0" ]; then
        echo "tailscale-ssh-probe: failed status=$ssh_status" >> "$qemu_log"
        kill -TERM "$qemu_pid" 2>/dev/null || true
        [ -n "$tail_pid" ] && kill -TERM "$tail_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        [ -n "$tail_pid" ] && wait "$tail_pid" 2>/dev/null || true
        exit 2
      fi

      echo "tailscale-ssh-probe: ok" >> "$qemu_log"
    fi

    kill -TERM "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && kill -TERM "$tail_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && wait "$tail_pid" 2>/dev/null || true
    exit 0
  fi

  if [ -f "$console_log" ] && grep -q 'LAPUTA_USERSPACE_E2E_FAILED' "$console_log"; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && kill -TERM "$tail_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && wait "$tail_pid" 2>/dev/null || true
    exit 2
  fi

  if [ -f "$console_log" ] && grep -q 'LAPUTA_USERSPACE_E2E_LOGIN_SHELL' "$console_log"; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && kill -TERM "$tail_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && wait "$tail_pid" 2>/dev/null || true
    exit 0
  fi

  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    wait "$qemu_pid"
    status=$?
    [ -n "$tail_pid" ] && kill -TERM "$tail_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && wait "$tail_pid" 2>/dev/null || true
    exit "$status"
  fi

  if [ "$waterfox_visual_proof" = "1" ] && [ "$ticks" -ge 10 ] && [ -S "$monitor_sock" ]; then
    if [ "$proof_attempts" -lt 36 ]; then
      echo "waterfox-qemu-monitor attempt=$proof_attempts ticks=$ticks" >> "$qemu_log"
      capture_qmp_ppm "$monitor_sock" "$screenshot" >> "$qemu_log" 2>&1 || true
      proof_attempts=$((proof_attempts + 1))
    fi

    if [ "$waterfox_input_proof" = "1" ] && [ "$input_attempts" -lt 70 ] && [ "$ticks" -ge 18 ]; then
      echo "waterfox-qemu-input attempt=$input_attempts ticks=$ticks" >> "$qemu_log"
      write_qmp_input_proof "$monitor_sock" >> "$qemu_log" 2>&1 || true
      input_attempts=$((input_attempts + 1))
    fi

    if [ "$waterfox_browser_proof" = "1" ] && [ "$browser_attempts" -lt 8 ] && [ "$ticks" -ge 30 ]; then
      echo "waterfox-qemu-browser-input attempt=$browser_attempts ticks=$ticks" >> "$qemu_log"
      send_qmp_browser_proof "$monitor_sock" >> "$qemu_log" 2>&1 || true
      browser_attempts=$((browser_attempts + 1))
    fi
  fi

  ticks=$((ticks + 1))
  if [ "$saw_output" = "0" ] && [ "$ticks" -ge "$timeout_seconds" ]; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && kill -TERM "$tail_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && wait "$tail_pid" 2>/dev/null || true
    exit 124
  fi

  if [ "$attach_enabled" = "0" ] && [ "$boot_proof" != "1" ] && [ "$tailscale_probe" != "1" ] && [ "$userspace_e2e" != "1" ] && [ "$saw_output" = "1" ] && [ "$ticks" -ge "$timeout_seconds" ]; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    exit 0
  fi

  if { [ "$boot_proof" = "1" ] || [ "$tailscale_probe" = "1" ] || [ "$userspace_e2e" = "1" ]; } && [ "$ticks" -ge "$timeout_seconds" ]; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && kill -TERM "$tail_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && wait "$tail_pid" 2>/dev/null || true
    exit 124
  fi

  if [ "$waterfox_visual_proof" = "1" ]; then
    proof_selected=0
    proof_done=1

    if [ "$waterfox_input_proof" = "1" ]; then
      proof_selected=1
      grep -q 'waterfox-qemu foot-input ok' "$console_log" || proof_done=0
    fi

    if [ "$waterfox_browser_proof" = "1" ]; then
      proof_selected=1
      if ! { [ "$browser_attempts" -ge 2 ] && [ -s "$screenshot" ] && grep -q 'waterfox-qemu browser-session-ready' "$console_log" && grep -q 'waterfox-qemu-browser-qmp-input ok' "$qemu_log"; } && ! grep -q 'Example Domain' "$console_log"; then
        proof_done=0
      fi
    fi

    if [ "$waterfox_clipboard_proof" = "1" ]; then
      proof_selected=1
      grep -q 'waterfox-qemu clipboard ok' "$console_log" || proof_done=0
    fi

    if [ "$waterfox_audio_proof" = "1" ]; then
      proof_selected=1
      grep -q 'waterfox-qemu audio ok' "$console_log" || proof_done=0
    fi

    if [ "$waterfox_mesa_proof" = "1" ]; then
      proof_selected=1
      grep -q 'waterfox-qemu mesa ok' "$console_log" || proof_done=0
    fi

    if { [ "$proof_selected" = "0" ] && grep -q 'waterfox-qemu debug done' "$console_log"; } || { [ "$proof_selected" = "1" ] && [ "$proof_done" = "1" ]; }; then
      kill -TERM "$qemu_pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$qemu_pid" 2>/dev/null || true
      wait "$qemu_pid" 2>/dev/null || true
      exit 0
    fi
  fi

  if [ "$waterfox_visual_proof" != "1" ] && [ "$waterfox_audio_proof" = "1" ] && grep -q 'waterfox-qemu audio ok' "$console_log"; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    exit 0
  fi

  sleep 1
done
""",
    "qemu-watch",
    console_log.display(),
    log.display(),
    f"${console_timeout}",
    if boot_attach_enabled() { "1" } else { "0" },
    if boot_attach_enabled() and ! proof_enabled { "1" } else { "0" },
    qemu_monitor.display(),
    waterfox_screenshot.display(),
    if waterfox_qemu_visual_proof_enabled() { "1" } else { "0" },
    if waterfox_qemu_proof_enabled() and ! waterfox_qemu_debug_enabled() and ! waterfox_qemu_foot_shell_enabled() and ! waterfox_qemu_browser_proof_enabled() and ! waterfox_qemu_clipboard_proof_enabled() and ! waterfox_qemu_audio_proof_enabled() and ! waterfox_qemu_mesa_proof_enabled() {
      "1"
    } else {
      "0"
    },
    if waterfox_qemu_browser_proof_enabled() { "1" } else { "0" },
    if waterfox_qemu_clipboard_proof_enabled() { "1" } else { "0" },
    if waterfox_qemu_audio_proof_enabled() { "1" } else { "0" },
    if waterfox_qemu_mesa_proof_enabled() { "1" } else { "0" },
    qmp_proof.display(),
    if proof_enabled { "1" } else { "0" },
    if tailscale_probe { "1" } else { "0" },
    if env_value("XSH_BOOT_TAILSCALE_HOST_SSH_PROBE", "0") == "1" { "1" } else { "0" },
    if userspace_e2e { "1" } else { "0" },
  ].extend(qemu_argv)

  let status = process.run(process.command_argv(sh, watch))?
  trace_file(trace, "qemu log", log)?
  trace_file(trace, "console log", console_log)?
  print_console_excerpt(trace, console_log, 40)?

  if ! boot_attach_enabled() {
    if ! status.ok {
      return Err(ScriptError.Failed("boot-console-failed", f"console probe failed; see ${trace}"))
    }

    if waterfox_qemu_visual_proof_enabled() {
      verify_waterfox_qemu_visual_proof(
        trace,
        console_log,
        log,
        waterfox_screenshot,
        sh,
        waterfox_qemu_debug_enabled(),
        waterfox_qemu_foot_shell_enabled(),
        waterfox_qemu_browser_proof_enabled(),
        waterfox_qemu_clipboard_proof_enabled(),
        waterfox_qemu_mesa_proof_enabled(),
      )?
    }

    if waterfox_qemu_audio_proof_enabled() {
      verify_waterfox_qemu_audio_proof(trace, console_log)?
    }

    if userspace_e2e {
      if ! console_contains(console_log, "LAPUTA_USERSPACE_E2E_BOOT_OK")? {
        return Err(ScriptError.Failed("boot-userspace-e2e", f"missing userspace boot marker in ${console_log}"))
      }

      if ! console_contains(console_log, "LAPUTA_USERSPACE_E2E_MDEVD")? {
        return Err(ScriptError.Failed("boot-userspace-e2e", f"missing mdevd marker in ${console_log}"))
      }

      if ! console_contains(console_log, "LAPUTA_USERSPACE_E2E_LOGIN_SHELL")? {
        return Err(ScriptError.Failed("boot-userspace-e2e", f"missing login shell marker in ${console_log}"))
      }

      trace_line(trace, "userspace e2e: ok")?
    }

    trace_line(trace, "boot probe complete without console attach")?
    return
  }

  if console_has_panic(console_log)? {
    return Err(ScriptError.Failed("boot-kernel-panic", f"kernel panic; see ${console_log}"))
  }

  if ! console_has_output(console_log)? {
    return Err(ScriptError.Failed("boot-console-silent", f"no console output after ${console_timeout}s; see ${trace}"))
  }

  if ! status.ok {
    return Err(ScriptError.Failed("boot-console-failed", f"qemu exited non-zero; see ${trace}"))
  }

  if waterfox_qemu_visual_proof_enabled() {
    verify_waterfox_qemu_visual_proof(
      trace,
      console_log,
      log,
      waterfox_screenshot,
      sh,
      waterfox_qemu_debug_enabled(),
      waterfox_qemu_foot_shell_enabled(),
      waterfox_qemu_browser_proof_enabled(),
      waterfox_qemu_clipboard_proof_enabled(),
      waterfox_qemu_mesa_proof_enabled(),
    )?
  }
}

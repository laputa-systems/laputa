#!/bin/xsh
error InstallerSizeError = Failed(message: Str)

type PackageSize = {name: Str, size: Int}

proc env_value(name: Str, fallback: Str) [env] -> Str {
  let value = env.get(name) ?? ""

  if value == "" {
    return fallback
  }

  return value
}

proc env_path(name: Str, fallback: Path) [env, error] -> Result[Path] {
  return fp"${env_value(name, fallback.display())}"
}

pure normalize_arch(arch: Str) -> Result[Str] {
  if arch == "amd64" {
    return "x86_64"
  }

  if arch == "arm64" {
    return "aarch64"
  }

  if arch == "aarch64" or arch == "x86_64" {
    return arch
  }

  return Err(InstallerSizeError.Failed(f"unsupported installer arch ${arch}"))
}

pure kib(value: Int) -> Int {
  return (value + 1024 - 1) / 1024
}

pure size_label(value: Int) -> Str {
  return f"${kib(value)}K"
}

proc path_size(path_value: Path) [fs, error] -> Result[Int] {
  if ! fs.exists(path_value)? {
    return 0
  }

  let meta = path_value.metadata()?

  if meta.kind != "dir" {
    return meta.size
  }

  var total = meta.size

  for child in fs.ls(path_value)? {
    total += path_size(child.path)?
  }

  return total
}

proc print_path_size(label: Str, path_value: Path) [fs, error] {
  if fs.exists(path_value)? {
    print ${label}: size_label(path_size(path_value)?) $path_value
  } else {
    print ${label}: missing $path_value
  }
}

proc package_size(rootfs: Path, manifest_path: Path) [fs, error] -> Result[Int] {
  let manifest: List[Str] = json.read(manifest_path)?
  var total = 0

  for rel in manifest {
    total += path_size(fp"${rootfs}/${rel}")?
  }

  return total
}

proc package_size_rows(rootfs: Path) [fs, error] -> Result[List[PackageSize]] {
  let db = fp"${rootfs}/var/lib/xsh-pm/packages"
  var rows: List[PackageSize] = []

  if ! fs.exists(db)? {
    return rows
  }

  for entry in fs.ls(db)? |> where .kind == "dir" {
    rows = rows.push({name: entry.name, size: package_size(rootfs, fp"${entry.path}/manifest.json")?})
  }

  return rows |> sort-by .size
}

proc print_package_sizes(label: Str, rootfs: Path) [fs, error] {
  print $label packages:
  let rows = package_size_rows(rootfs)?
  var index = rows.len()

  while index > 0 {
    index -= 1
    let row = rows[index]
    print size_label(row.size) ${row.name}
  }
}

proc print_report(arch: Str, work: Path, iso: Path, kernel: Path) [fs, error] {
  print installer size report: $arch
  print_path_size("iso", iso)?
  print_path_size("kernel", kernel)?
  print_path_size("target rootfs", fp"${work}/rootfs-target")?
  print_path_size("installer rootfs", fp"${work}/rootfs-installer")?
  print_path_size("tools rootfs", fp"${work}/rootfs-tools")?
  print_path_size("target root payload", fp"${work}/target-root.tar.gz")?
  print_path_size("installer root image", fp"${work}/installer-root.ext4")?
  print_package_sizes("target rootfs", fp"${work}/rootfs-target")?
  print_package_sizes("installer rootfs", fp"${work}/rootfs-installer")?
}

proc main(...argv: List[Str]) [fs, env, error] {
  if argv.len() > 4 {
    return Err(InstallerSizeError.Failed("usage: installer-size.xsh ARCH [WORK [ISO [KERNEL]]]"))
  }

  let raw_arch = if argv.len() >= 1 { argv[0] } else { env_value("LAPUTA_INSTALLER_ARCH", "aarch64") }
  let arch = normalize_arch(raw_arch)?
  let root = env_path("LAPUTA_ROOT", fs.cwd()?)?

  let work = if argv.len() >= 2 {
    fp"${argv[1]}"
  } else {
    env_path("LAPUTA_INSTALLER_WORK", fp"${root}/target/laputa-installer-${arch}")?
  }

  let iso = if argv.len() >= 3 {
    fp"${argv[2]}"
  } else {
    env_path("LAPUTA_INSTALLER_ISO", fp"${work}/laputa-installer-${arch}.iso")?
  }

  let kernel = if argv.len() >= 4 {
    fp"${argv[3]}"
  } else {
    env_path("LAPUTA_INSTALLER_KERNEL", fp"${work}/laputa-installer-${arch}.vmlinuz")?
  }

  print_report(arch, work, iso, kernel)?
}

main(@args)?

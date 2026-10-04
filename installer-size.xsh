#!/bin/xsh
use installer.host as host

error InstallerSizeError = Failed(message: Str)

type PackageSize = {name: Str, size: Int}

pure kib(value: Int) -> Int {
  (value + 1024 - 1) / 1024
}

pure size_label(value: Int) -> Str {
  f"{kib(value)}K"
}

proc path_size(path_value: Path) [fs, error] -> Result[Int] {
  guard fs.exists(path_value)? else {
    return 0
  }

  let meta = path_value.metadata()?

  return meta.size when meta.kind != "dir"

  var total = meta.size

  for child in fs.children(path_value)? {
    total += path_size(child.path)?
  }

  total
}

proc print_path_size(label: Str, path_value: Path) [fs, error] {
  if fs.exists(path_value)? {
    print ${label}: size_label(path_size(path_value)?) $path_value
  } else {
    print ${label}: missing $path_value
  }
}

proc package_size(rootfs: Path, manifest_path: Path) [fs, error] -> Result[Int] {
  let manifest = json.read(manifest_path)?.require(List[Str])?
  var total = 0

  for rel in manifest {
    total += path_size(fp"{rootfs}/{rel}")?
  }

  total
}

proc package_size_rows(rootfs: Path) [fs, error] -> Result[List[PackageSize]] {
  let db = fp"{rootfs}/var/lib/xsh-pm/packages"
  var rows: List[PackageSize] = []

  return rows unless fs.exists(db)?

  for entry in fs.children(db)? |> where .kind == "dir" {
    rows = rows.push({name: entry.name, size: package_size(rootfs, fp"{entry.path}/manifest.json")?})
  }

  rows |> sort-by .size
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
  print_path_size("target rootfs", fp"{work}/rootfs-target")?
  print_path_size("installer rootfs", fp"{work}/rootfs-installer")?
  print_path_size("tools rootfs", fp"{work}/rootfs-tools")?
  print_path_size("target root payload", fp"{work}/target-root.tar.gz")?
  print_path_size("installer root image", fp"{work}/installer-root.ext4")?
  print_package_sizes("target rootfs", fp"{work}/rootfs-target")?
  print_package_sizes("installer rootfs", fp"{work}/rootfs-installer")?
}

proc main(...argv: List[Str]) [fs, env, error] {
  if argv.len() > 4 {
    return Err(InstallerSizeError.Failed("usage: installer-size.xsh ARCH [WORK [ISO [KERNEL]]]"))
  }

  let raw_arch = if argv.len() >= 1 { argv[0] } else { host.installer_env_value("LAPUTA_INSTALLER_ARCH", "aarch64") }
  let arch = host.installer_arch(raw_arch)?
  let root = host.installer_env_path("LAPUTA_ROOT", fs.cwd()?)?

  let work = if argv.len() >= 2 {
    fp"{argv[1]}"
  } else {
    host.installer_env_path("LAPUTA_INSTALLER_WORK", fp"{root}/target/laputa-installer-{arch}")?
  }

  let iso = if argv.len() >= 3 {
    fp"{argv[2]}"
  } else {
    host.installer_env_path("LAPUTA_INSTALLER_ISO", fp"{work}/laputa-installer-{arch}.iso")?
  }

  let kernel = if argv.len() >= 4 {
    fp"{argv[3]}"
  } else {
    host.installer_env_path("LAPUTA_INSTALLER_KERNEL", fp"{work}/laputa-installer-{arch}.vmlinuz")?
  }

  print_report(arch, work, iso, kernel)?
}

main(@args)?

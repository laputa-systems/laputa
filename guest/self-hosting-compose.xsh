use pm.generation
use pm.util

proc main(root: Path) [fs, process, env, time, error] -> Result[Unit, Error] {
  assert generation.read_generation_receipt(/)?.profile.name == "qemu-self-hosting"
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  let output = p"/run/self-hosting-output"
  output.mkdir()?
  linux.mount(b"/dev/vdc", output, fstype: "ext4", options: ["nosuid", "nodev"])?
  linux.mount(b"scratch", fp"{root}/scratch", fstype: "tmpfs", options: ["mode=1777", "size=1G", "nosuid", "nodev"])?
  linux.mount(b"proc", fp"{root}/proc", fstype: "proc", options: ["nosuid", "noexec", "nodev"])?
  linux.mount(b"dev", fp"{root}/dev", fstype: "devtmpfs", options: ["nosuid"])?
  p"/run/self-hosting-sentinel".write("guest boundary sentinel\n")?
  let work = p"/run/self-hosting-successor"
  work.mkdir()?
  linux.mount(b"successor", work, fstype: "tmpfs", options: ["size=1G", "nosuid", "nodev"])?
  let repository = fp"{work}/repository"
  let _ = fs.copy_tree(fp"{root}/inputs/laputa", repository, parents: true)?
  let seed = fp"{repository}/.out/seed/x86_64"
  let _ = fs.copy_tree(fp"{root}/inputs/seed-A", seed, parents: true)?
  let runners = fp"{work}/runners"
  runners.mkdir()?
  for name in ["xsh", "xsht"] {
    let source = fp"{output}/target/x86_64-unknown-linux-musl/verification/{name}"
    fs.install(source, fp"{runners}/{name}", 0o755)?
    fs.install(source, fp"{seed}/{name}", 0o755, overwrite: true)?
  }
  let manifest = fp"{seed}/manifest.json"
  let record = json.read(manifest)?.require(Record)?
  let files = {name: hash.sha256(fp"{seed}/{name}")?.hex() for name in ["xsh", "xshi", "xsht", "core.tar.xz"]}
  json.write(manifest, {format: record.get("format")?.require(Str)?, arch: record.get("arch")?.require(Str)?, files})?
  for name in ["cohort-c", "cohort-rust", "cohort-xsh"] {
    let _ = fs.copy_tree(fp"{root}/cohort/packages/{name}", fp"{repository}/packages/{name}")?
  }
  let profile = fp"{repository}/profiles/qemu-self-hosting.xsh"
  profile.write(profile.read_text()?.replace("\"laputa-pm\", \"xinit\"", with: "\"laputa-pm\", \"xinit\", \"cohort-c\", \"cohort-rust\", \"cohort-xsh\""))?
  util.normalize_checkout_tree(repository)?
  let artifacts = fp"{output}/successor-artifacts"
  let _ = fs.copy_tree(fp"{root}/inputs/artifacts-A", artifacts)?
  let bundle = fp"{output}/successor"
  bundle.mkdir()?
  for directory in [artifacts, bundle] {
    fs.set_owner(directory, uid: 65534, gid: 65534)?
    for entry in fs.walk(directory, hidden: true)? { fs.set_owner(entry.path, uid: 65534, gid: 65534)? }
  }
  for pair in [
    {source: repository, destination: fp"{root}/src/laputa"},
    {source: artifacts, destination: fp"{root}/artifacts"},
    {source: bundle, destination: fp"{root}/output"},
    {source: fp"{runners}/xsh", destination: fp"{root}/bin/xsh"},
    {source: fp"{runners}/xsht", destination: fp"{root}/bin/xsht"},
  ] {
    linux.mount(bytes.from_text(pair.source.display()), pair.destination, options: ["bind"])?
  }
  linux.mount(b"", fp"{root}/src/laputa", options: ["remount", "bind", "ro"])?
  let command = process.command_argv(/bin/xsh, ["/bin/xsh", "/src/laputa/guest/self-hosting-compose-inner.xsh"], env: {
    PATH: "/bin:/usr/lib/xsh/core:/usr/bin", XSH_MODULE_PATH: "/src/laputa", HOME: "/scratch/home",
    TMPDIR: "/output/tmp", LANG: "C", LC_ALL: "C", TZ: "UTC",
    LAPUTA_SOURCE_CACHE: "/inputs/source-cache", XSH_PM_TARGET_ARCH: "x86_64",
    XSH_PM_BOOTSTRAP_LLVM_ROOT: "/usr/lib/llvm23",
    LAPUTA_SENTINEL_PATH: "/run/self-hosting-sentinel",
    LAPUTA_COHORT_SOURCE: "/src/laputa/packages/cohort-c/files/hello.c",
    KACHE_CACHE_DIR: "/scratch/kache", KACHE_RUNTIME_DIR: "/scratch/kache-runtime",
    KACHE_SOCKET_PATH: "/scratch/kache-runtime/daemon.sock", KACHE_LOCAL_ONLY: "1",
  })
  fp"{bundle}/tmp".mkdir()?
  fs.set_owner(fp"{bundle}/tmp", uid: 65534, gid: 65534)?
  let status = linux.run_in_namespaces(command, unshare: ["net"], root: root, cwd: root, uid: 65534, gid: 65534, drop_groups: true)?
  fs.sync()?
  fail "in-guest successor composition failed" unless status.ok
  print "LAPUTA_SELF_HOSTING_SUCCESSOR_COMPOSED"
}

main(@args)?

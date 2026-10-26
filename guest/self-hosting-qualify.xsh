use pm.generation

proc run_closed(root: Path, script: Str, arguments: List[Str]) [process, error] -> Result[Unit, Error] {
  let command = process.command_argv(/bin/xsh, ["/bin/xsh", script, @arguments], env: {
    PATH: "/bin:/usr/lib/xsh/core:/usr/bin",
    XSH_MODULE_PATH: "/pm",
    HOME: "/scratch/home",
    TMPDIR: "/scratch",
    LANG: "C", LC_ALL: "C", TZ: "UTC",
    KACHE_CACHE_DIR: "/scratch/kache",
    KACHE_RUNTIME_DIR: "/scratch/kache-runtime",
    KACHE_SOCKET_PATH: "/scratch/kache-runtime/daemon.sock",
    KACHE_LOCAL_ONLY: "1",
    LAPUTA_SENTINEL_PATH: "/run/self-hosting-sentinel",
    LAPUTA_COHORT_SOURCE: f"{arguments[0]}/packages/cohort-c/files/hello.c",
  })
  let status = linux.run_in_namespaces(command, unshare: ["net"], root: root, cwd: root, uid: 65534, gid: 65534, drop_groups: true)?
  fail f"guest qualification failed: {script}" unless status.ok
}

proc main(root: Path) [fs, process, env, time, error] -> Result[Unit, Error] {
  let receipt = generation.read_generation_receipt(/)?
  assert receipt.profile.name == "qemu-self-hosting"
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  let output = p"/run/self-hosting-output"
  output.mkdir()?
  linux.mount(b"/dev/vdc", output, fstype: "ext4", options: ["nosuid", "nodev"])?
  linux.mount(b"scratch", fp"{root}/scratch", fstype: "tmpfs", options: ["mode=1777", "size=1G", "nosuid", "nodev"])?
  linux.mount(b"proc", fp"{root}/proc", fstype: "proc", options: ["nosuid", "noexec", "nodev"])?
  linux.mount(b"dev", fp"{root}/dev", fstype: "devtmpfs", options: ["nosuid"])?
  let runners = p"/run/self-hosting-runners"
  runners.mkdir()?
  p"/run/self-hosting-sentinel".write("guest boundary sentinel\n")?
  for name in ["xsh", "xsht"] {
    fs.install(fp"{output}/target/x86_64-unknown-linux-musl/verification/{name}", fp"{runners}/{name}", 0o755)?
  }
  for pass in ["baseline", "replacement"] {
    let store = fp"{output}/{pass}"
    store.mkdir()?
    fs.set_owner(store, uid: 65534, gid: 65534)?
    if pass == "replacement" {
      for name in ["xsh", "xsht"] {
        linux.mount(bytes.from_text(fp"{runners}/{name}".display()), fp"{root}/bin/{name}", options: ["bind"])?
      }
    }
    linux.mount(bytes.from_text(store.display()), fp"{root}/output", options: ["bind"])?
    run_closed(root, "/inputs/laputa/guest/self-hosting-cohort.xsh", [if pass == "baseline" { "/checkout-one" } else { "/checkout-two" }])?
    assert p"/run/self-hosting-sentinel".read_text()? == "guest boundary sentinel\n"
    linux.umount(fp"{root}/output")?
  }
  for name in ["cohort-c", "cohort-rust", "cohort-xsh"] {
    var first: Record = {}
    var second: Record = {}
    var first_payload: Path = /
    var second_payload: Path = /
    for pass in ["baseline", "replacement"] {
      for entry in fs.walk(fp"{output}/{pass}/store", hidden: true)? {
        continue unless entry.kind == "file" and entry.path.name == "artifact.json"
        let value = json.read(entry.path)?.require(Record)?
        continue unless value.get("package_name")?.require(Str)? == name
        if pass == "baseline" {
          first = value
          first_payload = fp"{entry.path.parent}/payload.tar.gz"
        } else {
          second = value
          second_payload = fp"{entry.path.parent}/payload.tar.gz"
        }
      }
    }
    for field in ["key", "payload_sha256"] { assert first.get(field)? == second.get(field)? }
    assert first.get("executor_sha256")? != second.get("executor_sha256")?
    assert first_payload.read_bytes()? == second_payload.read_bytes()?
    print "LAP29_COHORT_MATCH" $name
  }
  fs.sync()?
  print "LAPUTA_SELF_HOSTING_QUALIFIED"
}

main(@args)?

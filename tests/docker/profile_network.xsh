use system.docker

proc main(image: Str, seed: Path) [fs, process, env, error] {
  let checkout = fs.cwd()?
  let temporary = fs.tempdir()?
  let scratch = temporary.host_path()?
  let root = fp"{scratch}/checkout"
  let output = fp"{scratch}/output"
  let artifacts = fp"{scratch}/artifacts"
  let sentinel = fp"{scratch}/host-sentinel"
  let mounted_sentinel = fp"{root}/mounted-sentinel"
  let entry = fp"{root}/seed/container_entry.xsh"
  let probe = fp"{root}/probe.xsh"
  entry.parent.mkdir()
  fp"{checkout}/seed/container_entry.xsh".copy(to: entry)
  fp"{checkout}/tests/docker/fixtures/profile_network_probe.xsh".copy(to: probe)
  output.mkdir()
  artifacts.mkdir()
  fp"{root}/.out/cache/linux-kbuild".mkdir()
  sentinel.write("host sentinel\n")
  mounted_sentinel.write("mounted sentinel\n")
  let identity = unix.id()?
  let config: docker.DockerConfig = {
    docker: process.which("docker")?,
    arch: "x86_64",
    platform: "linux/amd64",
    laputa_root: root,
    seed: seed,
    output_root: output,
    artifact_root: artifacts,
    image: image,
    repo_url: "",
    owner: {uid: identity.uid, gid: identity.gid},
  }

  for expected in ["reachable", "isolated"] {
    let inner = ["/bin/xsh", "/src/laputa/probe.xsh", "--", expected, sentinel.display()]
    let constructed = docker.docker_command_argv(config, inner)
    let argv = if expected == "reachable" {
      [constructed[index] for index in range(constructed.len())
        if constructed[index] != "--network" and (index == 0 or constructed[index - 1] != "--network")]
    } else {
      constructed
    }
    env ({LAPUTA_AMBIENT_POISON: "host-only", HTTP_PROXY: "http://laputa-poison.invalid:9", HTTPS_PROXY: "http://laputa-poison.invalid:9"}) {
      let status = process.run(process.command_argv(config.docker, argv, root))?
      assert status.ok
    }?
    assert sentinel.read_text()? == "host sentinel\n"
    assert mounted_sentinel.read_text()? == "mounted sentinel\n"
    assert fp"{output}/offline-result".read_text()? == "declared offline operation passed\n"
  }
}

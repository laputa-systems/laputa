use seed.images
use seed.world
use seed.xsh_seed
use system.build
use system.docker
use system.profile

proc main(repository: Path, artifacts: Path, output: Path, image: Str) [fs, process, env, error] -> Result[Unit, Error] {
  let arch = xsh_seed.xsh_seed_arch("x86_64")?
  let identity = unix.id()?
  world.world_kbuild_cache(repository).mkdir()?
  let config: docker.DockerConfig = {
    docker: images.docker_program()?,
    arch: arch.arch,
    platform: arch.docker_platform,
    laputa_root: repository,
    seed: xsh_seed.xsh_seed_require(repository, arch.arch)?,
    output_root: output,
    artifact_root: artifacts,
    image,
    repo_url: "",
    owner: {uid: identity.uid, gid: identity.gid},
  }
  let intent = profile.load_system_profile("qemu-self-hosting", fp"{repository}/profiles")?
  let result = build.build_profile(config, intent, 2)?
  print "self-hosting system bundle" $result.current
}

main(@args)?

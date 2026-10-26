use system.docker
use system.profile

proc main() [fs, process, env, error] -> Result[Unit, Error] {
  let intent = profile.load_system_profile("qemu-self-hosting", /src/laputa/profiles)?
  let commands = [
    docker.docker_pm_plan_argv(intent, "x86_64"),
    ["/bin/xsh", "/src/laputa/system/container_build.xsh", "--", "plan", intent.name, "2"],
    ["/bin/xsh", "/src/laputa/system/container_build.xsh", "--", "build", intent.name, "2"],
  ]
  for argv in commands {
    let status = process.run(process.command_argv(/bin/xsh, argv, /src/laputa))?
    fail "successor PM operation failed" unless status.ok
  }
  let value = json.read(p"/output/current/generation.json")?.require(Record)?
  let identity = json.encode(value)?
  print "LAP30_COMPOSED_GENERATION" $identity
}

main()?

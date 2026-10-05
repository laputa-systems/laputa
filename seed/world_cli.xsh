##! Entrypoint behind `make plan`, `make build`, `make publish`, and `make root`; seed/world.xsh owns the commands.
#!/bin/xsh
use seed.world

proc main(...argv: List[Str]) [fs, net, process, env, time, error] {
  world.world_command(fs.cwd()?, world.parse_world_args(argv)?)
}

main(@args)

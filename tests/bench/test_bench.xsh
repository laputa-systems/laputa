use bench.registry
use profiles.qemu-tinyland-ghostty as tinyland
use system.build
use system.qemu
use system.types

test test_bench_selection [error] {
  let all = registry.workloads("xsht")
  let edit = registry.select(all, "edit", [], [], [], false)?
  let pm = registry.select(all, "change", [], ["pm"], [], false)?
  let graph = registry.select(all, "change", ["make-graph"], [], [], false)?
  assert [w.name for w in edit] == ["selection"]
  assert [w.name for w in pm] == ["pm-catalog", "pm-check"]
  assert [w.name for w in graph] == ["make-graph"]
  assert registry.select(all, "change", ["unknown"], [], [], false) is Err(_)
  assert registry.select(all, "change", [], ["unknown"], [], false) is Err(_)
  assert registry.select(all, "edit", ["pm-catalog"], [], [], false) is Err(_)
  assert registry.select(all, "edit", [], [], ["selection"], false) is Err(_)
  assert registry.select(all, "full", [], [], [], false) is Err(_)
  let scenario = registry.select(all, "scenario", ["world-plan"], [], [], false)?
  let journeys = registry.select(all, "scenario", ["world-plan", "warm-rebuild", "root-compose"], [], [], false)?
  assert [w.name for w in journeys] == ["world-plan", "warm-rebuild", "root-compose"]
  let new_journeys = registry.select(all, "scenario", ["mirror-publish", "profile-ready", "xinit-service-start"], [], [], false)?
  assert [w.name for w in new_journeys] == ["mirror-publish", "profile-ready", "xinit-service-start"]
  let full = registry.select(all, "full", [], [], [], true)?
  assert [w.name for w in scenario] == ["world-plan"]
  assert [w.name for w in full if w.tier == 3] == ["package-build", "mirror-build", "installer-size", "profile-boot"]
  assert registry.select(all, "change", ["world-plan"], [], [], false) is Err(_)
  assert [registry.tier_name(n) for n in [0, 1, 2, 3]] == ["edit", "change", "scenario", "full"]
}

test test_bench_measurement_contracts [process, error] {
  let result = process.run(process.command_argv("bash", ["bash", "tests/bench/support-test.sh"]))?
  assert result.ok
}

test test_profile_argv_matches_proof_builder [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "profile-argv")?
  let image = fp"{root}/profile image"
  let target = qemu.host_qemu_target()?
  let config = qemu.qemu_config(target)?
  let outputs = build.outputs(p".")
  let selected = {...outputs, disk: fp"{image}/disk.img", kernel: fp"{image}/vmlinuz", qmp_socket: p"qmp.sock"}
  let expected = qemu.qemu_command_argv(config, tinyland.profile, selected, types.Test)
  let xsh = process.which("xsh")?
  let output = fp"{root}/argv.json"
  let result = process.run(process.command_argv(xsh, [xsh, "bench/profile_argv.xsh", "--", image], stdout: output))?
  assert result.ok
  assert json.decode(output.read_text()?)?.require(List[Str])? == expected
}

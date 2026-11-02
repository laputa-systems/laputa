#!/bin/xsh --
const case_dir = p"/usr/lib/asterinas/case"
const probe = p"/usr/lib/asterinas/case/device-probe"
const disk_group = 9
const disk_mode = 0o660
const memory_mode = 0o666

error DeviceCaseError = Failed(message: Str)

type Node = {name: Str, kind: Str, mode: Int, owner: Int, group: Int}

proc require(condition: Bool, message: Str) [error] {
  guard condition else {
    eprint --flush f"DEV_FAILED {message}"
    return Err(DeviceCaseError.Failed(message:))
  }
}

proc coldplug() [process, error] {
  let result = process.run(process.command_argv(p"/usr/bin/mdevd-coldplug", ["mdevd-coldplug", "-O", "4"]))?
  require(result.ok, "mdevd-coldplug failed")?
}

proc show_node(name: Str, expected_kind: Str, expected_mode: Int, expected_group: Int) [fs, error] {
  let node = fs.stat(fp"/dev/{name}")?
  eprint --flush f"DEV_NODE name={name} kind={node.kind} major={node.rdev / 256} minor={node.rdev % 256} mode={node.mode % 4096} owner={node.uid} group={node.gid}"
  require(node.kind == expected_kind, f"/dev/{name} is a {node.kind}, expected a {expected_kind}")?
  require(node.mode % 4096 == expected_mode, f"/dev/{name} has mode {node.mode % 4096}, expected {expected_mode}")?
  require(node.uid == 0 and node.gid == expected_group, f"/dev/{name} belongs to {node.uid}:{node.gid}, expected 0:{expected_group}")?
}

proc nodes() [fs, process, error] {
  for name in ["vda", "vdb", "vdb1", "vdb2"] {
    fp"/dev/{name}".remove()
  }
  for name in ["null", "zero", "full", "random", "urandom"] {
    fp"/dev/{name}".chmod(0o600)
  }
  coldplug()?
  for name in ["vda", "vdb", "vdb1", "vdb2"] {
    show_node(name, "block", disk_mode, disk_group)?
  }
  for name in ["null", "zero", "full", "random", "urandom"] {
    show_node(name, "char", memory_mode, 0)?
  }
}

proc main() [fs, process, error] {
  let mode = p"/usr/lib/asterinas/case/mode".read_text()?.trim()
  eprint --flush f"DEV_BEGIN {mode}"
  match mode {
    "sysfs" => {
      let status = run.status /usr/lib/asterinas/case/device-probe sysfs vda vdb vdb1 vdb2 null zero full random urandom
      require(status.exited_with(0), "the sysfs layout differs from Linux")?
    }
    "add" => {
      let status = run.status /usr/lib/asterinas/case/device-probe events vda vdb vdb1 vdb2 null zero full random urandom
      require(status.exited_with(0), "an add event is wrong or missing")?
    }
    "missing" => {
      let status = run.status /usr/lib/asterinas/case/device-probe missing vdb
      require(status.exited_with(0), "an expected add event never arrived")?
    }
    "nodes" => nodes()?
    other => fail f"unknown device mode {other}"
  }
  eprint --flush "DEV_DONE"
}
main()

#!/bin/xsh
use pm.generation
use pm.types as pm_types

proc run_guest_proof() [fs, process, env, error] -> Result[Unit, Error] {
  let receipt = generation.read_generation_receipt(p"/")?
  assert receipt.profile.name == "qemu-self-hosting"
  assert receipt.target == pm_types.target_x86_64()
  assert "LAPUTA_SELF_HOSTING_PROOF=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  assert unix.id()?.uid == 0
  let root = p"/mnt/self-hosting"
  root.mkdir()?
  linux.mount(b"/dev/vdb", root, fstype: "ext4", options: ["ro", "nosuid", "nodev"])?
  let entry = fp"{root}/inputs/entry.xsh"
  let status = process.run(process.command_argv(
    p"/usr/bin/xsh",
    ["/usr/bin/xsh", entry.display(), root.display()],
    env: {XSH_MODULE_PATH: f"{root}/inputs/laputa:/usr/lib/pm:/usr/lib/xsh/core"},
  ))?
  fail "self-hosting guest entry failed" unless status.ok
  let words = p"/proc/cmdline".read_text()?.trim().split(" ")
  let ids = words |> where .starts_with("LAPUTA_GENERATION_ID=") |> collect
  let serials = words |> where .starts_with("LAPUTA_BOOT_SERIAL=") |> collect
  if ! ids.is_empty() or ! serials.is_empty() {
    assert ids.len() == 1 and serials.len() == 1
    print "LAPUTA_SELF_HOSTING_ACTIVATION" json.encode({
      generation_id: ids[0].replace("LAPUTA_GENERATION_ID=", with: ""),
      boot_serial: serials[0].replace("LAPUTA_BOOT_SERIAL=", with: "").parse_int()?,
      root_digest: receipt.generation_sha256,
    })?
  }
}

match run_guest_proof() {
  Ok(_) => {}
  Err(problem) => {
    print "LAPUTA_SELF_HOSTING_FAILED" $problem.message
    exit 1
  }
}

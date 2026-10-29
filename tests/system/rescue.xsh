##! Unit coverage for detached ext repair classification and rescue plans.
use system.rescue

const checker = p"/var/rescue/e2fsck"
const device = p"/var/disks/broken.raw"
const image = p"/var/rescue/image.raw"

pure command_has(command: List[Str], needle: Str) -> Bool {
  command |> any needle in .
}

test test_writable_mount_refuses_repair [error] {
  match rescue.rescue_repair_argv(checker, device, rescue.RescueWritable) {
    Ok(_) => test.fail("writable mount produced an argv")
    Err(problem) => {
      assert "writable" in problem.message, problem.message
      assert ! ("-p" in problem.message), problem.message
      assert ! ("-y" in problem.message), problem.message
    }
  }

  match rescue.rescue_classify(1, rescue.RescueWritable) {
    Ok(_) => test.fail("writable mount produced a repair class")
    Err(problem) => assert "writable" in problem.message, problem.message
  }
}

test test_read_only_mount_allows_preen_argv [error] {
  let argv = rescue.rescue_repair_argv(checker, device, rescue.RescueReadOnly)?
  let unmounted = rescue.rescue_repair_argv(checker, device, rescue.RescueUnmounted)?
  let again = rescue.rescue_repair_argv(checker, device, rescue.RescueReadOnly)?

  assert argv == [checker.display(), "-f", "-p", device.display()]
  assert ! ("-y" in argv), "no automatic yes"
  assert unmounted == argv, "unmounted uses the same preen argv"
  assert again == argv, "read-only argv is stable"
}

test test_classify_clean_repaired_and_unrecoverable [error] {
  let mount = rescue.RescueReadOnly
  let repaired = rescue.rescue_classify(2, mount)?
  let again = rescue.rescue_classify(2, mount)?

  assert rescue.rescue_classify(0, mount)? == .RescueClean
  assert rescue.rescue_classify(1, mount)? == .RescueRepaired
  assert repaired == .RescueRepaired
  assert again == repaired, "classification is stable"
  assert rescue.rescue_classify(4, mount)? == .RescueUnrecoverable
  assert rescue.rescue_classify(8, rescue.RescueUnmounted)? == .RescueUnrecoverable
  assert rescue.rescue_classify(3, mount)? == .RescueFailed
  assert rescue.rescue_classify(16, mount)? == .RescueFailed
}

test test_rescue_plan_is_independent_and_stable [error] {
  let plan = rescue.rescue_plan(image, device, checker)
  let again = rescue.rescue_plan(image, device, checker)

  assert plan.image == image
  assert plan.disk == device
  assert command_has(plan.command, device.display()), "disk"
  assert checker.display() in plan.command, "e2fsck"
  assert ! command_has(plan.command, "-netdev"), "no network"
  assert ! command_has(plan.command, "/usr/bin/xsh"), "not the guest xsh"
  assert ! command_has(plan.command, "/usr/bin/pm"), "not the guest package manager"
  assert ! command_has(plan.command, "ssh"), "no ssh"
  assert ! command_has(plan.command, "mount"), "mounts nothing from the broken guest"
  assert again.image == plan.image
  assert again.disk == plan.disk
  assert again.command == plan.command, "plan is stable"
}

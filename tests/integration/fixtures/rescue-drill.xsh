##! Rescue drill fixture: print the rescue QEMU drive arguments and classify an e2fsck status
##! through the same `system.rescue` contract the production decision uses.
use system.rescue

proc class_text(class: rescue.RescueClass) -> Str {
  match class {
    rescue.RescueClean => "clean"
    rescue.RescueRepaired => "repaired"
    rescue.RescueUnrecoverable => "unrecoverable"
    rescue.RescueFailed => "failed"
  }
}

proc main(operation: Str, first: Str, second: Str = "") {
  if operation == "plan" {
    let plan = rescue.rescue_plan(Path(first), Path(second))?
    let encoded = json.encode({command: plan.command})?
    print $encoded
  } else if operation == "classify" {
    let class = rescue.rescue_classify(first as Int, rescue.RescueUnmounted)?
    print (class_text(class))
  } else {
    fail "unknown rescue drill operation"
  }
}

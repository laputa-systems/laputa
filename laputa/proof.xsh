##! Console-marker validation shared by the qemu-dwl-foot QEMU supervisor.
use laputa.types as types

## Return the first configured failure marker found in `console`, if any.
export pure failure_marker(value: types.ProofSpec, console: Str) -> Str {
  for marker in value.failure_markers {
    if marker in console {
      return marker
    }
  }

  return ""
}

## Return whether the guest has emitted every required success marker.
export pure succeeded(value: types.ProofSpec, console: Str) -> Bool {
  for marker in value.success_markers {
    if ! (marker in console) {
      return false
    }
  }

  return true
}

## Fail closed when a console contains a kernel or guest-proof failure marker.
export proc verify_console(value: types.ProofSpec, console: Str) [error] {
  let failed = failure_marker(value, console)
  if failed != "" {
    return Err(types.LaputaError.Profile(f"guest proof failed with marker ${failed}"))
  }

  if ! succeeded(value, console) {
    return Err(types.LaputaError.Profile("guest proof did not emit every success marker"))
  }
}

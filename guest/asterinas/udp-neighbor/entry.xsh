#!/bin/xsh --
error NeighborCaseError = Failed(message: Str)
proc main() [process, error] {
  let status = run.status /usr/lib/asterinas/case/udp_neighbor_error
  guard status.exited_with(0) else { return Err(NeighborCaseError.Failed(message: "neighbor witness failed")) }
  eprint --flush "CASE_NEIGHBOR_OK"
}
main()

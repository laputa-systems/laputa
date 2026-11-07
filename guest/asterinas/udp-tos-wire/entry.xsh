#!/bin/xsh --
error UdpTosWireCase = Failed(message: Str)
proc main() [process, error] {
  let status = run.status /usr/lib/asterinas/case/udp_tos_wire
  guard status.exited_with(0) else { return Err(UdpTosWireCase.Failed(message: "UDP TOS wire witness failed")) }
  eprint --flush "CASE_UDP_TOS_WIRE_OK"
}
main()

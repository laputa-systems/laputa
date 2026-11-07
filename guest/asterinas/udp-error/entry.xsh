#!/bin/xsh --
error UdpErrorCase = Failed(message: Str)
proc main() [process, error] {
  let status = run.status /usr/lib/asterinas/case/udp_icmp_error
  guard status.exited_with(0) else { return Err(UdpErrorCase.Failed(message: "UDP error witness failed")) }
  eprint --flush "CASE_UDP_ERROR_OK"
}
main()

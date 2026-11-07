#!/bin/xsh --
error UdpDontRouteCase = Failed(message: Str)
proc main() [process, error] {
  let status = run.status /usr/lib/asterinas/case/udp_dontroute
  guard status.exited_with(0) else { return Err(UdpDontRouteCase.Failed(message: "UDP route witness failed")) }
  eprint --flush "CASE_UDP_DONT_ROUTE_OK"
}
main()

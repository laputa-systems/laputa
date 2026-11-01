#!/bin/xsh --
proc main() [fs, process, env, time, error] {
  eprint --flush "NETSURVEY_BEGIN"
  let dump = linux.network_dump()?
  for link in dump.links {
    eprint --flush f"LINK {link.ifindex} {link.name ?? "-"} flags={link.flags} mtu={link.mtu ?? 0} oper={link.operstate ?? 0} kind={link.kind ?? "-"}"
  }
  for address in dump.addresses {
    eprint --flush f"ADDR {address.ifindex} {address.family} {address.local ?? "-"}/{address.prefix_length} scope={address.scope} label={address.label ?? "-"}"
  }
  for route in dump.routes {
    eprint --flush f"ROUTE {route.family} {route.destination ?? "default"}/{route.destination_prefix_length} via {route.gateway ?? "-"} flags={route.flags}"
  }
  for issue in dump.issues { eprint --flush f"ISSUE {issue.object} {issue.error_kind} errno={issue.errno ?? 0} {issue.message}" }
  eprint --flush f"ISSUES {dump.issues.len()} enumeration={dump.enumeration_succeeded}"
  eprint --flush "NETSURVEY_DONE"
}
main()

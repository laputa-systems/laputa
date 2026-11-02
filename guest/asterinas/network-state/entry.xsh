#!/bin/xsh --
type Attribute = {data: Bytes, kind: Int}

pure attribute_text(attributes: List[Attribute]) -> Str {
  [f"{attribute.kind}:{attribute.data.base64()}" for attribute in attributes].join(",")
}

proc report(label: Str, only_device: Str, link_state: Bool) [fs, process, env, time, error] {
  let dump = linux.network_dump()?
  var names: Map[Int, Str] = {}
  for link in dump.links { names[link.ifindex] = link.name ?? "-" }
  let links = dump.links |> where .name != "sit0"
  for link in links |> where only_device == "" or .name == only_device {
    let state = if link_state { f" flags={link.flags} oper={link.operstate ?? 0}" } else { "" }
    eprint --flush f"NET_{label}_LINK {link.name ?? "-"} mtu={link.mtu ?? 0} hw={link.hardware_type}{state}"
  }
  for address in dump.addresses {
    guard only_device == "" or (names.get(address.ifindex) ?? "-") == only_device else { continue }
    eprint --flush f"NET_{label}_ADDR {names.get(address.ifindex) ?? "-"} {address.family} {address.local ?? "-"}/{address.prefix_length} peer={address.address ?? "-"} brd={address.broadcast ?? "-"} scope={address.scope} flags={address.flags} label={address.label ?? "-"}"
  }
  for route in dump.routes {
    let device = if let index = route.output_ifindex { names.get(index) ?? "-" } else { "-" }
    guard only_device == "" or device == only_device else { continue }
    eprint --flush f"NET_{label}_ROUTE {route.family} {route.destination ?? "default"}/{route.destination_prefix_length} via={route.gateway ?? "-"} dev={device} table={route.table} proto={route.protocol} scope={route.scope} type={route.route_type} prio={route.priority ?? 0} src={route.preferred_source ?? "-"} flags={route.flags} tos={route.tos} attrs={attribute_text(route.attributes)}"
  }
  for rule in dump.rules {
    eprint --flush f"NET_{label}_RULE {rule.family} prio={rule.priority ?? 0} table={rule.table} action={rule.action} src={rule.source ?? "-"}/{rule.source_prefix_length} dst={rule.destination ?? "-"}/{rule.destination_prefix_length} flags={rule.flags} attrs={attribute_text(rule.attributes)}"
  }
  for issue in dump.issues { eprint --flush f"NET_{label}_ISSUE {issue.object} {issue.error_kind} errno={issue.errno ?? 0}" }
  eprint --flush f"NET_{label}_COMPLETE {dump.enumeration_succeeded}"
}

proc main() [fs, process, env, time, error] {
  let mode = p"/usr/lib/asterinas/case/mode".read_text()?.trim()
  eprint --flush f"NET_BEGIN {mode}"
  report("initial", if mode == "loopback" { "lo" } else { "" }, false)?
  eprint --flush "NET_DONE"
}
main()

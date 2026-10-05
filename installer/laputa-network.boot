#!/bin/xsh
type StaticInterface = {iface: Str, address: Str, netmask: Str, gateway: Str}

pure empty_static_interface() -> StaticInterface {
  {iface: "", address: "", netmask: "", gateway: ""}
}

proc apply_static_interface(cfg: StaticInterface) {
  if cfg.iface == "" or cfg.address == "" or cfg.netmask == "" or cfg.gateway == "" {
    return
  }

  linux.link_up(cfg.iface)
  linux.set_ipv4_address(cfg.iface, cfg.address, cfg.netmask)
  linux.add_default_ipv4_route(cfg.gateway, interface: cfg.iface)
}

proc main() [fs, process, error] {
  if p"/usr/bin/ifup".exists() {
    run /usr/bin/ifup "-a"
    return
  }

  let path_value = /etc/network/interfaces

  return unless path_value.exists()

  var current = empty_static_interface()

  for raw in path_value.read_lines()? {
    let line = raw.trim()
    continue when line == "" or line.starts_with("#")
    let fields = line.words()

    if fields.len() >= 4 and fields[0] == "iface" and fields[2] == "inet" and fields[3] == "static" {
      apply_static_interface(current)
      current = {iface: fields[1], address: "", netmask: "", gateway: ""}
    } else if fields.len() >= 2 and current.iface != "" {
      if fields[0] == "address" {
        current = {...current, address: fields[1]}
      } else if fields[0] == "netmask" {
        current = {...current, netmask: fields[1]}
      } else if fields[0] == "gateway" {
        current = {...current, gateway: fields[1]}
      }
    }
  }

  apply_static_interface(current)
}

main()

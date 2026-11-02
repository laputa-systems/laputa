#!/bin/xsh --
use tests.support.dhcp_script as script
use tests.support.dhcp_types as types

const SERVER = "192.0.2.1"
const OFFERED = "192.0.2.100"

pure granted(kind: Str, lease: Int) -> types.Reply {
  {...script.reply(kind), address: OFFERED, lease: lease, routers: [SERVER], dns: [SERVER], server_id: SERVER}
}

pure reconfigured(kind: Str, lease: Int) -> types.Reply {
  {...granted(kind, lease), routers: [], classless: [f"198.18.0.0/24 {SERVER}", "198.19.0.0/24 0.0.0.0"], dns: ["192.0.2.53", "192.0.2.54"]}
}

pure rules_for(mode: Str) -> Result[List[types.Rule], Error] {
  match mode {
    "lease-acquire" => Ok(
      [
        script.always("discover", [granted("offer", 3600)]),
        script.always("request", [granted("ack", 3600)]),
      ],
    )
    "lifecycle" => Ok(
      [
        script.always("discover", [granted("offer", 20)]),
        script.only("request", 1, [granted("ack", 20)]),
        script.from("request", 2, []),
      ],
    )
    "restart" | "carrier" | "tcp" => Ok(
      [
        script.always("discover", [granted("offer", 3600)]),
        script.always("request", [granted("ack", 3600)]),
      ],
    )
    "renewal" => Ok(
      [
        script.always("discover", [granted("offer", 20)]),
        script.always("request", [granted("ack", 20)]),
      ],
    )
    "reconfigure" => Ok(
      [
        script.always("discover", [granted("offer", 20)]),
        script.only("request", 1, [granted("ack", 20)]),
        script.from("request", 2, [reconfigured("ack", 20)]),
      ],
    )
    "nak" => Ok(
      [
        script.always("discover", [granted("offer", 20)]),
        script.only("request", 1, [granted("ack", 20)]),
        script.only("request", 2, [granted("nak", 20)]),
        script.from("request", 3, [granted("ack", 20)]),
      ],
    )
    other => fail f"unknown DHCP case mode {other}"
  }
}

proc main(...argv: List[Str]) [fs, error] {
  fp"{argv[1]}".write(json.encode({rules: rules_for(argv[0])?})?)?
}

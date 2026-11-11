##! The equivalent of failures-broken.py.

use infra.declare
use infra.model

## The resources one host should have.
export proc resources(host: model.Host) [fs, error] -> Result[List[model.Resource], Error] {
  [
    declare.directory(id: "dir", at: "/var/tmp/pi")?,
    declare.command(id: "first", argv: ["touch", "/var/tmp/pi/first"], creates: "/var/tmp/pi/first", needs: ["dir"])?,
    declare.command(id: "boom", argv: ["sh", "-c", "exit 7"], always: true, needs: ["first"])?,
    declare.command(id: "last", argv: ["touch", "/var/tmp/pi/last"], creates: "/var/tmp/pi/last", needs: ["boom"])?,
  ]
}

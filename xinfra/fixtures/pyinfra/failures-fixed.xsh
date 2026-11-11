##! The equivalent of failures-fixed.py.

use infra.declare
use infra.model

## The resources one host should have.
export proc resources(host: model.Host) [fs, error] -> Result[List[model.Resource], Error] {
  [
    declare.directory(id: "dir", at: "/var/tmp/pi")?,
    declare.command(id: "first", argv: ["touch", "/var/tmp/pi/first"], creates: "/var/tmp/pi/first", needs: ["dir"])?,
    declare.command(id: "boom", argv: ["sh", "-c", "true"], always: true, needs: ["first"])?,
    declare.command(id: "last", argv: ["touch", "/var/tmp/pi/last"], creates: "/var/tmp/pi/last", needs: ["boom"])?,
  ]
}

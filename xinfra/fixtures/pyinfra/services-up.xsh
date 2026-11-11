##! The equivalent of services-up.py.

use infra.declare
use infra.model

## The resources one host should have.
export proc resources(host: model.Host) [fs, error] -> Result[List[model.Resource], Error] {
  [
    declare.file(id: "init", at: "/etc/init.d/xinfradiff", source: p"fixtures/pyinfra/xinfradiff", mode: 0o755, owner: "root", group_name: "root")?,
    declare.service(id: "svc", name: "xinfradiff", enabled: true, running: true, needs: ["init"])?,
  ]
}

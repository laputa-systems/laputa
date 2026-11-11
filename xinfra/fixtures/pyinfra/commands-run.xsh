##! The equivalent of commands-run.py.

use infra.declare
use infra.model

## The resources one host should have.
export proc resources(host: model.Host) [fs, error] -> Result[List[model.Resource], Error] {
  [
    declare.directory(id: "dir", at: "/var/tmp/pi")?,
    declare.command(id: "creates", shell: "echo x >> /var/tmp/pi/creates.log; touch /var/tmp/pi/created", creates: "/var/tmp/pi/created", needs: ["dir"])?,
    declare.command(id: "always", shell: "echo x >> /var/tmp/pi/always.log", always: true, needs: ["dir"])?,
  ]
}

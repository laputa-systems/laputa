##! The equivalent of packages-remove.py.

use infra.declare
use infra.model

## The resources one host should have.
export proc resources(host: model.Host) [fs, error] -> Result[List[model.Resource], Error] {
  [declare.package(id: "tree", name: "tree", presence: .Absent)?]
}

##! The equivalent of packages-install.py.

use infra.declare
use infra.model

## The resources one host should have.
export proc resources(host: model.Host) [fs, error] -> Result[List[model.Resource], Error] {
  [
    declare.package(id: "jq", name: "jq")?,
    declare.package(id: "tree", name: "tree")?,
  ]
}

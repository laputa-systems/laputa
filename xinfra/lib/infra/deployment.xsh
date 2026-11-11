##! The contract a deployment program satisfies and the code that loads one.
##! A deployment is trusted operator code: loading it runs its module
##! initializers and `resources` runs on the controller. Declaring is meant to
##! build values only; xsh-infra does not sandbox it.

use infra.model

## A deployment module exports `resources`, which returns the resources one
## host should have. It is a `proc` with exactly the effects `[fs, error]`: it may
## read local templates and files and may fail, and it may not run processes,
## reach the network or read the environment.
export type Deployment = module {
  export proc resources(host: model.Host) [fs, error] -> Result[List[model.Resource], Error]
}

## Load and check a deployment module. A module that lacks `resources` or gives
## it another signature is refused with every difference listed.
export proc load(file: Path) [fs, error] -> Result[Deployment, Error] {
  ctx f"loading deployment {file}" { module.load(file)?.require(Deployment)? }
}

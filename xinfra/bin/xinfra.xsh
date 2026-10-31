##! xinfra command line entry point.

use xinfra.cli as command_line
use xinfra.redact as redact

let root = match fs.gitroot() {
  Ok(value) => value,
  Err(_) => fs.cwd()?,
}
let code = command_line.run_cli(args, null, root, redact.empty(), true)
exit code

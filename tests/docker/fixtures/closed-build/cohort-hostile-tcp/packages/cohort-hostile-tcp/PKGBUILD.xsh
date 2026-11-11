##! Closed-build hostile TCP package: a TCP connection must fail under confinement.
## Package name.
export let name = "cohort-hostile-tcp"
## Installable package kind.
export let package_kind = "payload"
## Package version.
export let ver = "1.0.0"
## Package release.
export let rel = "1"
## No runtime dependencies.
export let deps = []
## No build host dependencies.
export let mkdeps_host = []
## No build target dependencies.
export let mkdeps_target = []
## No upstream sources.
export let upstream_sources = []
## Preserve the outputs.
export let nostrip = true
## Installed payload contract.
export let filetree = [{path: p"usr/share/cohort-hostile-tcp", kind: "file"}]

error Escape = Failed(message: Str)

pure tcp_probe() -> Str {
  r"""let c = linux.net_constants()
let fd = linux.socket(c.AF_INET, c.SOCK_STREAM)?
match linux.connect(fd, {family: "inet", address: "127.0.0.1", port: 9}) {
  Ok(_) => print "tcp-connected"
  Err(problem) => print f"tcp-denied {problem.message}"
}
"""
}

## The helper inherits the build child's Landlock domain, so its TCP connect is confined too.
export proc build(dest: Path) [fs, process, env, error] -> Result[Unit, Error] {
  let recipe = fp"{env("XSH_PM_RECIPE_DIR")?}"
  let helper = fp"{recipe}/tcp-probe.xsh"
  helper.write(tcp_probe())?
  let out = fp"{recipe}/tcp-probe.out"
  let xsh = process.which("xsh")?
  let status = process.run(process.command_argv(xsh, [xsh, helper], recipe, {}, b"", out))?
  let text = out.read_text()?
  if ! status.ok {
    return Err(Escape.Failed(f"tcp probe exited {status.shell_code()?}: {text}"))
  }
  if "tcp-connected" in text {
    return Err(Escape.Failed("TCP connect succeeded; the build ran unconfined"))
  }
  if "Permission denied" not in text {
    return Err(Escape.Failed(f"tcp probe did not report denial: {text.trim()}"))
  }
  Err(Escape.Failed(f"TCP connect denied by confinement: {text.trim()}"))
}

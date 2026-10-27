#!/bin/xsh
##! PID 1 trampoline: the kernel launches /init without a module path, and
##! XSH only imports non-standard modules through XSH_MODULE_PATH. This
##! trampoline carries no imports and re-executes the real guest proof with
##! the module path set. The child powers the machine off itself on success;
##! the trampoline only intervenes when the child returns instead.
proc main() [fs, process, env, error] {
  let command = process.command_argv(
    "/bin/xsh",
    ["xsh", "/guest/main.xsh"],
    "/",
    {XSH_MODULE_PATH: "/lib"},
    stdout: p"/child.out",
    stderr: p"/child.err",
  )
  let status = process.run(command)?
  guard status.ok else {
    p"/dev/console".write(bytes.from_text("LAPUTA_TRUST_GUEST FAIL trampoline child failed\n"))?
    if p"/child.out".exists()? {
      p"/dev/console".write(bytes.from_text("--- child stdout ---\n"))?
      p"/dev/console".write(p"/child.out".read_bytes()?)?
    }

    if p"/child.err".exists()? {
      p"/dev/console".write(bytes.from_text("--- child stderr ---\n"))?
      p"/dev/console".write(p"/child.err".read_bytes()?)?
    }

    linux.poweroff()?
    return
  }
}

main()?

#!/bin/xsh --
##! The init of a disposable DHCP qualification guest: mounts the pseudo file
##! systems, runs the scenario named by the `dhcpvm=` kernel argument with its
##! output on the serial console, and powers the machine off.

proc scenario_name(cmdline: Str) -> Result[Str] {
  for word in cmdline.trim().split(" ") {
    if word.starts_with("dhcpvm=") {
      return word.byte_slice(7)
    }
  }
  Err(error.failure("the kernel command line names no dhcpvm= scenario"))
}

proc main() {
  linux.mount(b"proc", p"/proc", "proc")?
  linux.mount(b"sysfs", p"/sys", "sysfs")?
  linux.mount(b"devtmpfs", p"/dev", "devtmpfs")?
  linux.mount(b"tmpfs", p"/run", "tmpfs")?
  linux.mount(b"tmpfs", p"/tmp", "tmpfs")?
  let scenario = scenario_name(p"/proc/cmdline".read_text()?)?
  let console = p"/dev/ttyS0"
  let command = process.command_argv(
    p"/bin/xsh",
    [p"/bin/xsh", fp"/guest/dhcp_{scenario}_guest.xsh"],
    p"/",
    {XSH_MODULE_PATH: "/core", PATH: "/bin", HOME: "/", LC_ALL: "C"},
    b"",
    console,
    console,
    timeout: 3600s,
  )
  let status = process.run(command)?
  console.write(f"VMEXIT {status.shell_code()?}\n")
  linux.poweroff()?
}

main()?

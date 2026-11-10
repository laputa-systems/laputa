##! Lifecycle graph service fixture.
## The service record.
export let service = {
  name: "r1-broken",
  command: process.command_argv("/bin/xsh", ["/bin/xsh"]),
  targets: [
    "r1",
  ],
  typo: true,
}

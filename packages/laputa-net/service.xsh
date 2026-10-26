##! XSH module `service` package and build operations.
## Exported declaration `service`.
export let service = {
  name: "net",
  kind: "oneshot",
  command: process.command_argv(/usr/bin/ifup, ["ifup", "-a"], env: {PATH: "/usr/local/bin:/usr/bin:/bin"}),
  targets: [
    "boot",
  ],
  logging: "append",
}

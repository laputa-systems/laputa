proc main() [env, process, error] {
  let notify = e"NOTIFY_FD" ?? ""
  fail "missing chrony readiness descriptor" when notify == ""
  unix.exec(process.command_argv(p"/mnt/self-hosting/inputs/chronyd", ["chronyd", "-d", "-N", notify, "-f", "/run/chrony-oracle.conf"]))?
}

main()

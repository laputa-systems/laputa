##! PM and Laputa modules must load together in one XSH process.
use pm.cli as pm_cli
use system.cli as laputa_cli

test test_pm_and_laputa_clis_share_one_runtime_namespace [fs, net, process, env, time, error] {
  match pm_cli.run_pm_cli(["unknown"]) {
    Ok(_) => test.fail("unknown PM command unexpectedly succeeded")?
    Err(problem) => assert "unknown pm command" in problem.message, problem.message
  }

  assert "usage: laputa" in laputa_cli.usage()
}

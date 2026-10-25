##! PM and Laputa modules must load together in one XSH process.
use pm.cli as pm_cli
use system.cli as laputa_cli

test test_pm_and_laputa_clis_share_one_runtime_namespace [fs, net, process, env, time, error] {
  match pm_cli.pm_cli_repo_plan({repo: "", all: false, roots: [], without: [], target: "", output: p"unused"}) {
    Ok(_) => test.fail("invalid PM selection unexpectedly succeeded")
    Err(problem) => assert "requires exactly one of --all or one-or-more --root" in problem.message, problem.message
  }

  assert "usage: laputa" in laputa_cli.usage()
}

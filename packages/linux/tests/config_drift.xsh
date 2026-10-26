use packages.linux.config_drift as drift

test test_config_drift_reports_added_removed_disabled_and_changed_symbols {
  let before = """CONFIG_ENABLED=y
# CONFIG_DISABLED is not set
CONFIG_REMOVED=m
CONFIG_CMDLINE="root=a=b"
"""
  let after = """CONFIG_ENABLED=m
CONFIG_DISABLED=y
CONFIG_ADDED=y
CONFIG_CMDLINE="root=a=c"
"""
  assert drift.linux_config_changes(before, after) == [
    "CONFIG_ADDED: <absent> -> y",
    "CONFIG_CMDLINE: \"root=a=b\" -> \"root=a=c\"",
    "CONFIG_DISABLED: n -> y",
    "CONFIG_ENABLED: y -> m",
    "CONFIG_REMOVED: m -> <absent>",
  ]
}

test test_config_drift_ignores_only_comments_order_and_disabled_spelling {
  assert drift.linux_config_changes(
    "# Linux version\nCONFIG_B=y\n# CONFIG_A is not set\n",
    "CONFIG_A=n\n# Different heading\nCONFIG_B=y\n",
  ) == []
  assert drift.linux_config_changes("# CONFIG_A is not set\n", "") == ["CONFIG_A: n -> <absent>"]
}

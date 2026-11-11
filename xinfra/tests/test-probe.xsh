use infra.fact
use infra.probe

const regular = "state found\nkind file\nmode 644\nuid 0\ngid 0\nsize 784\nmtime 1793678100\nowner 726f6f74\ngroup 726f6f74\ndigest a17d\n"

test decode_hex_round_trips_text_and_rejects_garbage {
  assert probe.decode_hex("")? == ""
  assert probe.decode_hex("68656c6c6f0a776f726c64")? == "hello\nworld"
  assert probe.decode_hex("C3A9")? == "\u{e9}"
  assert probe.decode_hex("6") is Err(_)
  assert probe.decode_hex("zz") is Err(_)
  assert probe.decode_hex("ff") is Err(_)
}

test a_regular_file_report_becomes_typed_path_info {
  match probe.path_fact(regular) {
    fact.Found(info) => {
      assert info.kind == .Regular
      assert info.mode == 0o644
      assert info.owner == "root"
      assert info.size == 784
      assert info.digest == "a17d"
      assert info.link_target == null
    }
    else => assert false, "not found"
  }
}

test an_unreadable_digest_is_not_a_digest {
  let report = regular.replace("digest a17d", with: "digest unreadable")
  match probe.path_fact(report) {
    fact.Found(info) => assert info.digest == null
    else => assert false, "not found"
  }
}

test a_symlink_target_with_newlines_survives {
  let report = "state found\nkind link\nmode 777\nuid 0\ngid 0\nsize 3\nmtime 1\nowner 726f6f74\ngroup 726f6f74\ntarget 7461720a67657420776974680a6e65776c696e65\n"
  match probe.path_fact(report) {
    fact.Found(info) => {
      assert info.kind == .Symlink
      assert info.link_target == "tar\nget with\nnewline"
    }
    else => assert false, "not found"
  }
}

test missing_denied_and_blocked_paths_are_different_facts {
  assert probe.path_fact("state missing\n") is fact.Missing
  match probe.path_fact("state denied\ndetail 6e6f\n") {
    fact.Unseen(unreadable) => {
      assert unreadable.cause == .Denied
      assert unreadable.detail == "no"
    }
    else => assert false, "denied was not unseen"
  }
  match probe.path_fact("state blocked\ndetail 6e6f\n") {
    fact.Blocked(unreadable) => assert unreadable.cause == .Conflict
    else => assert false, "blocked was not blocked"
  }
}

test garbage_never_reads_as_absence {
  for report in ["", "state weird\n", "state found\nkind file\n", "state found\nkind socket\nmode 1\n"] {
    match probe.path_fact(report) {
      fact.Unseen(unreadable) => assert unreadable.cause == .Malformed
      else => assert false, f"{report} was not unseen"
    }
  }
}

test package_reports_map_to_installed_absent_and_unavailable {
  assert probe.package_fact("state absent\n") is fact.NotInstalled
  match probe.package_fact("state installed\nversion 1.37.0-r20\nordering lt\n") {
    fact.Installed(installed) => {
      assert installed.version == "1.37.0-r20"
      assert installed.ordering == .Older
    }
    else => assert false, "not installed"
  }
  match probe.package_fact("state installed\nversion 1.0\n") {
    fact.Installed(installed) => assert installed.ordering == null
    else => assert false, "not installed"
  }
  match probe.package_fact("state unavailable\n") {
    fact.PackageUnseen(unreadable) => assert unreadable.cause == .Unavailable
    else => assert false, "not unseen"
  }
  match probe.package_fact("state installed\nversion 1.0\nordering unknown\n") {
    fact.PackageUnseen(unreadable) => assert unreadable.cause == .Malformed
    else => assert false, "unorderable version was accepted"
  }
}

const accounts_report = "state ok\n@@passwd@@\nroot:x:0:0:root:/root:/bin/sh\ndeploy:x:1000:1000:Linux User,,,:/home/deploy:/bin/ash\n@@group@@\nroot:x:0:root\nwheel:x:10:root,deploy\ndeploy:x:1000:\nempty:x:2000:\n"

pure found_accounts(report: Str) -> probe.Accounts? {
  match probe.accounts(report) {
    probe.AccountsFound(accounts) => accounts
    else => null
  }
}

test accounts_resolve_primary_group_and_memberships {
  guard let accounts = found_accounts(accounts_report) else {
    assert false, "accounts unseen"
    return
  }

  match probe.user_fact(accounts, "deploy") {
    fact.UserFound(info) => {
      assert info.uid == 1000
      assert info.group == "deploy"
      assert info.home == "/home/deploy"
      assert info.shell == "/bin/ash"
      assert info.memberships == ["wheel"]
    }
    else => assert false, "deploy missing"
  }
  assert probe.user_fact(accounts, "ghost") is fact.NoUser
  match probe.group_fact(accounts, "wheel") {
    fact.GroupFound(info) => {
      assert info.gid == 10
      assert info.members == ["root", "deploy"]
    }
    else => assert false, "wheel missing"
  }
  match probe.group_fact(accounts, "empty") {
    fact.GroupFound(info) => assert info.members.is_empty()
    else => assert false, "empty missing"
  }
}

test an_unreadable_or_malformed_account_database_is_an_error_not_an_empty_one {
  match probe.accounts("state denied\n") {
    probe.AccountsUnseen(unreadable) => assert unreadable.cause == .Denied
    else => assert false, "denied database parsed"
  }
  match probe.accounts("state ok\n@@passwd@@\nbroken line\n@@group@@\n") {
    probe.AccountsUnseen(unreadable) => assert unreadable.cause == .Malformed
    else => assert false, "malformed database parsed"
  }
  assert found_accounts("") == null
}

test service_reports_map_status_codes {
  match probe.service_fact("state found\nenabled yes\nstatus 0\n") {
    fact.ServiceFound(info) => {
      assert info.enabled
      assert info.running == .Started
    }
    else => assert false, "not found"
  }
  match probe.service_fact("state found\nenabled no\nstatus 3\n") {
    fact.ServiceFound(info) => {
      assert ! info.enabled
      assert info.running == .Stopped
    }
    else => assert false, "not found"
  }
  match probe.service_fact("state found\nenabled no\nstatus 7\n") {
    fact.ServiceFound(info) => assert info.running == .Indeterminate
    else => assert false, "not found"
  }
  assert probe.service_fact("state missing\n") is fact.NoService
  match probe.service_fact("state unavailable\n") {
    fact.ServiceUnseen(unreadable) => assert unreadable.cause == .Unavailable
    else => assert false, "not unseen"
  }
}

test capabilities_need_the_shell_marker_and_a_uid {
  let report = probe.capabilities("shell ok\nhave stat\nlack apk\nuid 1000\n")?
  assert report.present == ["stat"]
  assert report.absent == ["apk"]
  assert report.uid == 1000
  assert probe.capabilities("have stat\nuid 0\n") is Err(_)
  assert probe.capabilities("shell ok\nhave stat\n") is Err(_)
}

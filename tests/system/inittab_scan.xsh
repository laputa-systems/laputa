##! Shipped inittabs own the boot graph through one scanner.
use installer.setup-laputa as installer

const scanner_entry = "::respawn:/usr/bin/xinit scan boot"

pure scanner_entries(text: Str) -> List[Str] {
  collect {
    for line in text.lines() {
      let entry = line.trim()
      yield entry when entry == scanner_entry
    }
  }
}

pure daemon_supervisors(text: Str) -> List[Str] {
  collect {
    for line in text.lines() {
      let entry = line.trim()
      if entry.starts_with("::once:") and ("xinit supervise" in entry or "mdev.supervise" in entry) {
        yield entry
      }
    }
  }
}

test test_normal_target_inittab_runs_one_boot_scanner {
  let text = installer.normal_target_inittab("ttyS0")
  assert scanner_entries(text).len() == 1
  assert daemon_supervisors(text).is_empty()
  assert ! ("mdev.supervise" in text)
  assert "ttyS0::respawn:/usr/bin/login -f pazu" in text
  assert "tty1::respawn:/usr/bin/login -f pazu" in text
}

test test_ci_target_inittab_runs_one_boot_scanner {
  let text = installer.ci_target_inittab()
  assert scanner_entries(text).len() == 1
  assert daemon_supervisors(text).is_empty()
  assert ! ("mdev.supervise" in text)
  assert "::respawn:/usr/local/bin/laputa-ci-idle" in text
}

test test_baselayout_inittab_runs_one_boot_scanner [fs, error] {
  let text = p"packages/baselayout/files/rootfs/etc/inittab".read_text()?
  assert scanner_entries(text).len() == 1
  assert daemon_supervisors(text).is_empty()
}

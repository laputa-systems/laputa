##! ELF runtime-dependency checks applied to package proofs.
use pm.elfdeps

test test_elfdeps_rejects_a_needed_build_time_path [error] { |_|
  let failures = elfdeps.missing_elf_runtime_dependencies(
    "libva",
    ["musl"],
    ["libc.so", "../../build-root/usr/lib/libdl.so"],
    "",
    {"libc.so": "musl"},
  )

  assert failures.len() == 1
  assert failures[0].soname == "../../build-root/usr/lib/libdl.so"
  assert failures[0].provider == ""
}

test test_elfdeps_accepts_names_its_dependencies_provide [error] { |_|
  let failures = elfdeps.missing_elf_runtime_dependencies(
    "libinput",
    ["musl", "libevdev"],
    ["libc.so", "libm.so", "libevdev.so.2"],
    "",
    {"libc.so": "musl", "libm.so": "musl", "libevdev.so.2": "libevdev"},
  )

  assert failures == []
}

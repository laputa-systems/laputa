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
  assert failures[0].gap == elfdeps.BuildTimePath
}

test test_elfdeps_accepts_names_its_dependencies_provide [error] { |_|
  let failures = elfdeps.missing_elf_runtime_dependencies(
    "ghostty-custom",
    ["musl", "mesa"],
    ["libc.so", "libEGL.so.1"],
    "",
    {"libc.so": "musl", "libEGL.so.1": "mesa"},
  )

  assert failures == []
}

test test_elfdeps_rejects_a_name_no_installed_package_provides [error] { |_|
  let failures = elfdeps.missing_elf_runtime_dependencies(
    "play",
    ["musl"],
    ["libc.musl-x86_64.so.1", "libvulkan.so.1"],
    "/lib/ld-musl-x86_64.so.1",
    {"libc.so": "musl"},
  )

  assert failures.len() == 1
  assert failures[0].soname == "libvulkan.so.1"
  assert failures[0].gap == elfdeps.Unprovided
}

test test_elfdeps_rejects_a_provider_outside_the_dependency_closure [error] { |_|
  let failures = elfdeps.missing_elf_runtime_dependencies(
    "play",
    ["musl"],
    ["libc.so", "libasound.so.2"],
    "",
    {"libc.so": "musl", "libasound.so.2": "alsa-lib"},
  )

  assert failures.len() == 1
  assert failures[0].gap == elfdeps.Undeclared("alsa-lib")
}

test test_elfdeps_resolves_musl_loader_names_to_musl [error] { |_|
  let needed = ["libc.musl-x86_64.so.1", "libm.so.6", "libpthread.so.0", "libdl.so.2"]
  let accepted = elfdeps.missing_elf_runtime_dependencies("play", ["musl"], needed, "/lib/ld-musl-x86_64.so.1", {})
  assert accepted == []

  let undeclared = elfdeps.missing_elf_runtime_dependencies("play", [], needed, "/lib/ld-musl-x86_64.so.1", {})
  assert undeclared.len() == 1
  assert undeclared[0].gap == elfdeps.Undeclared("musl")

  let lookalike = elfdeps.missing_elf_runtime_dependencies("play", ["musl"], ["libcap.so.2"], "", {})
  assert lookalike.len() == 1
  assert lookalike[0].gap == elfdeps.Unprovided
}

test test_elfdeps_library_symlinks_provide_their_names [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "elfdeps-library-symlinks")?
  let db = fp"{root}/var/lib/xsh-pm/packages/gnu-stubs"
  db.mkdir(true)
  fp"{root}/usr/lib".mkdir(true)
  fp"{root}/usr/share".mkdir(true)
  fp"{root}/usr/lib/libgcc_s.so".write("not an ELF image")
  fp"{root}/usr/lib/libgcc_s.so.1".symlink(to: p"libgcc_s.so")
  fp"{root}/usr/lib/libgone.so.1".symlink(to: p"libgone.so")
  fp"{root}/usr/share/libdata.so.1".symlink(to: p"../lib/libgcc_s.so")
  fp"{db}/manifest.json".write(
    "[\"usr/lib/libgcc_s.so\",\"usr/lib/libgcc_s.so.1\",\"usr/lib/libgone.so.1\",\"usr/share/libdata.so.1\"]",
  )

  let providers = elfdeps.collect_library_providers(root)?
  assert providers.get("libgcc_s.so")? == "gnu-stubs"
  assert providers.get("libgcc_s.so.1")? == "gnu-stubs"
  assert "libgone.so.1" not in providers
  assert "libdata.so.1" not in providers
}

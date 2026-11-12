use pm.proof

test test_relocated_independent_builds_preserve_identical_elf_and_assertion_sources [fs, process, env, error] { |ctx|
  let first = env.path("LAPUTA_FONTCONFIG_REPRO_FIRST_ROOT")?
  let second = env.path("LAPUTA_FONTCONFIG_REPRO_SECOND_ROOT")?
  let relative = "usr/lib/libfontconfig.so.1.17.0"
  let first_library = fp"{first}/{relative}"
  let second_library = fp"{second}/{relative}"
  let identical = first_library.read_bytes()? == second_library.read_bytes()?
  assert identical
  let readelf = proof.readelf_tool()?
  let rodata = run.bytes $readelf "--string-dump=.rodata" $first_library
  let strings = [line.split("]")[1].trim() for line in rodata.strings() if "]" in line]
  for source in ["fcmatch.c", "fcserialize.c", "fcweight.c"] {
    assert f"src/{source}" in strings
  }
}

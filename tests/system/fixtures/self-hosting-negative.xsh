use seed.self_hosting_verify as verify

proc rejected(bundle: Path, expected: Str, kernel: Path, tools_image: Str, expected_failure: Str) [fs, process, env, error] -> Result[Unit, Error] {
  match verify.self_hosting_verify_bundle(bundle, expected, kernel, tools_image) {
    Err(problem) => { assert problem.message == expected_failure }
    Ok(_) => { fail "invalid successor was accepted" }
  }
}

proc main(previous: Path, successor: Path, previous_identity: Str, successor_identity: Str, kernel: Path, tools_image: Str) [fs, process, env, error] -> Result[Unit, Error] {
  let names = ["vmlinuz", "rootfs.ext4", "disk.img", "generation.json"]
  let before = {name: hash.sha256(fp"{previous}/{name}")?.hex() for name in names}
  verify.self_hosting_verify_bundle(successor, successor_identity, kernel, tools_image)?
  rejected(successor, previous_identity, kernel, tools_image, "successor generation differs from the expected generation")?
  for corruption in ["root", "disk", "kernel"] {
    let handle = fs.tempdir()?
    let mixed = handle.host_path()?
    for name in names {
      if name == "vmlinuz" and corruption == "kernel" {
        fp"{mixed}/{name}".write(bytes.concat([fp"{successor}/{name}".read_bytes()?, b"\0"]))?
      } else {
        let source = if (name == "rootfs.ext4" and corruption == "root") or (name == "disk.img" and corruption == "disk") { previous } else { successor }
        fp"{source}/{name}".hardlink(at: fp"{mixed}/{name}")?
      }
    }
    let expected_failure = match corruption {
      "root" => "successor root receipt differs from its bundle"
      "disk" => "successor disk root payload differs from its root filesystem"
      else => "successor kernel differs from the selected PM kernel"
    }
    rejected(mixed, successor_identity, kernel, tools_image, expected_failure)?
  }
  for name in names { assert hash.sha256(fp"{previous}/{name}")?.hex() == before[name] }
  print "LAP30_REJECTED stale-generation mixed-root mixed-disk altered-kernel"
  print "LAP30_PREVIOUS_BUNDLE_PRESERVED"
}

main(@args)?

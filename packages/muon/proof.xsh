use pm.proof
use pm.util as pm_util

proc proof_encoded_argv(value: Str) -> Str {
  let hex = "0123456789abcdef"
  let parts = collect {
    for byte in bytes.from_text(value) {
      yield hex.byte_slice(byte / 16, 1) + hex.byte_slice(byte % 16, 1)
    }
  }
  "x" + parts.join("")
}

error ScriptError = Failed(kind: Str, message: Str)

proc main(rootfs = /rootfs) [fs, process, env, error] -> Result[Unit, Error] {
  let muon = fp"{rootfs}/usr/bin/muon"

  if ! muon.exists() {
    return Err(ScriptError.Failed(kind: "proof-muon", message: f"missing muon: {muon}"))?
  }

  proof.target_elf(rootfs, p"usr/bin/muon", "muon")

  if pm_util.build_arch()? == pm_util.target_arch()? {
    let out = run.text $muon "version"
    let trimmed = out.trim()

    if trimmed == "" {
      return Err(ScriptError.Failed(kind: "proof-muon", message: "muon version produced no output"))?
    }

    if "meson compatibility version 1.11" not in trimmed {
      return Err(ScriptError.Failed(kind: "proof-muon", message: f"muon is not meson 1.11 compatible: {trimmed}"))?
    }

    let tmp = fp"{rootfs}/var/tmp/proof-muon"
    tmp.remove()
    tmp.mkdir(true)
    defer tmp.remove()
    let script = fp"{tmp}/argument proof.xsh"
    script.write("proc main(value: Str) { print $value }\n")
    let argument = "space ; $literal \"quoted\""
    let xsh_arg = proof_encoded_argv("/bin/xsh")
    let script_arg = proof_encoded_argv(script.display())
    let value_arg = proof_encoded_argv(argument)
    fp"{tmp}/build.ninja".write(
      f"""rule structured
 command = ignored
 argv = {xsh_arg} {script_arg} {value_arg}
build good: structured
""",
    )
    let structured = run.text $muon "-C" $tmp "samu"
    proof.ensure(argument in structured, "proof-muon", "structured argv changed an argument")
    fp"{tmp}/build.ninja".write(
      """rule shell
 command = /bin/xsh --help
build bad: shell
""",
    )
    let rejected = run.status $muon "-C" $tmp "samu" 2> /dev/null
    proof.ensure(! rejected.ok, "proof-muon", "unstructured command was accepted")
    fp"{tmp}/build.ninja".write(
      """rule malformed
 command = /bin/xsh --help
 argv = x0
build bad: malformed
""",
    )
    let malformed = run.status $muon "-C" $tmp "samu" 2> /dev/null
    proof.ensure(! malformed.ok, "proof-muon", "malformed argv was accepted")
    print "muon ok: "${trimmed}
  } else {
    print "muon ok: cross-built "${pm_util.target_arch()?}
  }
}

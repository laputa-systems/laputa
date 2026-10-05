##! Proof that the built deno runs JavaScript and type-checks TypeScript offline.
use pm.proof
use pm.util as pm_util

proc main(rootfs: Path = /rootfs) [fs, process, env, error] {
  proof.target_elf(rootfs, p"usr/bin/deno", "deno")
  let arch = pm_util.target_arch()?

  if pm_util.build_arch()? != arch {
    print f"deno ok: cross-built {arch}"
    return
  }

  let ver = proof.package_version(rootfs, "deno")?
  let dynlinker = fp"{rootfs}/usr/lib/ld-musl-{arch}.so.1"
  let deno = fp"{rootfs}/usr/bin/deno"
  let tmp = fp"{rootfs}/var/tmp/proof-deno"
  tmp.remove(missing_ok: true)
  tmp.mkdir()
  defer tmp.remove(missing_ok: true)?

  # A relative import and a type annotation: `deno run` strips the types and
  # resolves the module graph, `deno check` runs the TypeScript checker.
  fp"{tmp}/sum.ts".write(
    """export function sum(values: number[]): number {
  return values.reduce((total, value) => total + value, 0);
}
""",
  )
  fp"{tmp}/main.ts".write(
    r"""import { sum } from "./sum.ts";

const total: number = sum([40, 1, 1]);
console.log(`total=${total}`);
""",
  )
  # The checker must reject a mistyped program, or a passing check proves nothing.
  fp"{tmp}/mistyped.ts".write(
    """import { sum } from "./sum.ts";

const total: string = sum([1, 2]);
console.log(total);
""",
  )

  var version = ""
  var evaluated = ""
  var ran = ""
  var checked = ""
  var mistyped = ""

  # Every command is offline: DENO_DIR and HOME stay in the proof's scratch
  # directory and no module is remote. An empty FORCE_COLOR keeps an
  # inherited one from overriding NO_COLOR, so output compares as plain text.
  env ({
    LD_LIBRARY_PATH: fp"{rootfs}/usr/lib".display(),
    DENO_DIR: fp"{tmp}/deno-dir".display(),
    HOME: tmp.display(),
    NO_COLOR: "1",
    FORCE_COLOR: "",
    DENO_NO_UPDATE_CHECK: "1",
  }) {
    cd $tmp {
      version = run.text $dynlinker $deno "--version" ?
      evaluated = run.text $dynlinker $deno "eval" "console.log(1+1)" ?
      ran = run.text $dynlinker $deno "run" "--no-remote" "main.ts" ?
      checked = (run.capture --text $dynlinker $deno "check" "--no-remote" "main.ts" ?).stderr
      let rejected = run.capture --text --accept=[1] $dynlinker $deno "check" "--no-remote" "mistyped.ts" ?
      mistyped = rejected.stderr
    }
  }

  let first = version.trim().split("\n")[0]
  proof.ensure(first.starts_with(f"deno {ver} "), "proof-deno", f"deno --version reported {first}, expected deno {ver}")
  proof.ensure(f"{arch}-unknown-linux-musl" in first, "proof-deno", f"deno --version names another target: {first}")
  proof.ensure(evaluated.trim() == "2", "proof-deno", f"deno eval printed {evaluated.trim()}, expected 2")
  proof.ensure(ran.trim() == "total=42", "proof-deno", f"deno run main.ts printed {ran.trim()}, expected total=42")
  proof.ensure("Check main.ts" in checked, "proof-deno", f"deno check main.ts did not type-check: {checked.trim()}")
  proof.ensure("TS2322" in mistyped, "proof-deno", f"deno check accepted a mistyped program: {mistyped.trim()}")
  print f"deno ok: {first}"
}

main(@args)

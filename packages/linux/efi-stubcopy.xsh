#!/bin/xsh

proc main(...argv: List[Str]) [fs, process, env, error] -> Result[Unit, Error] {
  guard argv.len() == 4 else { return Err(error.failure("expected EFI stub input, output, helper and digest"))? }
  let input = fp"{argv[0]}"
  let output = fp"{argv[1]}"
  let helper = fp"{argv[2]}"
  if hash.sha256(helper)?.hex() != argv[3] {
    return Err(error.failure("EFI stub helper changed after planning"))?
  }
  with temporary = fs.tempdir_in(output.parent)? {
    let stripped = fp"{temporary.host_path()?}/stripped.o"
    let strip = run.capture --text "llvm-strip" "--strip-debug" "-o" $stripped $input
    if ! strip.status.ok {
      return Err(error.failure(f"EFI stub strip failed: {strip.stderr}"))?
    }
    let relocations = run.capture --text "llvm-objdump" "-r" $stripped
    if ! relocations.status.ok {
      return Err(error.failure(f"EFI stub relocation inspection failed: {relocations.stderr}"))?
    }
    if "R_X86_64_64" in relocations.stdout {
      return Err(error.failure(f"EFI stub has absolute relocations: {input}"))?
    }
    let copy = run.capture --text "llvm-objcopy" "--remove-section=.note.gnu.property" $input $output
    if ! copy.status.ok {
      return Err(error.failure(f"EFI stub copy failed: {copy.stderr}"))?
    }
  }?
}

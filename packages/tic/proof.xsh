##! XSH module `proof` package and build operations.
use pm.proof

# A source that exercises use= merging, a cancelled standard capability, the
# cancellation of an inherited extended boolean (which ncurses leaves set),
# extended strings, tic's `%{48}` to `%'0'` rewrite, an alias, and a number
# that needs the 32-bit format.
const source = """
  laputa+base|fragment for the tic proof,
  	am, xenl, cols#80, it#8, bel=^G, cr=\\r, AX, XT,
  	setaf=\\E[3%p1%{48}%+%cm, Ms=\\E]52;%p1%s;%p2%s\\007,
  laputa-proof|laputa-tic|Laputa tic proof terminal,
  	colors#0x1000000, kbs=^?, cup=\\E[%i%p1%d;%p2%dH,
  	am@, XT@, use=laputa+base,
  """

# ncurses 6.6 `tic -x -e laputa-proof` output for `source`, base64-encoded.
const expected_base64 = "HgIyAAUADgBoAScAbGFwdXRhLXByb29mfGxhcHV0YS10aWN8TGFwdXRhIHRpYyBwcm9vZiB0ZXJtaW5hbAAAAAAAAQBQAAAACAAAAP//////////////////////////////////////////////////////////AAAAAf//AAACAP//////////////////BAD/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////FQD///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8XAAcADQAbWyVpJXAxJWQ7JXAyJWRIAH8AG1szJXAxJScwJyUrJWNtAAACAAAAAQAEABsAAQEAAAAAAwAGABtdNTI7JXAxJXM7JXAyJXMHAEFYAFhUAE1zAA=="

proc main(root: Path = /rootfs) [fs, process, error] {
  proof.package_metadata(root, "tic")
  let tic = fp"{root}/usr/bin/tic"
  proof.ensure(tic.executable()?, "proof-tic", f"missing executable {tic}")

  let tmp = fp"{root}/var/tmp/proof-tic"
  tmp.remove()
  tmp.mkdir()
  defer tmp.remove()
  let input = fp"{tmp}/proof.src"
  input.write(source + "\n")
  let out = fp"{tmp}/terminfo"

  run $tic -x -o $out -e laputa-proof $input

  let compiled = fp"{out}/l/laputa-proof".read_bytes()?
  let expected = expected_base64.base64_decode()?
  proof.ensure(compiled == expected, "proof-tic", "laputa-proof differs from ncurses tic's output")
  proof.ensure(fp"{out}/l/laputa-tic".read_bytes()? == expected, "proof-tic", "the laputa-tic alias differs")
  proof.ensure(! fp"{out}/l/laputa+base".exists()?, "proof-tic", "-e wrote an unselected entry")
  print f"tic ok: {compiled.len()}-byte 32-bit entry with extended capabilities matches ncurses tic"
}

main(@args)

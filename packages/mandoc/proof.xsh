##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

# One page in each input language mandoc parses: mdoc(7) semantic markup
# and man(7) presentational markup.
const mdoc_page = """.Dd October 4, 2026
.Dt LAPUTA-HELLO 1
.Os Laputa
.Sh NAME
.Nm laputa-hello
.Nd greet the floating island
.Sh SYNOPSIS
.Nm
.Op Fl v
.Ar name
.Sh DESCRIPTION
The
.Nm
utility prints a greeting for
.Ar name .
.Bl -tag -width Ds
.It Fl v
Also print the island's altitude.
.El
.Sh SEE ALSO
.Xr laputa-island 7
"""

const man_page = """.TH LAPUTA-ISLAND 7 2026-10-04 "Laputa" "Laputa Manual"
.SH NAME
laputa-island \\- overview of the flying island
.SH DESCRIPTION
The island is held aloft by a
.B lodestone
and steered by its astronomers.
.TP
.I altitude
Four miles above Balnibarbi.
.SH SEE ALSO
.BR laputa-hello (1)
"""

const mdoc_text = """LAPUTA-HELLO(1)    General Commands Manual   LAPUTA-HELLO(1)

NAME
     laputa-hello - greet the floating island

SYNOPSIS
     laputa-hello [-v] name

DESCRIPTION
     The laputa-hello utility prints a greeting for name.

     -v      Also print the island's altitude.

SEE ALSO
     laputa-island(7)

Laputa                 October 4, 2026                Laputa
"""

const man_text = """LAPUTA-ISLAND(7)        Laputa Manual       LAPUTA-ISLAND(7)

NAME
       laputa-island - overview of the flying island

DESCRIPTION
       The island is held aloft by a lodestone and steered
       by its astronomers.

       altitude
              Four miles above Balnibarbi.

SEE ALSO
       laputa-hello(1)

Laputa                   2026-10-04         LAPUTA-ISLAND(7)
"""

# The terminal formatters mark bold and underlined text by overstriking each
# character (`c BACKSPACE c`, `_ BACKSPACE c`); dropping the struck-over
# character leaves the plain text.
const overstrike = rx".\x08"

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "mandoc")

  for program in ["mandoc", "demandoc", "soelim"] {
    proof.target_elf(root, fp"usr/bin/{program}", "mandoc")
  }

  for link in ["man", "apropos", "whatis", "makewhatis"] {
    proof.ensure(fp"{root}/usr/bin/{link}".readlink()?.display() == "mandoc", "mandoc-links", f"usr/bin/{link} is not a link to mandoc")
  }

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"mandoc ok: cross-built {pm_util.target_arch()?}"
    return
  }

  let os = system.uname()?
  let loader = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"
  let libdir = fp"{root}/usr/lib".display()
  let bin = fp"{root}/usr/bin"
  let tmp = fp"{root}/var/tmp/proof-mandoc"
  fs.remove(tmp, missing_ok: true)
  fs.mkdir(tmp)
  defer fs.remove(tmp, missing_ok: true)?

  let manpath = fp"{tmp}/man"
  let mdoc_file = fp"{manpath}/man1/laputa-hello.1"
  let man_file = fp"{manpath}/man7/laputa-island.7"
  fs.mkdir(fp"{manpath}/man1", parents: true)
  fs.mkdir(fp"{manpath}/man7")
  fs.write(mdoc_file, mdoc_page)
  fs.write(man_file, man_page)

  env ({LD_LIBRARY_PATH: libdir}) {
    let mdoc_out = overstrike.replace(run.text $loader fp"{bin}/mandoc" "-T" "ascii" "-O" "width=60" $mdoc_file ?, "")
    proof.ensure(mdoc_out == mdoc_text, "mandoc-mdoc", f"unexpected mdoc rendering:\n{mdoc_out}")
    let man_out = overstrike.replace(run.text $loader fp"{bin}/mandoc" "-T" "ascii" "-O" "width=60" $man_file ?, "")
    proof.ensure(man_out == man_text, "mandoc-man", f"unexpected man rendering:\n{man_out}")

    # makewhatis indexes the tree into mandoc.db; apropos and whatis then
    # answer from that database, and man finds the page by section and name.
    run $loader fp"{bin}/makewhatis" $manpath ?
    proof.ensure(fs.exists(fp"{manpath}/mandoc.db")?, "mandoc-makewhatis", "makewhatis wrote no mandoc.db")
    let found = run.text $loader fp"{bin}/apropos" "-M" $manpath "island" ?
    let found_expected = "laputa-hello(1) - greet the floating island\nlaputa-island(7) - overview of the flying island\n"
    proof.ensure(found == found_expected, "mandoc-apropos", f"unexpected apropos output:\n{found}")
    let by_name = run.text $loader fp"{bin}/apropos" "-M" $manpath "Nm=laputa-hello" ?
    proof.ensure(by_name == "laputa-hello(1) - greet the floating island\n", "mandoc-apropos", f"unexpected apropos Nm= output:\n{by_name}")
    let what = run.text $loader fp"{bin}/whatis" "-M" $manpath "laputa-island" ?
    proof.ensure(what == "laputa-island(7) - overview of the flying island\n", "mandoc-whatis", f"unexpected whatis output:\n{what}")
    let shown = overstrike.replace(run.text $loader fp"{bin}/man" "-M" $manpath "-T" "ascii" "-O" "width=60" "7" "laputa-island" ?, "")
    proof.ensure(shown == man_text, "mandoc-man-lookup", f"unexpected man 7 laputa-island output:\n{shown}")

    let words = run.text $loader fp"{bin}/demandoc" "-w" $mdoc_file ?
    proof.ensure("laputa-hello\ngreet\nthe\nfloating\nisland\n" in words, "mandoc-demandoc", f"unexpected demandoc words:\n{words}")
  }

  fs.write(fp"{tmp}/top.man", ".SH INCLUDED\n.so part.man\n.SH AFTER\n")
  fs.write(fp"{tmp}/part.man", "from the part\n")

  cd $tmp {
    let inlined = run.text $loader fp"{bin}/soelim" "top.man" ?
    proof.ensure(inlined == ".SH INCLUDED\nfrom the part\n.SH AFTER\n", "mandoc-soelim", f"unexpected soelim output:\n{inlined}")
  }

  print "mandoc ok: mdoc and man rendered, makewhatis/apropos/whatis/man lookup, demandoc, soelim"
}

main(@args)

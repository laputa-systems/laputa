##! XSH module `proof` package and build operations.
use pm.proof

# The proof root holds man-pages alone (it has no runtime dependencies), so
# rendering through mandoc happens at the end of the build; this proof checks
# the installed tree: upstream's section layout, the release substitution in
# page headers, and that every `.so` link names a page the package installs.
const sections = [
  "man0",
  "man1",
  "man2",
  "man2const",
  "man2type",
  "man3",
  "man3attr",
  "man3const",
  "man3head",
  "man3type",
  "man4",
  "man5",
  "man6",
  "man7",
  "man8",
  "man9",
]

# The tarball's 3132 pages, less man7/man.7.
const page_count = 3131

proc main(root: Path = /rootfs) [fs, error] {
  proof.package_metadata(root, "man-pages")?
  let mandir = fp"{root}/usr/share/man"
  let installed = fs.children(mandir)? |> map .name |> sort
  proof.ensure(installed == sections, "man-pages-sections", f"unexpected section directories: {installed.join(" ")}")?

  let pages = fs.walk(mandir)? |> where .kind == "file"
  proof.ensure(pages.len() == page_count, "man-pages-count", f"expected {page_count} pages, found {pages.len()}")?
  proof.ensure(! fs.exists(fp"{mandir}/man7/man.7")?, "man-pages-man7", "man7/man.7 belongs to mandoc")?

  var links = 0

  for page in pages {
    let text = page.path.read_text()?

    for line in text.lines() {
      if line.starts_with(".TH ") or line.starts_with(".Os ") {
        proof.ensure(! ("(unreleased)" in line), "man-pages-release", f"{page.path} keeps a release placeholder: {line}")?
      }

      if line.starts_with(".so ") {
        let target = line.replace(".so ", "")
        proof.ensure(fs.exists(fp"{mandir}/{target}")?, "man-pages-links", f"{page.path} sources missing {target}")?
        links += 1
      }
    }
  }

  let open_th = [line for line in fp"{mandir}/man2/open.2".read_text()?.lines() if line.starts_with(".TH ")]
  proof.ensure(open_th == [".TH open 2 2026-02-08 \"Linux man-pages 6.19\""], "man-pages-release", f"unexpected open(2) header: {open_th.join(" | ")}")?
  proof.ensure(fs.exists(fp"{mandir}/man3type/FILE.3type")?, "man-pages-sections", "missing man3type/FILE.3type")?
  print f"man-pages ok: {pages.len()} pages in {sections.len()} sections, {links} .so links resolve"
}

main(@args)?

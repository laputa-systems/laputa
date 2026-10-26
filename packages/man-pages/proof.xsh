##! XSH module `proof` package and build operations.
use pm.proof

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

const page_count = 3131

const rendered_pages = [
  {
    args: [
      "2",
      "open",
    ],
    header: "open(2)                        System Calls Manual                       open(2)",
    name_line: "       open, openat, creat - open and possibly create a file",
  },
  {
    args: [
      "3",
      "printf",
    ],
    header: "printf(3)                   Library Functions Manual                   printf(3)",
    name_line: "       printf, fprintf, dprintf, vprintf, vfprintf, vdprintf, - formatted output",
  },
  {
    args: [
      "3",
      "fprintf",
    ],
    header: "printf(3)                   Library Functions Manual                   printf(3)",
    name_line: "       printf, fprintf, dprintf, vprintf, vfprintf, vdprintf, - formatted output",
  },
  {
    args: [
      "3type",
      "FILE",
    ],
    header: "FILE(3type)                                                          FILE(3type)",
    name_line: "       FILE - input/output stream",
  },
]

const overstrike = rx".\x08"

proc check_rendering(root: Path, version: Str) [fs, process, env, error] {
  let mandir = fp"{root}/usr/share/man"
  let man = fp"{root}/usr/bin/man"

  for page in rendered_pages {
    let args = page.args
    let out = overstrike.replace(run.text $man "-M" $mandir "-T" "ascii" "-O" "width=80" @args?, with: "")
    let lines = out.lines()
    let label = args.join(" ")

    guard lines.len() > 3 and lines[0] == page.header and page.name_line in lines else {
      fail f"man {label} rendered unexpectedly:\n{out}"
    }

    guard f"Linux man-pages {version}" in lines[-1] else {
      fail f"man {label} footer lacks the release version: {lines[-1]}"
    }
  }
}

proc main(root = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "man-pages")
  let mandir = fp"{root}/usr/share/man"
  let installed = fs.children(mandir)? |> map .name |> sort
  proof.ensure(installed == sections, "man-pages-sections", f"unexpected section directories: {installed.join(" ")}")

  let manifest: List[Str] = json.read(fp"{root}/var/lib/xsh-pm/packages/man-pages/manifest.json")?.require()?
  let pages = [fp"{root}/{path_value}" for path_value in manifest if path_value.starts_with("usr/share/man/") and fp"{root}/{path_value}".is_file()?]
  proof.ensure(pages.len() == page_count, "man-pages-count", f"expected {page_count} pages, found {pages.len()}")
  proof.ensure("usr/share/man/man7/man.7" not in manifest, "man-pages-man7", "man7/man.7 belongs to mandoc")

  var links = 0

  for page in pages {
    let text = page.read_text()?

    for line in text.lines() {
      if line.starts_with(".TH ") or line.starts_with(".Os ") {
        proof.ensure(
          ! ("(unreleased)" in line),
          "man-pages-release",
          f"{page} keeps a release placeholder: {line}",
        )
      }

      if line.starts_with(".so ") {
        let target = line.replace(".so ", with: "")
        proof.ensure(f"usr/share/man/{target}" in manifest, "man-pages-links", f"{page} sources missing {target}")
        links += 1
      }
    }
  }

  let open_th = [line for line in fp"{mandir}/man2/open.2".read_lines()? if line.starts_with(".TH ")]
  proof.ensure(
    open_th == [".TH open 2 2026-02-08 \"Linux man-pages 6.19\""],
    "man-pages-release",
    f"unexpected open(2) header: {open_th.join(" | ")}",
  )
  proof.ensure(fp"{mandir}/man3type/FILE.3type".exists()?, "man-pages-sections", "missing man3type/FILE.3type")
  check_rendering(root, proof.package_version(root, "man-pages")?)
  print f"man-pages ok: {pages.len()} pages in {sections.len()} sections, {links} .so links resolve"
}

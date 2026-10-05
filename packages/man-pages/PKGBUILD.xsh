##! Package recipe metadata and build operations.
## Package recipe export.
export const name = "man-pages"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "6.19"

## Package recipe export.
export const rel = "1"

## The payload is man(7) source text; reading it takes a formatter such as
## mandoc, which the system chooses, so nothing is needed at runtime.
export const deps: List[Str] = []

## mandoc renders a sample of the installed pages at the end of the build,
## so the pages are proven readable by Laputa's man(1) as installed. It is a
## build input only and never enters a runtime root through this package.
export const mkdeps_host = ["mandoc"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://cdn.kernel.org/pub/linux/docs/man-pages/man-pages-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "88a7c42ad2e03d8b96dc72d95e451f2d875ff0f43103a8eb8ac8242133bdcb05",
      },
    ],
  },
]

## Every section directory upstream ships, subsections (man2const,
## man3type, ...) included, installs as /usr/share/man/man<section>.
export const filetree = [
  {
    path: p"usr/share/man",
    kind: "tree",
  },
]

# man7/man.7 is only `.so man7/groff_man.7`, groff's page, which no Laputa
# package provides; mandoc installs the real man(7) there instead.
const excluded_pages = ["man7/man.7"]

# Upstream's build-man rule rewrites the release placeholders of every page
# with a .TH or .Dd header, line by line:
#   sed '/^\.TH /s/(unreleased)/$(DISTVERSION)/' | sed '/^\.Os /s/(unreleased)/$(DISTVERSION)/'
# The `(date)` and `$Mdocdate$` substitutions take the date from git; the
# release tarball already carries every page's date, so they never apply.
pure release_page(text: Str) -> Str {
  return text unless "(unreleased)" in text

  [
    if line.starts_with(".TH ") or line.starts_with(".Os ") { line.replace("(unreleased)", with: ver) } else { line }
    for line in text.split("\n")
  ].join("\n")
}

# Renders pages with mandoc's man(1) from this build's tree, and checks each
# header and NAME line. fprintf(3) is a `.so` page, so it also proves the
# links resolve to their target page as installed.
const rendered_pages = [
  {
    args: ["2", "open"],
    header: "open(2)                        System Calls Manual                       open(2)",
    name_line: "       open, openat, creat - open and possibly create a file",
  },
  {
    args: ["3", "printf"],
    header: "printf(3)                   Library Functions Manual                   printf(3)",
    name_line: "       printf, fprintf, dprintf, vprintf, vfprintf, vdprintf, - formatted output",
  },
  {
    args: ["3", "fprintf"],
    header: "printf(3)                   Library Functions Manual                   printf(3)",
    name_line: "       printf, fprintf, dprintf, vprintf, vfprintf, vdprintf, - formatted output",
  },
  {
    args: ["3type", "FILE"],
    header: "FILE(3type)                                                          FILE(3type)",
    name_line: "       FILE - input/output stream",
  },
]

# The terminal formatter marks bold and underline by overstriking each
# character with a backspace; dropping the struck-over character leaves text.
const overstrike = rx".\x08"

proc check_rendering(mandir: Path) [fs, process, env, error] {
  let man = process.which("man")?

  for page in rendered_pages {
    let args = page.args
    let out = overstrike.replace(run.text $man "-M" $mandir "-T" "ascii" "-O" "width=80" @args ?, with: "")
    let lines = out.lines()
    let label = args.join(" ")

    guard lines.len() > 3 and lines[0] == page.header and page.name_line in lines else {
      fail f"man {label} rendered unexpectedly:\n{out}"
    }

    guard f"Linux man-pages {ver}" in lines[-1] else {
      fail f"man {label} footer lacks the release version: {lines[-1]}"
    }
  }
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let mandir = fp"{dest}/usr/share/man"
  # Pages sit exactly one level down, in their section directory.
  for section in fs.children(p"man")? {
    fp"{mandir}/{section.name}".mkdir()

    for page in fs.children(section.path)? {
      let rel = f"{section.name}/{page.name}"
      continue when rel in excluded_pages
      fp"{mandir}/{rel}".write(release_page(page.path.read_text()?))
    }
  }

  check_rendering(mandir)
}

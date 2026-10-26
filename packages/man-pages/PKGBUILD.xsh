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

## Build tools.
export const mkdeps_host: List[Str] = []

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

  [if line.starts_with(".TH ") or line.starts_with(".Os ") { line.replace("(unreleased)", with: ver) } else { line } for line in text.split(
    "\n",
  )].join("\n")
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let mandir = fp"{dest}/usr/share/man"
  for section in fs.children(p"man")? {
    fp"{mandir}/{section.name}".mkdir()

    for page in fs.children(section.path)? {
      let page_path = f"{section.name}/{page.name}"
      continue when page_path in excluded_pages
      fp"{mandir}/{page_path}".write(release_page(page.path.read_text()?))
    }
  }

}

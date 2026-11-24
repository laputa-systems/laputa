##! Refresh GitHub release pins in recipes from the newest published prerelease.
#!/usr/bin/env -S XSH_MODULE_PATH=.:/usr/lib/pm /bin/xsh
use pm.recipe
use pm.types
use refresh.prereleases

const HELP = """usage: refresh-prereleases [--repo PATH] [--apply] [--verify] [--prefix PREFIX] PACKAGE...

Discover the newest GitHub prerelease for each selected recipe's pinned
repository, then propose the URL, SHA-256, rel and archive-format edits that
move the recipe to it. Default is a dry run: it prints a unified diff and writes
nothing. --apply writes the recipe in place. --verify additionally runs
`pm sources fetch` against the proposed recipe to confirm the new assets match
the new checksums.

Release discovery uses the repository's public releases.atom feed; checksums
come from that release's SHA256SUMS. Recipes whose newest prerelease is already
pinned are reported as current. An explicitly named recipe without a GitHub
release pin, conflicting pins, or a release missing pinned assets is an error. Run from the
repository root; --repo selects an alternative recipe tree.

options:
  --repo PATH        recipe repository root (default: current directory)
  --apply            write the refreshed recipe instead of printing a diff
  --verify           run pm sources fetch against the proposed recipe
  --prefix PREFIX    prerelease tag prefix (default: release-)
  --all              refresh recipes with GitHub release sources; report skipped recipes
  -h, --help         print this help

examples:
  xsh refresh-prereleases.xsh ghostty-custom
  xsh refresh-prereleases.xsh --verify ghostty-custom
  xsh refresh-prereleases.xsh --apply ghostty-custom
"""

cli main(repo: Path = p".", apply = false, verify = false, prefix = "release-", all = false, ...packages: List[Str]) with {
  name: "refresh-prereleases",
  help: HELP,
  parameters: {
    repo: {form: "--repo PATH"},
    apply: {form: "--apply"},
    verify: {form: "--verify"},
    prefix: {form: "--prefix PREFIX"},
    all: {form: "--all"},
    packages: {form: "...PACKAGE"},
  },
} {
  if packages.is_empty() and !all {
    print $HELP
  } else {
    let repo_root = path.absolute(repo)?
    let names = if all { prereleases.catalog_names(repo_root)? } else { packages }
    let plans: List[prereleases.RefreshPlan] = collect {
      for name in names {
        let dir = fp"{repo_root}/packages/{name}"
        let pkg = recipe.load_package_for_target(dir, types.X86_64LinuxMusl)?
        if all {
          let release_sources = [source for source in pkg.upstream_sources if prereleases.parse_pin_text(source.source.display()) is Ok(_)]
          if release_sources.is_empty() {
            print f"{name}: skipped (no GitHub release source)"
            continue
          }
        }
        let pin = prereleases.current_pin(pkg)?
        let feed = prereleases.fetch_text(f"https://github.com/{pin.owner}/{pin.repository}/releases.atom")?
        let tag = prereleases.latest_tag(feed, prefix)
        guard tag != "" else {
          return Err(types.PmError.RemoteFetch(f"{name}: no {prefix} prerelease in the feed"))
        }
        if tag == pin.tag {
          print f"{name}: current ({tag})"
          continue
        }
        let sums_body = prereleases.fetch_text(f"https://github.com/{pin.owner}/{pin.repository}/releases/download/{tag}/SHA256SUMS")?
        let plan = prereleases.build_refresh(pkg, pin, tag, prereleases.sums_map(sums_body))?
        if verify { prereleases.verify_with_pm(plan.name, plan.after) }
        yield plan
      }
    }
    for plan in plans {
      if plan.warning != "" { print f"{plan.name}: warning: {plan.warning}" }
      if apply {
        plan.path.write_atomic(plan.after)
        print f"{plan.name}: {plan.old_rel} -> {plan.new_rel} ({plan.old_tag} -> {plan.new_tag})"
      } else {
        prereleases.show_diff(plan.name, plan.before, plan.after)
      }
    }
  }
}

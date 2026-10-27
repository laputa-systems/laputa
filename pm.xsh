##! XSH PM entrypoint for explicit typed package planning and execution.
#!/usr/bin/env -S XSH_MODULE_PATH=.:/usr/lib/pm /bin/xsh
use pm.cli as pm_cli
use pm.types

const PM_HELP = """usage: pm COMMAND [OPTIONS]

repository commands:
  repo lint [--repo PATH]
  repo outdated PACKAGE --github-release OWNER/REPO [--repo PATH]
  repo update-filetree PACKAGE --plan PLAN --store STORE [--repo PATH]
  repo check [--repo PATH]
  repo plan [--repo PATH] (--all [--without PACKAGE...] | --root PACKAGE...) [--target TARGET] --output PLAN
  repo show PLAN
  repo build PLAN --store STORE [-j N|--jobs N] [--logs DIR]
  repo build-node PLAN --repo PATH --store STORE --node ARTIFACT_KEY
  repo publish PLAN --store STORE
  repo publish-snapshot --from DIR
  repo checksum [--repo PATH] PACKAGE...
  repo update-checksums [--repo PATH] PACKAGE...

source commands:
  sources fetch [--repo PATH] (--all | PACKAGE...) [--target TARGET]...

root commands:
  root compose PLAN --store STORE --runtime-root PACKAGE... --output GENERATION
  root inspect GENERATION_OR_RECEIPT

store commands:
  store verify --store STORE
  store gc --store STORE --keep PLAN...
  store extract PLAN --store STORE --package PACKAGE --path PATH --output FILE

targets: aarch64-linux-musl, x86_64-linux-musl (default: the host's)
"""

const REPO_HELP = """usage: pm repo COMMAND [OPTIONS]

  lint [--repo PATH]
  outdated PACKAGE --github-release OWNER/REPO [--repo PATH]
  update-filetree PACKAGE --plan PLAN --store STORE [--repo PATH]
  check [--repo PATH]
  plan [--repo PATH] (--all [--without PACKAGE...] | --root PACKAGE...) [--target TARGET] --output PLAN
  show PLAN
  build PLAN --store STORE [-j N|--jobs N] [--logs DIR]
  build-node PLAN --repo PATH --store STORE --node ARTIFACT_KEY
  publish PLAN --store STORE
  publish-snapshot --from DIR
  checksum [--repo PATH] PACKAGE...
  update-checksums [--repo PATH] PACKAGE...

targets: aarch64-linux-musl, x86_64-linux-musl (default: the host's)
"""

const REPO_PLAN_HELP = """usage: pm repo plan [--repo PATH] (--all [--without PACKAGE...] | --root PACKAGE...) [--target TARGET] --output PLAN

--without PACKAGE drops from --all every package whose build closure needs
PACKAGE (and PACKAGE itself): `--all --without cmake --without linux` plans
everything that builds before cmake and linux exist.

targets: aarch64-linux-musl, x86_64-linux-musl (default: the host's)
"""

const SOURCES_HELP = """usage: pm sources fetch [--repo PATH] (--all | PACKAGE...) [--target TARGET]...

Downloads every pinned upstream source the selected packages use on each
target into the content-addressed source cache (LAPUTA_SOURCE_CACHE, default
REPO/.cache/sources) and verifies its sha256. Source fetches, checksum commands,
and explicit `repo outdated` lookups contact upstream hosts. Builds read the
cache or the local mirror named by LAPUTA_MIRROR.

targets: aarch64-linux-musl, x86_64-linux-musl (default: the host's)
"""

const ROOT_HELP = """usage: pm root COMMAND [OPTIONS]

  compose PLAN --store STORE --runtime-root PACKAGE... --output GENERATION
  inspect GENERATION_OR_RECEIPT
"""

const STORE_HELP = """usage: pm store COMMAND [OPTIONS]

  verify --store STORE
  gc --store STORE --keep PLAN...
  extract PLAN --store STORE --package PACKAGE --path PATH --output FILE
"""

cli main(...unknown: List[Str]) with {name: "pm", help: PM_HELP} {
  if unknown.is_empty() {
    print $PM_HELP
  } else {
    Err(types.PmError.Usage(f"unknown pm command {unknown[0]}"))?
  }
}

cli main repo(...unknown: List[Str]) with {name: "pm repo", help: REPO_HELP} {
  if unknown.is_empty() {
    print $REPO_HELP
  } else {
    Err(types.PmError.Usage(f"unknown pm repo command {unknown[0]}"))?
  }
}

cli main sources(...unknown: List[Str]) with {name: "pm sources", help: SOURCES_HELP} {
  if unknown.is_empty() {
    print $SOURCES_HELP
  } else {
    Err(types.PmError.Usage(f"unknown pm sources command {unknown[0]}"))?
  }
}

cli main root(...unknown: List[Str]) with {name: "pm root", help: ROOT_HELP} {
  if unknown.is_empty() {
    print $ROOT_HELP
  } else {
    Err(types.PmError.Usage(f"unknown pm root command {unknown[0]}"))?
  }
}

cli main store(...unknown: List[Str]) with {name: "pm store", help: STORE_HELP} {
  if unknown.is_empty() {
    print $STORE_HELP
  } else {
    Err(types.PmError.Usage(f"unknown pm store command {unknown[0]}"))?
  }
}

cli main repo check(repo: Str = "") with {
  name: "pm repo check",
  help: REPO_HELP,
  parameters: {
    repo: {form: "--repo PATH"},
  },
} {
  pm_cli.pm_cli_repo_check({repo: pm_cli.pm_cli_resolve_repo_root(repo)?})
}

cli main repo plan(output: Path, repo: Str = "", all: Bool = false, roots: List[Str] = [], without: List[Str] = [], target: Str = "") with {
  name: "pm repo plan",
  help: REPO_PLAN_HELP,
  parameters: {
    output: {form: "--output PLAN"},
    repo: {form: "--repo PATH"},
    all: {form: "--all"},
    roots: {form: "--root PACKAGE"},
    without: {form: "--without PACKAGE"},
    target: {form: "--target TARGET"},
  },
} {
  pm_cli.pm_cli_repo_plan({repo, all, roots, without, target, output})
}

cli main repo show(input: Path) with {
  name: "pm repo show",
  help: REPO_HELP,
  parameters: {
    input: {form: "PLAN"},
  },
} {
  pm_cli.pm_cli_repo_show({input})
}

cli main repo build(input: Path, store: Path, jobs: Int = cpu.count(), logs: Str = "") with {
  name: "pm repo build",
  help: REPO_HELP,
  parameters: {
    input: {form: "PLAN"},
    store: {form: "--store STORE"},
    jobs: {form: "-j --jobs N", min: 1},
    logs: {form: "--logs DIR"},
  },
} {
  pm_cli.pm_cli_repo_build({input, store, jobs, logs: fp"{logs}"})
}

cli main repo build_node(input: Path, repo: Path, store: Path, node: Str) with {
  name: "pm repo build-node",
  help: REPO_HELP,
  parameters: {
    input: {form: "PLAN"},
    repo: {form: "--repo PATH"},
    store: {form: "--store STORE"},
    node: {form: "--node ARTIFACT_KEY"},
  },
} {
  pm_cli.pm_cli_repo_build_node({input, repo, store, node})
}

cli main repo publish(input: Path, store: Path) with {
  name: "pm repo publish",
  help: REPO_HELP,
  parameters: {
    input: {form: "PLAN"},
    store: {form: "--store STORE"},
  },
} {
  pm_cli.pm_cli_repo_publish({input, store})
}

cli main repo publish_snapshot(snapshot_dir: Path) with {
  name: "pm repo publish-snapshot",
  help: REPO_HELP,
  parameters: {
    snapshot_dir: {form: "--from DIR"},
  },
} {
  pm_cli.pm_cli_repo_publish_snapshot({snapshot_dir})
}

cli main repo checksum(repo: Str = "", ...packages: List[Str]) with {
  name: "pm repo checksum",
  help: REPO_HELP,
  parameters: {
    repo: {form: "--repo PATH"},
    packages: {form: "...PACKAGE"},
  },
} {
  pm_cli.pm_cli_repo_checksum({repo, packages})
}

cli main repo update_checksums(repo: Str = "", ...packages: List[Str]) with {
  name: "pm repo update-checksums",
  help: REPO_HELP,
  parameters: {
    repo: {form: "--repo PATH"},
    packages: {form: "...PACKAGE"},
  },
} {
  pm_cli.pm_cli_repo_update_checksums({repo, packages})
}

cli main sources fetch(repo: Str = "", all: Bool = false, targets: List[Str] = [], ...packages: List[Str]) with {
  name: "pm sources fetch",
  help: SOURCES_HELP,
  parameters: {
    repo: {form: "--repo PATH"},
    all: {form: "--all"},
    targets: {form: "--target TARGET"},
    packages: {form: "...PACKAGE"},
  },
} {
  pm_cli.pm_cli_sources_fetch(repo, all, packages, targets)
}

cli main root compose(input: Path, store: Path, output: Path, runtime_roots: List[Str] = []) with {
  name: "pm root compose",
  help: ROOT_HELP,
  parameters: {
    input: {form: "PLAN"},
    store: {form: "--store STORE"},
    output: {form: "--output GENERATION"},
    runtime_roots: {form: "--runtime-root PACKAGE"},
  },
} {
  pm_cli.pm_cli_root_compose({input, store, runtime_roots, output})
}

cli main root inspect(input: Path) with {
  name: "pm root inspect",
  help: ROOT_HELP,
  parameters: {
    input: {form: "GENERATION"},
  },
} {
  pm_cli.pm_cli_root_inspect({input})
}

cli main store verify(store: Path) with {
  name: "pm store verify",
  parameters: {
    store: {form: "--store STORE"},
  },
} {
  pm_cli.pm_cli_store_verify({store})
}

cli main store gc(store: Path, keep: List[Str] = []) with {
  name: "pm store gc",
  parameters: {
    store: {form: "--store STORE"},
    keep: {form: "--keep PLAN"},
  },
} {
  pm_cli.pm_cli_store_gc({store, keep})
}

cli main store extract(input: Path, store: Path, package: Str, payload_path: Path, output: Path) with {
  name: "pm store extract",
  parameters: {
    input: {form: "PLAN"},
    store: {form: "--store STORE"},
    package: {form: "--package PACKAGE"},
    payload_path: {form: "--path PATH"},
    output: {form: "--output FILE"},
  },
} {
  pm_cli.pm_cli_store_extract({input, store, package, path: payload_path, output})
}

cli main repo lint(repo: Str = "") with {
  name: "pm repo lint",
  parameters: {repo: {form: "--repo PATH"}},
} {
  pm_cli.pm_cli_repo_lint(pm_cli.pm_cli_resolve_repo_root(repo)?)
}

cli main repo outdated(package: Str, github_release: Str, repo: Str = "") with {
  name: "pm repo outdated",
  parameters: {
    package: {form: "PACKAGE"},
    github_release: {form: "--github-release REPOSITORY"},
    repo: {form: "--repo PATH"},
  },
} {
  pm_cli.pm_cli_repo_outdated(repo, package, github_release)
}

cli main repo update_filetree(package: Str, input: Path, store_root: Path, repo: Str = "") with {
  name: "pm repo update-filetree",
  parameters: {
    package: {form: "PACKAGE"},
    input: {form: "--plan PLAN"},
    store_root: {form: "--store STORE"},
    repo: {form: "--repo PATH"},
  },
} {
  pm_cli.pm_cli_repo_update_filetree(repo, package, input, store_root)
}

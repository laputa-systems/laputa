##! XSH entrypoint for signed operating-system trust updates.
#!/usr/bin/env -S XSH_MODULE_PATH=.:/usr/lib/pm /bin/xsh
use trust.update as trust_update

const TRUST_HELP = """usage: trust COMMAND [OPTIONS]

  status [--root PATH]
  verify --from DIR [--root PATH]
  update (--from DIR | --url URL) [--root PATH]

Trust commands operate on the system root (default /). Every trust change
arrives as a signed release; HTTPS is transport only. Long-lived processes
pin their trust snapshot and fail closed on change: recreate their clients
or restart their services (for example with xinit restart) after updating.
"""

const TRUST_STATUS_HELP = """usage: trust status [--root PATH]

Reports the active trust generation, bundle and policy digests,
verification-key fingerprint, last activation, accepted generation,
pending work, freshness, and atomic-activation capability.
"""

const TRUST_VERIFY_HELP = """usage: trust verify --from DIR [--root PATH]

Verifies a release directory without changing installed state.
"""

const TRUST_UPDATE_HELP = """usage: trust update (--from DIR | --url URL) [--root PATH]

Verifies a signed release and atomically activates it. --from DIR is the
deterministic offline and emergency recovery path; it needs no networking
and no working WebPKI trust store. --url URL downloads the fixed four-file
release layout over HTTPS. With no store present, update first bootstraps
generation state from pinned package seeds, then applies the release.
"""

cli main(...unknown: List[Str]) with {name: "trust", help: TRUST_HELP} {
  if unknown.is_empty() {
    print $TRUST_HELP
  } else {
    Err(trust_update.TrustUpdateError.InvalidData(f"unknown trust command {unknown[0]}"))?
  }
}

cli main status(root: Str = "") with {
  name: "trust status",
  help: TRUST_STATUS_HELP,
  parameters: {
    root: {form: "--root PATH"},
  },
} {
  let system_root = if root == "" { p"/" } else { fp"{root}" }
  let _ = trust_update.trust_status(system_root)?
}

cli main verify(source: Path, root: Str = "") with {
  name: "trust verify",
  help: TRUST_VERIFY_HELP,
  parameters: {
    source: {form: "--from DIR"},
    root: {form: "--root PATH"},
  },
} {
  let system_root = if root == "" { p"/" } else { fp"{root}" }
  let _ = trust_update.trust_verify(system_root, source)?
}

cli main update(from: Str = "", url: Str = "", root: Str = "") with {
  name: "trust update",
  help: TRUST_UPDATE_HELP,
  parameters: {
    from: {form: "--from DIR"},
    url: {form: "--url URL"},
    root: {form: "--root PATH"},
  },
} {
  let system_root = if root == "" { p"/" } else { fp"{root}" }
  if from != "" and url != "" {
    return Err(
      trust_update.TrustUpdateError.InvalidData("trust update accepts exactly one of --from and --url"),
    )
  }

  if from != "" {
    let _ = trust_update.trust_update_from_dir(system_root, fp"{from}")?
  } else if url != "" {
    let _ = trust_update.trust_update_from_url(system_root, url)?
  } else {
    return Err(
      trust_update.TrustUpdateError.InvalidData("trust update requires --from DIR or --url URL"),
    )
  }
}

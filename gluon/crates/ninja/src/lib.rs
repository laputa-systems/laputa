//! ninja entry point. CLI dispatch only — all real work lives in submodules.

pub mod build;
pub mod cli;
pub mod graph;
pub mod manifest;
pub mod status;
pub mod tools;

use std::process::ExitCode;

pub fn main_entry() -> ExitCode {
    main_from(std::env::args().collect())
}

/// Run ninja with `argv`. `argv[0]` is the program name and is ignored.
/// Later words are flags and targets, so a wrapper that puts a subcommand
/// in `argv[1]` must drop that word before calling this.
pub fn main_from(raw: Vec<String>) -> ExitCode {
    let opts = match cli::parse(&raw) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("ninja: {e}");
            return ExitCode::from(1);
        }
    };

    if opts.show_version {
        println!("1.13.2");
        return ExitCode::SUCCESS;
    }

    // -C must take effect before we read the manifest, exactly like the
    // reference binary, which prints the chdir banner to stdout.
    if let Some(dir) = &opts.chdir {
        if let Err(e) = std::env::set_current_dir(dir) {
            eprintln!("ninja: chdir to '{dir}' - {e}");
            return ExitCode::from(1);
        }
        println!("ninja: Entering directory `{dir}'");
    }

    match run(&opts) {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            eprintln!("ninja: {e}");
            ExitCode::from(1)
        }
    }
}

fn run(opts: &cli::Options) -> Result<u8, String> {
    let mut state = manifest::parse_file(&opts.manifest_file)
        .map_err(|e| format!("{}: {}", opts.manifest_file, e))?;

    if let Some(tool) = &opts.tool {
        return tools::run(tool, &state, opts);
    }

    // Reference ninja rebuilds its own manifest before the real build and
    // then continues with the freshly loaded one. If the manifest is an
    // output of an edge, run just that edge; when it actually executed,
    // reparse and build against the new manifest.
    if state.producers.contains_key(&opts.manifest_file) {
        let report = build::run_targets(
            &state,
            opts,
            Some(std::slice::from_ref(&opts.manifest_file)),
            false,
        )?;
        if report.code != 0 {
            return Ok(report.code);
        }
        if report.ran {
            state = manifest::parse_file(&opts.manifest_file)
                .map_err(|e| format!("{}: {}", opts.manifest_file, e))?;
        }
    }

    build::run(&state, opts)
}

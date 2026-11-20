//! Argument parsing for the ninja CLI.
//!
//! Only the flags exercised by the upstream test suite are recognized.
//! Anything else is rejected so tests notice missing functionality.

#[derive(Debug, Default)]
pub struct Options {
    pub manifest_file: String,
    pub chdir: Option<String>,
    pub jobs: Option<usize>,
    /// Maximum number of failed jobs before stopping. `None` means
    /// "stop on first failure" (default). `Some(0)` means unlimited
    /// (`-k 0` in upstream ninja).
    pub keep_going: Option<usize>,
    pub quiet: bool,
    pub verbose: bool,
    pub show_version: bool,
    pub show_help: bool,
    pub dry_run: bool,
    pub debug: Vec<String>,
    pub tool: Option<String>,
    pub tool_args: Vec<String>,
    pub targets: Vec<String>,
}

pub fn parse(argv: &[String]) -> Result<Options, String> {
    let mut o = Options {
        manifest_file: "build.ninja".into(),
        ..Default::default()
    };
    let mut i = 1;
    while i < argv.len() {
        let a = &argv[i];
        match a.as_str() {
            cli_short_h!() | cli_long_help!() => o.show_help = true,
            cli_long_version!() => o.show_version = true,
            cli_long_quiet!() => o.quiet = true,
            cli_short_v!() | cli_long_verbose!() => o.verbose = true,
            cli_short_n!() | cli_long_dry_run!() => o.dry_run = true,
            cli_short_k!() => {
                i += 1;
                let n = argv
                    .get(i)
                    .ok_or_else(|| "-k needs an argument".to_string())?;
                o.keep_going = Some(n.parse().map_err(|_| format!("bad -k value: {n}"))?);
            }
            cli_short_C!() => {
                i += 1;
                o.chdir = Some(
                    argv.get(i)
                        .ok_or_else(|| "-C needs an argument".to_string())?
                        .clone(),
                );
            }
            cli_short_f!() => {
                i += 1;
                o.manifest_file = argv
                    .get(i)
                    .ok_or_else(|| "-f needs an argument".to_string())?
                    .clone();
            }
            cli_short_j!() => {
                i += 1;
                let n = argv
                    .get(i)
                    .ok_or_else(|| "-j needs an argument".to_string())?;
                o.jobs = Some(n.parse().map_err(|_| format!("bad -j value: {n}"))?);
            }
            cli_short_d!() => {
                i += 1;
                o.debug.push(
                    argv.get(i)
                        .ok_or_else(|| "-d needs an argument".to_string())?
                        .clone(),
                );
            }
            cli_short_t!() => {
                i += 1;
                o.tool = Some(
                    argv.get(i)
                        .ok_or_else(|| "-t needs an argument".to_string())?
                        .clone(),
                );
                // Everything after -t <name> is forwarded to the tool.
                i += 1;
                while i < argv.len() {
                    let arg = &argv[i];
                    if arg == cli_short_h!() || arg == cli_long_help!() { o.show_help = true; }
                    o.tool_args.push(arg.clone());
                    if o.tool.as_deref() == Some(cli_command_multi_inputs!()) && arg == cli_short_d!() && i + 1 < argv.len() {
                        i += 1;
                        o.tool_args.push(argv[i].clone());
                    }
                    i += 1;
                }
                return Ok(o);
            }
            s if s.starts_with(cli_short_C!()) => {
                o.chdir = Some(s[2..].to_string());
            }
            s if s.starts_with(cli_short_j!()) => {
                let n = &s[2..];
                o.jobs = Some(n.parse().map_err(|_| format!("bad -j value: {n}"))?);
            }
            s if s.starts_with(cli_short_k!()) => {
                let n = &s[2..];
                o.keep_going = Some(n.parse().map_err(|_| format!("bad -k value: {n}"))?);
            }
            s if s.starts_with(cli_short_f!()) => {
                o.manifest_file = s[2..].to_string();
            }
            s if s.starts_with('-') => {
                return Err(format!("unknown flag: {s}"));
            }
            _ => o.targets.push(a.clone()),
        }
        i += 1;
    }
    Ok(o)
}

impl Options {
    pub fn jobs_count(&self) -> usize {
        // Match reference ninja's GuessParallelism(): cores + 2, with a
        // minimum of 2 even on a single-CPU machine. Tests like
        // test_jobserver_client_with_posix_fifo run under
        // `taskset -c 0` and assert that ninja still spawns 2 jobs
        // in parallel.
        self.jobs.unwrap_or_else(|| {
            let n = std::thread::available_parallelism()
                .map(|n| n.get())
                .unwrap_or(1);
            match n {
                0 | 1 => 2,
                2 => 3,
                other => other + 2,
            }
        })
    }

    /// Maximum allowed failures before we stop launching new edges.
    /// Matches reference ninja's `-k N` semantics:
    ///   - flag absent          → 1 (stop on first failure)
    ///   - `-k 0`               → `usize::MAX` (never stop)
    ///   - `-k N` for N > 0     → N
    pub fn failure_limit(&self) -> usize {
        match self.keep_going {
            None => 1,
            Some(0) => usize::MAX,
            Some(n) => n,
        }
    }
}

impl Options {
    /// True if the user passed `-d explain`.
    pub fn explain(&self) -> bool {
        self.debug.iter().any(|d| d == "explain")
    }
}

#[cfg(test)]
mod help_tests {
    use super::parse;

    fn words(args: &[&str]) -> Vec<String> { args.iter().map(|s| s.to_string()).collect() }

    #[test]
    fn help_tokens_consumed_as_values_remain_values() {
        for flag in ["-C", "-f", "-d", "-t"] {
            let parsed = parse(&words(&["ninja", flag, "--help"])).unwrap();
            assert!(!parsed.show_help, "{flag}");
        }
        for flag in ["-j", "-k"] {
            assert!(parse(&words(&["ninja", flag, "-h"])).is_err());
        }
        let parsed = parse(&words(&["ninja", "-t", "multi-inputs", "-d", "--help", "app"])).unwrap();
        assert!(!parsed.show_help);
        assert_eq!(parsed.tool_args, ["-d", "--help", "app"]);
        assert!(parse(&words(&["ninja", "-t", "multi-inputs", "-h"])).unwrap().show_help);
    }
}

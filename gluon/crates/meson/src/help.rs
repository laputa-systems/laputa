struct Entry { path: &'static str, detail: &'static str, example: &'static str }
const ENTRIES: &[Entry] = &[
    Entry { path: cli_command_help!(), detail: "\n  Print this command reference without configuring a project.", example: cli_command_help!() },
    Entry { path: cli_command_version!(), detail: "\n  Print the existing Meson version token.", example: cli_command_version!() },
    Entry { path: cli_command_setup!(), detail: concat!("[BUILD_DIR] [SOURCE_DIR] [-DKEY=VALUE] [", cli_long_cross_file!(), " FILE] [", cli_long_native_file!(), " FILE] [", cli_long_reconfigure!(), "] [", cli_long_wipe!(), "] [BUILTIN OPTIONS]\n  Configure a project (defaults: source ., ", cli_command_build!(), " builddir).", "\n    BUILD_DIR and SOURCE_DIR are optional. -DKEY=VALUE sets a repeatable project option (last value wins). ", cli_long_cross_file!(), " and ", cli_long_native_file!(), " select machine files; ", cli_long_reconfigure!(), " reuses a configured directory; ", cli_long_wipe!(), " recreates it."), example: concat!(cli_command_setup!(), " builddir") },
    Entry { path: cli_command_configure!(), detail: concat!("[BUILD_DIR] [-DKEY=VALUE] [BUILTIN OPTIONS]\n  Change project options (default ", cli_command_build!(), " directory: .).", "\n    BUILD_DIR is optional. -DKEY=VALUE updates a repeatable project option (last value wins)."), example: concat!(cli_command_configure!(), " builddir -Ddebug=true") },
    Entry { path: cli_command_compile!(), detail: concat!("[", cli_short_C!(), " DIR] [", cli_short_j!(), " N|", cli_long_jobs!(), " N] [", cli_short_v!(), "|", cli_long_verbose!(), "] [", cli_long_clean!(), "] [TARGET...]\n  Build targets (alias: ", cli_command_build!(), "; default directory: .).", "\n    ", cli_short_C!(), " selects the ", cli_command_build!(), " directory; ", cli_short_j!(), "/", cli_long_jobs!(), " sets an optional job count; ", cli_short_v!(), "/", cli_long_verbose!(), " displays commands; ", cli_long_clean!(), " removes ", cli_command_build!(), " outputs. TARGET is optional and repeatable."), example: concat!(cli_command_compile!(), " ", cli_short_C!(), " builddir") },
    Entry { path: cli_command_test!(), detail: concat!("[", cli_short_C!(), " DIR] [", cli_short_v!(), "|", cli_long_verbose!(), "] [", cli_long_suite!(), " NAME] [", cli_short_t!(), "|", cli_long_timeout_multiplier!(), " N] [", cli_short_j!(), "|", cli_long_num_processes!(), " N] [", cli_long_no_rebuild!(), "] [", cli_long_repeat!(), " N] [TEST...]\n  Run tests (default directory ., timeout multiplier 1, repeat 1).", "\n    ", cli_short_C!(), " selects the ", cli_command_build!(), " directory; ", cli_long_suite!(), " filters a suite; ", cli_short_t!(), "/", cli_long_timeout_multiplier!(), " scales timeouts; ", cli_short_j!(), "/", cli_long_num_processes!(), " selects concurrency; ", cli_long_no_rebuild!(), " skips rebuilding; ", cli_long_repeat!(), " runs each ", cli_command_test!(), " N times; ", cli_short_v!(), "/", cli_long_verbose!(), " shows output. TEST is optional and repeatable."), example: concat!(cli_command_test!(), " ", cli_short_C!(), " builddir") },
    Entry { path: cli_command_install!(), detail: concat!("[", cli_short_C!(), " DIR] [", cli_long_destdir!(), " DIR] [", cli_long_skip_subprojects!(), "] [", cli_long_tags!(), " TAGS] [", cli_long_strip!(), "] [", cli_long_no_rebuild!(), "] [", cli_short_q!(), "|", cli_long_quiet!(), "]\n  Install the project (default directory: .; tags are comma-separated).", "\n    ", cli_short_C!(), " selects the ", cli_command_build!(), " directory; ", cli_long_destdir!(), " stages installation; ", cli_long_skip_subprojects!(), " omits ", cli_command_subprojects!(), "; ", cli_long_tags!(), " selects comma-separated tags; ", cli_long_strip!(), " strips files; ", cli_long_no_rebuild!(), " skips rebuilding; ", cli_short_q!(), "/", cli_long_quiet!(), " reduces output."), example: concat!(cli_command_install!(), " ", cli_short_C!(), " builddir ", cli_long_destdir!(), " staging") },
    Entry { path: cli_command_introspect!(), detail: concat!("[BUILD_DIR] [", cli_short_a!(), "|", cli_long_all!(), "] [", cli_long_targets!(), "] [", cli_long_tests!(), "] [", cli_long_dependencies!(), "] [", cli_long_buildoptions!(), "] [", cli_long_projectinfo!(), "] [", cli_long_installed!(), "] [", cli_long_benchmarks!(), "]\n  Report project information (default directory: .).", "\n    BUILD_DIR is optional. ", cli_long_all!(), " selects all reports; the other flags select their named report. Multiple report flags may be combined."), example: concat!(cli_command_introspect!(), " builddir ", cli_long_targets!()) },
    Entry { path: cli_command_init!(), detail: concat!("[NAME] [", cli_short_n!(), "|", cli_long_name!(), " NAME] [", cli_short_l!(), "|", cli_long_language!(), " LANG] [", cli_long_type!(), " TYPE] [", cli_short_b!(), "|", cli_long_builddir!(), " DIR] [", cli_long_version!(), " VERSION]\n  Create a project (defaults: c, executable, 0.1.0).", "\n    NAME or ", cli_long_name!(), " names the project; ", cli_long_language!(), " selects its source language; ", cli_long_type!(), " selects executable or library; ", cli_long_builddir!(), " requests a ", cli_command_build!(), " directory; ", cli_long_version!(), " sets the project ", cli_command_version!(), "."), example: concat!(cli_command_init!(), " ", cli_long_name!(), " hello") },
    Entry { path: cli_command_dist!(), detail: concat!("[", cli_short_C!(), " DIR] [", cli_long_formats!(), " FORMATS] [", cli_long_include_subprojects!(), "] [", cli_long_no_tests!(), "]\n  Create an archive (defaults: directory ., ", cli_command_format!(), " xztar).", "\n    ", cli_short_C!(), " selects the ", cli_command_build!(), " directory; ", cli_long_formats!(), " selects comma-separated archive formats; ", cli_long_include_subprojects!(), " includes ", cli_command_subprojects!(), "; ", cli_long_no_tests!(), " skips archive tests."), example: concat!(cli_command_dist!(), " ", cli_short_C!(), " builddir") },
    Entry { path: cli_command_wrap!(), detail: concat!("[COMMAND] [NAME]\n  Manage wraps (default command: ", cli_command_list!(), ").", "\n    Compatibility ", cli_command_status!(), " command: currently prints a ", cli_command_status!(), " message only; it does not ", cli_command_download!(), ", ", cli_command_update!(), ", execute or remove files."), example: concat!(cli_command_wrap!(), " ", cli_command_list!()) },
    Entry { path: concat!(cli_command_wrap!(), " ", cli_command_list!()), detail: concat!("\n  List wraps.", "\n    Compatibility ", cli_command_status!(), " command: currently prints a ", cli_command_status!(), " message only; it does not ", cli_command_download!(), ", ", cli_command_update!(), ", execute or remove files."), example: concat!(cli_command_wrap!(), " ", cli_command_list!()) },
    Entry { path: concat!(cli_command_wrap!(), " ", cli_command_install!()), detail: concat!("NAME\n  Install a ", cli_command_wrap!(), ".", "\n    Compatibility ", cli_command_status!(), " command: currently prints a ", cli_command_status!(), " message only; it does not ", cli_command_download!(), ", ", cli_command_update!(), ", execute or remove files."), example: concat!(cli_command_wrap!(), " ", cli_command_install!(), " zlib") },
    Entry { path: concat!(cli_command_wrap!(), " ", cli_command_update!()), detail: concat!("\n  Update wraps.", "\n    Compatibility ", cli_command_status!(), " command: currently prints a ", cli_command_status!(), " message only; it does not ", cli_command_download!(), ", ", cli_command_update!(), ", execute or remove files."), example: concat!(cli_command_wrap!(), " ", cli_command_update!()) },
    Entry { path: concat!(cli_command_wrap!(), " ", cli_command_info!()), detail: concat!("NAME\n  Show ", cli_command_wrap!(), " information.", "\n    Compatibility ", cli_command_status!(), " command: currently prints a ", cli_command_status!(), " message only; it does not ", cli_command_download!(), ", ", cli_command_update!(), ", execute or remove files."), example: concat!(cli_command_wrap!(), " ", cli_command_info!(), " zlib") },
    Entry { path: concat!(cli_command_wrap!(), " ", cli_command_search!()), detail: concat!("QUERY\n  Search wraps.", "\n    Compatibility ", cli_command_status!(), " command: currently prints a ", cli_command_status!(), " message only; it does not ", cli_command_download!(), ", ", cli_command_update!(), ", execute or remove files."), example: concat!(cli_command_wrap!(), " ", cli_command_search!(), " zlib") },
    Entry { path: concat!(cli_command_wrap!(), " ", cli_command_status!()), detail: concat!("\n  Show ", cli_command_wrap!(), " ", cli_command_status!(), ".", "\n    Compatibility ", cli_command_status!(), " command: currently prints a ", cli_command_status!(), " message only; it does not ", cli_command_download!(), ", ", cli_command_update!(), ", execute or remove files."), example: concat!(cli_command_wrap!(), " ", cli_command_status!()) },
    Entry { path: cli_command_subprojects!(), detail: concat!("[COMMAND]\n  Manage ", cli_command_subprojects!(), " (default command: ", cli_command_list!(), ").", "\n    Compatibility ", cli_command_status!(), " command: currently prints a ", cli_command_status!(), " message only; it does not ", cli_command_download!(), ", ", cli_command_update!(), ", execute or remove files."), example: concat!(cli_command_subprojects!(), " ", cli_command_list!()) },
    Entry { path: concat!(cli_command_subprojects!(), " ", cli_command_list!()), detail: concat!("\n  List ", cli_command_subprojects!(), ".", "\n    Compatibility ", cli_command_status!(), " command: currently prints a ", cli_command_status!(), " message only; it does not ", cli_command_download!(), ", ", cli_command_update!(), ", execute or remove files."), example: concat!(cli_command_subprojects!(), " ", cli_command_list!()) },
    Entry { path: concat!(cli_command_subprojects!(), " ", cli_command_download!()), detail: concat!("\n  Download ", cli_command_subprojects!(), ".", "\n    Compatibility ", cli_command_status!(), " command: currently prints a ", cli_command_status!(), " message only; it does not ", cli_command_download!(), ", ", cli_command_update!(), ", execute or remove files."), example: concat!(cli_command_subprojects!(), " ", cli_command_download!()) },
    Entry { path: concat!(cli_command_subprojects!(), " ", cli_command_update!()), detail: concat!("\n  Update ", cli_command_subprojects!(), ".", "\n    Compatibility ", cli_command_status!(), " command: currently prints a ", cli_command_status!(), " message only; it does not ", cli_command_download!(), ", ", cli_command_update!(), ", execute or remove files."), example: concat!(cli_command_subprojects!(), " ", cli_command_update!()) },
    Entry { path: concat!(cli_command_subprojects!(), " ", cli_command_purge!()), detail: concat!("\n  Purge ", cli_command_subprojects!(), ".", "\n    Compatibility ", cli_command_status!(), " command: currently prints a ", cli_command_status!(), " message only; it does not ", cli_command_download!(), ", ", cli_command_update!(), ", execute or remove files."), example: concat!(cli_command_subprojects!(), " ", cli_command_purge!()) },
    Entry { path: concat!(cli_command_subprojects!(), " ", cli_command_checkout!()), detail: concat!("\n  Check out ", cli_command_subprojects!(), ".", "\n    Compatibility ", cli_command_status!(), " command: currently prints a ", cli_command_status!(), " message only; it does not ", cli_command_download!(), ", ", cli_command_update!(), ", execute or remove files."), example: concat!(cli_command_subprojects!(), " ", cli_command_checkout!()) },
    Entry { path: concat!(cli_command_subprojects!(), " ", cli_command_foreach!()), detail: concat!("\n  Run across ", cli_command_subprojects!(), ".", "\n    Compatibility ", cli_command_status!(), " command: currently prints a ", cli_command_status!(), " message only; it does not ", cli_command_download!(), ", ", cli_command_update!(), ", execute or remove files."), example: concat!(cli_command_subprojects!(), " ", cli_command_foreach!()) },
    Entry { path: concat!(cli_command_subprojects!(), " ", cli_command_packagefiles!()), detail: concat!("\n  Manage package files.", "\n    Compatibility ", cli_command_status!(), " command: currently prints a ", cli_command_status!(), " message only; it does not ", cli_command_download!(), ", ", cli_command_update!(), ", execute or remove files."), example: concat!(cli_command_subprojects!(), " ", cli_command_packagefiles!()) },
    Entry { path: cli_command_rewrite!(), detail: "\n  Modify project definition (not yet implemented).", example: cli_command_rewrite!() },
    Entry { path: cli_command_devenv!(), detail: concat!("[", cli_short_C!(), " DIR] [-- COMMAND...]\n  Run a development shell or command (default directory ., shell from SHELL).", "\n    ", cli_short_C!(), " selects the ", cli_command_build!(), " directory; COMMAND and its arguments follow --. Without COMMAND, start SHELL."), example: concat!(cli_command_devenv!(), " ", cli_short_C!(), " builddir -- echo hello") },
    Entry { path: cli_command_env2mfile!(), detail: "\n  Convert environment to machine file (not yet implemented).", example: cli_command_env2mfile!() },
    Entry { path: cli_command_format!(), detail: concat!("[", cli_short_i!(), "|", cli_long_inplace!(), "] [", cli_short_r!(), "|", cli_long_recursive!(), "] [FILE...]\n  Format Meson files (alias: ", cli_command_fmt!(), ").", "\n    FILE is optional and repeatable; ", cli_short_i!(), "/", cli_long_inplace!(), " writes files; ", cli_short_r!(), "/", cli_long_recursive!(), " walks directories."), example: concat!(cli_command_format!(), " meson.", cli_command_build!()) },
    Entry { path: concat!(cli_long_internal!(), " ", cli_command_exe!()), detail: concat!("[", cli_long_capture!(), " FILE] [", cli_long_feed!(), " FILE] [", cli_long_env!(), " KEY=VALUE]... -- COMMAND [ARG...]\n  Execute a generated ", cli_command_build!(), " command.", "\n    ", cli_long_capture!(), " redirects stdout to FILE; ", cli_long_feed!(), " reads stdin from FILE; ", cli_long_env!(), " KEY=VALUE supplies repeatable environment overrides; COMMAND after -- is required."), example: concat!(cli_long_internal!(), " ", cli_command_exe!(), " -- echo hello") },
    Entry { path: concat!(cli_long_internal!(), " ", cli_command_copy!()), detail: concat!("SOURCE DEST\n  Copy a file.", "\n    SOURCE and DEST are required paths."), example: concat!(cli_long_internal!(), " ", cli_command_copy!(), " input output") },
    Entry { path: concat!(cli_long_internal!(), " ", cli_command_static_link!()), detail: concat!("ARCHIVE -- ARCHIVER [ARG...]\n  Replace an archive using an archiver.", "\n    ARCHIVE and ARCHIVER are required. Arguments after -- are forwarded to the archiver."), example: concat!(cli_long_internal!(), " ", cli_command_static_link!(), " lib.a -- ar rcs lib.a object.o") },
];

pub const FOOTER: &str = include_str!("../../../owned-help.txt");

pub enum Page<'a> {
    Primary,
    Embedded,
    Command(&'a str),
}

pub fn reference(program: &str, page: Page<'_>) -> String {
    let selection = match page { Page::Command(name) => Some(name), _ => None };
    let primary = matches!(page, Page::Primary);
    let embedded = matches!(page, Page::Embedded);
    let common = concat!("Options:\n  ", cli_short_h!(), ", ", cli_long_help!(), "  Show ", cli_command_help!(), "\n  ", cli_long_version!(), "   Print ", cli_command_version!(), "\n");
    let mut out = format!("usage: {program} <command> [options]\n\n");
    if !embedded { out.push_str(common); }
    out.push_str("\nCommands:\n");
    for e in ENTRIES.iter().filter(|e| selection.is_none_or(|s| e.path == s || e.path.starts_with(&format!("{s} ")))) {
        out.push_str(&format!("  {program} {} {}\n", e.path, e.detail));
    }
    if selection.is_none() || matches!(selection, Some(cli_command_setup!() | cli_command_configure!())) {
        out.push_str("\nBuilt-in options for setup and configure (use --NAME VALUE or --NAME=VALUE):\n");
        let defaults = std::collections::HashMap::new();
        for key in crate::options::BUILTIN_OPTION_KEYS {
            let default = crate::options::builtin_default(key, &defaults)
                .map(|value| value.to_display_string())
                .unwrap_or_else(|_| "no built-in default".into());
            out.push_str(&format!("  --{} VALUE  Set {}; type {}; default: {}\n", key.replace('_', "-"), key, crate::options::builtin_option_kind(key), default));
        }
        out.push_str(&format!("  --{} VALUE  Alias for --warning-level\n", crate::options::WARNING_LEVEL_ALIAS));
    }
    out.push_str("\nEnvironment:\n  CC, CXX, OBJC, OBJCXX, AR  Select compiler and archiver commands\n  CPPFLAGS, CFLAGS, CXXFLAGS, OBJCFLAGS, OBJCXXFLAGS, LDFLAGS\n      Supply initial compile/link flags; machine files and project options also apply\n  DESTDIR  Installation staging root when --destdir is absent\n  SHELL  Development shell (default: /bin/sh)\n\nArguments marked [...] are optional; ... means repeatable. Flags are optional\nunless a command says otherwise. Options that take paths or names consume the\nnext argument even if it is -h or --help.\n");
    out.push_str("\nExamples:\n");
    for e in ENTRIES.iter().filter(|e| selection.is_none_or(|s| e.path == s || e.path.starts_with(&format!("{s} ")))) {
        out.push_str(&format!("  {program} {}\n", e.example));
    }
    if primary { out.push('\n'); out.push_str(FOOTER); } else if !embedded { out.push_str("\nSee meson --help for the complete reference.\n"); }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn builtin_help_uses_runtime_defaults_and_unique_commands() {
        let help = reference("meson", Page::Primary);
        for line in [
            "--localstatedir VALUE  Set localstatedir; type string; default: /var/local",
            "--debug VALUE  Set debug; type bool; default: true",
            "--backend VALUE  Set backend; type string; default: ninja",
        ] {
            assert!(help.contains(line), "missing {line}");
        }
        let mut paths = std::collections::HashSet::new();
        for entry in ENTRIES { assert!(paths.insert(entry.path), "duplicate {}", entry.path); }
    }
    #[test]
    fn examples_parse_without_executing_commands() {
        for entry in ENTRIES {
            let argv = std::iter::once("meson".to_owned()).chain(entry.example.split_whitespace().map(str::to_owned)).collect();
            let cli = crate::Cli::parse_args_from(argv);
            assert!(cli.example_matches(entry.path), "{}", entry.example);
        }
        assert!(crate::internal::parse_exe(&["--".into(), "echo".into(), "hello".into()]).is_ok());
    }
}

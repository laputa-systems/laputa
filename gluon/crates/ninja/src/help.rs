struct Tool { name: &'static str, args: &'static str, description: &'static str, example: &'static str }
const TOOLS: &[Tool] = &[
    Tool { name: cli_command_clean!(), args: concat!("[", cli_short_g!(), "] [", cli_short_r!(), "] [TARGET|RULE...]"), description: concat!("Remove outputs; ", cli_short_g!(), " includes generator outputs, ", cli_short_r!(), " selects rules."), example: concat!(cli_command_clean!(), " app") },
    Tool { name: cli_command_inputs!(), args: concat!("[", cli_long_dependency_order!(), "] [", cli_long_no_shell_escape!(), "] [", cli_long_print0!(), "] [TARGET...]"), description: concat!("List ", cli_command_inputs!(), " of targets."), example: concat!(cli_command_inputs!(), " app") },
    Tool { name: cli_command_multi_inputs!(), args: concat!("[", cli_long_print0!(), "] [", cli_short_d!(), " DELIMITER] [TARGET...]"), description: concat!("List ", cli_command_inputs!(), " for multiple targets."), example: concat!(cli_command_multi_inputs!(), " app") },
    Tool { name: cli_command_compdb_targets!(), args: concat!("[", cli_short_x!(), "] TARGET..."), description: "Write a compilation database for targets.", example: concat!(cli_command_compdb_targets!(), " app") },
    Tool { name: cli_command_graph_json!(), args: "[TARGET...]", description: "Write the build graph as JSON.", example: concat!(cli_command_graph_json!(), " app") },
    Tool { name: cli_command_recompact!(), args: "", description: "Recompact the build log.", example: cli_command_recompact!() },
    Tool { name: cli_command_restat!(), args: "", description: "Restat the build log.", example: cli_command_restat!() },
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
    let mut out = format!("usage: {program} [options] [TARGET...]\n\n");
    if !embedded { out.push_str(concat!("Common options:\n  ", cli_short_h!(), ", ", cli_long_help!(), "  Show help\n  ", cli_long_version!(), "  Print version\n\n")); }
    out.push_str(concat!("Options:\n  ", cli_short_C!(), " DIR           Change directory\n  ", cli_short_f!(), " FILE          Build file (default: build.ninja)\n  ", cli_short_j!(), " N             Parallel jobs (default: based on CPU count)\n  ", cli_short_k!(), " N             Stop after N failures (default: 1; 0 means unlimited)\n  ", cli_short_n!(), ", ", cli_long_dry_run!(), "    Do not run commands\n  ", cli_short_v!(), ", ", cli_long_verbose!(), "    Show commands\n  ", cli_long_quiet!(), "          Suppress progress\n  ", cli_short_d!(), " MODE          Enable debug mode (repeatable)\n  ", cli_short_t!(), " TOOL          Run a tool; remaining arguments belong to that tool\n\nTools:\n"));

    for tool in TOOLS.iter().filter(|t| selection.is_none_or(|s| s == t.name)) {
        out.push_str(&format!("  {program} -t {} {}\n    {}\n", tool.name, tool.args, tool.description));
    }
    out.push_str("\nTARGET is optional and repeatable; absent targets use manifest defaults.\nDebug mode explain prints rebuild reasons; other mode names are accepted.\nEnvironment:\n  MAKEFLAGS  Inherit the supported FIFO jobserver\n  NINJA_STATUS  Progress prefix (default: [%f/%t] )\n  TERM, CLICOLOR_FORCE  Terminal and color detection\n\nExamples:\n");
    if selection.is_none() { out.push_str(&format!("  {program} -C builddir app\n")); }
    for tool in TOOLS.iter().filter(|t| selection.is_none_or(|s| s == t.name)) {
        out.push_str(&format!("  {program} -t {}\n", tool.example));
    }
    if primary { out.push('\n'); out.push_str(FOOTER); } else if !embedded { out.push_str("\nSee ninja --help for the complete reference.\n"); }
    out
}

#[cfg(test)]
pub(crate) fn example_args(name: &str) -> Vec<String> {
    TOOLS.iter().find(|tool| tool.name == name).unwrap().example.split_whitespace().skip(1).map(str::to_owned).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn examples_parse_without_running_tools() {
        for tool in TOOLS {
            let argv = std::iter::once("ninja".to_owned()).chain(std::iter::once("-t".to_owned())).chain(tool.example.split_whitespace().map(str::to_owned)).collect::<Vec<_>>();
            let parsed = crate::cli::parse(&argv).unwrap();
            assert_eq!(parsed.tool.as_deref(), Some(tool.name));
            assert_eq!(parsed.tool_args, example_args(tool.name));
        }
    }
}

//! Built-in ninja subtools (`-t <name>`).
//!
//! Each tool lives in its own submodule. Dispatch happens here.

mod clean;
mod compdb_targets;
mod graph_json;
mod inputs;
mod multi_inputs;
mod recompact;

use crate::cli::Options;
use crate::graph::State;

pub fn run(name: &str, state: &State, opts: &Options) -> Result<u8, String> {
    match name {
        cli_command_recompact!() | cli_command_restat!() => recompact::run(),
        cli_command_inputs!() => inputs::run(state, &opts.tool_args),
        cli_command_multi_inputs!() => multi_inputs::run(state, &opts.tool_args),
        cli_command_compdb_targets!() => compdb_targets::run(state, &opts.tool_args),
        cli_command_graph_json!() => graph_json::run(state, &opts.tool_args),
        cli_command_clean!() => clean::run(state, &opts.tool_args),
        other => Err(format!("unknown tool: {other}")),
    }
}

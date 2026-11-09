#![allow(
    dead_code,
    unused_imports,
    unused_variables,
    unused_mut,
    unused_assignments,
    unknown_lints,
    suspicious_double_ref_op,
    clippy::empty_line_after_doc_comments,
    clippy::manual_map,
    clippy::needless_return,
    clippy::redundant_field_names,
    clippy::single_match,
    clippy::match_like_matches_macro,
    clippy::needless_borrow,
    clippy::collapsible_if,
    clippy::collapsible_else_if,
    clippy::too_many_arguments,
    clippy::type_complexity,
    clippy::ptr_arg,
    clippy::manual_strip,
    clippy::collapsible_str_replace,
    clippy::unnecessary_lazy_evaluations,
    clippy::map_clone,
    clippy::explicit_auto_deref,
    clippy::clone_on_copy,
    clippy::useless_format,
    clippy::len_zero,
    clippy::redundant_closure,
    clippy::iter_cloned_collect,
    clippy::unnecessary_to_owned,
    clippy::search_is_some,
    clippy::manual_flatten,
    clippy::or_fun_call,
    clippy::unnecessary_unwrap,
    clippy::derivable_impls,
    clippy::field_reassign_with_default,
    clippy::format_in_format_args,
    clippy::unnecessary_map_or,
    clippy::wildcard_in_or_patterns,
    clippy::if_same_then_else,
    clippy::enum_variant_names
)]

pub const VERSION: &str = "1.12.1";

pub mod ast;
pub mod backend;
pub mod builtins;
pub mod cli;
pub mod compiler;
pub mod compilers;
pub mod dependencies;
pub mod elf;
pub mod install;
pub mod internal;
pub mod interpreter;
pub mod lexer;
pub mod modules;
pub mod objects;
pub mod options;
pub mod parser;
pub mod vm;
pub mod wrap;

pub use cli::Cli;

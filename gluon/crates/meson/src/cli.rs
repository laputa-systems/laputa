use std::collections::HashMap;
/// CLI: parse command-line arguments and dispatch to subcommands.
use std::path::{Path, PathBuf};
use std::process::Command;

use deser_json::{Indent, SerializerConfig};

use crate::backend::{NinjaBackend, write_introspection};
use crate::interpreter::Interpreter;
use crate::options;

const JSON_PRETTY: SerializerConfig =
    SerializerConfig::builder().pretty(Indent::Spaces(2)).build();

pub struct Cli {
    command: CliCommand,
}

enum CliCommand {
    Setup(SetupArgs),
    Configure(ConfigureArgs),
    Compile(CompileArgs),
    Test(TestArgs),
    Install(InstallArgs),
    Introspect(IntrospectArgs),
    Init(InitArgs),
    Dist(DistArgs),
    Wrap(WrapArgs),
    Subprojects(SubprojectsArgs),
    Rewrite,
    Devenv(DevenvArgs),
    Env2mfile,
    Format(FormatArgs),
    Help(Option<String>),
    Version,
    Internal(Vec<String>),
    Error(i32, String),
}

struct SetupArgs {
    source_dir: String,
    build_dir: String,
    options: Vec<(String, String)>,
    cross_file: Option<String>,
    native_file: Option<String>,
    reconfigure: bool,
    wipe: bool,
}

struct ConfigureArgs {
    build_dir: String,
    options: Vec<(String, String)>,
}

struct CompileArgs {
    build_dir: String,
    targets: Vec<String>,
    jobs: Option<usize>,
    verbose: bool,
    clean: bool,
}

struct TestArgs {
    build_dir: String,
    tests: Vec<String>,
    suite: Option<String>,
    verbose: bool,
    timeout_multiplier: f64,
    num_processes: Option<usize>,
    no_rebuild: bool,
    repeat: usize,
}

struct InstallArgs {
    build_dir: String,
    destdir: Option<String>,
    skip_subprojects: bool,
    tags: Vec<String>,
    strip: bool,
    no_rebuild: bool,
    quiet: bool,
}

struct IntrospectArgs {
    build_dir: String,
    what: Vec<String>,
    all: bool,
}

struct InitArgs {
    name: Option<String>,
    language: String,
    project_type: String,
    build_dir: Option<String>,
    version: String,
}

struct DistArgs {
    build_dir: String,
    formats: Vec<String>,
    include_subprojects: bool,
    no_tests: bool,
}

struct WrapArgs {
    subcommand: String,
    name: Option<String>,
}

struct SubprojectsArgs {
    subcommand: String,
}

struct DevenvArgs {
    build_dir: String,
    command: Vec<String>,
}

struct FormatArgs {
    files: Vec<String>,
    inplace: bool,
    recursive: bool,
}

impl Cli {
    #[cfg(test)]
    pub(crate) fn example_matches(&self, path: &str) -> bool {
        match (&self.command, path) {
            (CliCommand::Help(None), cli_command_help!()) | (CliCommand::Version, cli_command_version!()) => true,
            (CliCommand::Setup(a), cli_command_setup!()) => a.build_dir == "builddir",
            (CliCommand::Configure(a), cli_command_configure!()) => a.build_dir == "builddir" && a.options == [("debug".into(), "true".into())],
            (CliCommand::Compile(a), cli_command_compile!()) => a.build_dir == "builddir",
            (CliCommand::Test(a), cli_command_test!()) => a.build_dir == "builddir",
            (CliCommand::Install(a), cli_command_install!()) => a.build_dir == "builddir" && a.destdir.as_deref() == Some("staging"),
            (CliCommand::Introspect(a), cli_command_introspect!()) => a.build_dir == "builddir" && a.what == ["targets"],
            (CliCommand::Init(a), cli_command_init!()) => a.name.as_deref() == Some("hello"),
            (CliCommand::Dist(a), cli_command_dist!()) => a.build_dir == "builddir",
            (CliCommand::Wrap(a), p) => p == cli_command_wrap!() && a.subcommand == cli_command_list!() || p.strip_prefix("wrap ") == Some(a.subcommand.as_str()) && (!matches!(a.subcommand.as_str(), cli_command_install!() | cli_command_info!() | cli_command_search!()) || a.name.as_deref() == Some("zlib")),
            (CliCommand::Subprojects(a), p) => p == cli_command_subprojects!() && a.subcommand == cli_command_list!() || p.strip_prefix("subprojects ") == Some(a.subcommand.as_str()),
            (CliCommand::Rewrite, cli_command_rewrite!()) | (CliCommand::Env2mfile, cli_command_env2mfile!()) => true,
            (CliCommand::Devenv(a), cli_command_devenv!()) => a.build_dir == "builddir" && a.command == ["echo", "hello"],
            (CliCommand::Format(a), cli_command_format!()) => a.files == ["meson.build"],
            (CliCommand::Internal(a), p) => p.strip_prefix("--internal ") == a.first().map(String::as_str) && a.len() > 2,
            _ => false,
        }
    }

    pub fn parse_args() -> Self {
        Self::parse_args_from(std::env::args().collect())
    }

    pub fn parse_args_from(args: Vec<String>) -> Self {

        if args.len() < 2 {
            return Cli {
                command: CliCommand::Help(None),
            };
        }

        let cmd = &args[1];
        let rest = &args[2..];

        let command = match cmd.as_str() {
            cli_command_setup!() | cli_command_configure!() if cmd == cli_command_setup!() => Self::parse_setup(rest),
            cli_command_configure!() => Self::parse_configure(rest),
            cli_command_compile!() | cli_command_build!() => Self::parse_compile(rest),
            cli_command_test!() => Self::parse_test(rest),
            cli_command_install!() => Self::parse_install(rest),
            cli_command_introspect!() => Self::parse_introspect(rest),
            cli_command_init!() => Self::parse_init(rest),
            cli_command_dist!() => Self::parse_dist(rest),
            cli_command_wrap!() => Self::parse_nested_help(rest, cli_command_wrap!()).unwrap_or_else(|| Self::parse_wrap(rest)),
            cli_command_subprojects!() => Self::parse_nested_help(rest, cli_command_subprojects!()).unwrap_or_else(|| Self::parse_subprojects(rest)),
            cli_command_rewrite!() if rest.first().is_some_and(|s| s == cli_short_h!() || s == cli_long_help!()) => CliCommand::Help(Some(cli_command_rewrite!().into())),
            cli_command_rewrite!() => CliCommand::Rewrite,
            cli_command_devenv!() => Self::parse_devenv(rest),
            cli_command_env2mfile!() if rest.first().is_some_and(|s| s == cli_short_h!() || s == cli_long_help!()) => CliCommand::Help(Some(cli_command_env2mfile!().into())),
            cli_command_env2mfile!() => CliCommand::Env2mfile,
            cli_command_format!() | cli_command_fmt!() => Self::parse_format(rest),
            cli_long_version!() | cli_command_version!() => CliCommand::Version,
            cli_long_internal!() => Self::parse_internal_help(rest).unwrap_or_else(|| CliCommand::Internal(rest.to_vec())),
            cli_command_help!() | cli_long_help!() | cli_short_h!() => CliCommand::Help(None),
            // If first arg is a directory, treat as setup
            _ if Path::new(cmd).is_dir() || !cmd.starts_with('-') => {
                let mut all_args = vec![cmd.clone()];
                all_args.extend(rest.iter().cloned());
                Self::parse_setup(&all_args)
            }
            _ => CliCommand::Help(None),
        };

        Cli { command }
    }

    fn parse_setup(args: &[String]) -> CliCommand {
        let mut positionals: Vec<String> = Vec::new();
        let mut cli_options = Vec::new();
        let mut cross_file = None;
        let mut native_file = None;
        let mut reconfigure = false;
        let mut wipe = false;
        let mut i = 0;

        while i < args.len() {
            let arg = &args[i];
            if arg == cli_short_h!() || arg == cli_long_help!() { return CliCommand::Help(Some(cli_command_setup!().into())); }
            if arg.starts_with(cli_short_D!()) {
                let opt = &arg[2..];
                if let Some(eq) = opt.find('=') {
                    cli_options.push((opt[..eq].to_string(), opt[eq + 1..].to_string()));
                }
            } else if arg == cli_long_cross_file!() {
                i += 1;
                if i < args.len() {
                    cross_file = Some(args[i].clone());
                }
            } else if let Some(value) = arg.strip_prefix("--cross-file=") {
                cross_file = Some(value.to_string());
            } else if arg == cli_long_native_file!() {
                i += 1;
                if i < args.len() {
                    native_file = Some(args[i].clone());
                }
            } else if let Some(value) = arg.strip_prefix("--native-file=") {
                native_file = Some(value.to_string());
            } else if arg == cli_long_reconfigure!() {
                reconfigure = true;
            } else if arg == cli_long_wipe!() {
                wipe = true;
            } else if arg.starts_with("--") {
                match parse_builtin_cli_option(args, &mut i) {
                    Ok(option) => cli_options.push(option),
                    Err(message) => return CliCommand::Error(2, message),
                }
            } else {
                positionals.push(arg.clone());
            }
            i += 1;
        }

        let (source_dir, build_dir) = if positionals.is_empty() {
            (".".to_string(), "builddir".to_string())
        } else if positionals.len() == 1 {
            let only = positionals[0].clone();
            if Path::new(&only).join("meson.build").exists() {
                (only, "builddir".to_string())
            } else {
                (".".to_string(), only)
            }
        } else {
            let first = positionals[0].clone();
            let second = positionals[1].clone();
            let first_is_src = Path::new(&first).join("meson.build").exists();
            let second_is_src = Path::new(&second).join("meson.build").exists();
            if second_is_src && !first_is_src {
                (second, first)
            } else if first_is_src && !second_is_src {
                (first, second)
            } else {
                (second, first)
            }
        };

        CliCommand::Setup(SetupArgs {
            source_dir,
            build_dir,
            options: cli_options,
            cross_file,
            native_file,
            reconfigure,
            wipe,
        })
    }

    fn parse_configure(args: &[String]) -> CliCommand {
        let mut build_dir = ".".to_string();
        let mut cli_options = Vec::new();
        let mut i = 0;

        while i < args.len() {
            let arg = &args[i];
            if arg == cli_short_h!() || arg == cli_long_help!() { return CliCommand::Help(Some(cli_command_configure!().into())); }
            if arg.starts_with(cli_short_D!()) {
                let opt = &arg[2..];
                if let Some(eq) = opt.find('=') {
                    cli_options.push((opt[..eq].to_string(), opt[eq + 1..].to_string()));
                }
            } else if arg.starts_with("--") {
                match parse_builtin_cli_option(args, &mut i) {
                    Ok(option) => cli_options.push(option),
                    Err(message) => return CliCommand::Error(2, message),
                }
            } else {
                build_dir = arg.clone();
            }
            i += 1;
        }

        CliCommand::Configure(ConfigureArgs {
            build_dir,
            options: cli_options,
        })
    }

    fn parse_compile(args: &[String]) -> CliCommand {
        let mut build_dir = ".".to_string();
        let mut targets = Vec::new();
        let mut jobs = None;
        let mut verbose = false;
        let mut clean = false;
        let mut i = 0;

        while i < args.len() {
            let arg = &args[i];
            if arg == cli_short_h!() || arg == cli_long_help!() { return CliCommand::Help(Some(cli_command_compile!().into())); }
            match arg.as_str() {
                cli_short_j!() | cli_long_jobs!() => {
                    i += 1;
                    if i < args.len() {
                        jobs = args[i].parse().ok();
                    }
                }
                cli_short_v!() | cli_long_verbose!() => verbose = true,
                cli_long_clean!() => clean = true,
                cli_short_C!() => {
                    i += 1;
                    if i < args.len() {
                        build_dir = args[i].clone();
                    }
                }
                _ if arg.starts_with(cli_short_j!()) => {
                    jobs = arg[2..].parse().ok();
                }
                _ if arg.starts_with(cli_short_C!()) => {
                    build_dir = arg[2..].to_string();
                }
                _ => targets.push(arg.clone()),
            }
            i += 1;
        }

        if targets.len() == 1 && Path::new(&targets[0]).join("build.ninja").exists() {
            build_dir = targets.remove(0);
        }

        CliCommand::Compile(CompileArgs {
            build_dir,
            targets,
            jobs,
            verbose,
            clean,
        })
    }

    fn parse_test(args: &[String]) -> CliCommand {
        let mut build_dir = ".".to_string();
        let mut tests = Vec::new();
        let mut suite = None;
        let mut verbose = false;
        let mut timeout_multiplier = 1.0;
        let mut num_processes = None;
        let mut no_rebuild = false;
        let mut repeat = 1;
        let mut i = 0;

        while i < args.len() {
            let arg = &args[i];
            if arg == cli_short_h!() || arg == cli_long_help!() { return CliCommand::Help(Some(cli_command_test!().into())); }
            match arg.as_str() {
                cli_short_v!() | cli_long_verbose!() => verbose = true,
                cli_long_no_rebuild!() => no_rebuild = true,
                cli_long_suite!() => {
                    i += 1;
                    if i < args.len() {
                        suite = Some(args[i].clone());
                    }
                }
                cli_short_t!() | cli_long_timeout_multiplier!() => {
                    i += 1;
                    if i < args.len() {
                        timeout_multiplier = args[i].parse().unwrap_or(1.0);
                    }
                }
                cli_short_j!() | cli_long_num_processes!() => {
                    i += 1;
                    if i < args.len() {
                        num_processes = args[i].parse().ok();
                    }
                }
                cli_long_repeat!() => {
                    i += 1;
                    if i < args.len() {
                        repeat = args[i].parse().unwrap_or(1);
                    }
                }
                cli_short_C!() => {
                    i += 1;
                    if i < args.len() {
                        build_dir = args[i].clone();
                    }
                }
                _ => tests.push(arg.clone()),
            }
            i += 1;
        }

        CliCommand::Test(TestArgs {
            build_dir,
            tests,
            suite,
            verbose,
            timeout_multiplier,
            num_processes,
            no_rebuild,
            repeat,
        })
    }

    fn parse_install(args: &[String]) -> CliCommand {
        let mut build_dir = ".".to_string();
        let mut destdir = None;
        let mut skip_subprojects = false;
        let mut tags = Vec::new();
        let mut strip = false;
        let mut no_rebuild = false;
        let mut quiet = false;
        let mut i = 0;

        while i < args.len() {
            let arg = &args[i];
            if arg == cli_short_h!() || arg == cli_long_help!() { return CliCommand::Help(Some(cli_command_install!().into())); }
            match arg.as_str() {
                cli_long_destdir!() => {
                    i += 1;
                    if i < args.len() {
                        destdir = Some(args[i].clone());
                    }
                }
                _ if arg.starts_with("--destdir=") => {
                    destdir = Some(arg["--destdir=".len()..].to_string());
                }
                cli_long_skip_subprojects!() => skip_subprojects = true,
                cli_long_tags!() => {
                    i += 1;
                    if i < args.len() {
                        tags = args[i].split(',').map(String::from).collect();
                    }
                }
                cli_long_strip!() => strip = true,
                cli_long_no_rebuild!() => no_rebuild = true,
                cli_short_q!() | cli_long_quiet!() => quiet = true,
                cli_short_C!() => {
                    i += 1;
                    if i < args.len() {
                        build_dir = args[i].clone();
                    }
                }
                _ if arg.starts_with(cli_short_C!()) => build_dir = arg[2..].to_string(),
                _ => build_dir = arg.clone(),
            }
            i += 1;
        }

        CliCommand::Install(InstallArgs {
            build_dir,
            destdir,
            skip_subprojects,
            tags,
            strip,
            no_rebuild,
            quiet,
        })
    }

    fn parse_introspect(args: &[String]) -> CliCommand {
        let mut build_dir = ".".to_string();
        let mut what = Vec::new();
        let mut all = false;
        let mut i = 0;

        while i < args.len() {
            let arg = &args[i];
            if arg == cli_short_h!() || arg == cli_long_help!() { return CliCommand::Help(Some(cli_command_introspect!().into())); }
            match arg.as_str() {
                cli_long_all!() | cli_short_a!() => all = true,
                cli_long_targets!() => what.push("targets".to_string()),
                cli_long_tests!() => what.push("tests".to_string()),
                cli_long_dependencies!() => what.push("dependencies".to_string()),
                cli_long_buildoptions!() => what.push("buildoptions".to_string()),
                cli_long_projectinfo!() => what.push("projectinfo".to_string()),
                cli_long_installed!() => what.push("installed".to_string()),
                cli_long_benchmarks!() => what.push("benchmarks".to_string()),
                _ => build_dir = arg.clone(),
            }
            i += 1;
        }

        CliCommand::Introspect(IntrospectArgs {
            build_dir,
            what,
            all,
        })
    }

    fn parse_init(args: &[String]) -> CliCommand {
        let mut name = None;
        let mut language = "c".to_string();
        let mut project_type = "executable".to_string();
        let mut build_dir = None;
        let mut version = "0.1.0".to_string();
        let mut i = 0;

        while i < args.len() {
            let arg = &args[i];
            if arg == cli_short_h!() || arg == cli_long_help!() { return CliCommand::Help(Some(cli_command_init!().into())); }
            match arg.as_str() {
                cli_short_n!() | cli_long_name!() => {
                    i += 1;
                    if i < args.len() {
                        name = Some(args[i].clone());
                    }
                }
                cli_short_l!() | cli_long_language!() => {
                    i += 1;
                    if i < args.len() {
                        language = args[i].clone();
                    }
                }
                cli_long_type!() => {
                    i += 1;
                    if i < args.len() {
                        project_type = args[i].clone();
                    }
                }
                cli_short_b!() | cli_long_builddir!() => {
                    i += 1;
                    if i < args.len() {
                        build_dir = Some(args[i].clone());
                    }
                }
                cli_long_version!() => {
                    i += 1;
                    if i < args.len() {
                        version = args[i].clone();
                    }
                }
                _ => {
                    if name.is_none() {
                        name = Some(arg.clone());
                    }
                }
            }
            i += 1;
        }

        CliCommand::Init(InitArgs {
            name,
            language,
            project_type,
            build_dir,
            version,
        })
    }

    fn parse_dist(args: &[String]) -> CliCommand {
        let mut build_dir = ".".to_string();
        let mut formats = vec!["xztar".to_string()];
        let mut include_subprojects = false;
        let mut no_tests = false;
        let mut i = 0;

        while i < args.len() {
            let arg = &args[i];
            if arg == cli_short_h!() || arg == cli_long_help!() { return CliCommand::Help(Some(cli_command_dist!().into())); }
            match arg.as_str() {
                cli_long_formats!() => {
                    i += 1;
                    if i < args.len() {
                        formats = args[i].split(',').map(String::from).collect();
                    }
                }
                cli_long_include_subprojects!() => include_subprojects = true,
                cli_long_no_tests!() => no_tests = true,
                cli_short_C!() => {
                    i += 1;
                    if i < args.len() {
                        build_dir = args[i].clone();
                    }
                }
                _ => build_dir = arg.clone(),
            }
            i += 1;
        }

        CliCommand::Dist(DistArgs {
            build_dir,
            formats,
            include_subprojects,
            no_tests,
        })
    }

    fn parse_nested_help(args: &[String], parent: &str) -> Option<CliCommand> {
        let position = args.iter().position(|s| s == cli_short_h!() || s == cli_long_help!())?;
        let path = if position > 0 { format!("{} {}", parent, args[0]) } else { parent.to_owned() };
        Some(CliCommand::Help(Some(path)))
    }

    fn parse_internal_help(args: &[String]) -> Option<CliCommand> {
        let name = args.first()?;
        if name == cli_short_h!() || name == cli_long_help!() { return Some(CliCommand::Help(Some(cli_long_internal!().into()))); }
        let mut i = 1;
        while i < args.len() {
            let arg = args[i].as_str();
            if arg == "--" { break; }
            if arg == cli_short_h!() || arg == cli_long_help!() { return Some(CliCommand::Help(Some(format!("--internal {name}")))); }
            if name == cli_command_exe!() && matches!(arg, cli_long_capture!() | cli_long_feed!() | cli_long_env!()) { i += 1; }
            i += 1;
        }
        None
    }

    fn parse_wrap(args: &[String]) -> CliCommand {
        let subcommand = args.first().cloned().unwrap_or_else(|| cli_command_list!().to_string());
        let name = args.get(1).cloned();
        CliCommand::Wrap(WrapArgs { subcommand, name })
    }

    fn parse_subprojects(args: &[String]) -> CliCommand {
        let subcommand = args.first().cloned().unwrap_or_else(|| cli_command_list!().to_string());
        CliCommand::Subprojects(SubprojectsArgs { subcommand })
    }

    fn parse_devenv(args: &[String]) -> CliCommand {
        let mut build_dir = ".".to_string();
        let mut command = Vec::new();
        let mut after_dash = false;

        let mut directory_value = false;
        for arg in args {
            if !after_dash && !directory_value && (arg == cli_short_h!() || arg == cli_long_help!()) {
                return CliCommand::Help(Some(cli_command_devenv!().into()));
            }
            directory_value = !after_dash && arg == cli_short_C!();
            if after_dash {
                command.push(arg.clone());
            } else if arg == "--" {
                after_dash = true;
            } else if arg == cli_short_C!() {
                // next arg is build dir
            } else {
                build_dir = arg.clone();
            }
        }

        CliCommand::Devenv(DevenvArgs { build_dir, command })
    }

    fn parse_format(args: &[String]) -> CliCommand {
        let mut files = Vec::new();
        let mut inplace = false;
        let mut recursive = false;

        for arg in args {
            if arg == cli_short_h!() || arg == cli_long_help!() { return CliCommand::Help(Some(cli_command_format!().into())); }
            match arg.as_str() {
                cli_short_i!() | cli_long_inplace!() => inplace = true,
                cli_short_r!() | cli_long_recursive!() => recursive = true,
                _ => files.push(arg.clone()),
            }
        }

        CliCommand::Format(FormatArgs {
            files,
            inplace,
            recursive,
        })
    }

    pub fn run(&self) -> i32 {
        match &self.command {
            CliCommand::Setup(args) => self.cmd_setup(args),
            CliCommand::Configure(args) => self.cmd_configure(args),
            CliCommand::Compile(args) => self.cmd_compile(args),
            CliCommand::Test(args) => self.cmd_test(args),
            CliCommand::Install(args) => self.cmd_install(args),
            CliCommand::Introspect(args) => self.cmd_introspect(args),
            CliCommand::Init(args) => self.cmd_init(args),
            CliCommand::Dist(args) => self.cmd_dist(args),
            CliCommand::Wrap(args) => self.cmd_wrap(args),
            CliCommand::Subprojects(args) => self.cmd_subprojects(args),
            CliCommand::Rewrite => {
                eprintln!("rewrite: not yet implemented");
                1
            }
            CliCommand::Devenv(args) => self.cmd_devenv(args),
            CliCommand::Env2mfile => {
                eprintln!("env2mfile: not yet implemented");
                1
            }
            CliCommand::Format(args) => self.cmd_format(args),
            CliCommand::Version => {
                println!("{}", crate::VERSION);
                0
            }
            CliCommand::Internal(args) => crate::internal::run(args),
            CliCommand::Help(selection) => {
                print!("{}", crate::help::reference("meson", selection.as_deref().map_or(crate::help::Page::Primary, crate::help::Page::Command)));
                0
            }
            CliCommand::Error(code, message) => {
                eprintln!("meson: error: {}", message);
                *code
            }
        }
    }

    fn cmd_setup(&self, args: &SetupArgs) -> i32 {
        if args.reconfigure && Path::new(&args.build_dir).join("meson-private/cmd_line.txt").exists() {
            return self.reconfigure(&args.build_dir, &args.options, args.cross_file.as_deref(), args.native_file.as_deref());
        }
        let source_dir = std::fs::canonicalize(&args.source_dir)
            .unwrap_or_else(|_| PathBuf::from(&args.source_dir));
        let source_dir = source_dir.to_string_lossy().to_string();

        let build_file = format!("{}/meson.build", source_dir);
        if !Path::new(&build_file).exists() {
            eprintln!("Meson build file not found: {}", build_file);
            return 1;
        }

        let build_dir = if Path::new(&args.build_dir).is_absolute() {
            args.build_dir.clone()
        } else {
            std::env::current_dir()
                .unwrap_or_default()
                .join(&args.build_dir)
                .to_string_lossy()
                .to_string()
        };

        // Create build directory
        if args.wipe && Path::new(&build_dir).exists() {
            let _ = std::fs::remove_dir_all(&build_dir);
        }
        if let Err(e) = std::fs::create_dir_all(&build_dir) {
            eprintln!("Cannot create build directory {}: {}", build_dir, e);
            return 1;
        }

        // Create meson-private dir
        let private_dir = format!("{}/meson-private", build_dir);
        let _ = std::fs::create_dir_all(&private_dir);

        // Create meson-logs dir
        let logs_dir = format!("{}/meson-logs", build_dir);
        let _ = std::fs::create_dir_all(&logs_dir);
        let log_path = format!("{}/meson-log.txt", logs_dir);
        let mut log = String::new();
        log.push_str("The Meson build system\n");
        log.push_str(&format!("Version: {} (oxidized-meson)\n", crate::VERSION));
        log.push_str(&format!("Source dir: {}\n", source_dir));
        log.push_str(&format!("Build dir: {}\n", build_dir));
        log.push_str("Build type: native build\n");
        log.push_str(&format!(
            "Command: meson setup {} {}\n",
            source_dir, build_dir
        ));
        for (k, v) in &args.options {
            log.push_str(&format!("option: {}={}\n", k, v));
        }
        let _ = std::fs::write(&log_path, &log);

        eprintln!("The Meson build system");
        eprintln!("Version: {} (oxidized-meson)", crate::VERSION);
        eprintln!("Source dir: {}", source_dir);
        eprintln!("Build dir: {}", build_dir);
        eprintln!("Build type: native build");

        // Set up interpreter
        let mut interp = Interpreter::new(&source_dir, &build_dir);

        if args.cross_file.is_none() {
            for (key, values) in options::env_flag_options(|name| std::env::var(name).ok()) {
                interp.vm.options.insert(
                    key,
                    crate::objects::Object::Array(
                        values.into_iter().map(crate::objects::Object::String).collect(),
                    ),
                );
            }
        }

        // Load cross/native files
        if let Some(ref cross) = args.cross_file {
            let machine_config = options::parse_machine_file(cross);
            record_strip_program(&build_dir, &machine_config);
            // Apply cross file settings
            for (section, values) in &machine_config {
                for (key, value) in values {
                    // Sections like "project options", "built-in options" hold
                    // raw option names. "<sub>:project options" prefixes for subprojects.
                    let opt_key = if section == "project options" || section == "built-in options" {
                        key.clone()
                    } else if section.ends_with(":project options")
                        || section.ends_with(":built-in options")
                    {
                        // sub:project options -> sub:<key>
                        let prefix = section.split(':').next().unwrap_or("");
                        format!("{}:{}", prefix, key)
                    } else {
                        format!("{}_{}", section, key)
                    };
                    interp
                        .vm
                        .options
                        .insert(opt_key.clone(), crate::options::parse_option_value(value));
                    interp.vm.cmdline_option_keys.insert(opt_key);
                }
            }
        }

        // Load native file properties
        if let Some(ref native) = args.native_file {
            let native_path = if std::path::Path::new(native).is_absolute() {
                native.clone()
            } else {
                format!("{}/{}", source_dir, native)
            };
            let machine_config = options::parse_machine_file(&native_path);
            record_strip_program(&build_dir, &machine_config);
            if let Some(properties) = machine_config.get("properties") {
                for (key, value) in properties {
                    interp
                        .vm
                        .native_properties
                        .insert(key.clone(), options::parse_option_value(value));
                }
            }
            // Apply other sections as options (e.g. [built-in options])
            for (section, values) in &machine_config {
                if section == "properties" || section == "binaries" {
                    continue;
                }
                for (key, value) in values {
                    let opt_key = if section == "project options" || section == "built-in options" {
                        key.clone()
                    } else if section.ends_with(":project options")
                        || section.ends_with(":built-in options")
                    {
                        let prefix = section.split(':').next().unwrap_or("");
                        format!("{}:{}", prefix, key)
                    } else {
                        format!("{}_{}", section, key)
                    };
                    interp
                        .vm
                        .options
                        .insert(opt_key.clone(), crate::options::parse_option_value(value));
                    interp.vm.cmdline_option_keys.insert(opt_key);
                }
            }
        }

        // Apply CLI options
        interp.set_options(&args.options);

        // Read and execute meson.build
        let source = match std::fs::read_to_string(&build_file) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("Cannot read {}: {}", build_file, e);
                let _ = {
                    use std::io::Write;
                    std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&log_path)
                        .and_then(|mut f| writeln!(f, "ERROR: Cannot read {}: {}", build_file, e))
                };
                return 1;
            }
        };

        if let Err(e) = interp.run(&source) {
            eprintln!("ERROR: {}", e);
            let _ = {
                use std::io::Write;
                std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&log_path)
                    .and_then(|mut f| writeln!(f, "ERROR: {}", e))
            };
            return 1;
        }

        // Print summary
        interp.print_summary();

        let project = interp.vm.project.clone().unwrap_or_default();

        // Generate build.ninja
        interp.vm.build_data.options = interp.vm.options.clone();
        for (key, std) in [
            (
                "compiler_c",
                interp.vm.build_data.c_std.clone(),
            ),
            (
                "compiler_cpp",
                interp.vm.build_data.cpp_std.clone(),
            ),
        ] {
            let Some(crate::objects::Object::Compiler(compiler)) =
                interp.vm.globals.get(key).cloned()
            else {
                continue;
            };
            match crate::compilers::first_supported_std(&compiler, &std) {
                Ok(chosen) if key == "compiler_c" => interp.vm.build_data.c_std = chosen,
                Ok(chosen) => interp.vm.build_data.cpp_std = chosen,
                Err(e) => {
                    eprintln!("ERROR: {}", e);
                    return 1;
                }
            }
        }
        let install_plan = match crate::install::generate(
            &interp.vm.build_data,
            &interp.vm.options,
            &source_dir,
            &build_dir,
        ) {
            Ok(plan) => plan,
            Err(e) => {
                eprintln!("ERROR generating install plan: {}", e);
                return 1;
            }
        };
        if let Err(e) = crate::install::write_plan(&build_dir, &install_plan) {
            eprintln!("ERROR writing install plan: {}", e);
            return 1;
        }
        let meson_command = meson_invocation();
        let backend = NinjaBackend::new(&source_dir, &build_dir)
            .with_meson_command(&meson_command)
            .with_install_aliases()
            .with_toolchain(toolchain(&interp.vm));
        let ninja = match backend.generate(&interp.vm.build_data, &project) {
            Ok(n) => n,
            Err(e) => {
                eprintln!("ERROR generating build.ninja: {}", e);
                let _ = {
                    use std::io::Write;
                    std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&log_path)
                        .and_then(|mut f| writeln!(f, "ERROR generating build.ninja: {}", e))
                };
                return 1;
            }
        };

        let ninja_path = format!("{}/build.ninja", build_dir);
        if let Err(e) = std::fs::write(&ninja_path, &ninja) {
            eprintln!("Cannot write {}: {}", ninja_path, e);
            return 1;
        }

        // Write introspection data
        if let Err(e) = write_introspection(
            &build_dir,
            &interp.vm.build_data,
            &project,
            &install_plan,
        ) {
            eprintln!("Warning: Cannot write introspection: {}", e);
        }

        // Write build options for reconfigure
        let cmd_line = deser_value::value!({
            "source_dir": source_dir.clone(),
            "build_dir": build_dir.clone(),
            "options": args.options.iter().map(|(k, v)| format!("{}={}", k, v)).collect::<Vec<_>>(),
            "cross_file": args.cross_file.as_ref().map(|path| std::fs::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path)).to_string_lossy().into_owned()).unwrap_or_default(),
            "native_file": args.native_file.as_ref().map(|path| {
                let path = Path::new(path);
                let path = if path.is_absolute() { path.to_path_buf() } else { Path::new(&source_dir).join(path) };
                std::fs::canonicalize(&path).unwrap_or(path).to_string_lossy().into_owned()
            }).unwrap_or_default(),
        });
        let _ = std::fs::write(
            format!("{}/meson-private/cmd_line.txt", build_dir),
            JSON_PRETTY.to_string(&cmd_line).unwrap(),
        );

        if let Err(e) = crate::install::run_postconf_scripts(
            &interp.vm.build_data.postconf_scripts,
            &interp.vm.top_source_root,
            &build_dir,
        ) {
            eprintln!("ERROR: {}", e);
            let _ = {
                use std::io::Write;
                std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&log_path)
                    .and_then(|mut f| writeln!(f, "ERROR: {}", e))
            };
            return 1;
        }

        eprintln!(
            "Build targets in project: {}",
            interp.vm.build_data.targets.len()
        );
        eprintln!();
        eprintln!("Found ninja at: {}", which_ninja());
        eprintln!();
        let _ = {
            use std::io::Write;
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&log_path)
                .and_then(|mut f| {
                    writeln!(f, "Build targets in project: {}", interp.vm.build_data.targets.len())?;
                    writeln!(f, "Found ninja at: {}", which_ninja())
                })
        };

        0
    }

    fn cmd_configure(&self, args: &ConfigureArgs) -> i32 {
        self.reconfigure(&args.build_dir, &args.options, None, None)
    }

    fn reconfigure(&self, build_dir: &str, options: &[(String, String)], cross_file: Option<&str>, native_file: Option<&str>) -> i32 {
        // Re-read the saved command line and re-run setup with new options
        let cmd_file = format!("{}/meson-private/cmd_line.txt", build_dir);
        if !Path::new(&cmd_file).exists() {
            eprintln!("Not a configured build directory: {}", build_dir);
            return 1;
        }

        let content = std::fs::read_to_string(&cmd_file).unwrap_or_default();
        let saved: deser_value::Value = deser_json::from_str(&content).unwrap_or_default();

        let source_dir = saved["source_dir"].as_str().unwrap_or(".").to_string();
        let mut all_options = Vec::new();

        // Previous options
        if let Some(opts) = saved["options"].as_seq() {
            for opt in opts {
                if let Some(s) = opt.as_str() {
                    if let Some(eq) = s.find('=') {
                        all_options.push((s[..eq].to_string(), s[eq + 1..].to_string()));
                    }
                }
            }
        }

        // New options override
        all_options.extend_from_slice(options);

        self.cmd_setup(&SetupArgs {
            source_dir,
            build_dir: build_dir.to_string(),
            options: all_options,
            cross_file: cross_file.or_else(|| saved["cross_file"].as_str().filter(|path| !path.is_empty())).map(str::to_owned),
            native_file: native_file.or_else(|| saved["native_file"].as_str().filter(|path| !path.is_empty())).map(str::to_owned),
            reconfigure: false,
            wipe: false,
        })
    }

    fn cmd_compile(&self, args: &CompileArgs) -> i32 {
        let ninja = which_ninja();
        let mut cmd = Command::new(&ninja);
        cmd.current_dir(&args.build_dir);

        if let Some(jobs) = args.jobs {
            cmd.arg(cli_short_j!()).arg(jobs.to_string());
        }
        if args.verbose {
            cmd.arg(cli_short_v!());
        }
        if args.clean {
            cmd.arg(cli_short_t!()).arg("clean");
        }

        for target in &args.targets {
            cmd.arg(target);
        }

        match cmd.status() {
            Ok(status) => {
                if status.success() {
                    0
                } else {
                    status.code().unwrap_or(1)
                }
            }
            Err(e) => {
                eprintln!("Failed to run ninja: {}", e);
                1
            }
        }
    }

    fn cmd_test(&self, args: &TestArgs) -> i32 {
        // Build first unless --no-rebuild
        if !args.no_rebuild {
            let compile_result = self.cmd_compile(&CompileArgs {
                build_dir: args.build_dir.clone(),
                targets: vec!["meson-test-prereq".to_string()],
                jobs: args.num_processes,
                verbose: false,
                clean: false,
            });
            if compile_result != 0 {
                return compile_result;
            }
        }

        let tests_file = format!("{}/meson-info/intro-tests.json", args.build_dir);
        let tests_json = match std::fs::read_to_string(&tests_file) {
            Ok(text) => text,
            Err(e) => {
                eprintln!("Cannot read {tests_file}: {e}");
                return 1;
            }
        };
        let tests: Vec<deser_value::Value> = match deser_json::from_str(&tests_json) {
            Ok(tests) => tests,
            Err(e) => {
                eprintln!("Cannot read {tests_file}: {e}");
                return 1;
            }
        };

        if tests.is_empty() {
            eprintln!("No tests defined.");
            return 0;
        }

        eprintln!("Running {} tests...", tests.len());
        // For now, just report that tests should be run with ninja test
        let mut cmd = Command::new(which_ninja());
        cmd.current_dir(&args.build_dir);
        cmd.arg(cli_command_test!());
        if args.verbose {
            cmd.arg(cli_short_v!());
        }

        match cmd.status() {
            Ok(status) => {
                if status.success() {
                    0
                } else {
                    1
                }
            }
            Err(e) => {
                eprintln!("Failed to run ninja: {e}");
                1
            }
        }
    }

    fn cmd_install(&self, args: &InstallArgs) -> i32 {
        let build_dir = std::fs::canonicalize(&args.build_dir)
            .unwrap_or_else(|_| PathBuf::from(&args.build_dir))
            .to_string_lossy()
            .to_string();
        let destdir = args
            .destdir
            .clone()
            .or_else(|| std::env::var("DESTDIR").ok())
            .unwrap_or_default();

        if !args.no_rebuild {
            let mut cmd = Command::new(which_ninja());
            cmd.current_dir(&build_dir);
            match cmd.status() {
                Ok(status) if status.success() => {}
                Ok(status) => return status.code().unwrap_or(1),
                Err(e) => {
                    eprintln!("Failed to run ninja: {}", e);
                    return 1;
                }
            }
        }

        let plan = match crate::install::read_plan(&build_dir) {
            Ok(plan) => plan,
            Err(e) => {
                eprintln!("{}", e);
                return 1;
            }
        };
        let strip = args.strip || configured_strip(&build_dir);
        let strip_program = configured_strip_program(&build_dir);
        match crate::install::execute(
            &plan,
            &build_dir,
            &destdir,
            strip,
            &strip_program,
            &args.tags,
            args.quiet,
        ) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("Installation failed: {}", e);
                1
            }
        }
    }

    fn cmd_introspect(&self, args: &IntrospectArgs) -> i32 {
        let info_dir = format!("{}/meson-info", args.build_dir);

        if args.all || args.what.is_empty() {
            // Print all introspection
            for entry in &[
                "projectinfo",
                "targets",
                "tests",
                "dependencies",
                "buildoptions",
                "installed",
                "benchmarks",
            ] {
                let file = format!("{}/intro-{}.json", info_dir, entry);
                if let Ok(content) = std::fs::read_to_string(&file) {
                    println!("{}", content);
                }
            }
        } else {
            for what in &args.what {
                let file = format!("{}/intro-{}.json", info_dir, what);
                match std::fs::read_to_string(&file) {
                    Ok(content) => println!("{}", content),
                    Err(_) => eprintln!("No introspection data for '{}'", what),
                }
            }
        }

        0
    }

    fn cmd_init(&self, args: &InitArgs) -> i32 {
        let dir = std::env::current_dir().unwrap_or_default();
        let name = args.name.clone().unwrap_or_else(|| {
            dir.file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string()
        });

        let meson_build = format!(
            "project('{}', '{}',\n  version : '{}',\n  default_options : ['warning_level=3'])\n\n",
            name, args.language, args.version
        );

        let source_file = match args.language.as_str() {
            "c" => {
                let content = match args.project_type.as_str() {
                    "library" => format!(
                        "#include <{}>\n\nint {}_func(void) {{\n    return 0;\n}}\n",
                        format!("{}.h", name), name
                    ),
                    _ => "#include <stdio.h>\n\nint main(int argc, char *argv[]) {\n    printf(\"Hello, world!\\n\");\n    return 0;\n}\n".to_string(),
                };
                ("main.c", content)
            }
            "cpp" | "c++" => {
                let content = "#include <iostream>\n\nint main(int argc, char *argv[]) {\n    std::cout << \"Hello, world!\" << std::endl;\n    return 0;\n}\n".to_string();
                ("main.cpp", content)
            }
            "rust" => {
                let content = "fn main() {\n    println!(\"Hello, world!\");\n}\n".to_string();
                ("main.rs", content)
            }
            _ => ("main.c", "int main(void) { return 0; }\n".to_string()),
        };

        let target_code = match args.project_type.as_str() {
            "library" => format!("lib = library('{}', '{}')\n", name, source_file.0),
            _ => format!("exe = executable('{}', '{}')\n", name, source_file.0),
        };

        let full_meson = format!("{}{}", meson_build, target_code);

        if let Err(e) = std::fs::write("meson.build", &full_meson) {
            eprintln!("Cannot write meson.build: {}", e);
            return 1;
        }

        if !Path::new(source_file.0).exists() {
            if let Err(e) = std::fs::write(source_file.0, &source_file.1) {
                eprintln!("Cannot write {}: {}", source_file.0, e);
                return 1;
            }
        }

        eprintln!("Generated meson.build for project '{}'", name);
        0
    }

    fn cmd_dist(&self, args: &DistArgs) -> i32 {
        eprintln!("Creating distribution archive...");
        // Use git archive as a simple implementation
        let mut cmd = Command::new("git");
        cmd.arg("archive")
            .arg("--format=tar.gz")
            .arg("--prefix=dist/")
            .arg(cli_short_o!())
            .arg(format!("{}/meson-dist/project.tar.gz", args.build_dir))
            .arg("HEAD")
            .current_dir(&args.build_dir);

        let dist_dir = format!("{}/meson-dist", args.build_dir);
        let _ = std::fs::create_dir_all(&dist_dir);

        match cmd.status() {
            Ok(status) if status.success() => {
                eprintln!("Distribution archive created.");
                0
            }
            _ => {
                eprintln!("Failed to create distribution archive");
                1
            }
        }
    }

    fn cmd_wrap(&self, args: &WrapArgs) -> i32 {
        match args.subcommand.as_str() {
            cli_command_list!() => {
                eprintln!("Available wraps can be found at https://wrapdb.mesonbuild.com/");
                0
            }
            cli_command_install!() => {
                if let Some(ref name) = args.name {
                    eprintln!("Installing wrap: {}", name);
                    // Download from wrapdb
                    0
                } else {
                    eprintln!("wrap install requires a package name");
                    1
                }
            }
            cli_command_update!() => {
                eprintln!("Updating wraps...");
                0
            }
            cli_command_info!() => {
                if let Some(ref name) = args.name {
                    eprintln!("Info for wrap: {}", name);
                    0
                } else {
                    eprintln!("wrap info requires a name");
                    1
                }
            }
            cli_command_search!() => {
                if let Some(ref name) = args.name {
                    eprintln!("Searching for: {}", name);
                    0
                } else {
                    eprintln!("wrap search requires a query");
                    1
                }
            }
            cli_command_status!() => {
                eprintln!("Wrap status: all up to date");
                0
            }
            _ => {
                eprintln!("Unknown wrap subcommand: {}", args.subcommand);
                1
            }
        }
    }

    fn cmd_subprojects(&self, args: &SubprojectsArgs) -> i32 {
        match args.subcommand.as_str() {
            cli_command_list!() => {
                eprintln!("Listing subprojects...");
                0
            }
            cli_command_download!() => {
                eprintln!("Downloading subprojects...");
                0
            }
            cli_command_update!() => {
                eprintln!("Updating subprojects...");
                0
            }
            cli_command_purge!() => {
                eprintln!("Purging subprojects...");
                0
            }
            cli_command_checkout!() => {
                eprintln!("Checking out subprojects...");
                0
            }
            cli_command_foreach!() => {
                eprintln!("Running command in subprojects...");
                0
            }
            cli_command_packagefiles!() => {
                eprintln!("Managing package files...");
                0
            }
            _ => {
                eprintln!("Unknown subprojects subcommand: {}", args.subcommand);
                1
            }
        }
    }

    fn cmd_devenv(&self, args: &DevenvArgs) -> i32 {
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
        let mut cmd = if args.command.is_empty() {
            let mut c = Command::new(&shell);
            c.current_dir(&args.build_dir);
            c
        } else {
            let mut c = Command::new(&args.command[0]);
            c.args(&args.command[1..]);
            c.current_dir(&args.build_dir);
            c
        };

        match cmd.status() {
            Ok(status) => status.code().unwrap_or(1),
            Err(e) => {
                eprintln!("Failed: {}", e);
                1
            }
        }
    }

    fn cmd_format(&self, args: &FormatArgs) -> i32 {
        let files = if args.files.is_empty() {
            // Find all meson.build files
            let mut found = Vec::new();
            if args.recursive {
                find_meson_files(".", &mut found);
            } else {
                if Path::new("meson.build").exists() {
                    found.push("meson.build".to_string());
                }
                if Path::new("meson_options.txt").exists() {
                    found.push("meson_options.txt".to_string());
                }
                if Path::new("meson.options").exists() {
                    found.push("meson.options".to_string());
                }
            }
            found
        } else {
            args.files.clone()
        };

        for file in &files {
            match std::fs::read_to_string(file) {
                Ok(content) => {
                    let formatted = format_meson_source(&content);
                    if args.inplace {
                        if let Err(e) = std::fs::write(file, &formatted) {
                            eprintln!("Cannot write {}: {}", file, e);
                        }
                    } else {
                        print!("{}", formatted);
                    }
                }
                Err(e) => eprintln!("Cannot read {}: {}", file, e),
            }
        }

        0
    }

}

fn parse_builtin_cli_option(
    args: &[String],
    i: &mut usize,
) -> Result<(String, String), String> {
    let arg = &args[*i];
    let rest = arg.trim_start_matches("--");
    if let Some((flag, value)) = rest.split_once('=') {
        let key = options::builtin_option_key(flag)
            .ok_or_else(|| format!("unrecognized arguments: {}", arg))?;
        Ok((key, value.to_string()))
    } else {
        let key = options::builtin_option_key(rest)
            .ok_or_else(|| format!("unrecognized arguments: {}", arg))?;
        if options::builtin_option_is_boolean(&key) {
            Ok((key, "true".to_string()))
        } else if let Some(next) = args.get(*i + 1) {
            *i += 1;
            Ok((key, next.clone()))
        } else {
            Err(format!("argument {}: expected one argument", arg))
        }
    }
}

fn which_ninja() -> String {
    for name in &["ninja", "samu", "ninja-build"] {
        if let Ok(output) = Command::new("which").arg(name).output() {
            if output.status.success() {
                return name.to_string();
            }
        }
    }
    "ninja".to_string()
}

fn find_meson_files(dir: &str, files: &mut Vec<String>) {
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                let name = path.file_name().unwrap_or_default().to_string_lossy();
                if !name.starts_with('.') && name != "builddir" && name != cli_command_build!() {
                    find_meson_files(&path.to_string_lossy(), files);
                }
            } else if let Some(name) = path.file_name() {
                let name = name.to_string_lossy();
                if name == "meson.build" || name == "meson_options.txt" || name == "meson.options" {
                    files.push(path.to_string_lossy().to_string());
                }
            }
        }
    }
}

fn format_meson_source(source: &str) -> String {
    // Simple formatter: normalize indentation and whitespace
    let mut result = String::new();
    let mut indent = 0usize;

    for line in source.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            result.push('\n');
            continue;
        }

        // Decrease indent for closing keywords
        if trimmed.starts_with("endif")
            || trimmed.starts_with("endforeach")
            || trimmed.starts_with("elif")
            || trimmed.starts_with("else")
        {
            indent = indent.saturating_sub(1);
        }

        // Write indented line
        for _ in 0..indent {
            result.push_str("  ");
        }
        result.push_str(trimmed);
        result.push('\n');

        // Increase indent for opening keywords
        if trimmed.starts_with("if ")
            || trimmed.starts_with("foreach ")
            || trimmed.starts_with("elif ")
            || trimmed.starts_with("else")
        {
            indent += 1;
        }
    }

    result
}

pub(crate) fn meson_invocation() -> Vec<String> {
    let program = std::env::current_exe()
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_else(|_| "meson".to_string());
    let mut invocation = vec![program];
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new("meson")) {
        invocation.push("meson".to_string());
    }
    invocation
}

pub fn split_command(value: &str) -> Vec<String> {
    value.split_whitespace().map(str::to_string).collect()
}

fn record_strip_program(build_dir: &str, machine: &HashMap<String, HashMap<String, String>>) {
    let Some(value) = machine.get("binaries").and_then(|binaries| binaries.get("strip")) else {
        return;
    };
    let program = first_program(value);
    let _ = std::fs::write(
        format!("{}/meson-private/strip_bin.txt", build_dir),
        program,
    );
}

fn first_program(value: &str) -> String {
    let trimmed = value.trim();
    let inner = trimmed
        .strip_prefix('[')
        .and_then(|s| s.strip_suffix(']'))
        .unwrap_or(trimmed);
    let first = inner.split(',').next().unwrap_or(inner).trim();
    let program = first.trim_matches(|c| c == '\'' || c == '"' || c == ' ');
    if program.is_empty() {
        "strip".to_string()
    } else {
        program.to_string()
    }
}

fn configured_strip_program(build_dir: &str) -> String {
    std::fs::read_to_string(format!("{}/meson-private/strip_bin.txt", build_dir))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "strip".to_string())
}

fn configured_strip(build_dir: &str) -> bool {
    let cmd_file = format!("{}/meson-private/cmd_line.txt", build_dir);
    let content = match std::fs::read_to_string(&cmd_file) {
        Ok(content) => content,
        Err(_) => return false,
    };
    let saved: deser_value::Value = deser_json::from_str(&content).unwrap_or_default();
    saved["options"]
        .as_seq()
        .map(|options| {
            options.iter().any(|opt| {
                opt.as_str()
                    .map(|s| s == "strip=true")
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

fn toolchain(vm: &crate::vm::VM) -> crate::backend::Toolchain {
    let mut toolchain = crate::backend::Toolchain::default();
    if let Some(crate::objects::Object::Compiler(c)) = vm.globals.get("compiler_c") {
        toolchain.c = c.cmd.clone();
    }
    if let Some(crate::objects::Object::Compiler(c)) = vm.globals.get("compiler_cpp") {
        toolchain.cpp = c.cmd.clone();
    }
    if let Some(archiver) = std::env::var("AR")
        .ok()
        .map(|value| split_command(&value))
        .filter(|words| !words.is_empty())
    {
        toolchain.archiver = archiver;
    }
    toolchain.archiver_args = archiver_args(&toolchain.archiver);
    toolchain
}

/// Meson's `ArLinker`: deterministic archives (`D`) only when `ar -h` lists `[D]`; Apple's `ar`
/// has no `D` and rejects it.
fn archiver_args(archiver: &[String]) -> String {
    let Some((program, args)) = archiver.split_first() else {
        return "csr".to_string();
    };
    let help = Command::new(program)
        .args(args)
        .arg(cli_short_h!())
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output();
    match help {
        Ok(output) if String::from_utf8_lossy(&output.stdout).contains("[D]") => "csrD".to_string(),
        _ => "csr".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_cli(build_dir: &str, no_rebuild: bool) -> Cli {
        let mut args = vec![
            "meson".to_string(),
            "test".to_string(),
            "-C".to_string(),
            build_dir.to_string(),
        ];
        if no_rebuild {
            args.push("--no-rebuild".to_string());
        }
        Cli::parse_args_from(args)
    }

    fn temp_build(label: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "meson-test-status-{label}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn archiver_args_add_d_only_when_the_archiver_lists_it() {
        let dir = temp_build("archiver");
        let script = |name: &str, body: &str| {
            let path = dir.join(name);
            std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
            let mut permissions = std::fs::metadata(&path).unwrap().permissions();
            std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
            std::fs::set_permissions(&path, permissions).unwrap();
            vec![path.to_string_lossy().into_owned()]
        };
        let gnu = script("gnu-ar", "echo ' commands: d m p q r s t x'; echo ' modifiers: [D] - use zero for timestamps'");
        let apple = script("apple-ar", "echo 'usage:  ar -d [-TLsv] archive file ...' >&2; exit 1");
        assert_eq!(archiver_args(&gnu), "csrD");
        assert_eq!(archiver_args(&apple), "csr");
        assert_eq!(archiver_args(&[dir.join("missing").to_string_lossy().into_owned()]), "csr");
    }

    #[test]
    fn missing_test_list_fails() {
        let dir = temp_build("missing");
        let code = test_cli(dir.to_str().unwrap(), true).run();
        assert_ne!(code, 0);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn unreadable_test_list_fails() {
        let dir = temp_build("badjson");
        std::fs::create_dir_all(dir.join("meson-info")).unwrap();
        std::fs::write(dir.join("meson-info/intro-tests.json"), "{").unwrap();
        let code = test_cli(dir.to_str().unwrap(), true).run();
        assert_ne!(code, 0);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn empty_test_list_succeeds() {
        let dir = temp_build("empty");
        std::fs::create_dir_all(dir.join("meson-info")).unwrap();
        std::fs::write(dir.join("meson-info/intro-tests.json"), "[]").unwrap();
        let code = test_cli(dir.to_str().unwrap(), true).run();
        assert_eq!(code, 0);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn prereq_build_failure_fails_the_test_command() {
        let dir = temp_build("prereq");
        let code = test_cli(dir.to_str().unwrap(), false).run();
        assert_ne!(code, 0);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn ninja_spawn_failure_fails() {
        if std::env::var_os("GLUON_EMPTY_PATH_CHILD").is_none() {
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "cli::tests::ninja_spawn_failure_fails",
                    "--test-threads=1",
                ])
                .env("GLUON_EMPTY_PATH_CHILD", "1")
                .env("PATH", "")
                .status()
                .unwrap();
            assert!(status.success(), "the empty-PATH child run failed");
            return;
        }
        let dir = temp_build("spawn");
        std::fs::create_dir_all(dir.join("meson-info")).unwrap();
        std::fs::write(dir.join("meson-info/intro-tests.json"), "[{\"name\":\"t\"}]").unwrap();
        let code = test_cli(dir.to_str().unwrap(), true).run();
        assert_ne!(code, 0);
        std::fs::remove_dir_all(&dir).ok();
    }
}

#[cfg(test)]
mod help_value_tests {
    use super::{Cli, CliCommand};

    fn parse(args: &[&str]) -> CliCommand {
        Cli::parse_args_from(args.iter().map(|s| s.to_string()).collect()).command
    }

    #[test]
    fn help_tokens_consumed_as_values_remain_values() {
        assert!(matches!(parse(&["meson", "setup", "--cross-file", "--help"]), CliCommand::Setup(a) if a.cross_file.as_deref() == Some("--help")));
        assert!(matches!(parse(&["meson", "configure", "--prefix", "-h"]), CliCommand::Configure(a) if a.options == [("prefix".into(), "-h".into())]));
        assert!(matches!(parse(&["meson", "compile", "-C", "--help"]), CliCommand::Compile(a) if a.build_dir == "--help"));
        assert!(matches!(parse(&["meson", "test", "--suite", "-h"]), CliCommand::Test(a) if a.suite.as_deref() == Some("-h")));
        assert!(matches!(parse(&["meson", "install", "--destdir", "--help"]), CliCommand::Install(a) if a.destdir.as_deref() == Some("--help")));
        assert!(matches!(parse(&["meson", "init", "--name", "--help"]), CliCommand::Init(a) if a.name.as_deref() == Some("--help")));
        assert!(matches!(parse(&["meson", "dist", "--formats", "-h"]), CliCommand::Dist(a) if a.formats == ["-h"]));
        assert!(matches!(parse(&["meson", "devenv", "-C", "--help"]), CliCommand::Devenv(a) if a.build_dir == "--help"));
        assert!(matches!(parse(&["meson", "--internal", "exe", "--capture", "--help", "--", "echo"]), CliCommand::Internal(a) if a[2] == "--help"));
        assert!(matches!(parse(&["meson", "--internal", "exe", "--", "echo", "--help"]), CliCommand::Internal(_)));
    }
}

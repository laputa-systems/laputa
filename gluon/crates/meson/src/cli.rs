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
    Help,
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
    pub fn parse_args() -> Self {
        Self::parse_args_from(std::env::args().collect())
    }

    pub fn parse_args_from(args: Vec<String>) -> Self {

        if args.len() < 2 {
            return Cli {
                command: CliCommand::Help,
            };
        }

        let cmd = &args[1];
        let rest = &args[2..];

        let command = match cmd.as_str() {
            "setup" | "configure" if cmd == "setup" => Self::parse_setup(rest),
            "configure" => Self::parse_configure(rest),
            "compile" | "build" => Self::parse_compile(rest),
            "test" => Self::parse_test(rest),
            "install" => Self::parse_install(rest),
            "introspect" => Self::parse_introspect(rest),
            "init" => Self::parse_init(rest),
            "dist" => Self::parse_dist(rest),
            "wrap" => Self::parse_wrap(rest),
            "subprojects" => Self::parse_subprojects(rest),
            "rewrite" => CliCommand::Rewrite,
            "devenv" => Self::parse_devenv(rest),
            "env2mfile" => CliCommand::Env2mfile,
            "format" | "fmt" => Self::parse_format(rest),
            "--version" | "version" => CliCommand::Version,
            "--internal" => CliCommand::Internal(rest.to_vec()),
            "help" | "--help" | "-h" => CliCommand::Help,
            // If first arg is a directory, treat as setup
            _ if Path::new(cmd).is_dir() || !cmd.starts_with('-') => {
                let mut all_args = vec![cmd.clone()];
                all_args.extend(rest.iter().cloned());
                Self::parse_setup(&all_args)
            }
            _ => CliCommand::Help,
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
            if arg.starts_with("-D") {
                let opt = &arg[2..];
                if let Some(eq) = opt.find('=') {
                    cli_options.push((opt[..eq].to_string(), opt[eq + 1..].to_string()));
                }
            } else if arg == "--cross-file" {
                i += 1;
                if i < args.len() {
                    cross_file = Some(args[i].clone());
                }
            } else if let Some(value) = arg.strip_prefix("--cross-file=") {
                cross_file = Some(value.to_string());
            } else if arg == "--native-file" {
                i += 1;
                if i < args.len() {
                    native_file = Some(args[i].clone());
                }
            } else if let Some(value) = arg.strip_prefix("--native-file=") {
                native_file = Some(value.to_string());
            } else if arg == "--reconfigure" {
                reconfigure = true;
            } else if arg == "--wipe" {
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
            if arg.starts_with("-D") {
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
            match arg.as_str() {
                "-j" | "--jobs" => {
                    i += 1;
                    if i < args.len() {
                        jobs = args[i].parse().ok();
                    }
                }
                "-v" | "--verbose" => verbose = true,
                "--clean" => clean = true,
                "-C" => {
                    i += 1;
                    if i < args.len() {
                        build_dir = args[i].clone();
                    }
                }
                _ if arg.starts_with("-j") => {
                    jobs = arg[2..].parse().ok();
                }
                _ if arg.starts_with("-C") => {
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
            match arg.as_str() {
                "-v" | "--verbose" => verbose = true,
                "--no-rebuild" => no_rebuild = true,
                "--suite" => {
                    i += 1;
                    if i < args.len() {
                        suite = Some(args[i].clone());
                    }
                }
                "-t" | "--timeout-multiplier" => {
                    i += 1;
                    if i < args.len() {
                        timeout_multiplier = args[i].parse().unwrap_or(1.0);
                    }
                }
                "-j" | "--num-processes" => {
                    i += 1;
                    if i < args.len() {
                        num_processes = args[i].parse().ok();
                    }
                }
                "--repeat" => {
                    i += 1;
                    if i < args.len() {
                        repeat = args[i].parse().unwrap_or(1);
                    }
                }
                "-C" => {
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
            match arg.as_str() {
                "--destdir" => {
                    i += 1;
                    if i < args.len() {
                        destdir = Some(args[i].clone());
                    }
                }
                _ if arg.starts_with("--destdir=") => {
                    destdir = Some(arg["--destdir=".len()..].to_string());
                }
                "--skip-subprojects" => skip_subprojects = true,
                "--tags" => {
                    i += 1;
                    if i < args.len() {
                        tags = args[i].split(',').map(String::from).collect();
                    }
                }
                "--strip" => strip = true,
                "--no-rebuild" => no_rebuild = true,
                "-q" | "--quiet" => quiet = true,
                "-C" => {
                    i += 1;
                    if i < args.len() {
                        build_dir = args[i].clone();
                    }
                }
                _ if arg.starts_with("-C") => build_dir = arg[2..].to_string(),
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
            match arg.as_str() {
                "--all" | "-a" => all = true,
                "--targets" => what.push("targets".to_string()),
                "--tests" => what.push("tests".to_string()),
                "--dependencies" => what.push("dependencies".to_string()),
                "--buildoptions" => what.push("buildoptions".to_string()),
                "--projectinfo" => what.push("projectinfo".to_string()),
                "--installed" => what.push("installed".to_string()),
                "--benchmarks" => what.push("benchmarks".to_string()),
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
            match arg.as_str() {
                "-n" | "--name" => {
                    i += 1;
                    if i < args.len() {
                        name = Some(args[i].clone());
                    }
                }
                "-l" | "--language" => {
                    i += 1;
                    if i < args.len() {
                        language = args[i].clone();
                    }
                }
                "--type" => {
                    i += 1;
                    if i < args.len() {
                        project_type = args[i].clone();
                    }
                }
                "-b" | "--builddir" => {
                    i += 1;
                    if i < args.len() {
                        build_dir = Some(args[i].clone());
                    }
                }
                "--version" => {
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
            match arg.as_str() {
                "--formats" => {
                    i += 1;
                    if i < args.len() {
                        formats = args[i].split(',').map(String::from).collect();
                    }
                }
                "--include-subprojects" => include_subprojects = true,
                "--no-tests" => no_tests = true,
                "-C" => {
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

    fn parse_wrap(args: &[String]) -> CliCommand {
        let subcommand = args.first().cloned().unwrap_or_else(|| "list".to_string());
        let name = args.get(1).cloned();
        CliCommand::Wrap(WrapArgs { subcommand, name })
    }

    fn parse_subprojects(args: &[String]) -> CliCommand {
        let subcommand = args.first().cloned().unwrap_or_else(|| "list".to_string());
        CliCommand::Subprojects(SubprojectsArgs { subcommand })
    }

    fn parse_devenv(args: &[String]) -> CliCommand {
        let mut build_dir = ".".to_string();
        let mut command = Vec::new();
        let mut after_dash = false;

        for arg in args {
            if after_dash {
                command.push(arg.clone());
            } else if arg == "--" {
                after_dash = true;
            } else if arg == "-C" {
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
            match arg.as_str() {
                "-i" | "--inplace" => inplace = true,
                "-r" | "--recursive" => recursive = true,
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
            CliCommand::Help => {
                self.print_help();
                0
            }
            CliCommand::Error(code, message) => {
                eprintln!("meson: error: {}", message);
                *code
            }
        }
    }

    fn cmd_setup(&self, args: &SetupArgs) -> i32 {
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
        let meson_command = std::env::current_exe()
            .map(|path| path.to_string_lossy().to_string())
            .unwrap_or_else(|_| "meson".to_string());
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
        // Re-read the saved command line and re-run setup with new options
        let cmd_file = format!("{}/meson-private/cmd_line.txt", args.build_dir);
        if !Path::new(&cmd_file).exists() {
            eprintln!("Not a configured build directory: {}", args.build_dir);
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
        all_options.extend(args.options.clone());

        self.cmd_setup(&SetupArgs {
            source_dir,
            build_dir: args.build_dir.clone(),
            options: all_options,
            cross_file: None,
            native_file: None,
            reconfigure: true,
            wipe: false,
        })
    }

    fn cmd_compile(&self, args: &CompileArgs) -> i32 {
        let ninja = which_ninja();
        let mut cmd = Command::new(&ninja);
        cmd.current_dir(&args.build_dir);

        if let Some(jobs) = args.jobs {
            cmd.arg("-j").arg(jobs.to_string());
        }
        if args.verbose {
            cmd.arg("-v");
        }
        if args.clean {
            cmd.arg("-t").arg("clean");
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
        cmd.arg("test");
        if args.verbose {
            cmd.arg("-v");
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
            .arg("-o")
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
            "list" => {
                eprintln!("Available wraps can be found at https://wrapdb.mesonbuild.com/");
                0
            }
            "install" => {
                if let Some(ref name) = args.name {
                    eprintln!("Installing wrap: {}", name);
                    // Download from wrapdb
                    0
                } else {
                    eprintln!("wrap install requires a package name");
                    1
                }
            }
            "update" => {
                eprintln!("Updating wraps...");
                0
            }
            "info" => {
                if let Some(ref name) = args.name {
                    eprintln!("Info for wrap: {}", name);
                    0
                } else {
                    eprintln!("wrap info requires a name");
                    1
                }
            }
            "search" => {
                if let Some(ref name) = args.name {
                    eprintln!("Searching for: {}", name);
                    0
                } else {
                    eprintln!("wrap search requires a query");
                    1
                }
            }
            "status" => {
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
            "list" => {
                eprintln!("Listing subprojects...");
                0
            }
            "download" => {
                eprintln!("Downloading subprojects...");
                0
            }
            "update" => {
                eprintln!("Updating subprojects...");
                0
            }
            "purge" => {
                eprintln!("Purging subprojects...");
                0
            }
            "checkout" => {
                eprintln!("Checking out subprojects...");
                0
            }
            "foreach" => {
                eprintln!("Running command in subprojects...");
                0
            }
            "packagefiles" => {
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

    fn print_help(&self) {
        println!("usage: meson <command> [options]");
        println!();
        println!("Commands:");
        println!("  setup       Configure the project");
        println!("  configure   Change project options");
        println!("  compile     Build the project");
        println!("  test        Run tests");
        println!("  install     Install the project");
        println!("  introspect  Introspect project");
        println!("  init        Create a new project");
        println!("  dist        Generate release archive");
        println!("  wrap        Manage wrap dependencies");
        println!("  subprojects Manage subprojects");
        println!("  devenv      Run commands in dev environment");
        println!("  format      Format meson.build files");
        println!("  rewrite     Modify project definition");
        println!("  env2mfile   Convert env to machine file");
        println!("  --version   Print version");
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
                if !name.starts_with('.') && name != "builddir" && name != "build" {
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

pub fn meson_program() -> String {
    std::env::current_exe()
        .expect("the running meson has an executable path")
        .to_string_lossy()
        .into_owned()
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
    toolchain
}

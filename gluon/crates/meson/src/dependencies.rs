use crate::objects::*;
use crate::vm::*;
/// Dependency detection: pkg-config, cmake, config-tool, system library.
use std::collections::{HashMap, HashSet};
use std::process::Command;

/// Resolve the pkg-config command, honoring meson.override_find_program('pkg-config', ...).
fn pkgconfig_command(vm: &VM) -> String {
    if let Some(Object::ExternalProgram(p)) = vm.build_data.find_program_overrides.get("pkg-config")
    {
        if p.found && !p.path.is_empty() {
            return p.path.clone();
        }
    }
    "pkg-config".to_string()
}

/// Run a pkg-config invocation, working around missing shebang interpreters (e.g. in
/// hermetic build sandboxes where `/usr/bin/env` is absent).
fn run_pkgconfig(cmd: &str, args: &[&str]) -> Option<std::process::Output> {
    match Command::new(cmd).args(args).output() {
        Ok(o) => Some(o),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            // Likely a script with a shebang we cannot resolve. Read the shebang
            // and re-exec via the named interpreter found on PATH.
            let mut buf = [0u8; 256];
            use std::io::Read;
            let mut f = std::fs::File::open(cmd).ok()?;
            let n = f.read(&mut buf).ok()?;
            let head = std::str::from_utf8(&buf[..n]).ok()?;
            if !head.starts_with("#!") {
                return None;
            }
            let line = head.lines().next()?.trim_start_matches("#!").trim();
            // Examples:  /usr/bin/env python3   |   /usr/bin/python3   |   /bin/sh -e
            let mut parts = line.split_whitespace();
            let interp_path = parts.next()?;
            let mut argv: Vec<String> = Vec::new();
            // Strip /usr/bin/env wrapper - it's the most common reason this path fails.
            if interp_path.ends_with("/env") {
                if let Some(real) = parts.next() {
                    argv.push(real.to_string());
                }
            } else {
                let basename = std::path::Path::new(interp_path)
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or(interp_path);
                argv.push(basename.to_string());
            }
            for extra in parts {
                argv.push(extra.to_string());
            }
            let interp = argv.remove(0);
            argv.push(cmd.to_string());
            for a in args {
                argv.push((*a).to_string());
            }
            Command::new(&interp).args(&argv).output().ok()
        }
        Err(_) => None,
    }
}

/// Try to find a dependency using various methods.
fn special_dependency(vm: &VM, name: &str, method: &str) -> Option<Object> {
    let compiler = match vm.globals.get("compiler_c") {
        Some(Object::Compiler(c)) => Some(c.clone()),
        _ => None,
    };
    let wants_builtin = method == "auto" || method == "builtin";
    let wants_system = method == "auto" || method == "system";
    let dependency = |compile_args: Vec<String>, link_args: Vec<String>| {
        Object::Dependency(DependencyData {
            name: name.to_string(),
            found: true,
            version: String::new(),
            compile_args,
            link_args,
            link_with: Vec::new(),
            link_whole: Vec::new(),
            sources: Vec::new(),
            include_dirs: Vec::new(),
            dependencies: Vec::new(),
            variables: HashMap::new(),
            version_reqs: Vec::new(),
            is_internal: false,
            kind: "system".to_string(),
            config_tool: None,
        })
    };
    let prefix_arg = |header: &str| CallArg {
        name: Some("prefix".to_string()),
        value: Object::String(format!("#include <{}>", header)),
    };
    let args_arg = |args: &[&str]| CallArg {
        name: Some("args".to_string()),
        value: Object::Array(args.iter().map(|a| Object::String(a.to_string())).collect()),
    };

    match name {
        "dl" => {
            if wants_builtin {
                if let Some(c) = &compiler {
                    if crate::compilers::check_function(c, "dlopen", &[prefix_arg("dlfcn.h")]) {
                        return Some(dependency(Vec::new(), Vec::new()));
                    }
                }
            }
            if wants_system {
                if let Some(c) = &compiler {
                    if crate::compilers::check_header(c, "dlfcn.h") {
                        if let Some(Object::Dependency(d)) =
                            crate::compilers::find_library(c, "dl", &[])
                        {
                            return Some(dependency(d.compile_args, d.link_args));
                        }
                    }
                }
            }
            None
        }
        "threads" if wants_system => {
            let link_args = match compiler.as_ref().map(|c| c.id.as_str()) {
                Some("gcc") | Some("clang") if !cfg!(target_os = "macos") => {
                    vec!["-pthread".to_string()]
                }
                _ => Vec::new(),
            };
            Some(dependency(Vec::new(), link_args))
        }
        "iconv" => {
            if wants_builtin {
                if let Some(c) = &compiler {
                    let code =
                        "#include <iconv.h>\nint main(void) { iconv_open(\"\", \"\"); return 0; }";
                    if crate::compilers::try_link(c, code, &[]) {
                        return Some(dependency(Vec::new(), Vec::new()));
                    }
                }
            }
            if wants_system {
                if let Some(c) = &compiler {
                    if crate::compilers::check_header(c, "iconv.h") {
                        if let Some(Object::Dependency(d)) =
                            crate::compilers::find_library(c, "iconv", &[])
                        {
                            return Some(dependency(d.compile_args, d.link_args));
                        }
                    }
                }
            }
            None
        }
        "intl" => {
            if wants_builtin {
                if let Some(c) = &compiler {
                    let code = "#include <libintl.h>\nint main(void) { gettext(\"Hello world\"); return 0; }";
                    if crate::compilers::try_link(c, code, &[]) {
                        return Some(dependency(Vec::new(), Vec::new()));
                    }
                }
            }
            if wants_system {
                if let Some(c) = &compiler {
                    if crate::compilers::check_header(c, "libintl.h") {
                        if let Some(Object::Dependency(d)) =
                            crate::compilers::find_library(c, "intl", &[])
                        {
                            return Some(dependency(d.compile_args, d.link_args));
                        }
                    }
                }
            }
            None
        }
        "openmp" if wants_system => {
            let c = compiler.as_ref()?;
            let flags = match c.id.as_str() {
                "gcc" | "clang" => vec!["-fopenmp".to_string()],
                _ => return None,
            };
            let date = crate::compilers::get_define(c, "_OPENMP", &[args_arg(&["-fopenmp"])]);
            let version = match date.trim() {
                "202411" => "6.0",
                "202111" => "5.2",
                "202011" => "5.1",
                "201811" | "201611" => "5.0",
                "201511" => "4.5",
                "201307" => "4.0",
                "201107" => "3.1",
                "200805" => "3.0",
                "200505" => "2.5",
                "200203" => "2.0",
                "199810" => "1.0",
                _ => return None,
            };
            if !crate::compilers::check_header(c, "omp.h") {
                return None;
            }
            let mut dep = dependency(flags.clone(), flags);
            if let Object::Dependency(d) = &mut dep {
                d.version = version.to_string();
            }
            Some(dep)
        }
        "atomic" => {
            if wants_builtin {
                if let Some(c) = &compiler {
                    if crate::compilers::check_function(
                        c,
                        "atomic_flag_clear",
                        &[prefix_arg("stdatomic.h")],
                    ) {
                        return Some(dependency(Vec::new(), Vec::new()));
                    }
                }
            }
            if wants_system {
                if let Some(c) = &compiler {
                    if crate::compilers::check_header(c, "stdatomic.h") {
                        if let Some(Object::Dependency(d)) =
                            crate::compilers::find_library(c, "atomic", &[])
                        {
                            return Some(dependency(d.compile_args, d.link_args));
                        }
                    }
                }
            }
            None
        }
        _ => None,
    }
}

pub fn find_dependency(vm: &mut VM, name: &str, args: &[CallArg]) -> Option<Object> {
    let method = VM::get_arg_str(args, "method", usize::MAX).unwrap_or("auto");
    let version_req = VM::get_arg_str(args, "version", usize::MAX);
    let modules = VM::get_arg_string_array(args, "modules");
    let components = VM::get_arg_string_array(args, "components");

    if let Some(dep) = special_dependency(vm, name, method) {
        return Some(dep);
    }

    if name == "appleframeworks" {
        let mut link_args = Vec::new();
        for m in &modules {
            link_args.push("-framework".to_string());
            link_args.push(m.clone());
        }
        return Some(Object::Dependency(DependencyData {
            name: name.to_string(),
            found: true,
            version: String::new(),
            compile_args: Vec::new(),
            link_args,
            sources: Vec::new(),
            include_dirs: Vec::new(),
            dependencies: Vec::new(),
            variables: HashMap::new(),
            version_reqs: Vec::new(),
            is_internal: false,
            kind: String::new(),

                link_with: Vec::new(),
                link_whole: Vec::new(),
                config_tool: None,
            }));
    }

    // Check for internal/declared dependencies first
    if let Some(dep) = vm.build_data.dependencies.get(name) {
        return Some(dep.clone());
    }

    // Try subproject fallback
    if let Some(fallback) = VM::get_arg_value(args, "fallback") {
        if let Some(dep) = try_fallback(vm, name, fallback) {
            return Some(dep);
        }
    }

    if name == "llvm" && matches!(method, "auto" | "config-tool") {
        return find_llvm_config_tool(vm, args, version_req);
    }

    match method {
        "pkg-config" => find_pkgconfig(vm, name, version_req),
        "cmake" => find_cmake(vm, name, version_req, &components),
        "config-tool" => find_config_tool(name, version_req),
        "system" => find_system_library(name),
        "auto" | _ => {
            // Try methods in order
            find_pkgconfig(vm, name, version_req)
                .or_else(|| find_cmake(vm, name, version_req, &components))
                .or_else(|| find_config_tool(name, version_req))
                .or_else(|| find_system_library(name))
        }
    }
}

fn find_pkgconfig(vm: &VM, name: &str, version_req: Option<&str>) -> Option<Object> {
    let pkg_name = name.to_string();

    let pkgconfig_cmd = pkgconfig_command(vm);
    let output = run_pkgconfig(&pkgconfig_cmd, &["--modversion", &pkg_name])?;

    if !output.status.success() {
        return None;
    }

    let version = String::from_utf8_lossy(&output.stdout).trim().to_string();

    // Check version requirement
    if let Some(req) = version_req {
        if !crate::options::version_compare(&version, req) {
            return None;
        }
    }

    // Get compile flags
    let mut compile_args = Vec::new();
    let mut include_dirs = Vec::new();
    if let Some(output) = run_pkgconfig(&pkgconfig_cmd, &["--cflags", &pkg_name]) {
        if output.status.success() {
            let flags = String::from_utf8_lossy(&output.stdout);
            for flag in flags.split_whitespace() {
                if flag.starts_with("-I") {
                    include_dirs.push(flag[2..].to_string());
                } else {
                    compile_args.push(flag.to_string());
                }
            }
        }
    }

    // Get link flags
    let mut link_args = Vec::new();
    if let Some(output) = run_pkgconfig(&pkgconfig_cmd, &["--libs", &pkg_name]) {
        if output.status.success() {
            let flags = String::from_utf8_lossy(&output.stdout);
            for flag in flags.split_whitespace() {
                link_args.push(flag.to_string());
            }
        }
    }

    // Get variables
    let mut variables = HashMap::new();
    if let Some(output) = run_pkgconfig(&pkgconfig_cmd, &["--print-variables", &pkg_name]) {
        if output.status.success() {
            let vars_text = String::from_utf8_lossy(&output.stdout);
            for var in vars_text.lines() {
                let var = var.trim();
                if !var.is_empty() {
                    if let Some(val_output) =
                        run_pkgconfig(&pkgconfig_cmd, &["--variable", var, &pkg_name])
                    {
                        if val_output.status.success() {
                            let val = String::from_utf8_lossy(&val_output.stdout)
                                .trim()
                                .to_string();
                            variables.insert(var.to_string(), val);
                        }
                    }
                }
            }
        }
    }

    Some(Object::Dependency(DependencyData {
        name: name.to_string(),
        found: true,
        version,
        compile_args,
        link_args,
        sources: Vec::new(),
        include_dirs,
        dependencies: Vec::new(),
        variables,
        version_reqs: version_req.map(|req| vec![req.to_string()]).unwrap_or_default(),
        is_internal: false,
        kind: "pkgconfig".to_string(),

            link_with: Vec::new(),
            link_whole: Vec::new(),
            config_tool: None,
        }))
}

fn find_cmake(
    vm: &VM,
    name: &str,
    version_req: Option<&str>,
    components: &[String],
) -> Option<Object> {
    let probe_dir = std::path::Path::new(&vm.top_build_root)
        .join("meson-private")
        .join(format!("cmake_{}", name));
    std::fs::create_dir_all(&probe_dir).ok()?;
    let mut args = vec![
        "--find-package".to_string(),
        format!("-DNAME={}", name),
        "-DCOMPILER_ID=GNU".to_string(),
        "-DLANGUAGE=C".to_string(),
        "-DMODE=EXIST".to_string(),
    ];

    if !components.is_empty() {
        args.push(format!("-DCOMPONENTS={}", components.join(";")));
    }

    let output = Command::new("cmake")
        .args(&args)
        .current_dir(&probe_dir)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    // Get compile flags
    let compile_output = Command::new("cmake")
        .args([
            "--find-package",
            &format!("-DNAME={}", name),
            "-DCOMPILER_ID=GNU",
            "-DLANGUAGE=C",
            "-DMODE=COMPILE",
        ])
        .current_dir(&probe_dir)
        .output()
        .ok()?;

    let compile_args: Vec<String> = if compile_output.status.success() {
        String::from_utf8_lossy(&compile_output.stdout)
            .split_whitespace()
            .map(String::from)
            .collect()
    } else {
        Vec::new()
    };

    // Get link flags
    let link_output = Command::new("cmake")
        .args([
            "--find-package",
            &format!("-DNAME={}", name),
            "-DCOMPILER_ID=GNU",
            "-DLANGUAGE=C",
            "-DMODE=LINK",
        ])
        .current_dir(&probe_dir)
        .output()
        .ok()?;

    let link_args: Vec<String> = if link_output.status.success() {
        String::from_utf8_lossy(&link_output.stdout)
            .split_whitespace()
            .map(String::from)
            .collect()
    } else {
        Vec::new()
    };

    Some(Object::Dependency(DependencyData {
        name: name.to_string(),
        found: true,
        version: String::new(),
        compile_args,
        link_args,
        sources: Vec::new(),
        include_dirs: Vec::new(),
        dependencies: Vec::new(),
        variables: HashMap::new(),
        version_reqs: Vec::new(),
        is_internal: false,
        kind: String::new(),

            link_with: Vec::new(),
            link_whole: Vec::new(),
            config_tool: None,
        }))
}

fn find_config_tool(name: &str, version_req: Option<&str>) -> Option<Object> {
    let config_tool = format!("{}-config", name);
    let output = Command::new(&config_tool).arg("--version").output().ok()?;
    if !output.status.success() {
        return None;
    }

    let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if let Some(req) = version_req {
        if !crate::options::version_compare(&version, req) {
            return None;
        }
    }

    let compile_args: Vec<String> = Command::new(&config_tool)
        .arg("--cflags")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .split_whitespace()
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();

    let link_args: Vec<String> = Command::new(&config_tool)
        .arg("--libs")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .split_whitespace()
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();

    Some(Object::Dependency(DependencyData {
        name: name.to_string(),
        found: true,
        version,
        compile_args,
        link_args,
        sources: Vec::new(),
        include_dirs: Vec::new(),
        dependencies: Vec::new(),
        variables: HashMap::new(),
        version_reqs: Vec::new(),
        is_internal: false,
        kind: String::new(),
        link_with: Vec::new(),
        link_whole: Vec::new(),
        config_tool: Some(config_tool),
    }))
}

const LLVM_CONFIG_SUFFIXES: &[&str] = &[
    "", "-23.1", "23.1", "-23", "23", "-22.1", "22.1", "-22", "22", "-21.1", "21.1", "-21", "21",
    "-20.1", "20.1", "-20", "20", "-19.1", "19.1", "-19", "19", "-18.1", "18.1", "-18", "18",
    "-17", "17", "-16", "16", "-15", "15", "-14", "14", "-13", "13", "-12", "12", "-11", "11",
    "-10", "10", "-9", "90", "-8", "80", "-7", "70", "-6.0", "60", "-5.0", "50", "-4.0", "40",
    "-3.9", "39", "-3.8", "38", "-3.7", "37", "-3.6", "36", "-3.5", "35", "-devel", "-64",
];

fn find_on_path(program: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(program))
        .find(|candidate| candidate.is_file())
        .map(|candidate| candidate.to_string_lossy().into_owned())
}

fn llvm_config_words(tool: &str, args: &[&str]) -> Option<Vec<String>> {
    let output = Command::new(tool).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(
        String::from_utf8_lossy(&output.stdout)
            .split_whitespace()
            .map(String::from)
            .collect(),
    )
}

fn find_llvm_config_tool(vm: &VM, args: &[CallArg], version_req: Option<&str>) -> Option<Object> {
    let tool = LLVM_CONFIG_SUFFIXES
        .iter()
        .find_map(|suffix| find_on_path(&format!("llvm-config{suffix}")))?;
    let version = llvm_config_words(&tool, &["--version"])?.join(" ");
    if let Some(req) = version_req {
        if !crate::options::version_compare(&version, req) {
            return None;
        }
    }

    let provided: HashSet<String> = llvm_config_words(&tool, &["--components"])?
        .into_iter()
        .collect();
    let sorted_unique = |modules: Vec<String>| -> Vec<String> {
        let mut modules = modules;
        modules.sort();
        modules.dedup();
        modules
    };
    let mut modules = Vec::new();
    for module in sorted_unique(VM::get_arg_string_array(args, "modules")) {
        if !provided.contains(&module) {
            return None;
        }
        modules.push(module);
    }
    for module in sorted_unique(VM::get_arg_string_array(args, "optional_modules")) {
        if provided.contains(&module) && !modules.contains(&module) {
            modules.push(module);
        }
    }

    let compile_args: Vec<String> = llvm_config_words(&tool, &["--cppflags"])?
        .into_iter()
        .filter(|arg| arg != "-DNDEBUG")
        .collect();

    let static_link = VM::get_arg_bool(args, "static", false);
    let shared_mode = llvm_config_words(&tool, &["--shared-mode"])?
        .into_iter()
        .next()?;
    let link_args = if !static_link
        && shared_mode == "static"
        && llvm_config_words(&tool, &["--libfiles", "--link-shared"]).is_none()
    {
        let libdir = llvm_config_words(&tool, &["--libdir"])?
            .into_iter()
            .next()?;
        let mut shared_libs: Vec<String> = std::fs::read_dir(&libdir)
            .ok()?
            .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
            .filter(|file| file.starts_with("libLLVM") && file.ends_with(".so"))
            .collect();
        shared_libs.sort();
        let library = shared_libs.first()?;
        let mut link_args = llvm_config_words(&tool, &["--ldflags"])?;
        link_args.push(format!(
            "-l{}",
            &library["lib".len()..library.len() - ".so".len()]
        ));
        link_args
    } else {
        if static_link && shared_mode == "shared" {
            llvm_config_words(&tool, &["--libfiles", "--link-static"])?;
        }
        let mut query = vec!["--libs", "--ldflags"];
        if static_link {
            query.extend(["--link-static", "--system-libs"]);
        } else {
            query.push("--link-shared");
        }
        query.extend(modules.iter().map(String::as_str));
        llvm_config_words(&tool, &query)?
            .into_iter()
            .map(|arg| match arg.strip_prefix("-l") {
                Some(path) if arg.ends_with(".so") => path.to_string(),
                _ => arg,
            })
            .collect()
    };

    let dependencies: Vec<Object> = special_dependency(vm, "threads", "auto")
        .into_iter()
        .collect();

    Some(Object::Dependency(DependencyData {
        name: "llvm".to_string(),
        found: true,
        version,
        compile_args,
        link_args,
        link_with: Vec::new(),
        link_whole: Vec::new(),
        sources: Vec::new(),
        include_dirs: Vec::new(),
        dependencies,
        variables: HashMap::new(),
        version_reqs: Vec::new(),
        is_internal: false,
        kind: "config-tool".to_string(),
        config_tool: Some(tool),
    }))
}

fn find_system_library(name: &str) -> Option<Object> {
    // Try to link with -l<name>
    let code = "int main(void) { return 0; }";
    let output = Command::new("cc")
        .args(["-x", "c", "-", "-o", "/dev/null", &format!("-l{}", name)])
        .stdin(std::process::Stdio::piped())
        .output();

    match output {
        Ok(o) if o.status.success() => Some(Object::Dependency(DependencyData {
            name: name.to_string(),
            found: true,
            version: String::new(),
            compile_args: Vec::new(),
            link_args: vec![format!("-l{}", name)],
            sources: Vec::new(),
            include_dirs: Vec::new(),
            dependencies: Vec::new(),
            variables: HashMap::new(),
            version_reqs: Vec::new(),
            is_internal: false,
            kind: String::new(),

                link_with: Vec::new(),
                link_whole: Vec::new(),
                config_tool: None,
            })),
        _ => None,
    }
}

fn try_fallback(_vm: &mut VM, _name: &str, fallback: &Object) -> Option<Object> {
    match fallback {
        Object::Array(_arr) => {
            // Subproject fallback handling — deferred to subproject loading
            None
        }
        Object::String(_sp_name) => {
            // Auto-provided dependency from subproject
            None
        }
        _ => None,
    }
}

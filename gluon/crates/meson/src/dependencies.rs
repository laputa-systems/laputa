use crate::objects::*;
use crate::vm::*;
/// Dependency detection: pkg-config, cmake, config-tool, system library.
use std::collections::HashMap;
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

/// Build a dependency object for Meson's builtin/system dependency families
/// (dl, threads, iconv, intl, openmp, atomic). These are not pkg-config
/// lookups; Meson resolves them from the C compiler.
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
            is_internal: false,
            kind: "system".to_string(),
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
                        if let Some(lib) = crate::compilers::find_library(c, "dl", &[]) {
                            if let Object::Dependency(d) = lib {
                                return Some(dependency(d.compile_args, d.link_args));
                            }
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
                    let code = "#include <iconv.h>\nint main(void) { iconv_open(\"\", \"\"); return 0; }";
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
            let date = crate::compilers::get_define(
                c,
                "_OPENMP",
                &[args_arg(&["-fopenmp"])],
            );
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

/// Try to find a dependency using various methods.
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
            link_with: Vec::new(),
            link_whole: Vec::new(),
            sources: Vec::new(),
            include_dirs: Vec::new(),
            dependencies: Vec::new(),
            variables: HashMap::new(),
            is_internal: false,
            kind: String::new(),
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

    match method {
        "pkg-config" => find_pkgconfig(vm, name, version_req, &modules),
        "cmake" => find_cmake(name, version_req, &components),
        "config-tool" => find_config_tool(name, version_req),
        "system" => find_system_library(name),
        "auto" | _ => {
            // Try methods in order
            find_pkgconfig(vm, name, version_req, &modules)
                .or_else(|| find_cmake(name, version_req, &components))
                .or_else(|| find_config_tool(name, version_req))
                .or_else(|| find_system_library(name))
        }
    }
}

fn find_pkgconfig(
    vm: &VM,
    name: &str,
    version_req: Option<&str>,
    modules: &[String],
) -> Option<Object> {
    let pkg_name = if modules.is_empty() {
        name.to_string()
    } else {
        modules[0].clone()
    };

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
    let link_args = resolve_library_arguments(vm, link_args);

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
        link_with: Vec::new(),
        link_whole: Vec::new(),
        sources: Vec::new(),
        include_dirs,
        dependencies: Vec::new(),
        variables,
        is_internal: false,
        kind: String::new(),
    }))
}

fn find_cmake(name: &str, version_req: Option<&str>, components: &[String]) -> Option<Object> {
    // Try cmake --find-package
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

    let output = Command::new("cmake").args(&args).output().ok()?;
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
        link_with: Vec::new(),
        link_whole: Vec::new(),
        sources: Vec::new(),
        include_dirs: Vec::new(),
        dependencies: Vec::new(),
        variables: HashMap::new(),
        is_internal: false,
        kind: String::new(),
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
        link_with: Vec::new(),
        link_whole: Vec::new(),
        sources: Vec::new(),
        include_dirs: Vec::new(),
        dependencies: Vec::new(),
        variables: HashMap::new(),
        is_internal: false,
        kind: String::new(),
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
            link_with: Vec::new(),
            link_whole: Vec::new(),
            sources: Vec::new(),
            include_dirs: Vec::new(),
            dependencies: Vec::new(),
            variables: HashMap::new(),
            is_internal: false,
            kind: String::new(),
        })),
        _ => None,
    }
}

/// Like Meson, a `-lname` from pkg-config becomes the library's path only
/// when it lives in one of the `-L` directories the same output names and
/// that directory is not one the compiler already searches. A library in
/// the compiler's own library directories stays `-lname`, so the linker
/// records its SONAME instead of a build-root path.
fn resolve_library_arguments(vm: &VM, link_args: Vec<String>) -> Vec<String> {
    let system = compiler_library_dirs(vm);
    let search_dirs: Vec<String> = link_args
        .iter()
        .filter_map(|argument| argument.strip_prefix("-L").map(str::to_string))
        .filter(|dir| !dir.is_empty() && !system.contains(&normalize_absolute_path(dir)))
        .collect();
    link_args
        .into_iter()
        .map(|argument| {
            let Some(name) = argument.strip_prefix("-l") else {
                return argument;
            };
            if name.is_empty() || name.starts_with(':') {
                return argument;
            }
            library_in_dirs(&search_dirs, name).unwrap_or(argument)
        })
        .collect()
}

/// The library directories the C compiler searches by default, from
/// `-print-search-dirs`.
fn compiler_library_dirs(vm: &VM) -> Vec<String> {
    let Some(Object::Compiler(c)) = vm.globals.get("compiler_c") else {
        return Vec::new();
    };
    let Ok(output) = Command::new(&c.cmd[0]).args(&c.cmd[1..]).arg("-print-search-dirs").output() else {
        return Vec::new();
    };
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .find_map(|line| line.strip_prefix("libraries: ="))
        .map(|dirs| dirs.split(':').filter(|d| !d.is_empty()).map(normalize_absolute_path).collect())
        .unwrap_or_default()
}

fn library_in_dirs(dirs: &[String], name: &str) -> Option<String> {
    for dir in dirs {
        for suffix in [".so", ".a"] {
            let candidate = std::path::Path::new(dir).join(format!("lib{name}{suffix}"));
            if candidate.is_file() {
                return Some(normalize_absolute_path(&candidate.to_string_lossy()));
            }
        }
    }
    None
}

fn normalize_absolute_path(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for component in path.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                if parts.last().is_some_and(|last| *last != "..") {
                    parts.pop();
                } else {
                    parts.push("..");
                }
            }
            other => parts.push(other),
        }
    }
    format!("/{}", parts.join("/"))
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

#[cfg(test)]
mod library_argument_tests {
    use super::*;

    #[test]
    fn only_libraries_in_the_named_search_dirs_become_paths() {
        let dir = std::env::temp_dir().join(format!("gluon-libdir-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("libfoo.so"), b"").unwrap();
        let vm = VM::new();
        let args = vec![format!("-L{}", dir.display()), "-lfoo".to_string(), "-lm".to_string()];
        let resolved = resolve_library_arguments(&vm, args);
        assert_eq!(resolved[1], dir.join("libfoo.so").to_string_lossy());
        assert_eq!(resolved[2], "-lm");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}

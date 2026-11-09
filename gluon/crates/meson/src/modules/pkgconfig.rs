/// Pkg-config module: generates .pc files for library targets.
use crate::objects::*;
use crate::vm::*;

pub fn register(vm: &mut VM) {
    vm.method_registry.insert(
        ("module".to_string(), "pkgconfig.generate".to_string()),
        pkgconfig_generate,
    );
}

fn pkgconfig_generate(vm: &mut VM, _obj: &Object, args: &[CallArg]) -> Result<Object, String> {
    let positional = VM::get_positional_args(args);

    // The first positional argument is the library target (optional)
    let lib_name = match positional.first() {
        Some(Object::BuildTarget(t)) => t.name.clone(),
        Some(Object::String(s)) => s.clone(),
        _ => String::new(),
    };

    let name = VM::get_arg_str(args, "name", 99)
        .map(|s| s.to_string())
        .unwrap_or_else(|| lib_name.clone());
    let description = VM::get_arg_str(args, "description", 99)
        .unwrap_or("")
        .to_string();
    let version = VM::get_arg_str(args, "version", 99)
        .map(|s| s.to_string())
        .or_else(|| vm.project.as_ref().map(|p| p.version.clone()))
        .unwrap_or_else(|| "unset".to_string());
    let filebase = VM::get_arg_str(args, "filebase", 99)
        .map(|s| s.to_string())
        .unwrap_or_else(|| name.clone());
    let url = VM::get_arg_str(args, "url", 99).unwrap_or("").to_string();
    let subdirs = VM::get_arg_string_array(args, "subdirs");
    let requires = VM::get_arg_string_array(args, "requires");
    let requires_private = VM::get_arg_string_array(args, "requires_private");
    let _libraries = VM::get_arg_string_array(args, "libraries");
    let libraries_private = VM::get_arg_string_array(args, "libraries_private");
    let extra_cflags = VM::get_arg_string_array(args, "extra_cflags");
    let dataonly = VM::get_arg_bool(args, "dataonly", false);
    let prefix = option_value(vm, "prefix", "/usr/local");
    let libdir = option_value(vm, "libdir", "lib");
    let datadir = option_value(vm, "datadir", "share");
    let includedir = option_value(vm, "includedir", "include");
    let install_dir = VM::get_arg_str(args, "install_dir", 99)
        .map(|s| s.to_string())
        .unwrap_or_else(|| {
            if dataonly {
                format!("{}/pkgconfig", datadir)
            } else {
                format!("{}/pkgconfig", libdir)
            }
        });
    let mut variables: Vec<(String, String)> = Vec::new();
    if let Some(Object::Dict(entries)) = VM::get_arg_value(args, "variables") {
        for (key, value) in entries {
            variables.push((key.clone(), value.to_string_value()));
        }
    }
    let _uninstalled_variables = VM::get_arg_string_array(args, "uninstalled_variables");

    // Build the .pc file content
    let pc_filename = format!("{}.pc", filebase);

    let mut pc = String::new();
    pc.push_str(&format!("\nprefix={}\n", prefix));
    if !dataonly {
        pc.push_str(&format!("includedir=${{prefix}}/{}\n", includedir));
        pc.push_str(&format!("libdir=${{prefix}}/{}\n", libdir));
    }
    for (key, value) in &variables {
        if key == "prefix" {
            continue;
        }
        pc.push_str(&format!("{}={}\n", key, value));
    }
    pc.push('\n');
    pc.push_str(&format!("Name: {}\n", name));
    pc.push_str(&format!("Description: {}\n", description));
    if !url.is_empty() {
        pc.push_str(&format!("URL: {}\n", url));
    }
    pc.push_str(&format!("Version: {}\n", version));
    if !requires.is_empty() {
        pc.push_str(&format!("Requires: {}\n", requires.join(", ")));
    }
    if !requires_private.is_empty() {
        pc.push_str(&format!(
            "Requires.private: {}\n",
            requires_private.join(", ")
        ));
    }
    if !lib_name.is_empty() && !dataonly {
        pc.push_str(&format!("Libs: -L${{libdir}} -l{}\n", lib_name));
    }
    if !libraries_private.is_empty() {
        pc.push_str(&format!("Libs.private: {}\n", libraries_private.join(" ")));
    }
    if !dataonly || !subdirs.is_empty() || !extra_cflags.is_empty() {
        let mut cflags = if dataonly || !subdirs.is_empty() {
            Vec::new()
        } else {
            vec!["-I${includedir}".to_string()]
        };
        for sub in &subdirs {
            cflags.push(format!("-I${{includedir}}/{}", sub));
        }
        cflags.extend(extra_cflags);
        if !cflags.is_empty() {
            pc.push_str(&format!("Cflags: {}\n", cflags.join(" ")));
        }
    }

    // Register as install data
    let private_dir = std::path::Path::new(&vm.build_root).join("meson-private");
    let _ = std::fs::create_dir_all(&private_dir);
    let build_path = private_dir.join(&pc_filename);
    let _ = std::fs::write(&build_path, &pc);

    vm.build_data.install_data.push(InstallData {
        sources: vec![build_path.to_string_lossy().to_string()],
        install_dir: install_dir.clone(),
        install_mode: None,
        rename: Vec::new(),
        subdir: String::new(),
        preserve_path: false,
        strip_directory: false,
        exclude_files: Vec::new(),
        exclude_directories: Vec::new(),
        follow_symlinks: None,
    });

    Ok(Object::None)
}

fn option_value(vm: &VM, name: &str, default: &str) -> String {
    match vm.options.get(name) {
        Some(Object::String(s)) => s.clone(),
        _ => default.to_string(),
    }
}

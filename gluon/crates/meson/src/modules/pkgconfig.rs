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
    let variables = pkgconfig_variables(VM::get_arg_value(args, "variables"))?;
    let _uninstalled_variables = VM::get_arg_string_array(args, "uninstalled_variables");

    // Build the .pc file content
    let pc_filename = format!("{}.pc", filebase);

    let mut pc = String::new();
    pc.push_str(&format!("prefix={}\n", prefix));
    if !dataonly {
        pc.push_str(&format!("includedir=${{prefix}}/{}\n", includedir));
        pc.push_str(&format!("libdir=${{prefix}}/{}\n", libdir));
    }
    let custom: Vec<&(String, String)> = variables.iter().filter(|(key, _)| key != "prefix").collect();
    if !custom.is_empty() {
        pc.push('\n');
        for (key, value) in custom {
            pc.push_str(&format!("{}={}\n", key, value));
        }
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

/// Meson accepts pkg-config variables as a dict or as a list of
/// `name=value` strings.
fn pkgconfig_variables(value: Option<&Object>) -> Result<Vec<(String, String)>, String> {
    match value {
        None => Ok(Vec::new()),
        Some(Object::Dict(entries)) => Ok(entries.iter().map(|(k, v)| (k.clone(), v.to_string_value())).collect()),
        Some(Object::Array(items)) => items
            .iter()
            .map(|item| {
                let text = item.to_string_value();
                text.split_once('=')
                    .map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))
                    .ok_or_else(|| format!("pkgconfig variable '{text}' is not of the form name=value"))
            })
            .collect(),
        Some(Object::String(text)) => pkgconfig_variables(Some(&Object::Array(vec![Object::String(text.clone())]))),
        Some(other) => Err(format!("pkgconfig variables must be a dict or a list of strings, not {}", other.type_name())),
    }
}

#[cfg(test)]
mod variable_tests {
    use super::*;

    #[test]
    fn list_and_dict_variables_are_read() {
        let list = Object::Array(vec![Object::String("xkb_root=/usr/share/X11/xkb".into())]);
        assert_eq!(pkgconfig_variables(Some(&list)).unwrap(), vec![("xkb_root".to_string(), "/usr/share/X11/xkb".to_string())]);
        let dict = Object::Dict(vec![("a".into(), Object::String("b".into()))]);
        assert_eq!(pkgconfig_variables(Some(&dict)).unwrap(), vec![("a".to_string(), "b".to_string())]);
        assert!(pkgconfig_variables(Some(&Object::Array(vec![Object::String("novalue".into())]))).is_err());
    }
}

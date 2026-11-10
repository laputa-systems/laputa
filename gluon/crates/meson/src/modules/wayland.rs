/// Wayland protocol helpers: scan_xml, find_protocol.
use crate::objects::*;
use crate::vm::*;

pub fn register(vm: &mut VM) {
    vm.method_registry.insert(
        ("module".to_string(), "wayland.scan_xml".to_string()),
        wayland_scan_xml,
    );
    vm.method_registry.insert(
        ("module".to_string(), "wayland.find_protocol".to_string()),
        wayland_find_protocol,
    );
}

fn wayland_scan_xml(vm: &mut VM, _obj: &Object, args: &[CallArg]) -> Result<Object, String> {
    let mut sources = Vec::new();
    for arg in VM::get_positional_args(args) {
        collect_xml(vm, arg, &mut sources)?;
    }
    if sources.is_empty() {
        return Err("wayland.scan_xml: at least one XML protocol file required".to_string());
    }

    let scope = if VM::get_arg_bool(args, "public", false) { "public" } else { "private" };
    let include_core_only = VM::get_arg_bool(args, "include_core_only", true);
    let mut sides = Vec::new();
    if VM::get_arg_bool(args, "client", true) {
        sides.push("client");
    }
    if VM::get_arg_bool(args, "server", false) {
        sides.push("server");
    }
    let scanner = match crate::builtins::functions::resolve_command_program(vm, "wayland-scanner")? {
        Object::ExternalProgram(p) => p.path,
        other => other.to_string_value(),
    };

    let mut targets = Vec::new();
    for source in &sources {
        let name = std::path::Path::new(source)
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();
        targets.push(scanner_target(
            vm,
            format!("{name}-protocol"),
            source,
            format!("{name}-protocol.c"),
            vec![scanner.clone(), format!("{scope}-code"), "@INPUT@".to_string(), "@OUTPUT@".to_string()],
        ));
        for side in &sides {
            let mut command = vec![scanner.clone(), format!("{side}-header"), "@INPUT@".to_string(), "@OUTPUT@".to_string()];
            if include_core_only {
                command.push("--include-core-only".to_string());
            }
            targets.push(scanner_target(
                vm,
                format!("{name}-{side}-protocol"),
                source,
                format!("{name}-{side}-protocol.h"),
                command,
            ));
        }
    }
    Ok(Object::Array(targets))
}

fn collect_xml(vm: &VM, obj: &Object, sources: &mut Vec<String>) -> Result<(), String> {
    match obj {
        Object::String(s) if s.starts_with('/') => sources.push(s.clone()),
        Object::String(s) if vm.current_subdir.is_empty() => sources.push(format!("{}/{}", vm.source_root, s)),
        Object::String(s) => sources.push(format!("{}/{}/{}", vm.source_root, vm.current_subdir, s)),
        Object::File(f) => sources.push(crate::builtins::functions::resolved_file_path(vm, f)),
        Object::Array(items) => {
            for item in items {
                collect_xml(vm, item, sources)?;
            }
        }
        other => return Err(format!("wayland.scan_xml: unsupported source {}", other.type_name())),
    }
    Ok(())
}

fn scanner_target(vm: &mut VM, name: String, source: &str, output: String, command: Vec<String>) -> Object {
    let id = format!("{}@{}", name, vm.current_subdir);
    vm.build_data.custom_targets.push(CustomTarget {
        name: name.clone(),
        id: id.clone(),
        command,
        input: vec![source.to_string()],
        output: vec![output.clone()],
        depends: Vec::new(),
        depend_files: Vec::new(),
        depfile: None,
        capture: false,
        feed: false,
        install: false,
        install_dir: Vec::new(),
        install_tag: Vec::new(),
        build_by_default: false,
        build_always_stale: false,
        env: std::collections::HashMap::new(),
        subdir: vm.current_subdir.clone(),
    });
    Object::CustomTarget(CustomTargetRef {
        name,
        id,
        outputs: vec![output],
        subdir: vm.current_subdir.clone(),
    })
}

fn wayland_find_protocol(vm: &mut VM, _obj: &Object, args: &[CallArg]) -> Result<Object, String> {
    let name = match VM::get_positional_args(args).first() {
        Some(Object::String(s)) => s.clone(),
        _ => return Err("wayland.find_protocol: first argument must be protocol name".to_string()),
    };
    let state = VM::get_arg_str(args, "state", usize::MAX).unwrap_or("stable").to_string();
    let version = VM::get_arg_value(args, "version");
    let required_version = || match &version {
        Some(Object::Int(v)) => Ok(*v),
        _ => Err(format!("wayland.find_protocol: {} protocol '{}' requires a version", state, name)),
    };
    let xml_name = match state.as_str() {
        "stable" => format!("{}.xml", name),
        "staging" => format!("{}-v{}.xml", name, required_version()?),
        "unstable" => format!("{}-unstable-v{}.xml", name, required_version()?),
        other => return Err(format!("wayland.find_protocol: unknown state '{}'", other)),
    };
    let protocols = crate::dependencies::find_dependency(vm, "wayland-protocols", &[])
        .ok_or("wayland.find_protocol: dependency wayland-protocols not found")?;
    let pkgdatadir = crate::builtins::methods::dep_get_pkgconfig_variable(
        vm,
        &protocols,
        &[CallArg { name: None, value: Object::String("pkgdatadir".to_string()) }],
    )?
    .to_string_value();
    let path = std::path::Path::new(&pkgdatadir).join(&state).join(&name).join(&xml_name);
    if !path.is_file() {
        return Err(format!("wayland.find_protocol: {} does not exist", path.display()));
    }
    Ok(Object::File(FileData {
        path: path.to_string_lossy().to_string(),
        subdir: String::new(),
        is_built: false,
    }))
}

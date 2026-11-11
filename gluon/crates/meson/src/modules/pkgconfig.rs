/// Pkg-config module: generates .pc files for library targets.
use crate::objects::*;
use crate::options;
use crate::vm::*;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};

const DIRECTORY_OPTIONS: &[&str] = &[
    "prefix",
    "bindir",
    "datadir",
    "includedir",
    "infodir",
    "libdir",
    "licensedir",
    "libexecdir",
    "localedir",
    "localstatedir",
    "mandir",
    "sbindir",
    "sharedstatedir",
    "sysconfdir",
];

#[derive(Clone)]
enum LibEntry {
    Target(String),
    Str(String),
}

enum FlagMode<'a> {
    Installed {
        prefix: &'a str,
        default_libdir: &'a str,
    },
    Uninstalled {
        build_root: &'a str,
    },
}

struct PcFields<'a> {
    name: &'a str,
    description: &'a str,
    version: &'a str,
    license: &'a str,
    url: &'a str,
    conflicts: &'a [String],
    variables: &'a [(String, String)],
    requires: String,
    requires_private: String,
}

struct DependenciesHelper<'a> {
    targets: &'a [BuildTarget],
    metadata: &'a HashMap<String, (String, String)>,
    pub_libs: Vec<LibEntry>,
    pub_reqs: Vec<String>,
    priv_libs: Vec<LibEntry>,
    priv_reqs: Vec<String>,
    cflags: Vec<String>,
    version_reqs: BTreeMap<String, BTreeSet<String>>,
    link_whole: Vec<String>,
}

impl<'a> DependenciesHelper<'a> {
    fn new(
        targets: &'a [BuildTarget],
        metadata: &'a HashMap<String, (String, String)>,
    ) -> Self {
        Self {
            targets,
            metadata,
            pub_libs: Vec::new(),
            pub_reqs: Vec::new(),
            priv_libs: Vec::new(),
            priv_reqs: Vec::new(),
            cflags: Vec::new(),
            version_reqs: BTreeMap::new(),
            link_whole: Vec::new(),
        }
    }

    fn find_target(&self, id: &str) -> Option<&'a BuildTarget> {
        let targets = self.targets;
        targets.iter().find(|target| target.id == id)
    }

    fn metadata_filebase(&self, id: &str) -> Option<String> {
        self.metadata.get(id).map(|(filebase, _)| filebase.clone())
    }

    fn add_pub_libs(&mut self, libs: &[Object]) {
        let (processed, reqs, cflags) = self.process_libs(libs, true);
        let mut combined = processed;
        combined.append(&mut self.pub_libs);
        self.pub_libs = combined;
        self.pub_reqs.extend(reqs);
        self.cflags.extend(cflags);
    }

    fn add_priv_libs(&mut self, libs: &[Object]) {
        let (processed, reqs, _) = self.process_libs(libs, false);
        let mut combined = processed;
        combined.append(&mut self.priv_libs);
        self.priv_libs = combined;
        self.priv_reqs.extend(reqs);
    }

    fn add_pub_reqs(&mut self, reqs: &[Object]) {
        let processed = self.process_reqs(reqs);
        self.pub_reqs.extend(processed);
    }

    fn add_priv_reqs(&mut self, reqs: &[Object]) {
        let processed = self.process_reqs(reqs);
        self.priv_reqs.extend(processed);
    }

    fn add_version_reqs(&mut self, name: &str, reqs: &[String]) {
        if reqs.is_empty() {
            return;
        }
        let entry = self.version_reqs.entry(name.to_string()).or_default();
        for req in reqs {
            if !req.is_empty() {
                entry.insert(req.clone());
            }
        }
    }

    fn process_reqs(&mut self, reqs: &[Object]) -> Vec<String> {
        let mut processed = Vec::new();
        for obj in flatten(reqs) {
            match obj {
                Object::String(value) => {
                    if let Some((name, version_req)) = split_version_req(value) {
                        self.add_version_reqs(&name, &version_req);
                        processed.push(name);
                    }
                }
                Object::BuildTarget(target) => {
                    if let Some(filebase) = self.metadata_filebase(&target.id) {
                        processed.push(filebase);
                    }
                }
                Object::Dependency(dep) => {
                    if !dep.found {
                        continue;
                    }
                    if dep.kind == "pkgconfig" && !dep.name.is_empty() {
                        self.add_version_reqs(&dep.name, &dep.version_reqs);
                        processed.push(dep.name.clone());
                    } else if dep.is_internal {
                        for lib in &dep.link_with {
                            if let Object::BuildTarget(target) = lib {
                                if let Some(filebase) = self.metadata_filebase(&target.id) {
                                    processed.push(filebase);
                                }
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        processed
    }

    fn process_libs(
        &mut self,
        libs: &[Object],
        public: bool,
    ) -> (Vec<LibEntry>, Vec<String>, Vec<String>) {
        let mut processed = Vec::new();
        let mut reqs = Vec::new();
        let mut cflags = Vec::new();
        for obj in flatten(libs) {
            match obj {
                Object::BuildTarget(target_ref) => {
                    if let Some(filebase) = self.metadata_filebase(&target_ref.id) {
                        reqs.push(filebase);
                        continue;
                    }
                    if let Some(target) = self.find_target(&target_ref.id) {
                        processed.push(LibEntry::Target(target.id.clone()));
                        if target.target_type == TargetType::SharedLibrary
                            && target.shared_library_only
                        {
                            continue;
                        }
                        let deps_public =
                            target.target_type == TargetType::StaticLibrary && public;
                        self.add_lib_dependencies(target, deps_public);
                    }
                }
                Object::Dependency(dep) => {
                    if !dep.found {
                        continue;
                    }
                    if dep.name == "valgrind" {
                        continue;
                    }
                    if dep.is_internal {
                        for arg in &dep.link_args {
                            processed.push(LibEntry::Str(arg.clone()));
                        }
                        cflags.extend(dep.compile_args.iter().cloned());
                        self.add_internal_dependencies(
                            dep.link_with.clone(),
                            dep.link_whole.clone(),
                            dep.dependencies.clone(),
                            public,
                        );
                    } else if dep.kind == "pkgconfig" && !dep.name.is_empty() {
                        self.add_version_reqs(&dep.name, &dep.version_reqs);
                        reqs.push(dep.name.clone());
                    } else {
                        for arg in &dep.link_args {
                            processed.push(LibEntry::Str(arg.clone()));
                        }
                        cflags.extend(dep.compile_args.iter().cloned());
                    }
                }
                Object::String(value) => processed.push(LibEntry::Str(value.clone())),
                _ => {}
            }
        }
        (processed, reqs, cflags)
    }

    fn add_lib_dependencies(&mut self, target: &'a BuildTarget, public: bool) {
        self.add_dependency_graph(
            target.link_with.clone(),
            target.link_whole.clone(),
            target.dependencies.clone(),
            public,
            false,
        );
    }

    fn add_internal_dependencies(
        &mut self,
        link_with: Vec<Object>,
        link_whole: Vec<Object>,
        dependencies: Vec<Object>,
        public: bool,
    ) {
        self.add_dependency_graph(link_with, link_whole, dependencies, public, true);
    }

    fn add_dependency_graph(
        &mut self,
        link_with: Vec<Object>,
        link_whole: Vec<Object>,
        dependencies: Vec<Object>,
        public: bool,
        private_external_deps: bool,
    ) {
        for lib in &link_with {
            let Object::BuildTarget(target_ref) = lib else {
                self.add_libs(std::slice::from_ref(lib), public);
                continue;
            };
            let Some(linked) = self.find_target(&target_ref.id) else {
                continue;
            };
            if linked.target_type == TargetType::StaticLibrary && !linked.install {
                self.add_link_whole(linked, public);
            } else {
                self.add_libs(std::slice::from_ref(lib), public);
            }
        }
        for lib in &link_whole {
            let Object::BuildTarget(target_ref) = lib else {
                self.add_libs(std::slice::from_ref(lib), public);
                continue;
            };
            if let Some(linked) = self.find_target(&target_ref.id) {
                self.add_link_whole(linked, public);
            }
        }
        if private_external_deps || !public {
            self.add_priv_libs(&dependencies);
        } else {
            self.add_pub_libs(&dependencies);
        }
    }

    fn add_libs(&mut self, libs: &[Object], public: bool) {
        if public {
            self.add_pub_libs(libs);
        } else {
            self.add_priv_libs(libs);
        }
    }

    fn add_link_whole(&mut self, target: &'a BuildTarget, public: bool) {
        self.link_whole.push(target.id.clone());
        self.add_lib_dependencies(target, public);
    }

    fn remove_dups(&mut self) {
        let mut exclude: HashSet<String> = HashSet::new();
        for id in &self.link_whole {
            exclude.insert(id.clone());
        }
        self.pub_reqs = dedup_strings(&self.pub_reqs, false, &mut exclude);
        self.pub_libs = dedup_libs(&self.pub_libs, &mut exclude);
        self.priv_reqs = dedup_strings(&self.priv_reqs, false, &mut exclude);
        self.priv_libs = dedup_libs(&self.priv_libs, &mut exclude);
        let mut cflags_seen = HashSet::new();
        self.cflags.retain(|flag| cflags_seen.insert(flag.clone()));
    }

    fn format_reqs(&self, reqs: &[String]) -> String {
        let mut parts = Vec::new();
        for name in reqs {
            match self.version_reqs.get(name) {
                Some(version_reqs) => {
                    for version_req in version_reqs {
                        parts.push(format!("{} {}", name, format_version_req(version_req)));
                    }
                }
                None => parts.push(name.clone()),
            }
        }
        parts.join(", ")
    }

    fn library_name(&self, target: &BuildTarget) -> String {
        if let Some(prefix) = target.name_prefix.as_deref() {
            if prefix.is_empty() && target.name.starts_with("lib") {
                return target.name[3..].to_string();
            }
        }
        target.name.clone()
    }
}

fn flatten<'b>(objects: &'b [Object]) -> Vec<&'b Object> {
    fn collect<'b>(object: &'b Object, out: &mut Vec<&'b Object>) {
        match object {
            Object::Array(items) => {
                for item in items {
                    collect(item, out);
                }
            }
            other => out.push(other),
        }
    }
    let mut out = Vec::new();
    for object in objects {
        collect(object, &mut out);
    }
    out
}

fn dedup_strings(values: &[String], libs: bool, exclude: &mut HashSet<String>) -> Vec<String> {
    let mut result = Vec::new();
    for value in values {
        let cannot_dedup =
            libs && !value.starts_with("-l") && !value.starts_with("-L") && value != "-pthread";
        if !cannot_dedup && !exclude.insert(value.clone()) {
            continue;
        }
        result.push(value.clone());
    }
    result
}

fn dedup_libs(values: &[LibEntry], exclude: &mut HashSet<String>) -> Vec<LibEntry> {
    let mut result = Vec::new();
    for value in values {
        match value {
            LibEntry::Target(id) => {
                if !exclude.insert(id.clone()) {
                    continue;
                }
                result.push(value.clone());
            }
            LibEntry::Str(text) => {
                let cannot_dedup =
                    !text.starts_with("-l") && !text.starts_with("-L") && text != "-pthread";
                if !cannot_dedup && !exclude.insert(text.clone()) {
                    continue;
                }
                result.push(value.clone());
            }
        }
    }
    result
}

fn split_version_req(value: &str) -> Option<(String, Vec<String>)> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    for operator in [">=", "<=", "!=", "==", "=", ">", "<"] {
        if let Some(pos) = value.find(operator) {
            let name = value[..pos].trim();
            if name.is_empty() {
                return None;
            }
            let version = value[pos..].trim();
            return Some((name.to_string(), vec![version.to_string()]));
        }
    }
    Some((value.to_string(), Vec::new()))
}

fn format_version_req(version_req: &str) -> String {
    for operator in [">=", "<=", "!=", "==", "=", ">", "<"] {
        if let Some(rest) = version_req.strip_prefix(operator) {
            return format!("{} {}", operator, rest);
        }
    }
    version_req.to_string()
}

fn escape(value: &str) -> String {
    value.replace(' ', "\\ ")
}

fn make_relative(prefix: &str, subdir: &str) -> String {
    match Path::new(subdir).strip_prefix(prefix) {
        Ok(relative) => {
            let relative = relative.to_string_lossy();
            if relative.is_empty() {
                "${prefix}".to_string()
            } else {
                format!("${{prefix}}/{}", relative)
            }
        }
        Err(_) => subdir.to_string(),
    }
}

fn argument_objects(args: &[CallArg], name: &str) -> Vec<Object> {
    match VM::get_arg_value(args, name) {
        Some(Object::Array(items)) => items.clone(),
        Some(Object::None) | None => Vec::new(),
        Some(other) => vec![other.clone()],
    }
}

fn parse_variables(value: Option<&Object>) -> Result<Vec<(String, String)>, String> {
    let mut variables = Vec::new();
    let Some(value) = value else {
        return Ok(variables);
    };
    match value {
        Object::Dict(entries) => {
            for (key, value) in entries {
                variables.push((key.clone(), value.to_string_value()));
            }
        }
        Object::Array(items) => {
            for item in items {
                match item {
                    Object::String(text) => variables.push(parse_variable_entry(text)?),
                    other => variables.push(parse_variable_entry(&other.to_string_value())?),
                }
            }
        }
        Object::String(text) => variables.push(parse_variable_entry(text)?),
        other => {
            return Err(format!(
                "pkgconfig variables must be a dict or a list of strings, not {}",
                other.type_name()
            ))
        }
    }
    Ok(variables)
}

fn parse_variable_entry(text: &str) -> Result<(String, String), String> {
    text.split_once('=')
        .map(|(key, value)| (key.trim().to_string(), value.trim().to_string()))
        .ok_or_else(|| format!("pkgconfig variable '{text}' is not of the form name=value"))
}

fn directory_value(options: &HashMap<String, Object>, name: &str) -> String {
    options::builtin_string(options, name)
}

fn variable_directory(options: &HashMap<String, Object>, name: &str) -> String {
    let value = directory_value(options, name);
    if Path::new(&value).is_absolute() {
        value
    } else {
        format!("${{prefix}}/{}", value)
    }
}

fn target_type_name(target: &BuildTarget) -> &'static str {
    match target.target_type {
        TargetType::Executable => "executable",
        TargetType::SharedLibrary => "shared_library",
        TargetType::StaticLibrary => "static_library",
        TargetType::SharedModule => "shared_module",
        TargetType::BothLibraries => "both_libraries",
        TargetType::Jar => "jar",
    }
}

fn render_pc(
    directories: &[(&str, String)],
    srcdir: Option<&str>,
    fields: &PcFields,
    libs: &[String],
    libs_private: &[String],
    cflags: &[String],
) -> String {
    let mut pc = String::new();
    for (name, value) in directories {
        pc.push_str(&format!("{}={}\n", name, escape(value)));
    }
    if let Some(srcdir) = srcdir {
        pc.push_str(&format!("srcdir={}\n", escape(srcdir)));
    }
    if !fields.variables.is_empty() {
        pc.push('\n');
    }
    for (key, value) in fields.variables {
        pc.push_str(&format!("{}={}\n", key, escape(value)));
    }
    pc.push('\n');
    pc.push_str(&format!("Name: {}\n", fields.name));
    if !fields.description.is_empty() {
        pc.push_str(&format!("Description: {}\n", fields.description));
    }
    if !fields.url.is_empty() {
        pc.push_str(&format!("URL: {}\n", fields.url));
    }
    if !fields.license.is_empty() {
        pc.push_str(&format!("License: {}\n", fields.license));
    }
    pc.push_str(&format!("Version: {}\n", fields.version));
    if !fields.requires.is_empty() {
        pc.push_str(&format!("Requires: {}\n", fields.requires));
    }
    if !fields.requires_private.is_empty() {
        pc.push_str(&format!("Requires.private: {}\n", fields.requires_private));
    }
    if !fields.conflicts.is_empty() {
        pc.push_str(&format!("Conflicts: {}\n", fields.conflicts.join(" ")));
    }
    if !libs.is_empty() {
        pc.push_str(&format!("Libs: {}\n", libs.join(" ")));
    }
    if !libs_private.is_empty() {
        pc.push_str(&format!("Libs.private: {}\n", libs_private.join(" ")));
    }
    if !cflags.is_empty() {
        pc.push_str(&format!("Cflags: {}\n", cflags.join(" ")));
    }
    pc
}

fn libs_flags(deps: &DependenciesHelper, libs: &[LibEntry], mode: &FlagMode) -> Vec<String> {
    let mut out = Vec::new();
    let mut lflags: Vec<String> = Vec::new();
    for entry in libs {
        match entry {
            LibEntry::Str(value) => out.push(value.clone()),
            LibEntry::Target(id) => {
                let Some(target) = deps.find_target(id) else {
                    continue;
                };
                let flag = match mode {
                    FlagMode::Installed {
                        prefix,
                        default_libdir,
                    } => {
                        let custom_install_dir = match &target.install_dir {
                            Some(dir) => dir != default_libdir,
                            None => false,
                        };
                        if custom_install_dir {
                            let install_dir = target.install_dir.clone().unwrap_or_default();
                            format!("-L{}", escape(&make_relative(prefix, &install_dir)))
                        } else {
                            "-L${libdir}".to_string()
                        }
                    }
                    FlagMode::Uninstalled { build_root } => {
                        let target_dir = if target.subdir.is_empty() {
                            build_root.to_string()
                        } else {
                            format!("{}/{}", build_root, target.subdir)
                        };
                        format!("-L{}", escape(&make_relative(build_root, &target_dir)))
                    }
                };
                if !lflags.contains(&flag) {
                    lflags.push(flag.clone());
                    out.push(flag);
                }
                out.push(format!("-l{}", deps.library_name(target)));
            }
        }
    }
    out
}

fn uninstalled_cflags(vm: &VM, deps: &DependenciesHelper) -> Vec<String> {
    let build_root = vm.build_root.clone();
    let source_root = vm.source_root.clone();
    let mut cflags = Vec::new();
    let mut seen = HashSet::new();
    for entry in &deps.pub_libs {
        let LibEntry::Target(id) = entry else {
            continue;
        };
        let Some(target) = deps.find_target(id) else {
            continue;
        };
        let mut directories: Vec<String> = target.include_dirs.clone();
        directories.push(String::new());
        for directory in directories {
            let relative = if directory.is_empty() {
                target.subdir.clone()
            } else if target.subdir.is_empty() {
                directory.clone()
            } else {
                format!("{}/{}", target.subdir, directory)
            };
            for base in [&build_root, &source_root] {
                let path = if relative.is_empty() {
                    base.clone()
                } else {
                    format!("{}/{}", base, relative)
                };
                let flag = format!("-I{}", escape(&path));
                if seen.insert(flag.clone()) {
                    cflags.push(flag);
                }
            }
        }
    }
    for flag in &deps.cflags {
        cflags.push(escape(flag));
    }
    cflags
}

pub fn register(vm: &mut VM) {
    vm.method_registry.insert(
        ("module".to_string(), "pkgconfig.generate".to_string()),
        pkgconfig_generate,
    );
}

fn pkgconfig_generate(vm: &mut VM, _obj: &Object, args: &[CallArg]) -> Result<Object, String> {
    let positional = VM::get_positional_args(args);
    let targets = vm.build_data.targets.clone();
    let mainlib = positional.first().and_then(|object| match object {
        Object::BuildTarget(target_ref) => {
            targets.iter().find(|target| target.id == target_ref.id).cloned()
        }
        _ => None,
    });
    let legacy_name = match positional.first() {
        Some(Object::String(value)) => Some(value.clone()),
        _ => None,
    };

    let name = VM::get_arg_str(args, "name", 99)
        .map(|s| s.to_string())
        .or_else(|| mainlib.as_ref().map(|target| target.name.clone()))
        .or(legacy_name)
        .unwrap_or_default();
    let project_name = vm
        .project
        .as_ref()
        .map(|project| project.name.clone())
        .unwrap_or_default();
    let description = VM::get_arg_str(args, "description", 99)
        .map(|s| s.to_string())
        .unwrap_or_else(|| match &mainlib {
            Some(target) => format!("{}: {}", project_name, target.name),
            None => String::new(),
        });
    let version = VM::get_arg_str(args, "version", 99)
        .map(|s| s.to_string())
        .or_else(|| vm.project.as_ref().map(|p| p.version.clone()))
        .unwrap_or_else(|| "unset".to_string());
    let license = VM::get_arg_str(args, "license", 99)
        .unwrap_or("")
        .to_string();
    let filebase = VM::get_arg_str(args, "filebase", 99)
        .map(|s| s.to_string())
        .unwrap_or_else(|| name.clone());
    let url = VM::get_arg_str(args, "url", 99).unwrap_or("").to_string();
    let dataonly = VM::get_arg_bool(args, "dataonly", false);
    let relocatable = matches!(
        vm.options.get("pkgconfig.relocatable"),
        Some(Object::Bool(true))
    );

    let mut subdirs = VM::get_arg_string_array(args, "subdirs");
    if subdirs.is_empty() && !dataonly {
        subdirs.push(".".to_string());
    }
    let conflicts: Vec<String> = argument_objects(args, "conflicts")
        .iter()
        .map(|value| value.to_string_value())
        .collect();
    let variables = match parse_variables(VM::get_arg_value(args, "variables")) {
        Ok(variables) => variables,
        Err(e) => return Err(e),
    };

    let mut libraries = argument_objects(args, "libraries");
    if let Some(target) = &mainlib {
        libraries.insert(
            0,
            Object::BuildTarget(BuildTargetRef {
                name: target.name.clone(),
                id: target.id.clone(),
                target_type: target_type_name(target).to_string(),
                subdir: target.subdir.clone(),
                outputs: vec![target.output_name.clone()],
            }),
        );
    }
    let libraries_private = argument_objects(args, "libraries_private");
    let requires = argument_objects(args, "requires");
    let requires_private = argument_objects(args, "requires_private");
    let extra_cflags = VM::get_arg_string_array(args, "extra_cflags");

    let mut deps = DependenciesHelper::new(&targets, &vm.build_data.pkgconfig_metadata);
    deps.add_pub_libs(&libraries);
    deps.add_priv_libs(&libraries_private);
    deps.add_pub_reqs(&requires);
    deps.add_priv_reqs(&requires_private);
    deps.cflags.extend(extra_cflags);
    deps.remove_dups();

    let default_libdir = directory_value(&vm.options, "libdir");
    let default_install_dir = if dataonly {
        options::join_install_path(&directory_value(&vm.options, "datadir"), "pkgconfig")
    } else {
        options::join_install_path(&default_libdir, "pkgconfig")
    };
    let install_dir = VM::get_arg_str(args, "install_dir", 99)
        .map(String::from)
        .or_else(|| {
            mainlib.as_ref().and_then(|target| match &target.install_dir {
                Some(dir) if dir != &default_libdir => {
                    Some(options::join_install_path(dir, "pkgconfig"))
                }
                _ => None,
            })
        })
        .unwrap_or(default_install_dir);

    let prefix_option = directory_value(&vm.options, "prefix");
    let prefix = if relocatable {
        let pkgroot = if Path::new(&install_dir).is_absolute() {
            PathBuf::from(&install_dir)
        } else {
            Path::new(&prefix_option).join(&install_dir)
        };
        let relative = pkgroot.strip_prefix(&prefix_option).map_err(|_| {
            format!(
                "Pkgconfig prefix cannot be outside of the prefix when pkgconfig.relocatable=true. Pkgconfig prefix is {}.",
                pkgroot.display()
            )
        })?;
        let depth = relative.components().count();
        let mut result = "${pcfiledir}".to_string();
        for _ in 0..depth {
            result.push_str("/..");
        }
        result
    } else {
        prefix_option.clone()
    };

    let mut referenced: BTreeSet<&'static str> = BTreeSet::new();
    if !dataonly {
        referenced.insert("prefix");
        referenced.insert("includedir");
        if !deps.pub_libs.is_empty() || !deps.priv_libs.is_empty() {
            referenced.insert("libdir");
        }
    }
    let variable_names: HashSet<String> = variables
        .iter()
        .map(|(key, _)| key.clone())
        .collect();
    for (_, value) in &variables {
        for optname in DIRECTORY_OPTIONS {
            if value.starts_with(&format!("${{{}}}", optname)) && !variable_names.contains(*optname)
            {
                referenced.insert(optname);
                referenced.insert("prefix");
            }
        }
    }

    let mut directories = Vec::new();
    for optname in DIRECTORY_OPTIONS {
        if !referenced.contains(*optname) || variable_names.contains(*optname) {
            continue;
        }
        if *optname == "prefix" {
            directories.push((*optname, prefix.clone()));
        } else {
            directories.push((*optname, variable_directory(&vm.options, optname)));
        }
    }

    let fields = PcFields {
        name: &name,
        description: &description,
        version: &version,
        license: &license,
        url: &url,
        conflicts: &conflicts,
        variables: &variables,
        requires: deps.format_reqs(&deps.pub_reqs),
        requires_private: deps.format_reqs(&deps.priv_reqs),
    };

    let installed_mode = FlagMode::Installed {
        prefix: &prefix_option,
        default_libdir: &default_libdir,
    };
    let libs = libs_flags(&deps, &deps.pub_libs, &installed_mode);
    let libs_private = libs_flags(&deps, &deps.priv_libs, &installed_mode);
    let mut cflags = Vec::new();
    if !dataonly {
        for subdir in &subdirs {
            if subdir == "." {
                cflags.push("-I${includedir}".to_string());
            } else {
                cflags.push(format!(
                    "-I{}",
                    escape(&format!("${{includedir}}/{}", subdir))
                ));
            }
        }
        for flag in &deps.cflags {
            cflags.push(escape(flag));
        }
    }
    let pc = render_pc(&directories, None, &fields, &libs, &libs_private, &cflags);

    let pc_filename = format!("{}.pc", filebase);
    let build_path = Path::new(&vm.build_root)
        .join("meson-private")
        .join(&pc_filename);
    std::fs::create_dir_all(build_path.parent().unwrap_or(Path::new(".")))
        .map_err(|e| format!("Cannot create pkgconfig directory: {}", e))?;
    std::fs::write(&build_path, &pc)
        .map_err(|e| format!("Cannot write {}: {}", build_path.display(), e))?;

    let build_root = vm.build_root.clone();
    let uninstalled_mode = FlagMode::Uninstalled {
        build_root: &build_root,
    };
    let uninstalled_libs = libs_flags(&deps, &deps.pub_libs, &uninstalled_mode);
    let uninstalled_libs_private = libs_flags(&deps, &deps.priv_libs, &uninstalled_mode);
    let uninstalled_cflags = uninstalled_cflags(vm, &deps);
    let mut uninstalled_directories = Vec::new();
    for optname in DIRECTORY_OPTIONS {
        if !referenced.contains(*optname) {
            continue;
        }
        if *optname == "prefix" {
            uninstalled_directories.push((*optname, build_root.clone()));
        } else {
            uninstalled_directories.push((*optname, variable_directory(&vm.options, optname)));
        }
    }
    let uninstalled_pc = render_pc(
        &uninstalled_directories,
        Some(&vm.source_root),
        &fields,
        &uninstalled_libs,
        &uninstalled_libs_private,
        &uninstalled_cflags,
    );

    let register_ids: Vec<String> = if let Some(target) = &mainlib {
        vec![target.id.clone()]
    } else {
        deps.pub_libs
            .iter()
            .filter_map(|entry| match entry {
                LibEntry::Target(id) => Some(id.clone()),
                LibEntry::Str(_) => None,
            })
            .collect()
    };
    drop(deps);
    for id in register_ids {
        vm.build_data
            .pkgconfig_metadata
            .entry(id)
            .or_insert_with(|| (filebase.clone(), name.clone()));
    }
    let uninstalled_dir = Path::new(&vm.build_root).join("meson-uninstalled");
    std::fs::create_dir_all(&uninstalled_dir)
        .map_err(|e| format!("Cannot create pkgconfig directory: {}", e))?;
    let uninstalled_path = uninstalled_dir.join(format!("{}-uninstalled.pc", filebase));
    std::fs::write(&uninstalled_path, &uninstalled_pc)
        .map_err(|e| format!("Cannot write {}: {}", uninstalled_path.display(), e))?;

    vm.build_data.install_data.push(InstallData {
        sources: vec![build_path.to_string_lossy().to_string()],
        install_dir,
        install_mode: None,
        rename: Vec::new(),
        subdir: vm.current_subdir.clone(),
        preserve_path: false,
        strip_directory: false,
        exclude_files: Vec::new(),
        exclude_directories: Vec::new(),
        follow_symlinks: None,
    });

    Ok(Object::None)
}

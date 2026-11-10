/// Pkg-config module: generates .pc files for library targets.
use crate::objects::*;
use crate::vm::*;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

pub fn register(vm: &mut VM) {
    vm.method_registry.insert(
        ("module".to_string(), "pkgconfig.generate".to_string()),
        pkgconfig_generate,
    );
}

const BUILTIN_DIR_OPTIONS: [&str; 14] = [
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
enum LibItem {
    Str(String),
    Target(String),
}

#[derive(Clone)]
struct TargetInfo {
    name: String,
    target_type: TargetType,
    install: bool,
    install_dir: Option<String>,
    name_prefix: Option<String>,
    link_with: Vec<Object>,
    link_whole: Vec<Object>,
    dependencies: Vec<Object>,
}

impl TargetInfo {
    fn is_internal(&self) -> bool {
        self.target_type == TargetType::StaticLibrary && !self.install
    }
}

struct PcDeps<'a> {
    vm: &'a VM,
    prefix: String,
    pub_libs: Vec<LibItem>,
    pub_reqs: Vec<String>,
    priv_libs: Vec<LibItem>,
    priv_reqs: Vec<String>,
    cflags: Vec<String>,
    cflags_private: Vec<String>,
    version_reqs: BTreeMap<String, BTreeSet<String>>,
    link_whole: Vec<String>,
}

impl<'a> PcDeps<'a> {
    fn new(vm: &'a VM, prefix: String) -> Self {
        Self {
            vm,
            prefix,
            pub_libs: Vec::new(),
            pub_reqs: Vec::new(),
            priv_libs: Vec::new(),
            priv_reqs: Vec::new(),
            cflags: Vec::new(),
            cflags_private: Vec::new(),
            version_reqs: BTreeMap::new(),
            link_whole: Vec::new(),
        }
    }

    fn target_info(&self, id: &str) -> Option<TargetInfo> {
        let target = self
            .vm
            .build_data
            .targets
            .iter()
            .find(|target| target.id == id)?;
        Some(TargetInfo {
            name: target.name.clone(),
            target_type: target.target_type.clone(),
            install: target.install,
            install_dir: target.install_dir.clone(),
            name_prefix: target.name_prefix.clone(),
            link_with: target.link_with.clone(),
            link_whole: target.link_whole.clone(),
            dependencies: target.dependencies.clone(),
        })
    }

    fn metadata_filebase(&self, id: &str) -> Option<String> {
        self.vm
            .build_data
            .pkgconfig_metadata
            .get(id)
            .map(|(filebase, _)| filebase.clone())
    }

    fn is_shared_library_only(&self, id: &str) -> bool {
        self.vm.build_data.shared_library_only.contains(id)
    }

    fn add_pub_libs(&mut self, libs: &[Object]) {
        let (mut processed, reqs, cflags) = self.process_libs(libs, true);
        processed.extend(std::mem::take(&mut self.pub_libs));
        self.pub_libs = processed;
        self.pub_reqs.extend(reqs);
        self.cflags.extend(cflags);
    }

    fn add_priv_libs(&mut self, libs: &[Object]) {
        let (mut processed, reqs, _) = self.process_libs(libs, false);
        processed.extend(std::mem::take(&mut self.priv_libs));
        self.priv_libs = processed;
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

    fn add_cflags(&mut self, cflags: &[String]) {
        self.cflags.extend(cflags.iter().cloned());
    }

    fn add_cflags_private(&mut self, cflags: &[String]) {
        self.cflags_private.extend(cflags.iter().cloned());
    }

    fn process_reqs(&mut self, reqs: &[Object]) -> Vec<String> {
        let mut processed = Vec::new();
        for obj in reqs {
            match obj {
                Object::String(text) => {
                    if let Some((name, version_req)) = split_version_req(text) {
                        if let Some(version_req) = version_req {
                            self.version_reqs
                                .entry(name.clone())
                                .or_default()
                                .insert(version_req);
                        }
                        processed.push(name);
                    }
                }
                Object::BuildTarget(target) => {
                    if let Some(filebase) = self.metadata_filebase(&target.id) {
                        processed.push(filebase);
                    }
                }
                Object::CustomTarget(target) => {
                    if let Some(filebase) = self.metadata_filebase(&target.id) {
                        processed.push(filebase);
                    }
                }
                Object::Dependency(dep) => {
                    if !dep.found {
                        continue;
                    }
                    if dep.kind == "system" && dep.name == "threads" {
                        continue;
                    }
                    if dep.is_internal {
                        for target in &dep.link_with {
                            if let Some(id) = target_id(target) {
                                if let Some(filebase) = self.metadata_filebase(&id) {
                                    processed.push(filebase);
                                }
                            }
                        }
                    } else if dep.kind.is_empty() && !dep.name.is_empty() {
                        processed.push(dep.name.clone());
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
    ) -> (Vec<LibItem>, Vec<String>, Vec<String>) {
        let mut processed_libs = Vec::new();
        let mut processed_reqs = Vec::new();
        let mut processed_cflags = Vec::new();
        for obj in libs {
            match obj {
                Object::BuildTarget(target) => {
                    if let Some(filebase) = self.metadata_filebase(&target.id) {
                        processed_reqs.push(filebase);
                        continue;
                    }
                    let Some(info) = self.target_info(&target.id) else {
                        continue;
                    };
                    match info.target_type {
                        TargetType::SharedLibrary => {
                            processed_libs.push(LibItem::Target(target.id.clone()));
                            if !self.is_shared_library_only(&target.id) {
                                self.add_lib_dependencies(
                                    info.link_with,
                                    info.link_whole,
                                    info.dependencies,
                                    false,
                                    false,
                                );
                            }
                        }
                        TargetType::StaticLibrary => {
                            processed_libs.push(LibItem::Target(target.id.clone()));
                            self.add_lib_dependencies(
                                info.link_with,
                                info.link_whole,
                                info.dependencies,
                                public,
                                false,
                            );
                        }
                        _ => processed_libs.push(LibItem::Target(target.id.clone())),
                    }
                }
                Object::CustomTarget(target) => {
                    if let Some(filebase) = self.metadata_filebase(&target.id) {
                        processed_reqs.push(filebase);
                    } else {
                        processed_libs.push(LibItem::Target(target.id.clone()));
                    }
                }
                Object::BothLibraries(shared, static_lib) => {
                    let prefer_static = matches!(
                        self.pub_libs.first(),
                        Some(LibItem::Target(id)) if self.target_info(id).map(|t| t.target_type == TargetType::StaticLibrary).unwrap_or(false)
                    );
                    let chosen: &Object = if prefer_static {
                        static_lib.as_ref()
                    } else {
                        shared.as_ref()
                    };
                    let (libs, reqs, cflags) =
                        self.process_libs(std::slice::from_ref(chosen), public);
                    processed_libs.extend(libs);
                    processed_reqs.extend(reqs);
                    processed_cflags.extend(cflags);
                }
                Object::Dependency(dep) => {
                    self.process_dependency(
                        dep,
                        public,
                        &mut processed_libs,
                        &mut processed_reqs,
                        &mut processed_cflags,
                    );
                }
                Object::String(text) => processed_libs.push(LibItem::Str(text.clone())),
                _ => {}
            }
        }
        (processed_libs, processed_reqs, processed_cflags)
    }

    fn process_dependency(
        &mut self,
        dep: &DependencyData,
        public: bool,
        processed_libs: &mut Vec<LibItem>,
        processed_reqs: &mut Vec<String>,
        processed_cflags: &mut Vec<String>,
    ) {
        if !dep.found {
            return;
        }
        if dep.name == "valgrind" {
            return;
        }
        if dep.is_internal {
            processed_libs.extend(dep.link_args.iter().cloned().map(LibItem::Str));
            processed_cflags.extend(dep.compile_args.iter().cloned());
            self.add_lib_dependencies(
                dep.link_with.clone(),
                dep.link_whole.clone(),
                dep.dependencies.clone(),
                public,
                true,
            );
        } else if dep.kind.is_empty() {
            if !dep.name.is_empty() {
                processed_reqs.push(dep.name.clone());
            }
        } else {
            processed_libs.extend(dep.link_args.iter().cloned().map(LibItem::Str));
            processed_cflags.extend(dep.compile_args.iter().cloned());
        }
    }

    fn add_lib_dependencies(
        &mut self,
        link_targets: Vec<Object>,
        link_whole_targets: Vec<Object>,
        external_deps: Vec<Object>,
        public: bool,
        private_external_deps: bool,
    ) {
        for target in &link_targets {
            if let Some(id) = target_id(target) {
                if self.target_info(&id).map(|info| info.is_internal()).unwrap_or(false) {
                    self.add_link_whole(&id, public);
                } else {
                    self.add_libs(std::slice::from_ref(target), public);
                }
            } else {
                self.add_libs(std::slice::from_ref(target), public);
            }
        }
        for target in &link_whole_targets {
            if let Some(id) = target_id(target) {
                self.add_link_whole(&id, public);
            } else {
                self.add_libs(std::slice::from_ref(target), public);
            }
        }
        if private_external_deps || !public {
            self.add_priv_libs(&external_deps);
        } else {
            self.add_pub_libs(&external_deps);
        }
    }

    fn add_libs(&mut self, libs: &[Object], public: bool) {
        if public {
            self.add_pub_libs(libs);
        } else {
            self.add_priv_libs(libs);
        }
    }

    fn add_link_whole(&mut self, id: &str, public: bool) {
        self.link_whole.push(id.to_string());
        if let Some(info) = self.target_info(id) {
            self.add_lib_dependencies(
                info.link_with,
                info.link_whole,
                info.dependencies,
                public,
                false,
            );
        }
    }

    fn remove_dups(&mut self) {
        let mut exclude: HashSet<String> = HashSet::new();
        for id in self.link_whole.clone() {
            self.add_exclude(&LibItem::Target(id), &mut exclude);
        }
        let pub_reqs = std::mem::take(&mut self.pub_reqs);
        self.pub_reqs = dedup_strings(pub_reqs, &mut exclude);
        let pub_libs = std::mem::take(&mut self.pub_libs);
        let pub_libs = self.dedup_libs(pub_libs, true, &mut exclude);
        self.pub_libs = pub_libs;
        let priv_reqs = std::mem::take(&mut self.priv_reqs);
        self.priv_reqs = dedup_strings(priv_reqs, &mut exclude);
        let priv_libs = std::mem::take(&mut self.priv_libs);
        let priv_libs = self.dedup_libs(priv_libs, true, &mut exclude);
        self.priv_libs = priv_libs;
        exclude.clear();
        let cflags = std::mem::take(&mut self.cflags);
        self.cflags = dedup_strings(cflags, &mut exclude);
        let cflags_private = std::mem::take(&mut self.cflags_private);
        self.cflags_private = dedup_strings(cflags_private, &mut exclude);
    }

    fn dedup_libs(
        &self,
        items: Vec<LibItem>,
        libs: bool,
        exclude: &mut HashSet<String>,
    ) -> Vec<LibItem> {
        let mut result = Vec::new();
        for item in items {
            let cannot_dedup = libs
                && match &item {
                    LibItem::Str(text) => {
                        !text.starts_with("-l")
                            && !text.starts_with("-L")
                            && text != "-pthread"
                    }
                    LibItem::Target(_) => false,
                };
            if !cannot_dedup && self.add_exclude(&item, exclude) {
                continue;
            }
            result.push(item);
        }
        result
    }

    fn add_exclude(&self, item: &LibItem, exclude: &mut HashSet<String>) -> bool {
        let mut was_excluded = false;
        match item {
            LibItem::Str(text) => {
                if exclude.contains(text) {
                    was_excluded = true;
                } else {
                    exclude.insert(text.clone());
                }
            }
            LibItem::Target(id) => {
                if let Some((_, display_name)) =
                    self.vm.build_data.pkgconfig_metadata.get(id)
                {
                    if exclude.contains(display_name) {
                        was_excluded = true;
                    } else {
                        exclude.insert(display_name.clone());
                    }
                }
                if exclude.contains(id) {
                    was_excluded = true;
                } else {
                    exclude.insert(id.clone());
                }
            }
        }
        was_excluded
    }

    fn format_reqs(&self, names: &[String]) -> String {
        let mut result = Vec::new();
        for name in names {
            if let Some(version_reqs) = self.version_reqs.get(name) {
                if !version_reqs.is_empty() {
                    for version_req in version_reqs {
                        result.push(format!("{} {}", name, format_vreq(version_req)));
                    }
                    continue;
                }
            }
            result.push(name.clone());
        }
        result.join(", ")
    }

    fn libs_flags(&self, libs: &[LibItem]) -> Vec<String> {
        let mut result = Vec::new();
        let mut lflags: Vec<String> = Vec::new();
        for item in libs {
            match item {
                LibItem::Str(text) => result.push(text.clone()),
                LibItem::Target(id) => {
                    let Some(info) = self.target_info(id) else {
                        continue;
                    };
                    let lflag = if let Some(install_dir) = &info.install_dir {
                        format!("-L{}", escape(&make_relative(&self.prefix, install_dir)))
                    } else {
                        "-L${libdir}".to_string()
                    };
                    if !lflags.contains(&lflag) {
                        lflags.push(lflag.clone());
                        result.push(lflag);
                    }
                    result.push(format!("-l{}", link_name(&info)));
                }
            }
        }
        result
    }
}

fn target_id(obj: &Object) -> Option<String> {
    match obj {
        Object::BuildTarget(target) => Some(target.id.clone()),
        Object::BothLibraries(shared, _) => target_id(shared),
        _ => None,
    }
}

fn link_name(info: &TargetInfo) -> String {
    match &info.name_prefix {
        Some(prefix) if prefix.is_empty() && info.name.starts_with("lib") => {
            info.name[3..].to_string()
        }
        _ => info.name.clone(),
    }
}

fn split_version_req(text: &str) -> Option<(String, Option<String>)> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    for op in [">=", "<=", "!=", "==", "=", ">", "<"] {
        if let Some(position) = text.find(op) {
            if position == 0 {
                return None;
            }
            let name = text[..position].trim();
            if name.is_empty() {
                return None;
            }
            return Some((
                name.to_string(),
                Some(text[position..].trim().to_string()),
            ));
        }
    }
    Some((text.to_string(), None))
}

fn format_vreq(version_req: &str) -> String {
    for op in [">=", "<=", "!=", "==", "=", ">", "<"] {
        if let Some(rest) = version_req.strip_prefix(op) {
            return format!("{} {}", op, rest);
        }
    }
    version_req.to_string()
}

fn dedup_strings(items: Vec<String>, exclude: &mut HashSet<String>) -> Vec<String> {
    let mut result = Vec::new();
    for item in items {
        if exclude.contains(&item) {
            continue;
        }
        exclude.insert(item.clone());
        result.push(item);
    }
    result
}

fn escape(value: &str) -> String {
    value.replace(' ', "\\ ")
}

fn make_relative(prefix: &str, dir: &str) -> String {
    let prefix = prefix.trim_end_matches('/');
    if let Some(rest) = dir.strip_prefix(prefix) {
        if rest.is_empty() {
            return "${prefix}".to_string();
        }
        if rest.starts_with('/') {
            return format!("${{prefix}}{}", rest);
        }
    }
    if dir.starts_with('/') {
        dir.to_string()
    } else {
        format!("${{prefix}}/{}", dir)
    }
}

fn flatten_objects(value: Option<&Object>, out: &mut Vec<Object>) {
    match value {
        Some(Object::Array(items)) => {
            for item in items {
                flatten_objects(Some(item), out);
            }
        }
        Some(Object::None) | None => {}
        Some(item) => out.push(item.clone()),
    }
}

fn pkgconfig_generate(vm: &mut VM, _obj: &Object, args: &[CallArg]) -> Result<Object, String> {
    let positional = VM::get_positional_args(args);
    let main_object = match positional.first() {
        Some(Object::BuildTarget(_)) => positional.first().map(|obj| (*obj).clone()),
        Some(Object::BothLibraries(shared, _)) => Some((**shared).clone()),
        _ => None,
    };
    let main_target_id = main_object.as_ref().and_then(|obj| match obj {
        Object::BuildTarget(target) => Some(target.id.clone()),
        _ => None,
    });
    let main_name = main_object.as_ref().and_then(|obj| match obj {
        Object::BuildTarget(target) => Some(target.name.clone()),
        _ => None,
    });

    let dataonly = VM::get_arg_bool(args, "dataonly", false);
    let name = VM::get_arg_str(args, "name", 99)
        .map(|s| s.to_string())
        .or(main_name.clone())
        .unwrap_or_default();
    let project_name = vm
        .project
        .as_ref()
        .map(|project| project.name.clone())
        .unwrap_or_default();
    let description = VM::get_arg_str(args, "description", 99)
        .map(|s| s.to_string())
        .or_else(|| {
            main_name
                .as_ref()
                .map(|name| format!("{}: {}", project_name, name))
        })
        .unwrap_or_default();
    let version = VM::get_arg_str(args, "version", 99)
        .map(|s| s.to_string())
        .or_else(|| vm.project.as_ref().map(|project| project.version.clone()))
        .unwrap_or_else(|| "unset".to_string());
    let filebase = VM::get_arg_str(args, "filebase", 99)
        .map(|s| s.to_string())
        .unwrap_or_else(|| name.clone());
    let url = VM::get_arg_str(args, "url", 99).unwrap_or("").to_string();
    let license = VM::get_arg_str(args, "license", 99)
        .unwrap_or("")
        .to_string();

    let mut subdirs = VM::get_arg_string_array(args, "subdirs");
    if subdirs.is_empty() && !dataonly {
        subdirs.push(".".to_string());
    }

    let variables = pkgconfig_variables(VM::get_arg_value(args, "variables"))?;

    let mut libraries = Vec::new();
    if let Some(main_object) = &main_object {
        libraries.push(main_object.clone());
    }
    flatten_objects(VM::get_arg_value(args, "libraries"), &mut libraries);
    let mut libraries_private = Vec::new();
    flatten_objects(
        VM::get_arg_value(args, "libraries_private"),
        &mut libraries_private,
    );
    let mut requires = Vec::new();
    flatten_objects(VM::get_arg_value(args, "requires"), &mut requires);
    let mut requires_private = Vec::new();
    flatten_objects(
        VM::get_arg_value(args, "requires_private"),
        &mut requires_private,
    );
    let extra_cflags = VM::get_arg_string_array(args, "extra_cflags");
    let cflags_private = VM::get_arg_string_array(args, "cflags_private");

    let prefix = crate::builtins::functions::builtin_dir_option(vm, "prefix");
    let libdir = crate::builtins::functions::builtin_dir_option(vm, "libdir");
    let datadir = crate::builtins::functions::builtin_dir_option(vm, "datadir");

    let install_dir = VM::get_arg_str(args, "install_dir", 99)
        .map(|s| s.to_string())
        .unwrap_or_else(|| {
            if dataonly {
                format!("{}/pkgconfig", datadir)
            } else if let Some(install_dir) = main_object
                .as_ref()
                .and_then(|obj| match obj {
                    Object::BuildTarget(target) => vm
                        .build_data
                        .targets
                        .iter()
                        .find(|build| build.id == target.id)
                        .and_then(|build| build.install_dir.clone()),
                    _ => None,
                })
            {
                format!("{}/pkgconfig", install_dir)
            } else {
                format!("{}/pkgconfig", libdir)
            }
        });

    let (pc, register_ids) = {
        let mut deps = PcDeps::new(vm, prefix.clone());
        deps.add_pub_libs(&libraries);
        deps.add_priv_libs(&libraries_private);
        deps.add_pub_reqs(&requires);
        deps.add_priv_reqs(&requires_private);
        deps.add_cflags(&extra_cflags);
        deps.add_cflags_private(&cflags_private);
        deps.remove_dups();

        let varnames: HashSet<String> = variables.iter().map(|(key, _)| key.clone()).collect();
        let mut referenced: HashSet<&'static str> = HashSet::new();
        if !dataonly {
            referenced.insert("prefix");
            referenced.insert("includedir");
            if !deps.pub_libs.is_empty() || !deps.priv_libs.is_empty() {
                referenced.insert("libdir");
            }
        }
        for optname in BUILTIN_DIR_OPTIONS {
            let optvar = format!("${{{}}}", optname);
            if variables.iter().any(|(_, value)| value.starts_with(&optvar))
                && !varnames.contains(optname)
            {
                referenced.insert("prefix");
                referenced.insert(optname);
            }
        }

        let mut pc = String::new();
        for optname in BUILTIN_DIR_OPTIONS {
            if !referenced.contains(optname) || varnames.contains(optname) {
                continue;
            }
            if optname == "prefix" {
                pc.push_str(&format!("prefix={}\n", escape(&deps.prefix)));
            } else {
                let value = crate::builtins::functions::builtin_dir_option(deps.vm, optname);
                let rendered = if value.is_empty() {
                    "${prefix}".to_string()
                } else if value.starts_with('/') {
                    value
                } else {
                    format!("${{prefix}}/{}", value)
                };
                pc.push_str(&format!("{}={}\n", optname, escape(&rendered)));
            }
        }
        if !variables.is_empty() {
            pc.push('\n');
        }
        for (key, value) in &variables {
            pc.push_str(&format!("{}={}\n", key, escape(value)));
        }
        pc.push('\n');
        pc.push_str(&format!("Name: {}\n", name));
        if !description.is_empty() {
            pc.push_str(&format!("Description: {}\n", description));
        }
        if !url.is_empty() {
            pc.push_str(&format!("URL: {}\n", url));
        }
        if !license.is_empty() {
            pc.push_str(&format!("License: {}\n", license));
        }
        pc.push_str(&format!("Version: {}\n", version));
        let reqs = deps.format_reqs(&deps.pub_reqs);
        if !reqs.is_empty() {
            pc.push_str(&format!("Requires: {}\n", reqs));
        }
        let reqs = deps.format_reqs(&deps.priv_reqs);
        if !reqs.is_empty() {
            pc.push_str(&format!("Requires.private: {}\n", reqs));
        }
        if !deps.pub_libs.is_empty() {
            pc.push_str(&format!("Libs: {}\n", deps.libs_flags(&deps.pub_libs).join(" ")));
        }
        if !deps.priv_libs.is_empty() {
            pc.push_str(&format!(
                "Libs.private: {}\n",
                deps.libs_flags(&deps.priv_libs).join(" ")
            ));
        }
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
        }
        cflags.extend(deps.cflags.iter().map(|flag| escape(flag)));
        if !cflags.is_empty() && !dataonly {
            pc.push_str(&format!("Cflags: {}\n", cflags.join(" ")));
        }
        let cflags_private: Vec<String> = deps
            .cflags_private
            .iter()
            .map(|flag| escape(flag))
            .collect();
        if !cflags_private.is_empty() && !dataonly {
            pc.push_str(&format!("Cflags.private: {}\n", cflags_private.join(" ")));
        }

        let register_ids = if let Some(id) = &main_target_id {
            vec![id.clone()]
        } else {
            deps.pub_libs
                .iter()
                .filter_map(|item| match item {
                    LibItem::Target(id) => Some(id.clone()),
                    LibItem::Str(_) => None,
                })
                .collect()
        };
        (pc, register_ids)
    };

    for id in register_ids {
        vm.build_data
            .pkgconfig_metadata
            .entry(id)
            .or_insert_with(|| (filebase.clone(), name.clone()));
    }

    let pc_filename = format!("{}.pc", filebase);
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

    #[test]
    fn version_requirement_is_split_and_formatted() {
        assert_eq!(
            split_version_req("xcb>=1.10"),
            Some(("xcb".to_string(), Some(">=1.10".to_string())))
        );
        assert_eq!(
            split_version_req("libdrm >= 2.4.75"),
            Some(("libdrm".to_string(), Some(">= 2.4.75".to_string())))
        );
        assert_eq!(
            split_version_req("libva, wayland-client"),
            Some(("libva, wayland-client".to_string(), None))
        );
        assert_eq!(format_vreq(">=1.10"), ">= 1.10");
    }

    #[test]
    fn duplicate_requirement_names_keep_first_position() {
        let mut exclude = HashSet::new();
        let names = vec![
            "libffi".to_string(),
            "-lm".to_string(),
            "libffi".to_string(),
            "-lrt".to_string(),
            "-lrt".to_string(),
        ];
        assert_eq!(
            dedup_strings(names, &mut exclude),
            vec!["libffi".to_string(), "-lm".to_string(), "-lrt".to_string()]
        );
    }

    fn dependency(name: &str, kind: &str, link_args: &[&str]) -> Object {
        Object::Dependency(DependencyData {
            name: name.to_string(),
            found: true,
            version: String::new(),
            compile_args: Vec::new(),
            link_args: link_args.iter().map(|arg| arg.to_string()).collect(),
            link_with: Vec::new(),
            link_whole: Vec::new(),
            sources: Vec::new(),
            include_dirs: Vec::new(),
            dependencies: Vec::new(),
            variables: HashMap::new(),
            is_internal: false,
            kind: kind.to_string(),
            config_tool: None,
        })
    }

    fn target_ref(id: &str, name: &str) -> Object {
        Object::BuildTarget(BuildTargetRef {
            name: name.to_string(),
            id: id.to_string(),
            target_type: String::new(),
            subdir: ".".to_string(),
            outputs: Vec::new(),
        })
    }

    fn build_target(
        id: &str,
        name: &str,
        target_type: TargetType,
        install: bool,
        link_with: Vec<Object>,
        dependencies: Vec<Object>,
    ) -> BuildTarget {
        BuildTarget {
            name: name.to_string(),
            id: id.to_string(),
            target_type,
            sources: Vec::new(),
            objects: Vec::new(),
            dependencies,
            include_dirs: Vec::new(),
            link_with,
            link_whole: Vec::new(),
            link_args: Vec::new(),
            link_depends: Vec::new(),
            c_args: Vec::new(),
            cpp_args: Vec::new(),
            rust_args: Vec::new(),
            install,
            install_dir: None,
            install_mode: None,
            version: None,
            soversion: None,
            install_rpath: String::new(),
            build_rpath: String::new(),
            pic: None,
            pie: None,
            override_options: Vec::new(),
            gnu_symbol_visibility: String::new(),
            native: false,
            extra_files: Vec::new(),
            implicit_include_directories: true,
            win_subsystem: "console".to_string(),
            name_prefix: None,
            name_suffix: None,
            rust_crate_type: None,
            build_by_default: true,
            subdir: ".".to_string(),
            output_name: name.to_string(),
        }
    }

    #[test]
    fn requirements_and_private_libs_derive_from_target_dependencies() {
        let main = target_ref("main@.", "main");
        let mut vm = VM::new();
        vm.build_data.targets.push(build_target(
            "main@.",
            "main",
            TargetType::SharedLibrary,
            true,
            Vec::new(),
            vec![
                dependency("libffi", "", &[]),
                dependency("threads", "system", &["-pthread"]),
                dependency("m", "library", &["-lm"]),
            ],
        ));
        let mut deps = PcDeps::new(&vm, "/usr".to_string());
        deps.add_pub_libs(std::slice::from_ref(&main));
        deps.remove_dups();

        assert_eq!(
            deps.libs_flags(&deps.pub_libs),
            vec!["-L${libdir}".to_string(), "-lmain".to_string()]
        );
        assert!(deps.pub_reqs.is_empty());
        assert_eq!(deps.priv_reqs, vec!["libffi".to_string()]);
        assert_eq!(
            deps.libs_flags(&deps.priv_libs),
            vec!["-pthread".to_string(), "-lm".to_string()]
        );
    }

    #[test]
    fn internal_static_library_dependencies_become_private_libs() {
        let main = target_ref("main@.", "main");
        let private = target_ref("private@.", "private");
        let mut vm = VM::new();
        vm.build_data.targets.push(build_target(
            "main@.",
            "main",
            TargetType::SharedLibrary,
            true,
            vec![private.clone()],
            Vec::new(),
        ));
        vm.build_data.targets.push(build_target(
            "private@.",
            "private",
            TargetType::StaticLibrary,
            false,
            Vec::new(),
            vec![
                dependency("rt", "library", &["-lrt"]),
                dependency("libffi", "", &[]),
            ],
        ));
        let mut deps = PcDeps::new(&vm, "/usr".to_string());
        deps.add_pub_libs(std::slice::from_ref(&main));
        deps.remove_dups();

        assert!(deps.link_whole.contains(&"private@.".to_string()));
        assert_eq!(deps.priv_reqs, vec!["libffi".to_string()]);
        assert_eq!(
            deps.libs_flags(&deps.priv_libs),
            vec!["-lrt".to_string()]
        );
    }

    #[test]
    fn shared_library_only_targets_do_not_pull_dependencies() {
        let main = target_ref("main@.", "main");
        let mut vm = VM::new();
        vm.build_data
            .shared_library_only
            .insert("main@.".to_string());
        vm.build_data.targets.push(build_target(
            "main@.",
            "main",
            TargetType::SharedLibrary,
            true,
            Vec::new(),
            vec![dependency("libffi", "", &[])],
        ));
        let mut deps = PcDeps::new(&vm, "/usr".to_string());
        deps.add_pub_libs(std::slice::from_ref(&main));
        deps.remove_dups();

        assert!(deps.priv_reqs.is_empty());
        assert!(deps.priv_libs.is_empty());
    }
}

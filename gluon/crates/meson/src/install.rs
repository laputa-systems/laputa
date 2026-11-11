use crate::objects::Object;
use crate::options;
use crate::vm::{BuildData, BuildTarget, TargetType};
use deser_json::{Indent, SerializerConfig};
use deser_value::{Map, Value};
use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

const PLAN_FILE: &str = "meson-private/install_plan.json";
const JSON_PRETTY: SerializerConfig =
    SerializerConfig::builder().pretty(Indent::Spaces(2)).build();

#[derive(Debug, Clone, Default, PartialEq)]
pub struct InstallPlan {
    pub prefix: String,
    pub umask: String,
    pub files: Vec<InstallFile>,
    pub symlinks: Vec<InstallSymlink>,
    pub directories: Vec<InstallDirectory>,
    pub subdirs: Vec<InstallSubdir>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct InstallFile {
    pub source: String,
    pub destination: String,
    pub mode: Option<String>,
    pub kind: String,
    pub follow_symlinks: Option<bool>,
    pub install_rpath: Option<String>,
    pub build_rpaths: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct InstallSymlink {
    pub target: String,
    pub destination: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct InstallDirectory {
    pub destination: String,
    pub mode: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct InstallSubdir {
    pub source: String,
    pub destination: String,
    pub mode: Option<String>,
    pub exclude_files: Vec<String>,
    pub exclude_directories: Vec<String>,
    pub follow_symlinks: Option<bool>,
}

pub fn generate(
    build_data: &BuildData,
    options: &HashMap<String, Object>,
    source_root: &str,
    build_root: &str,
) -> Result<InstallPlan, String> {
    let mut plan = InstallPlan {
        prefix: options::builtin_string(options, "prefix"),
        umask: options::builtin_string(options, "install_umask"),
        ..InstallPlan::default()
    };

    for target in &build_data.targets {
        if !target.install {
            continue;
        }
        let dir = match &target.install_dir {
            Some(dir) => dir.clone(),
            None => default_target_dir(&target.target_type, options),
        };
        plan.files.push(InstallFile {
            source: build_output_path(build_root, &target.subdir, &target.output_name),
            destination: options::join_install_path(&dir, &target.output_name),
            mode: first_permission(target.install_mode.as_deref()),
            kind: "target".to_string(),
            follow_symlinks: None,
            install_rpath: if target.install_rpath.is_empty() {
                None
            } else {
                Some(target.install_rpath.clone())
            },
            build_rpaths: rpath_dirs_to_remove(target),
        });
        for (alias, alias_target) in target.install_aliases() {
            plan.symlinks.push(InstallSymlink {
                target: alias_target,
                destination: options::join_install_path(&dir, &alias),
            });
        }
    }

    for target in &build_data.custom_targets {
        if !target.install {
            continue;
        }
        if target.install_dir.is_empty() {
            return Err(format!(
                "custom_target '{}' has install: true but no install_dir",
                target.name
            ));
        }
        for (index, output) in target.output.iter().enumerate() {
            let dir = if target.install_dir.len() == 1 {
                target.install_dir[0].clone()
            } else if target.install_dir.len() == target.output.len() {
                target.install_dir[index].clone()
            } else {
                return Err(format!(
                    "custom_target '{}' has {} outputs but {} install_dir values",
                    target.name,
                    target.output.len(),
                    target.install_dir.len()
                ));
            };
            plan.files.push(InstallFile {
                source: build_output_path(build_root, &target.subdir, output),
                destination: options::join_install_path(&dir, output),
                mode: None,
                kind: "target".to_string(),
                follow_symlinks: None,
                install_rpath: None,
                build_rpaths: Vec::new(),
            });
        }
    }

    for configure in &build_data.configure_files {
        if !configure.install {
            continue;
        }
        let dir = configure.install_dir.clone().ok_or_else(|| {
            format!(
                "configure_file '{}' has install: true but no install_dir",
                configure.output
            )
        })?;
        let output = substitute_placeholders(&configure.output, configure.input.as_deref());
        plan.files.push(InstallFile {
            source: build_output_path(build_root, &configure.subdir, &configure.output),
            destination: options::join_install_path(&dir, &output),
            mode: None,
            kind: "configure".to_string(),
            follow_symlinks: None,
            install_rpath: None,
            build_rpaths: Vec::new(),
        });
    }

    for headers in &build_data.install_headers {
        for source in &headers.sources {
            let child = if headers.preserve_path {
                parent_directory(source)
            } else {
                ""
            };
            let dir = options::join_install_path(&headers.install_dir, child);
            plan.files.push(InstallFile {
                source: source_file_path(source_root, &headers.subdir, source),
                destination: options::join_install_path(&dir, &file_name(source)),
                mode: first_permission(headers.install_mode.as_deref()),
                kind: "headers".to_string(),
                follow_symlinks: headers.follow_symlinks,
                install_rpath: None,
                build_rpaths: Vec::new(),
            });
        }
    }

    for data in &build_data.install_data {
        for (index, source) in data.sources.iter().enumerate() {
            let renamed = data.rename.get(index).map(String::as_str);
            let child = if data.preserve_path {
                parent_directory(source)
            } else {
                ""
            };
            let dir = options::join_install_path(&data.install_dir, child);
            plan.files.push(InstallFile {
                source: source_file_path(source_root, &data.subdir, source),
                destination: options::join_install_path(
                    &dir,
                    renamed.unwrap_or_else(|| file_name(source)),
                ),
                mode: first_permission(data.install_mode.as_deref()),
                kind: "data".to_string(),
                follow_symlinks: data.follow_symlinks,
                install_rpath: None,
                build_rpaths: Vec::new(),
            });
        }
    }

    for man in &build_data.install_man {
        for source in &man.sources {
            let section = man_section(source)?;
            let dir = if man.install_dir.is_empty() {
                options::join_install_path(
                    &options::builtin_string(options, "mandir"),
                    &format!("man{}", section),
                )
            } else {
                man.install_dir.clone()
            };
            plan.files.push(InstallFile {
                source: source_file_path(source_root, &man.subdir, source),
                destination: options::join_install_path(&dir, &file_name(source)),
                mode: first_permission(man.install_mode.as_deref()),
                kind: "man".to_string(),
                follow_symlinks: None,
                install_rpath: None,
                build_rpaths: Vec::new(),
            });
        }
    }

    for subdir in &build_data.install_subdirs {
        let source = match subdir.sources.first() {
            Some(source) => source,
            None => continue,
        };
        let directory = source_file_path(source_root, &subdir.subdir, source);
        let base = subdir.install_dir.clone();
        let destination = if subdir.strip_directory {
            base
        } else {
            options::join_install_path(&base, Path::new(&directory).file_name().map(|n| n.to_string_lossy().to_string()).as_deref().unwrap_or(""))
        };
        plan.subdirs.push(InstallSubdir {
            source: directory,
            destination,
            mode: first_permission(subdir.install_mode.as_deref()),
            exclude_files: subdir.exclude_files.clone(),
            exclude_directories: subdir.exclude_directories.clone(),
            follow_symlinks: subdir.follow_symlinks,
        });
    }

    for directory in &build_data.install_empty_dirs {
        plan.directories.push(InstallDirectory {
            destination: directory.clone(),
            mode: None,
        });
    }

    for link in &build_data.install_symlinks {
        plan.symlinks.push(InstallSymlink {
            target: link.target.clone(),
            destination: options::join_install_path(&link.install_dir, &link.name),
        });
    }

    Ok(plan)
}

fn default_target_dir(target_type: &TargetType, options: &HashMap<String, Object>) -> String {
    match target_type {
        TargetType::Executable => options::builtin_string(options, "bindir"),
        TargetType::SharedLibrary | TargetType::StaticLibrary | TargetType::SharedModule => {
            options::builtin_string(options, "libdir")
        }
        TargetType::BothLibraries => options::builtin_string(options, "libdir"),
        TargetType::Jar => options::join_install_path(
            &options::builtin_string(options, "datadir"),
            "java",
        ),
    }
}

fn first_permission(mode: Option<&[String]>) -> Option<String> {
    mode.and_then(|parts| parts.first().cloned())
}

fn parent_directory(path: &str) -> &str {
    Path::new(path)
        .parent()
        .and_then(|parent| parent.to_str())
        .unwrap_or("")
}

fn file_name(path: &str) -> &str {
    Path::new(path)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(path)
}

fn man_section(source: &str) -> Result<u32, String> {
    let section = source.rsplit('.').next().unwrap_or("");
    match section.parse::<u32>() {
        Ok(section) if (1..=9).contains(&section) => Ok(section),
        _ => Err(format!(
            "Man file '{}' must have a file extension of a number between 1 and 9",
            source
        )),
    }
}

fn substitute_placeholders(output: &str, input: Option<&str>) -> String {
    let Some(input) = input else {
        return output.to_string();
    };
    let plain = file_name(input);
    let base = Path::new(plain)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or(plain);
    output
        .replace("@PLAINNAME@", plain)
        .replace("@BASENAME@", base)
}

fn source_file_path(source_root: &str, subdir: &str, source: &str) -> String {
    if Path::new(source).is_absolute() {
        return source.to_string();
    }
    if subdir.is_empty() {
        format!("{}/{}", source_root, source)
    } else {
        format!("{}/{}/{}", source_root, subdir, source)
    }
}

fn build_output_path(build_root: &str, subdir: &str, output: &str) -> String {
    if subdir.is_empty() {
        format!("{}/{}", build_root, output)
    } else {
        format!("{}/{}/{}", build_root, subdir, output)
    }
}

pub fn installed_path(prefix: &str, destination: &str) -> String {
    if Path::new(destination).is_absolute() {
        destination.to_string()
    } else if prefix.is_empty() {
        destination.to_string()
    } else {
        format!("{}/{}", prefix.trim_end_matches('/'), destination)
    }
}

pub fn installed_entries(plan: &InstallPlan) -> Vec<(String, String)> {
    let mut entries = Vec::new();
    for kind in ["target", "configure", "data", "headers", "man"] {
        for file in plan.files.iter().filter(|file| file.kind == kind) {
            entries.push((
                file.source.clone(),
                installed_path(&plan.prefix, &file.destination),
            ));
        }
    }
    for subdir in &plan.subdirs {
        entries.push((
            subdir.source.clone(),
            installed_path(&plan.prefix, &subdir.destination),
        ));
    }
    for link in &plan.symlinks {
        entries.push((
            file_name(&link.destination).to_string(),
            installed_path(&plan.prefix, &link.destination),
        ));
    }
    entries
}

pub fn write_plan(build_root: &str, plan: &InstallPlan) -> Result<(), String> {
    let path = format!("{}/{}", build_root, PLAN_FILE);
    let parent = Path::new(&path).parent().unwrap_or(Path::new("."));
    fs::create_dir_all(parent).map_err(|e| format!("Cannot create {}: {}", parent.display(), e))?;
    fs::write(&path, JSON_PRETTY.to_string(&plan.to_value()).unwrap())
        .map_err(|e| format!("Cannot write {}: {}", path, e))
}

pub fn read_plan(build_root: &str) -> Result<InstallPlan, String> {
    let path = format!("{}/{}", build_root, PLAN_FILE);
    let text = fs::read_to_string(&path)
        .map_err(|e| format!("Cannot read install plan {}: {}", path, e))?;
    let value: Value =
        deser_json::from_str(&text).map_err(|e| format!("Cannot parse {}: {}", path, e))?;
    InstallPlan::from_value(&value).map_err(|e| format!("Invalid install plan {}: {}", path, e))
}

impl InstallPlan {
    fn to_value(&self) -> Value {
        let mut map = Map::new();
        map.insert("prefix", self.prefix.clone());
        map.insert("umask", self.umask.clone());
        map.insert(
            "files",
            Value::from(self.files.iter().map(InstallFile::to_value).collect::<Vec<_>>()),
        );
        map.insert(
            "symlinks",
            Value::from(
                self.symlinks
                    .iter()
                    .map(InstallSymlink::to_value)
                    .collect::<Vec<_>>(),
            ),
        );
        map.insert(
            "directories",
            Value::from(
                self.directories
                    .iter()
                    .map(InstallDirectory::to_value)
                    .collect::<Vec<_>>(),
            ),
        );
        map.insert(
            "subdirs",
            Value::from(
                self.subdirs
                    .iter()
                    .map(InstallSubdir::to_value)
                    .collect::<Vec<_>>(),
            ),
        );
        Value::from(map)
    }

    fn from_value(value: &Value) -> Result<Self, String> {
        Ok(InstallPlan {
            prefix: string_field(value, "prefix")?,
            umask: string_field(value, "umask")?,
            files: sequence(value, "files")?
                .iter()
                .map(InstallFile::from_value)
                .collect::<Result<_, _>>()?,
            symlinks: sequence(value, "symlinks")?
                .iter()
                .map(InstallSymlink::from_value)
                .collect::<Result<_, _>>()?,
            directories: sequence(value, "directories")?
                .iter()
                .map(InstallDirectory::from_value)
                .collect::<Result<_, _>>()?,
            subdirs: sequence(value, "subdirs")?
                .iter()
                .map(InstallSubdir::from_value)
                .collect::<Result<_, _>>()?,
        })
    }
}

impl InstallFile {
    fn to_value(&self) -> Value {
        let mut map = Map::new();
        map.insert("source", self.source.clone());
        map.insert("destination", self.destination.clone());
        map.insert("mode", option_value(self.mode.as_deref()));
        map.insert("kind", self.kind.clone());
        map.insert("follow_symlinks", option_bool_value(self.follow_symlinks));
        map.insert("install_rpath", option_value(self.install_rpath.as_deref()));
        map.insert(
            "build_rpaths",
            Value::from(
                self.build_rpaths
                    .iter()
                    .map(|path| Value::from(path.clone()))
                    .collect::<Vec<_>>(),
            ),
        );
        Value::from(map)
    }

    fn from_value(value: &Value) -> Result<Self, String> {
        Ok(InstallFile {
            source: string_field(value, "source")?,
            destination: string_field(value, "destination")?,
            mode: optional_string(value, "mode"),
            kind: string_field(value, "kind")?,
            follow_symlinks: optional_bool(value, "follow_symlinks"),
            install_rpath: optional_string(value, "install_rpath"),
            build_rpaths: string_sequence(value, "build_rpaths"),
        })
    }
}

impl InstallSymlink {
    fn to_value(&self) -> Value {
        let mut map = Map::new();
        map.insert("target", self.target.clone());
        map.insert("destination", self.destination.clone());
        Value::from(map)
    }

    fn from_value(value: &Value) -> Result<Self, String> {
        Ok(InstallSymlink {
            target: string_field(value, "target")?,
            destination: string_field(value, "destination")?,
        })
    }
}

impl InstallDirectory {
    fn to_value(&self) -> Value {
        let mut map = Map::new();
        map.insert("destination", self.destination.clone());
        map.insert("mode", option_value(self.mode.as_deref()));
        Value::from(map)
    }

    fn from_value(value: &Value) -> Result<Self, String> {
        Ok(InstallDirectory {
            destination: string_field(value, "destination")?,
            mode: optional_string(value, "mode"),
        })
    }
}

impl InstallSubdir {
    fn to_value(&self) -> Value {
        let mut map = Map::new();
        map.insert("source", self.source.clone());
        map.insert("destination", self.destination.clone());
        map.insert("mode", option_value(self.mode.as_deref()));
        map.insert(
            "exclude_files",
            Value::from(self.exclude_files.iter().map(|s| Value::from(s.clone())).collect::<Vec<_>>()),
        );
        map.insert(
            "exclude_directories",
            Value::from(
                self.exclude_directories
                    .iter()
                    .map(|s| Value::from(s.clone()))
                    .collect::<Vec<_>>(),
            ),
        );
        map.insert("follow_symlinks", option_bool_value(self.follow_symlinks));
        Value::from(map)
    }

    fn from_value(value: &Value) -> Result<Self, String> {
        Ok(InstallSubdir {
            source: string_field(value, "source")?,
            destination: string_field(value, "destination")?,
            mode: optional_string(value, "mode"),
            exclude_files: string_sequence(value, "exclude_files"),
            exclude_directories: string_sequence(value, "exclude_directories"),
            follow_symlinks: optional_bool(value, "follow_symlinks"),
        })
    }
}

fn string_field(value: &Value, field: &str) -> Result<String, String> {
    value
        .get(field)
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .ok_or_else(|| format!("missing string field '{}'", field))
}

fn optional_string(value: &Value, field: &str) -> Option<String> {
    value.get(field).and_then(|v| v.as_str()).map(str::to_string)
}

fn optional_bool(value: &Value, field: &str) -> Option<bool> {
    value.get(field).and_then(|v| v.as_bool())
}

fn sequence<'a>(value: &'a Value, field: &str) -> Result<&'a deser_value::Seq, String> {
    value
        .get(field)
        .and_then(|v| v.as_seq())
        .ok_or_else(|| format!("missing sequence field '{}'", field))
}

fn string_sequence(value: &Value, field: &str) -> Vec<String> {
    value
        .get(field)
        .and_then(|v| v.as_seq())
        .map(|items| {
            items
                .iter()
                .filter_map(|v| v.as_str())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn option_value(value: Option<&str>) -> Value {
    match value {
        Some(value) => Value::from(value),
        None => Value::from(()),
    }
}

fn option_bool_value(value: Option<bool>) -> Value {
    match value {
        Some(value) => Value::from(value),
        None => Value::from(()),
    }
}

pub fn execute(
    plan: &InstallPlan,
    build_dir: &str,
    destdir: &str,
    strip: bool,
    strip_program: &str,
) -> Result<(), String> {
    let destdir = if destdir.is_empty() {
        String::new()
    } else if Path::new(destdir).is_absolute() {
        destdir.to_string()
    } else {
        format!("{}/{}", build_dir.trim_end_matches('/'), destdir)
    };
    let umask = parse_umask(&plan.umask);

    for subdir in &plan.subdirs {
        let destination = destdir_path(&destdir, &plan.prefix, &subdir.destination);
        copy_directory(subdir, &destination, umask)?;
    }
    for file in &plan.files {
        let destination = destdir_path(&destdir, &plan.prefix, &file.destination);
        copy_installed_file(
            &file.source,
            &destination,
            file.mode.as_deref(),
            umask,
            file.follow_symlinks,
        )?;
        if file.kind == "target" && cfg!(target_os = "macos") {
            let final_path = installed_path(&plan.prefix, &file.destination);
            fix_install_name(&file.source, &destination, &final_path)?;
        }
        if file.kind == "target" || file.kind == "configure" {
            if strip {
                strip_file(Path::new(&destination), strip_program)?;
            }
            adjust_rpath(
                Path::new(&destination),
                file.install_rpath.as_deref().unwrap_or(""),
                &file.build_rpaths,
            )?;
        }
    }
    for directory in &plan.directories {
        let destination = destdir_path(&destdir, &plan.prefix, &directory.destination);
        create_directories(&destination, umask)?;
        apply_directory_mode(&destination, directory.mode.as_deref(), umask)?;
    }
    for link in &plan.symlinks {
        let destination = destdir_path(&destdir, &plan.prefix, &link.destination);
        install_symlink(&link.target, &destination, umask)?;
    }

    Ok(())
}

fn fix_install_name(source: &str, destination: &str, final_path: &str) -> Result<(), String> {
    if !source.ends_with(".dylib") || !is_mach_o(destination) {
        return Ok(());
    }
    match Command::new("install_name_tool")
        .args(["-id", final_path, destination])
        .output()
    {
        Ok(output) if output.status.success() => Ok(()),
        Ok(output) => Err(format!(
            "install_name_tool failed for {}: {}",
            destination,
            String::from_utf8_lossy(&output.stderr).trim()
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!(
            "Cannot run install_name_tool for {}: {}",
            destination, error
        )),
    }
}

fn is_mach_o(path: &str) -> bool {
    use std::io::Read;
    let mut magic = [0u8; 4];
    fs::File::open(path)
        .and_then(|mut file| file.read_exact(&mut magic))
        .is_ok()
        && matches!(
            u32::from_be_bytes(magic),
            0xfeed_face | 0xfeed_facf | 0xcefa_edfe | 0xcffa_edfe | 0xcafe_babe | 0xbeba_feca
        )
}

fn destdir_path(destdir: &str, prefix: &str, destination: &str) -> String {
    let path = installed_path(prefix, destination);
    if destdir.is_empty() {
        path
    } else {
        format!(
            "{}/{}",
            destdir.trim_end_matches('/'),
            path.trim_start_matches('/')
        )
    }
}

fn is_elf(path: &Path) -> bool {
    use std::io::Read;
    let mut magic = [0u8; 4];
    match fs::File::open(path) {
        Ok(mut file) => file.read_exact(&mut magic).is_ok() && magic == [0x7f, b'E', b'L', b'F'],
        Err(_) => false,
    }
}

fn adjust_rpath(target: &Path, install_rpath: &str, build_rpaths: &[String]) -> Result<(), String> {
    if !is_elf(target) {
        return Ok(());
    }
    crate::elf::fix_rpath(target, build_rpaths, install_rpath)
        .map_err(|e| format!("Cannot adjust rpath on {}: {}", target.display(), e))
}

fn strip_file(target: &Path, strip_program: &str) -> Result<(), String> {
    if !is_elf(target) {
        return Ok(());
    }
    let mut command = Command::new(strip_program);
    if cfg!(target_os = "macos") {
        command.arg("-S").arg("-x");
    }
    let output = command.arg(target).output().map_err(|e| {
        format!(
            "Cannot run strip program '{}' on {}: {}",
            strip_program,
            target.display(),
            e
        )
    })?;
    if !output.status.success() {
        return Err(format!(
            "strip program '{}' failed on {} ({}): {}",
            strip_program,
            target.display(),
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(())
}

fn split_paths(value: &str) -> Vec<String> {
    value
        .split(':')
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect()
}

fn rpath_dirs_to_remove(target: &BuildTarget) -> Vec<String> {
    let mut paths = split_paths(&target.build_rpath);
    let mut directories = Vec::new();
    let mut linked: Vec<&Object> = Vec::new();
    linked.extend(target.link_with.iter());
    linked.extend(target.link_whole.iter());
    linked.extend(target.dependencies.iter());
    collect_link_directories(&linked, &mut directories);
    for directory in directories {
        let origin = origin_relative(&target.subdir, &directory);
        if !paths.contains(&origin) {
            paths.push(origin);
        }
    }
    paths
}

fn collect_link_directories(objects: &[&Object], directories: &mut Vec<String>) {
    for object in objects {
        match object {
            Object::BuildTarget(target) => {
                if target.target_type != "static_library"
                    && !directories.contains(&target.subdir)
                {
                    directories.push(target.subdir.clone());
                }
            }
            Object::Dependency(dependency) => {
                let nested: Vec<&Object> = dependency.dependencies.iter().collect();
                collect_link_directories(&nested, directories);
            }
            Object::Array(items) => {
                let nested: Vec<&Object> = items.iter().collect();
                collect_link_directories(&nested, directories);
            }
            Object::BothLibraries(shared, _) => {
                collect_link_directories(&[shared.as_ref()], directories);
            }
            _ => {}
        }
    }
}

fn origin_relative(from: &str, to: &str) -> String {
    let from_parts: Vec<&str> = from.split('/').filter(|s| !s.is_empty()).collect();
    let to_parts: Vec<&str> = to.split('/').filter(|s| !s.is_empty()).collect();
    let mut common = 0;
    while common < from_parts.len() && common < to_parts.len() && from_parts[common] == to_parts[common]
    {
        common += 1;
    }
    let mut relative: Vec<&str> = Vec::new();
    for _ in common..from_parts.len() {
        relative.push("..");
    }
    relative.extend_from_slice(&to_parts[common..]);
    if relative.is_empty() {
        "$ORIGIN/".to_string()
    } else {
        format!("$ORIGIN/{}", relative.join("/"))
    }
}

fn parse_umask(value: &str) -> Option<u32> {
    if value == "preserve" {
        return None;
    }
    u32::from_str_radix(value.trim_start_matches("0o"), 8).ok()
}

fn create_directories(path: &str, umask: Option<u32>) -> Result<(), String> {
    let umask = match umask {
        Some(umask) => umask,
        None => {
            return fs::create_dir_all(path)
                .map_err(|e| format!("Cannot create directory {}: {}", path, e));
        }
    };
    let mut missing = Vec::new();
    let mut current = std::path::PathBuf::from(path);
    while !current.exists() {
        missing.push(current.clone());
        match current.parent() {
            Some(parent) => current = parent.to_path_buf(),
            None => break,
        }
    }
    fs::create_dir_all(path).map_err(|e| format!("Cannot create directory {}: {}", path, e))?;
    for directory in missing {
        fs::set_permissions(
            &directory,
            fs::Permissions::from_mode(0o777 & !umask),
        )
        .map_err(|e| format!("Cannot set mode on {}: {}", directory.display(), e))?;
    }
    Ok(())
}

fn copy_installed_file(
    source: &str,
    destination: &str,
    mode: Option<&str>,
    umask: Option<u32>,
    follow_symlinks: Option<bool>,
) -> Result<(), String> {
    let metadata = fs::symlink_metadata(source)
        .map_err(|e| format!("Cannot read install source {}: {}", source, e))?;
    if metadata.is_dir() {
        return Err(format!(
            "Tried to install directory {} as a file",
            source
        ));
    }
    let parent = Path::new(destination)
        .parent()
        .ok_or_else(|| format!("Invalid install destination {}", destination))?;
    create_directories(&parent.to_string_lossy(), umask)?;
    if let Ok(existing) = fs::symlink_metadata(destination) {
        if existing.is_dir() {
            return Err(format!(
                "Destination {} already exists and is not a file",
                destination
            ));
        }
    }

    if metadata.file_type().is_symlink() && follow_symlinks == Some(false) {
        let target = fs::read_link(source)
            .map_err(|e| format!("Cannot read symlink {}: {}", source, e))?;
        install_symlink(&target.to_string_lossy(), destination, umask)?;
        return Ok(());
    }

    let temporary = temporary_path(destination);
    let _ = fs::remove_file(&temporary);
    fs::copy(source, &temporary)
        .map_err(|e| format!("Cannot install {} to {}: {}", source, destination, e))?;
    let executable = fs::metadata(source)
        .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false);
    if let Err(error) = apply_file_mode(&temporary, mode, umask, executable) {
        let _ = fs::remove_file(&temporary);
        return Err(error);
    }
    if let Err(error) = fs::rename(&temporary, destination) {
        let _ = fs::remove_file(&temporary);
        return Err(format!(
            "Cannot move {} to {}: {}",
            temporary, destination, error
        ));
    }
    Ok(())
}

fn temporary_path(destination: &str) -> String {
    format!("{}.meson-tmp-{}", destination, std::process::id())
}

fn apply_file_mode(
    path: &str,
    mode: Option<&str>,
    umask: Option<u32>,
    executable: bool,
) -> Result<(), String> {
    let permissions = match mode.and_then(symbolic_permissions) {
        Some(permissions) => permissions,
        None => match umask {
            Some(umask) if executable => 0o777 & !umask,
            Some(umask) => 0o666 & !umask,
            None => return Ok(()),
        },
    };
    fs::set_permissions(path, fs::Permissions::from_mode(permissions))
        .map_err(|e| format!("Cannot set mode on {}: {}", path, e))
}

fn apply_directory_mode(path: &str, mode: Option<&str>, umask: Option<u32>) -> Result<(), String> {
    let permissions = match mode.and_then(symbolic_permissions) {
        Some(permissions) => permissions,
        None => match umask {
            Some(umask) => 0o777 & !umask,
            None => return Ok(()),
        },
    };
    fs::set_permissions(path, fs::Permissions::from_mode(permissions))
        .map_err(|e| format!("Cannot set mode on {}: {}", path, e))
}

fn symbolic_permissions(perms: &str) -> Option<u32> {
    if perms.len() != 9 {
        return None;
    }
    let mut bits = 0u32;
    let shifts = [6u32, 3, 0];
    for (index, shift) in shifts.iter().enumerate() {
        let chars: Vec<char> = perms.chars().skip(index * 3).take(3).collect();
        if chars.len() != 3 {
            return None;
        }
        if chars[0] == 'r' {
            bits |= 0o4 << shift;
        }
        if chars[1] == 'w' {
            bits |= 0o2 << shift;
        }
        match chars[2] {
            'x' => bits |= 0o1 << shift,
            's' => {
                bits |= 0o1 << shift;
                if index == 0 {
                    bits |= 0o4000;
                } else if index == 1 {
                    bits |= 0o2000;
                }
            }
            'S' => {
                if index == 0 {
                    bits |= 0o4000;
                } else if index == 1 {
                    bits |= 0o2000;
                }
            }
            't' => {
                bits |= 0o1 << shift;
                bits |= 0o1000;
            }
            'T' => bits |= 0o1000,
            _ => {}
        }
    }
    Some(bits)
}

fn install_symlink(target: &str, destination: &str, umask: Option<u32>) -> Result<(), String> {
    let parent = Path::new(destination)
        .parent()
        .ok_or_else(|| format!("Invalid symlink destination {}", destination))?;
    create_directories(&parent.to_string_lossy(), umask)?;
    if let Ok(existing) = fs::symlink_metadata(destination) {
        if !existing.file_type().is_symlink() {
            return Err(format!(
                "Destination {} already exists and is not a symlink",
                destination
            ));
        }
        fs::remove_file(destination)
            .map_err(|e| format!("Cannot replace symlink {}: {}", destination, e))?;
    }
    let temporary = temporary_path(destination);
    let _ = fs::remove_file(&temporary);
    std::os::unix::fs::symlink(target, &temporary)
        .map_err(|e| format!("Cannot create symlink {}: {}", temporary, e))?;
    fs::rename(&temporary, destination)
        .map_err(|e| format!("Cannot move symlink to {}: {}", destination, e))
}

fn copy_directory(subdir: &InstallSubdir, destination: &str, umask: Option<u32>) -> Result<(), String> {
    create_directories(destination, umask)?;
    apply_directory_mode(destination, subdir.mode.as_deref(), umask)?;
    copy_directory_contents(Path::new(&subdir.source), Path::new(destination), subdir, umask)
}

fn copy_directory_contents(
    source: &Path,
    destination: &Path,
    subdir: &InstallSubdir,
    umask: Option<u32>,
) -> Result<(), String> {
    let entries = fs::read_dir(source)
        .map_err(|e| format!("Cannot read directory {}: {}", source.display(), e))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("Cannot read directory {}: {}", source.display(), e))?;
        let path = entry.path();
        let relative = path
            .strip_prefix(Path::new(&subdir.source))
            .map_err(|_| format!("Cannot relativize {}", path.display()))?
            .to_string_lossy()
            .to_string();
        let metadata = fs::symlink_metadata(&path)
            .map_err(|e| format!("Cannot read {}: {}", path.display(), e))?;
        if metadata.is_dir() && !metadata.file_type().is_symlink() {
            if subdir.exclude_directories.iter().any(|dir| dir == &relative) {
                continue;
            }
            let target = destination.join(&relative);
            create_directories(&target.to_string_lossy(), umask)?;
            apply_directory_mode(
                target.to_str().unwrap_or(""),
                subdir.mode.as_deref(),
                umask,
            )?;
            copy_directory_contents(&path, destination, subdir, umask)?;
            continue;
        }
        if subdir.exclude_files.iter().any(|file| file == &relative) {
            continue;
        }
        if metadata.is_dir() {
            continue;
        }
        let target = destination.join(&relative);
        let source_str = path.to_string_lossy().to_string();
        let target_str = target.to_string_lossy().to_string();
        copy_installed_file(
            &source_str,
            &target_str,
            subdir.mode.as_deref(),
            umask,
            subdir.follow_symlinks,
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn symbolic_permissions_match_meson_modes() {
        assert_eq!(symbolic_permissions("rw-r--r--"), Some(0o644));
        assert_eq!(symbolic_permissions("rwxr-xr-x"), Some(0o755));
        assert_eq!(symbolic_permissions("rwsr-sr-t"), Some(0o7755));
    }

    #[test]
    fn installed_path_prefixes_relative_destinations() {
        assert_eq!(installed_path("/usr/local", "lib/libfoo.a"), "/usr/local/lib/libfoo.a");
        assert_eq!(installed_path("/usr/local", "/opt/libfoo.a"), "/opt/libfoo.a");
        assert_eq!(installed_path("/usr/local", "bin/tool"), "/usr/local/bin/tool");
    }
}

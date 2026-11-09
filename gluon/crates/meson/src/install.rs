use crate::objects::Object;
use crate::vm::*;
use deser_json::{Indent, SerializerConfig};
use deser_value::value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

const JSON_PRETTY: SerializerConfig =
    SerializerConfig::builder().pretty(Indent::Spaces(2)).build();

#[derive(Debug, Clone)]
pub enum InstallSource {
    File(String),
    Symlink(String),
    Directory {
        path: String,
        exclude_files: Vec<String>,
        exclude_directories: Vec<String>,
        follow_symlinks: bool,
    },
    EmptyDir,
}

#[derive(Debug, Clone)]
pub struct InstallEntry {
    pub source: InstallSource,
    pub destination: String,
    pub mode: Option<u32>,
    pub tag: String,
    pub built: bool,
    pub install_rpath: Option<String>,
    pub build_rpaths: Vec<String>,
}

pub struct InstallContext<'a> {
    pub source_root: &'a str,
    pub build_root: &'a str,
    pub options: &'a HashMap<String, Object>,
}

pub fn build_install_plan(build_data: &BuildData, ctx: &InstallContext<'_>) -> Vec<InstallEntry> {
    let mut plan = Vec::new();
    let prefix = option_string(ctx.options, "prefix", "/usr/local");

    for target in &build_data.targets {
        if !target.install {
            continue;
        }
        let install_dir = target
            .install_dir
            .clone()
            .unwrap_or_else(|| default_target_dir(&target.target_type, ctx.options));
        let source = join(ctx.build_root, &join(&target.subdir, &target.output_name));
        let destination_path = destination(&prefix, &install_dir, &target.output_name);
        plan.push(InstallEntry {
            source: InstallSource::File(source),
            destination: destination_path,
            mode: install_mode_bits(&target.install_mode),
            tag: "runtime".to_string(),
            built: true,
            install_rpath: if target.install_rpath.is_empty() {
                None
            } else {
                Some(target.install_rpath.clone())
            },
            build_rpaths: if target.build_rpath.is_empty() {
                Vec::new()
            } else {
                split_paths(&target.build_rpath)
            },
        });
        for (link_name, link_target) in target.shared_library_symlinks() {
            plan.push(InstallEntry {
                source: InstallSource::Symlink(link_target),
                destination: destination(&prefix, &install_dir, &link_name),
                mode: None,
                tag: "runtime".to_string(),
                built: false,
                install_rpath: None,
                build_rpaths: Vec::new(),
            });
        }
    }

    for ct in &build_data.custom_targets {
        if !ct.install {
            continue;
        }
        for (index, output) in ct.output.iter().enumerate() {
            let install_dir = ct
                .install_dir
                .get(index)
                .or_else(|| ct.install_dir.first())
                .cloned()
                .unwrap_or_default();
            if install_dir.is_empty() {
                continue;
            }
            let source = join(ctx.build_root, &join(&ct.subdir, output));
            let name = basename(output);
            plan.push(InstallEntry {
                source: InstallSource::File(source),
                destination: destination(&prefix, &install_dir, &name),
                mode: None,
                tag: ct
                    .install_tag
                    .get(index)
                    .or_else(|| ct.install_tag.first())
                    .cloned()
                    .unwrap_or_else(|| "runtime".to_string()),
                built: true,
                install_rpath: None,
                build_rpaths: Vec::new(),
            });
        }
    }

    for cf in &build_data.configure_files {
        if !cf.install {
            continue;
        }
        let install_dir = cf.install_dir.clone().unwrap_or_default();
        if install_dir.is_empty() {
            continue;
        }
        let source = join(ctx.build_root, &join(&cf.subdir, &cf.output));
        let name = basename(&cf.output);
        plan.push(InstallEntry {
            source: InstallSource::File(source),
            destination: destination(&prefix, &install_dir, &name),
            mode: None,
            tag: cf
                .install_tag
                .clone()
                .unwrap_or_else(|| "runtime".to_string()),
            built: true,
            install_rpath: None,
            build_rpaths: Vec::new(),
        });
    }

    for data in &build_data.install_headers {
        for raw in &data.sources {
            let source = resolve_source(ctx, &data.subdir, raw);
            let name = source_name(ctx, &data.subdir, raw, data.preserve_path);
            plan.push(InstallEntry {
                source: InstallSource::File(source),
                destination: destination(&prefix, &data.install_dir, &name),
                mode: install_mode_bits(&data.install_mode),
                tag: "devel".to_string(),
                built: false,
                install_rpath: None,
                build_rpaths: Vec::new(),
            });
        }
    }

    for data in &build_data.install_data {
        for (index, raw) in data.sources.iter().enumerate() {
            let source = resolve_source(ctx, &data.subdir, raw);
            let name = data
                .rename
                .get(index)
                .filter(|s| !s.is_empty())
                .cloned()
                .unwrap_or_else(|| source_name(ctx, &data.subdir, raw, data.preserve_path));
            plan.push(InstallEntry {
                source: InstallSource::File(source),
                destination: destination(&prefix, &data.install_dir, &name),
                mode: install_mode_bits(&data.install_mode),
                tag: "runtime".to_string(),
                built: false,
                install_rpath: None,
                build_rpaths: Vec::new(),
            });
        }
    }

    for data in &build_data.install_man {
        for raw in &data.sources {
            let source = resolve_source(ctx, &data.subdir, raw);
            let file_name = basename(unwrap_source(raw));
            let section = man_section(&file_name)
                .map(|s| format!("man{}", s))
                .unwrap_or_default();
            let install_dir = if section.is_empty() {
                data.install_dir.clone()
            } else {
                join(&data.install_dir, &section)
            };
            plan.push(InstallEntry {
                source: InstallSource::File(source),
                destination: destination(&prefix, &install_dir, &file_name),
                mode: install_mode_bits(&data.install_mode),
                tag: "runtime".to_string(),
                built: false,
                install_rpath: None,
                build_rpaths: Vec::new(),
            });
        }
    }

    for data in &build_data.install_subdirs {
        for raw in &data.sources {
            let source = resolve_source(ctx, &data.subdir, raw);
            let install_dir = if data.strip_directory {
                data.install_dir.clone()
            } else {
                join(&data.install_dir, &basename(raw))
            };
            plan.push(InstallEntry {
                source: InstallSource::Directory {
                    path: source,
                    exclude_files: data.exclude_files.clone(),
                    exclude_directories: data.exclude_directories.clone(),
                    follow_symlinks: data.follow_symlinks.unwrap_or(false),
                },
                destination: destination(&prefix, &install_dir, ""),
                mode: install_mode_bits(&data.install_mode),
                tag: "runtime".to_string(),
                built: false,
                install_rpath: None,
                build_rpaths: Vec::new(),
            });
        }
    }

    for symlink in &build_data.install_symlinks {
        plan.push(InstallEntry {
            source: InstallSource::Symlink(symlink.target.clone()),
            destination: destination(&prefix, &symlink.install_dir, &symlink.name),
            mode: None,
            tag: "runtime".to_string(),
            built: false,
            install_rpath: None,
            build_rpaths: Vec::new(),
        });
    }

    for dir in &build_data.install_empty_dirs {
        plan.push(InstallEntry {
            source: InstallSource::EmptyDir,
            destination: destination(&prefix, dir, ""),
            mode: None,
            tag: "runtime".to_string(),
            built: false,
            install_rpath: None,
            build_rpaths: Vec::new(),
        });
    }

    plan
}

pub fn write_install_metadata(build_root: &str, plan: &[InstallEntry]) -> Result<(), String> {
    let intro_dir = format!("{}/meson-info", build_root);
    std::fs::create_dir_all(&intro_dir)
        .map_err(|e| format!("Cannot create introspection dir: {}", e))?;

    let mut installed = deser_value::Map::new();
    for entry in plan {
        match &entry.source {
            InstallSource::File(path) | InstallSource::Directory { path, .. } => {
                installed.insert(path.clone(), entry.destination.clone());
            }
            InstallSource::Symlink(_) => {
                installed.insert(basename(&entry.destination), entry.destination.clone());
            }
            InstallSource::EmptyDir => {}
        }
    }
    let installed = deser_value::Value::from(installed);
    std::fs::write(
        format!("{}/intro-installed.json", intro_dir),
        JSON_PRETTY
            .to_string(&installed)
            .map_err(|e| format!("Cannot serialize installed data: {}", e))?,
    )
    .map_err(|e| format!("Cannot write introspection: {}", e))?;

    let entries: Vec<deser_value::Value> = plan.iter().map(entry_to_value).collect();
    let private_dir = format!("{}/meson-private", build_root);
    std::fs::create_dir_all(&private_dir)
        .map_err(|e| format!("Cannot create meson-private: {}", e))?;
    std::fs::write(
        format!("{}/install_plan.json", private_dir),
        JSON_PRETTY
            .to_string(&deser_value::Value::from(entries))
            .map_err(|e| format!("Cannot serialize install plan: {}", e))?,
    )
    .map_err(|e| format!("Cannot write install plan: {}", e))?;

    Ok(())
}

fn entry_to_value(entry: &InstallEntry) -> deser_value::Value {
    match &entry.source {
        InstallSource::File(path) => value!({
            "kind": "file",
            "source": path.clone(),
            "dest": entry.destination.clone(),
            "mode": entry.mode,
            "tag": entry.tag.clone(),
            "built": entry.built,
            "install_rpath": entry.install_rpath.clone(),
            "build_rpaths": entry.build_rpaths.clone(),
        }),
        InstallSource::Symlink(target) => value!({
            "kind": "symlink",
            "target": target.clone(),
            "dest": entry.destination.clone(),
            "tag": entry.tag.clone(),
        }),
        InstallSource::Directory {
            path,
            exclude_files,
            exclude_directories,
            follow_symlinks,
        } => value!({
            "kind": "directory",
            "source": path.clone(),
            "dest": entry.destination.clone(),
            "mode": entry.mode,
            "tag": entry.tag.clone(),
            "exclude_files": exclude_files.clone(),
            "exclude_directories": exclude_directories.clone(),
            "follow_symlinks": *follow_symlinks,
        }),
        InstallSource::EmptyDir => value!({
            "kind": "emptydir",
            "dest": entry.destination.clone(),
            "tag": entry.tag.clone(),
        }),
    }
}

pub fn run_install(build_dir: &str, destdir: &str, strip: bool) -> Result<(), String> {
    let plan_file = format!("{}/meson-private/install_plan.json", build_dir);
    let text = std::fs::read_to_string(&plan_file)
        .map_err(|e| format!("Cannot read install plan {}: {}", plan_file, e))?;
    let entries: Vec<deser_value::Value> = deser_json::from_str(&text)
        .map_err(|e| format!("Cannot parse install plan {}: {}", plan_file, e))?;

    let destdir = normalize_destdir(destdir);
    for entry in &entries {
        let kind = entry.get("kind").and_then(|v| v.as_str()).unwrap_or("");
        let dest = entry_dest(entry)?;
        let target = prefixed(&destdir, &dest);
        match kind {
            "file" => {
                let source = entry.get("source").and_then(|v| v.as_str()).unwrap_or("");
                let mode = entry.get("mode").and_then(|v| v.as_i64()).map(|v| v as u32);
                install_file(source, &target, mode)?;
                let built = entry
                    .get("built")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                if built {
                    let install_rpath = entry
                        .get("install_rpath")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string());
                    let build_rpaths = string_seq(entry.get("build_rpaths"));
                    adjust_rpath(&target, install_rpath.as_deref(), &build_rpaths);
                    if strip {
                        strip_file(&target);
                    }
                }
            }
            "symlink" => {
                let link_target = entry.get("target").and_then(|v| v.as_str()).unwrap_or("");
                install_symlink(link_target, &target)?;
            }
            "directory" => {
                let source = entry.get("source").and_then(|v| v.as_str()).unwrap_or("");
                let mode = entry.get("mode").and_then(|v| v.as_i64()).map(|v| v as u32);
                let exclude_files = string_seq(entry.get("exclude_files"));
                let exclude_directories = string_seq(entry.get("exclude_directories"));
                let follow = entry
                    .get("follow_symlinks")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                install_directory(
                    source,
                    &target,
                    mode,
                    &exclude_files,
                    &exclude_directories,
                    follow,
                )?;
            }
            "emptydir" => {
                std::fs::create_dir_all(&target)
                    .map_err(|e| format!("Cannot create {}: {}", target.display(), e))?;
                set_mode(&target, 0o755)?;
            }
            _ => {}
        }
    }

    Ok(())
}

fn entry_dest(entry: &deser_value::Value) -> Result<String, String> {
    entry
        .get("dest")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| "install plan entry without destination".to_string())
}

fn install_file(source: &str, target: &Path, mode: Option<u32>) -> Result<(), String> {
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Cannot create {}: {}", parent.display(), e))?;
    }
    remove_existing(target);
    std::fs::copy(source, target).map_err(|e| {
        format!(
            "Cannot copy {} to {}: {}",
            source,
            target.display(),
            e
        )
    })?;
    if let Some(mode) = mode {
        set_mode(target, mode)?;
    }
    Ok(())
}

fn install_symlink(link_target: &str, target: &Path) -> Result<(), String> {
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Cannot create {}: {}", parent.display(), e))?;
    }
    remove_existing(target);
    std::os::unix::fs::symlink(link_target, target).map_err(|e| {
        format!(
            "Cannot create symlink {} -> {}: {}",
            target.display(),
            link_target,
            e
        )
    })
}

fn install_directory(
    source: &str,
    target: &Path,
    mode: Option<u32>,
    exclude_files: &[String],
    exclude_directories: &[String],
    follow_symlinks: bool,
) -> Result<(), String> {
    std::fs::create_dir_all(target)
        .map_err(|e| format!("Cannot create {}: {}", target.display(), e))?;
    copy_directory(
        Path::new(source),
        target,
        "",
        mode,
        exclude_files,
        exclude_directories,
        follow_symlinks,
    )
}

fn copy_directory(
    source: &Path,
    destination: &Path,
    relative: &str,
    mode: Option<u32>,
    exclude_files: &[String],
    exclude_directories: &[String],
    follow_symlinks: bool,
) -> Result<(), String> {
    let entries = std::fs::read_dir(source)
        .map_err(|e| format!("Cannot read directory {}: {}", source.display(), e))?;
    let mut names: Vec<String> = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| format!("Cannot read directory {}: {}", source.display(), e))?;
        names.push(entry.file_name().to_string_lossy().to_string());
    }
    names.sort();
    for name in names {
        let source_path = source.join(&name);
        let relative_path = if relative.is_empty() {
            name.clone()
        } else {
            format!("{}/{}", relative, name)
        };
        let target_path = destination.join(&relative_path);
        let metadata = std::fs::symlink_metadata(&source_path)
            .map_err(|e| format!("Cannot stat {}: {}", source_path.display(), e))?;
        let file_type = metadata.file_type();
        if file_type.is_symlink() {
            if let Some(parent) = target_path.parent() {
                std::fs::create_dir_all(parent)
                    .map_err(|e| format!("Cannot create {}: {}", parent.display(), e))?;
            }
            remove_existing(&target_path);
            if follow_symlinks {
                if let Ok(resolved) = std::fs::canonicalize(&source_path) {
                    std::fs::copy(&resolved, &target_path).map_err(|e| {
                        format!(
                            "Cannot copy {} to {}: {}",
                            resolved.display(),
                            target_path.display(),
                            e
                        )
                    })?;
                    if let Some(mode) = mode {
                        set_mode(&target_path, mode)?;
                    }
                    continue;
                }
            }
            let target = std::fs::read_link(&source_path)
                .map_err(|e| format!("Cannot read symlink {}: {}", source_path.display(), e))?;
            std::os::unix::fs::symlink(&target, &target_path).map_err(|e| {
                format!(
                    "Cannot create symlink {} -> {}: {}",
                    target_path.display(),
                    target.display(),
                    e
                )
            })?;
            continue;
        }
        if file_type.is_dir() {
            if exclude_directories.iter().any(|d| d == &relative_path) {
                continue;
            }
            std::fs::create_dir_all(&target_path)
                .map_err(|e| format!("Cannot create {}: {}", target_path.display(), e))?;
            copy_directory(
                &source_path,
                destination,
                &relative_path,
                mode,
                exclude_files,
                exclude_directories,
                follow_symlinks,
            )?;
            continue;
        }
        if exclude_files.iter().any(|f| f == &relative_path) {
            continue;
        }
        if let Some(parent) = target_path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("Cannot create {}: {}", parent.display(), e))?;
        }
        remove_existing(&target_path);
        std::fs::copy(&source_path, &target_path).map_err(|e| {
            format!(
                "Cannot copy {} to {}: {}",
                source_path.display(),
                target_path.display(),
                e
            )
        })?;
        if let Some(mode) = mode {
            set_mode(&target_path, mode)?;
        }
    }
    Ok(())
}

fn remove_existing(path: &Path) {
    if let Ok(metadata) = std::fs::symlink_metadata(path) {
        if metadata.file_type().is_dir() {
            let _ = std::fs::remove_dir_all(path);
        } else {
            let _ = std::fs::remove_file(path);
        }
    }
}

fn set_mode(path: &Path, mode: u32) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
        .map_err(|e| format!("Cannot set mode on {}: {}", path.display(), e))
}

fn is_elf(path: &Path) -> bool {
    use std::io::Read;
    let mut magic = [0u8; 4];
    match std::fs::File::open(path) {
        Ok(mut file) => file.read_exact(&mut magic).is_ok() && magic == [0x7f, b'E', b'L', b'F'],
        Err(_) => false,
    }
}

fn adjust_rpath(target: &Path, install_rpath: Option<&str>, build_rpaths: &[String]) {
    if !is_elf(target) {
        return;
    }
    if let Some(rpath) = install_rpath {
        let _ = std::process::Command::new("patchelf")
            .arg("--set-rpath")
            .arg(rpath)
            .arg(target)
            .status();
    } else if !build_rpaths.is_empty() {
        let _ = std::process::Command::new("patchelf")
            .arg("--remove-rpath")
            .arg(target)
            .status();
    }
}

fn strip_file(target: &Path) {
    if !is_elf(target) {
        return;
    }
    let _ = std::process::Command::new("strip")
        .arg("--strip-unneeded")
        .arg(target)
        .status();
}

fn normalize_destdir(destdir: &str) -> String {
    if destdir.is_empty() {
        return String::new();
    }
    let path = Path::new(destdir);
    let resolved = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_default()
            .join(path)
    };
    resolved.to_string_lossy().trim_end_matches('/').to_string()
}

fn prefixed(destdir: &str, dest: &str) -> PathBuf {
    if destdir.is_empty() {
        PathBuf::from(dest)
    } else if dest.starts_with('/') {
        PathBuf::from(format!("{}{}", destdir, dest))
    } else {
        PathBuf::from(format!("{}/{}", destdir, dest))
    }
}

fn string_seq(value: Option<&deser_value::Value>) -> Vec<String> {
    value
        .and_then(|v| v.as_seq())
        .map(|seq| {
            seq.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

fn option_string(options: &HashMap<String, Object>, name: &str, default: &str) -> String {
    match options.get(name) {
        Some(Object::String(s)) => s.clone(),
        _ => default.to_string(),
    }
}

fn default_target_dir(target_type: &TargetType, options: &HashMap<String, Object>) -> String {
    match target_type {
        TargetType::Executable => option_string(options, "bindir", "bin"),
        TargetType::SharedLibrary
        | TargetType::StaticLibrary
        | TargetType::SharedModule
        | TargetType::BothLibraries
        | TargetType::Jar => option_string(options, "libdir", "lib"),
    }
}

fn install_mode_bits(mode: &Option<Vec<String>>) -> Option<u32> {
    let spec = mode.as_ref()?.first()?.trim();
    parse_mode(spec)
}

pub fn parse_mode(spec: &str) -> Option<u32> {
    if spec.is_empty() {
        return None;
    }
    if spec.chars().all(|c| c.is_ascii_digit() && c < '8') {
        return u32::from_str_radix(spec, 8).ok();
    }
    if spec.len() == 9 {
        let mut mode = 0u32;
        for (index, c) in spec.chars().enumerate() {
            let bit = match c {
                'r' | 'w' | 'x' | 's' | 't' => 1u32 << (8 - index),
                '-' | 'S' | 'T' => 0,
                _ => return None,
            };
            mode |= bit;
        }
        return Some(mode);
    }
    None
}

fn resolve_source(ctx: &InstallContext<'_>, subdir: &str, raw: &str) -> String {
    if let Some(inner) = raw
        .strip_prefix("<orderonly:")
        .and_then(|s| s.strip_suffix('>'))
        .or_else(|| raw.strip_prefix("<genout:").and_then(|s| s.strip_suffix('>')))
    {
        return join(ctx.build_root, inner);
    }
    if Path::new(raw).is_absolute() {
        return raw.to_string();
    }
    join(ctx.source_root, &join(subdir, raw))
}

fn source_name(ctx: &InstallContext<'_>, subdir: &str, raw: &str, preserve_path: bool) -> String {
    if preserve_path {
        if raw.starts_with("<orderonly:") || raw.starts_with("<genout:") {
            return basename(unwrap_source(raw));
        }
        return raw.to_string();
    }
    let _ = ctx;
    let _ = subdir;
    basename(unwrap_source(raw))
}

fn unwrap_source(raw: &str) -> &str {
    raw.strip_prefix("<orderonly:")
        .and_then(|s| s.strip_suffix('>'))
        .or_else(|| raw.strip_prefix("<genout:").and_then(|s| s.strip_suffix('>')))
        .unwrap_or(raw)
}

fn man_section(file_name: &str) -> Option<String> {
    let extension = Path::new(file_name).extension()?.to_string_lossy().to_string();
    if extension.chars().next().map(|c| c.is_ascii_digit()) == Some(true) {
        Some(extension)
    } else {
        None
    }
}

fn split_paths(value: &str) -> Vec<String> {
    value
        .split(':')
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect()
}

fn basename(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| path.to_string())
}

fn destination(prefix: &str, install_dir: &str, name: &str) -> String {
    let base = if install_dir.starts_with('/') {
        install_dir.to_string()
    } else {
        join(prefix, install_dir)
    };
    if name.is_empty() {
        base
    } else {
        join(&base, name)
    }
}

fn join(left: &str, right: &str) -> String {
    if left.is_empty() {
        return right.to_string();
    }
    if right.is_empty() {
        return left.to_string();
    }
    format!(
        "{}/{}",
        left.trim_end_matches('/'),
        right.trim_start_matches('/')
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::objects::Object;
    use crate::vm::{BuildData, BuildTarget, InstallData, TargetType};
    use std::os::unix::fs::PermissionsExt;

    fn options() -> HashMap<String, Object> {
        let mut options = HashMap::new();
        options.insert("prefix".to_string(), Object::String("/usr".to_string()));
        options.insert("libdir".to_string(), Object::String("lib".to_string()));
        options
    }

    fn shared_library() -> BuildTarget {
        BuildTarget {
            name: "foo".to_string(),
            id: "foo@".to_string(),
            target_type: TargetType::SharedLibrary,
            sources: vec!["foo.c".to_string()],
            objects: Vec::new(),
            dependencies: Vec::new(),
            include_dirs: Vec::new(),
            link_with: Vec::new(),
            link_whole: Vec::new(),
            link_args: Vec::new(),
            link_depends: Vec::new(),
            c_args: Vec::new(),
            cpp_args: Vec::new(),
            rust_args: Vec::new(),
            install: true,
            install_dir: None,
            install_mode: None,
            version: Some("1.2.3".to_string()),
            soversion: Some("1".to_string()),
            install_rpath: String::new(),
            build_rpath: String::new(),
            pic: Some(true),
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
            subdir: String::new(),
            output_name: "libfoo.so.1.2.3".to_string(),
        }
    }

    fn plan_with(roots: (&str, &str)) -> Vec<InstallEntry> {
        let options = options();
        let mut data = BuildData::default();
        data.targets.push(shared_library());
        data.install_headers.push(InstallData {
            sources: vec!["include/foo/foo.h".to_string()],
            install_dir: "include/foo".to_string(),
            install_mode: None,
            rename: Vec::new(),
            subdir: String::new(),
            preserve_path: false,
            strip_directory: false,
            exclude_files: Vec::new(),
            exclude_directories: Vec::new(),
            follow_symlinks: None,
        });
        data.install_data.push(InstallData {
            sources: vec![format!("{}/meson-private/foo.pc", roots.1)],
            install_dir: "lib/pkgconfig".to_string(),
            install_mode: None,
            rename: Vec::new(),
            subdir: String::new(),
            preserve_path: false,
            strip_directory: false,
            exclude_files: Vec::new(),
            exclude_directories: Vec::new(),
            follow_symlinks: None,
        });
        build_install_plan(
            &data,
            &InstallContext {
                source_root: roots.0,
                build_root: roots.1,
                options: &options,
            },
        )
    }

    #[test]
    fn versioned_library_installs_symlinks() {
        let plan = plan_with(("/src", "/build"));
        let links: Vec<(String, String)> = plan
            .iter()
            .filter_map(|entry| match &entry.source {
                InstallSource::Symlink(target) => {
                    Some((basename(&entry.destination), target.clone()))
                }
                _ => None,
            })
            .collect();
        assert_eq!(
            links,
            vec![
                ("libfoo.so.1".to_string(), "libfoo.so.1.2.3".to_string()),
                ("libfoo.so".to_string(), "libfoo.so.1".to_string()),
            ]
        );
        let file = plan
            .iter()
            .find(|entry| matches!(entry.source, InstallSource::File(_)) && entry.built)
            .expect("library file entry");
        assert_eq!(file.destination, "/usr/lib/libfoo.so.1.2.3");
    }

    #[test]
    fn soversion_without_version_links_base_only() {
        let mut target = shared_library();
        target.version = None;
        target.soversion = Some("1".to_string());
        target.output_name = "libfoo.so.1".to_string();
        assert_eq!(target.shared_library_soname().as_deref(), Some("libfoo.so.1"));
        assert_eq!(
            target.shared_library_symlinks(),
            vec![("libfoo.so".to_string(), "libfoo.so.1".to_string())]
        );
    }

    #[test]
    fn install_mode_parsing() {
        assert_eq!(parse_mode("rwxr-xr-x"), Some(0o755));
        assert_eq!(parse_mode("644"), Some(0o644));
        assert_eq!(parse_mode("0755"), Some(0o755));
        assert_eq!(parse_mode("preserve"), None);
    }

    #[test]
    fn install_writes_files_symlinks_modes_and_introspection() {
        let root = std::env::temp_dir().join(format!(
            "gluon-install-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let src = root.join("src");
        let build = root.join("build");
        let dest = root.join("dest");
        std::fs::create_dir_all(src.join("include/foo")).unwrap();
        std::fs::create_dir_all(build.join("meson-private")).unwrap();
        let library = build.join("libfoo.so.1.2.3");
        std::fs::write(&library, b"library").unwrap();
        std::fs::set_permissions(&library, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::write(src.join("include/foo/foo.h"), b"header").unwrap();
        std::fs::write(build.join("meson-private/foo.pc"), b"prefix=/usr\n").unwrap();

        let roots = (src.to_str().unwrap(), build.to_str().unwrap());
        let plan = plan_with(roots);
        write_install_metadata(roots.1, &plan).unwrap();
        run_install(roots.1, dest.to_str().unwrap(), false).unwrap();

        let installed = dest.join("usr/lib/libfoo.so.1.2.3");
        assert_eq!(std::fs::read(&installed).unwrap(), b"library");
        assert_eq!(
            std::fs::metadata(&installed).unwrap().permissions().mode() & 0o777,
            0o755
        );
        assert_eq!(
            std::fs::read_link(dest.join("usr/lib/libfoo.so.1")).unwrap(),
            PathBuf::from("libfoo.so.1.2.3")
        );
        assert_eq!(
            std::fs::read_link(dest.join("usr/lib/libfoo.so")).unwrap(),
            PathBuf::from("libfoo.so.1")
        );
        assert_eq!(
            std::fs::metadata(dest.join("usr/include/foo/foo.h"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o644
        );
        assert!(dest.join("usr/lib/pkgconfig/foo.pc").is_file());

        let intro = std::fs::read_to_string(build.join("meson-info/intro-installed.json")).unwrap();
        assert!(intro.contains("\"/usr/lib/libfoo.so.1.2.3\""));
        assert!(intro.contains("\"libfoo.so\""));
        assert!(intro.contains("\"/usr/include/foo/foo.h\""));

        std::fs::remove_dir_all(&root).ok();
    }
}


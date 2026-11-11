use crate::ast;
use crate::objects::{FeatureState, Object};
/// Options system: parsing meson_options.txt/meson.options, built-in options,
/// cross/native files, and version comparison.
use std::collections::HashMap;

const BUILTIN_OPTION_KEYS: &[&str] = &[
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
    "auto_features",
    "backend",
    "genvslite",
    "buildtype",
    "debug",
    "default_library",
    "default_both_libraries",
    "errorlogs",
    "install_umask",
    "layout",
    "namingscheme",
    "optimization",
    "prefer_static",
    "stdsplit",
    "strip",
    "unity",
    "unity_size",
    "warning_level",
    "werror",
    "wrap_mode",
    "force_fallback_for",
    "vsenv",
    "os2_emxomf",
    "pkgconfig.relocatable",
    "python.bytecompile",
    "python.install_env",
    "python.platlibdir",
    "python.purelibdir",
    "python.allow_limited_api",
    "python.build_config",
    "pkg_config_path",
    "build.pkg_config_path",
    "cmake_prefix_path",
    "build.cmake_prefix_path",
];

pub fn builtin_option_key(flag: &str) -> Option<String> {
    let key = if flag == "warnlevel" {
        "warning_level".to_string()
    } else {
        flag.replace('-', "_")
    };
    if BUILTIN_OPTION_KEYS.contains(&key.as_str()) {
        Some(key)
    } else {
        None
    }
}

fn builtin_option_kind(key: &str) -> &'static str {
    match key {
        "debug" | "errorlogs" | "prefer_static" | "stdsplit" | "strip" | "werror" | "vsenv"
        | "os2_emxomf" | "pkgconfig.relocatable" | "python.allow_limited_api" => "bool",
        "unity_size" | "python.bytecompile" => "integer",
        "force_fallback_for" | "pkg_config_path" | "build.pkg_config_path"
        | "cmake_prefix_path" | "build.cmake_prefix_path" => "array",
        _ => "string",
    }
}

pub fn builtin_option_is_boolean(key: &str) -> bool {
    builtin_option_kind(key) == "bool"
}

fn builtin_string_default(key: &str) -> Option<&'static str> {
    match key {
        "prefix" => Some("/usr/local"),
        "bindir" => Some("bin"),
        "libdir" => Some("lib"),
        "libexecdir" => Some("libexec"),
        "includedir" => Some("include"),
        "datadir" => Some("share"),
        "mandir" => Some("share/man"),
        "infodir" => Some("share/info"),
        "localedir" => Some("share/locale"),
        "sysconfdir" => Some("etc"),
        "localstatedir" => Some("var"),
        "sharedstatedir" => Some("com"),
        "sbindir" => Some("sbin"),
        "licensedir" => Some("share/licenses"),
        "install_umask" => Some("0022"),
        _ => None,
    }
}

fn prefix_dependent_default(prefix: &str, key: &str) -> Option<&'static str> {
    match (prefix.trim_end_matches('/'), key) {
        ("/usr", "sysconfdir") => Some("/etc"),
        ("/usr", "localstatedir") => Some("/var"),
        ("/usr", "sharedstatedir") => Some("/var/lib"),
        ("/usr/local", "localstatedir") => Some("/var/local"),
        ("/usr/local", "sharedstatedir") => Some("/var/local/lib"),
        _ => None,
    }
}

pub fn builtin_string(options: &HashMap<String, Object>, key: &str) -> String {
    match options.get(key) {
        Some(Object::String(value)) => value.clone(),
        Some(Object::Int(value)) => value.to_string(),
        _ => {
            let prefix = match options.get("prefix") {
                Some(Object::String(prefix)) => prefix.as_str(),
                _ => "/usr/local",
            };
            prefix_dependent_default(prefix, key)
                .or_else(|| builtin_string_default(key))
                .unwrap_or("")
                .to_string()
        }
    }
}

pub fn join_install_path(base: &str, child: &str) -> String {
    if child.is_empty() {
        return base.to_string();
    }
    if std::path::Path::new(child).is_absolute() || base.is_empty() || base == "." {
        return child.to_string();
    }
    format!("{}/{}", base.trim_end_matches('/'), child)
}

pub fn parse_builtin_option_value(key: &str, value: &str) -> Object {
    match builtin_option_kind(key) {
        "bool" => Object::Bool(value == "true" || value == "1"),
        "integer" => value
            .parse::<i64>()
            .map(Object::Int)
            .unwrap_or(Object::Int(0)),
        "array" => Object::Array(
            value
                .split(',')
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .map(|s| Object::String(s.to_string()))
                .collect(),
        ),
        _ => Object::String(value.to_string()),
    }
}

pub fn buildtype_dependents(buildtype: &str) -> Option<(&'static str, bool)> {
    match buildtype {
        "plain" => Some(("plain", false)),
        "debug" => Some(("0", true)),
        "debugoptimized" => Some(("2", true)),
        "release" => Some(("3", false)),
        "minsize" => Some(("s", true)),
        _ => None,
    }
}

pub fn effective_optimization(options: &HashMap<String, Object>) -> String {
    if let Some(value) = options.get("optimization") {
        if let Object::String(s) = value {
            return s.clone();
        }
    }
    if let Some(Object::String(buildtype)) = options.get("buildtype") {
        if let Some((optimization, _)) = buildtype_dependents(buildtype) {
            return optimization.to_string();
        }
    }
    "0".to_string()
}

pub fn effective_debug(options: &HashMap<String, Object>) -> bool {
    if let Some(Object::Bool(debug)) = options.get("debug") {
        return *debug;
    }
    if let Some(Object::String(buildtype)) = options.get("buildtype") {
        if let Some((_, debug)) = buildtype_dependents(buildtype) {
            return debug;
        }
    }
    true
}

pub fn split_shell_args(value: &str) -> Vec<String> {
    let mut args = Vec::new();
    let mut current = String::new();
    let mut in_arg = false;
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        match c {
            '\'' => {
                in_arg = true;
                for q in chars.by_ref() {
                    if q == '\'' {
                        break;
                    }
                    current.push(q);
                }
            }
            '"' => {
                in_arg = true;
                while let Some(q) = chars.next() {
                    match q {
                        '"' => break,
                        '\\' => match chars.next() {
                            Some(e @ ('"' | '\\' | '$' | '`')) => current.push(e),
                            Some('\n') => {}
                            Some(e) => {
                                current.push('\\');
                                current.push(e);
                            }
                            None => current.push('\\'),
                        },
                        other => current.push(other),
                    }
                }
            }
            '\\' => {
                in_arg = true;
                match chars.next() {
                    Some('\n') => {}
                    Some(e) => current.push(e),
                    None => {}
                }
            }
            c if c.is_whitespace() => {
                if in_arg {
                    args.push(std::mem::take(&mut current));
                    in_arg = false;
                }
            }
            other => {
                in_arg = true;
                current.push(other);
            }
        }
    }
    if in_arg {
        args.push(current);
    }
    args
}

/// Compiler and linker options Meson seeds from CPPFLAGS, CFLAGS, CXXFLAGS,
/// OBJCFLAGS, OBJCXXFLAGS, and LDFLAGS for a native build.
pub fn env_flag_options(env: impl Fn(&str) -> Option<String>) -> Vec<(String, Vec<String>)> {
    const LANGUAGES: &[(&str, &str)] = &[
        ("c", "CFLAGS"),
        ("cpp", "CXXFLAGS"),
        ("objc", "OBJCFLAGS"),
        ("objcpp", "OBJCXXFLAGS"),
    ];
    let split = |name: &str| env(name).map(|value| split_shell_args(&value));
    let cppflags = split("CPPFLAGS");
    let ldflags = split("LDFLAGS");
    let mut options = Vec::new();
    for (lang, var) in LANGUAGES {
        let langflags = split(var);
        if cppflags.is_some() || langflags.is_some() {
            let mut args = cppflags.clone().unwrap_or_default();
            args.extend(langflags.unwrap_or_default());
            options.push((format!("{}_args", lang), args));
        }
        if let Some(ldflags) = &ldflags {
            options.push((format!("{}_link_args", lang), ldflags.clone()));
        }
    }
    options
}

/// Parse a value string into an Object
pub fn parse_option_value(value: &str) -> Object {
    match value {
        "true" => Object::Bool(true),
        "false" => Object::Bool(false),
        "enabled" => Object::Feature(FeatureState::Enabled),
        "disabled" => Object::Feature(FeatureState::Disabled),
        "auto" => Object::Feature(FeatureState::Auto),
        _ => {
            if let Ok(n) = value.parse::<i64>() {
                Object::Int(n)
            } else if value.starts_with('[') && value.ends_with(']') {
                let inner = &value[1..value.len() - 1];
                let items: Vec<Object> = inner
                    .split(',')
                    .map(|s| {
                        Object::String(s.trim().trim_matches('\'').trim_matches('"').to_string())
                    })
                    .collect();
                Object::Array(items)
            } else {
                Object::String(value.to_string())
            }
        }
    }
}

/// Evaluate a constant expression from the options file AST.
fn eval_const_expr(expr: &ast::Expression) -> Option<Object> {
    match expr {
        ast::Expression::StringLiteral(s, _) => Some(Object::String(s.clone())),
        ast::Expression::IntLiteral(n, _) => Some(Object::Int(*n)),
        ast::Expression::BoolLiteral(b, _) => Some(Object::Bool(*b)),
        ast::Expression::Identifier(s, _) => match s.as_str() {
            "true" => Some(Object::Bool(true)),
            "false" => Some(Object::Bool(false)),
            _ => Some(Object::String(s.clone())),
        },
        ast::Expression::Array(items, _) => {
            let evaluated: Option<Vec<Object>> = items.iter().map(eval_const_expr).collect();
            evaluated.map(Object::Array)
        }
        ast::Expression::UnaryOp(op, inner, _) => {
            let val = eval_const_expr(inner)?;
            match op {
                ast::UnaryOp::Not => {
                    if let Object::Bool(b) = val {
                        Some(Object::Bool(!b))
                    } else {
                        None
                    }
                }
                ast::UnaryOp::Negate => {
                    if let Object::Int(n) = val {
                        Some(Object::Int(-n))
                    } else {
                        None
                    }
                }
            }
        }
        ast::Expression::BinaryOp(op, left, right, _) => {
            let l = eval_const_expr(left)?;
            let r = eval_const_expr(right)?;
            match op {
                ast::BinaryOp::Add => match (l, r) {
                    (Object::String(a), Object::String(b)) => Some(Object::String(a + &b)),
                    (Object::Int(a), Object::Int(b)) => Some(Object::Int(a + b)),
                    _ => None,
                },
                ast::BinaryOp::Sub => match (l, r) {
                    (Object::Int(a), Object::Int(b)) => Some(Object::Int(a - b)),
                    _ => None,
                },
                ast::BinaryOp::Mul => match (l, r) {
                    (Object::Int(a), Object::Int(b)) => Some(Object::Int(a * b)),
                    _ => None,
                },
                _ => None,
            }
        }
        ast::Expression::Dict(entries, _) => {
            let mut map = Vec::new();
            for (k, v) in entries {
                let key = eval_const_expr(k)?;
                let val = eval_const_expr(v)?;
                map.push((obj_to_string(&key), val));
            }
            Some(Object::Dict(map))
        }
        _ => None,
    }
}

fn obj_to_string(obj: &Object) -> String {
    match obj {
        Object::String(s) => s.clone(),
        Object::Int(n) => n.to_string(),
        Object::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}

/// Parse a meson_options.txt / meson.options file.
pub fn parse_options_file(source: &str, options: &mut HashMap<String, Object>) {
    let mut lexer = crate::lexer::Lexer::new(source);
    let tokens = match lexer.tokenize() {
        Ok(t) => t,
        Err(_) => return,
    };
    let mut parser = crate::parser::Parser::new(tokens);
    let program = match parser.parse() {
        Ok(p) => p,
        Err(_) => return,
    };
    for stmt in &program.statements {
        if let ast::Statement::Expression(ast::Expression::FunctionCall(func, args, _)) = stmt {
            if let ast::Expression::Identifier(name, _) = func.as_ref() {
                if name == "option" {
                    parse_option_call(args, options);
                }
            }
        }
    }
}

fn parse_option_call(args: &[ast::Argument], options: &mut HashMap<String, Object>) {
    let mut name = String::new();
    let mut opt_type = String::new();
    let mut value = None;
    let mut choices = Vec::new();
    for (i, arg) in args.iter().enumerate() {
        match arg.name.as_deref() {
            None if i == 0 => {
                if let Some(obj) = eval_const_expr(&arg.value) {
                    name = obj_to_string(&obj);
                }
            }
            Some("type") => {
                if let Some(obj) = eval_const_expr(&arg.value) {
                    opt_type = obj_to_string(&obj);
                }
            }
            Some("value") => {
                value = eval_const_expr(&arg.value);
            }
            Some("choices") => {
                if let Some(Object::Array(items)) = eval_const_expr(&arg.value) {
                    choices = items.into_iter().map(|o| obj_to_string(&o)).collect();
                }
            }
            _ => {}
        }
    }
    if name.is_empty() {
        return;
    }
    let value = value.map(|v| coerce_option_value(v, &opt_type));
    let default_value = value.unwrap_or_else(|| match opt_type.as_str() {
        "boolean" => Object::Bool(true),
        "integer" => Object::Int(0),
        "string" => Object::String(String::new()),
        "combo" => choices
            .first()
            .map(|f| Object::String(f.clone()))
            .unwrap_or(Object::String(String::new())),
        "array" => {
            if choices.is_empty() {
                Object::Array(Vec::new())
            } else {
                Object::Array(choices.iter().map(|c| Object::String(c.clone())).collect())
            }
        }
        "feature" => Object::Feature(FeatureState::Auto),
        _ => Object::String(String::new()),
    });
    options.entry(name).or_insert(default_value);
}

/// Option definition with metadata (including yield)
pub struct OptionDef {
    pub name: String,
    pub opt_type: String,
    pub default_value: Object,
    pub yield_to_parent: bool,
    pub deprecated: Option<DeprecatedInfo>,
}

/// Information about deprecated option
pub enum DeprecatedInfo {
    /// Option is fully deprecated (deprecated: true)
    Bool(bool),
    /// Renamed to another option
    Renamed(String),
    /// Value remapping
    ValueMap(std::collections::HashMap<String, String>),
    /// List of deprecated values (warning only, no remapping)
    DeprecatedValues(Vec<String>),
}

fn default_for_type(opt_type: &str, choices: &[String]) -> Object {
    match opt_type {
        "boolean" => Object::Bool(true),
        "integer" => Object::Int(0),
        "string" => Object::String(String::new()),
        "combo" => choices
            .first()
            .map(|f| Object::String(f.clone()))
            .unwrap_or(Object::String(String::new())),
        "array" => {
            if choices.is_empty() {
                Object::Array(Vec::new())
            } else {
                Object::Array(choices.iter().map(|c| Object::String(c.clone())).collect())
            }
        }
        "feature" => Object::Feature(FeatureState::Auto),
        _ => Object::String(String::new()),
    }
}

/// Parse a meson_options.txt / meson.options file and return structured defs.
pub fn parse_options_file_defs(source: &str) -> Vec<OptionDef> {
    let mut defs = Vec::new();
    let mut lexer = crate::lexer::Lexer::new(source);
    let tokens = match lexer.tokenize() {
        Ok(t) => t,
        Err(_) => return defs,
    };
    let mut parser = crate::parser::Parser::new(tokens);
    let program = match parser.parse() {
        Ok(p) => p,
        Err(_) => return defs,
    };
    for stmt in &program.statements {
        if let ast::Statement::Expression(ast::Expression::FunctionCall(func, args, _)) = stmt {
            if let ast::Expression::Identifier(name, _) = func.as_ref() {
                if name == "option" {
                    if let Some(def) = parse_option_call_def(args) {
                        defs.push(def);
                    }
                }
            }
        }
    }
    defs
}

fn parse_option_call_def(args: &[ast::Argument]) -> Option<OptionDef> {
    let mut name = String::new();
    let mut opt_type = String::new();
    let mut value = None;
    let mut choices = Vec::new();
    let mut yield_to_parent = false;
    let mut deprecated = None;

    for (i, arg) in args.iter().enumerate() {
        match arg.name.as_deref() {
            None if i == 0 => {
                if let Some(obj) = eval_const_expr(&arg.value) {
                    name = obj_to_string(&obj);
                }
            }
            Some("type") => {
                if let Some(obj) = eval_const_expr(&arg.value) {
                    opt_type = obj_to_string(&obj);
                }
            }
            Some("value") => {
                value = eval_const_expr(&arg.value);
            }
            Some("choices") => {
                if let Some(Object::Array(items)) = eval_const_expr(&arg.value) {
                    choices = items.into_iter().map(|o| obj_to_string(&o)).collect();
                }
            }
            Some("yield") => {
                if let Some(Object::Bool(b)) = eval_const_expr(&arg.value) {
                    yield_to_parent = b;
                }
            }
            Some("deprecated") => match eval_const_expr(&arg.value) {
                Some(Object::Bool(b)) => {
                    deprecated = Some(DeprecatedInfo::Bool(b));
                }
                Some(Object::String(s)) => {
                    deprecated = Some(DeprecatedInfo::Renamed(s));
                }
                Some(Object::Array(items)) => {
                    let vals: Vec<String> = items.iter().map(|o| obj_to_string(o)).collect();
                    deprecated = Some(DeprecatedInfo::DeprecatedValues(vals));
                }
                Some(Object::Dict(entries)) => {
                    let map: std::collections::HashMap<String, String> = entries
                        .into_iter()
                        .map(|(k, v)| (k, obj_to_string(&v)))
                        .collect();
                    deprecated = Some(DeprecatedInfo::ValueMap(map));
                }
                _ => {}
            },
            _ => {}
        }
    }
    if name.is_empty() {
        return None;
    }
    let value = value.map(|v| coerce_option_value(v, &opt_type));
    let default_value = value.unwrap_or_else(|| default_for_type(&opt_type, &choices));
    Some(OptionDef {
        name,
        opt_type,
        default_value,
        yield_to_parent,
        deprecated,
    })
}

fn coerce_option_value(value: Object, opt_type: &str) -> Object {
    match opt_type {
        "boolean" => match &value {
            Object::Bool(_) => value,
            Object::String(s) => match s.as_str() {
                "true" => Object::Bool(true),
                "false" => Object::Bool(false),
                _ => value,
            },
            _ => value,
        },
        "integer" => match &value {
            Object::Int(_) => value,
            Object::String(s) => s.parse::<i64>().map(Object::Int).unwrap_or(value),
            _ => value,
        },
        "feature" => match &value {
            Object::Feature(_) => value,
            Object::String(s) => match s.as_str() {
                "enabled" => Object::Feature(FeatureState::Enabled),
                "disabled" => Object::Feature(FeatureState::Disabled),
                "auto" => Object::Feature(FeatureState::Auto),
                _ => value,
            },
            _ => value,
        },
        _ => value,
    }
}

/// Compare a version string against a constraint like ">=1.0", "<2.0", "==1.5"
pub fn version_compare(version: &str, constraint: &str) -> bool {
    let constraint = constraint.trim();
    if constraint.is_empty() {
        return true;
    }

    let (op, required) = if constraint.starts_with(">=") {
        (">=", &constraint[2..])
    } else if constraint.starts_with("<=") {
        ("<=", &constraint[2..])
    } else if constraint.starts_with("!=") {
        ("!=", &constraint[2..])
    } else if constraint.starts_with("==") {
        ("==", &constraint[2..])
    } else if constraint.starts_with('>') {
        (">", &constraint[1..])
    } else if constraint.starts_with('<') {
        ("<", &constraint[1..])
    } else {
        // No operator means >=
        (">=", constraint)
    };

    let required = required.trim();
    let cmp = compare_versions(version, required);

    match op {
        ">=" => cmp >= 0,
        "<=" => cmp <= 0,
        ">" => cmp > 0,
        "<" => cmp < 0,
        "==" => cmp == 0,
        "!=" => cmp != 0,
        _ => false,
    }
}

/// Compare two version strings. Returns -1, 0, or 1.
fn compare_versions(a: &str, b: &str) -> i32 {
    let a_parts: Vec<&str> = a.split('.').collect();
    let b_parts: Vec<&str> = b.split('.').collect();
    let max_len = a_parts.len().max(b_parts.len());

    for i in 0..max_len {
        let a_part = a_parts.get(i).unwrap_or(&"0");
        let b_part = b_parts.get(i).unwrap_or(&"0");

        let a_num = a_part.parse::<i64>().unwrap_or(0);
        let b_num = b_part.parse::<i64>().unwrap_or(0);

        if a_num < b_num {
            return -1;
        } else if a_num > b_num {
            return 1;
        }
    }
    0
}

/// Parse a cross/native file (INI-like format)
pub fn parse_machine_file(path: &str) -> HashMap<String, HashMap<String, String>> {
    let mut sections: HashMap<String, HashMap<String, String>> = HashMap::new();
    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return sections,
    };

    let mut current_section = String::new();

    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            current_section = line[1..line.len() - 1].to_string();
            sections.entry(current_section.clone()).or_default();
        } else if let Some(eq_pos) = line.find('=') {
            let key = line[..eq_pos].trim().to_string();
            let value = line[eq_pos + 1..]
                .trim()
                .trim_matches('\'')
                .trim_matches('"')
                .to_string();
            sections
                .entry(current_section.clone())
                .or_default()
                .insert(key, value);
        }
    }

    sections
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_shell_args_follows_posix_quoting() {
        assert_eq!(
            split_shell_args(r#"-O2  -DA="b c" '-DD=$e' -DF=g\ h"#),
            vec!["-O2", "-DA=b c", "-DD=$e", "-DF=g h"]
        );
        assert_eq!(split_shell_args("  "), Vec::<String>::new());
        assert_eq!(split_shell_args("''"), vec![""]);
    }

    #[test]
    fn builtin_directory_defaults_follow_the_prefix() {
        let options = |prefix: &str| {
            let mut options = HashMap::new();
            options.insert("prefix".to_string(), Object::String(prefix.to_string()));
            options
        };
        assert_eq!(builtin_string(&options("/usr"), "sysconfdir"), "/etc");
        assert_eq!(builtin_string(&options("/usr"), "localstatedir"), "/var");
        assert_eq!(builtin_string(&options("/usr"), "sharedstatedir"), "/var/lib");
        assert_eq!(
            builtin_string(&options("/usr/local"), "localstatedir"),
            "/var/local"
        );
        assert_eq!(
            builtin_string(&options("/usr/local"), "sharedstatedir"),
            "/var/local/lib"
        );
        assert_eq!(builtin_string(&options("/usr/local"), "sysconfdir"), "etc");
        assert_eq!(builtin_string(&options("/opt/x"), "sysconfdir"), "etc");
    }

    #[test]
    fn env_flag_options_prepends_cppflags_and_shares_ldflags() {
        let env = |name: &str| match name {
            "CPPFLAGS" => Some("-DX".to_string()),
            "CFLAGS" => Some("-O2 -ffile-prefix-map=/w=.".to_string()),
            "LDFLAGS" => Some("-Wl,-z,now".to_string()),
            _ => None,
        };
        let options: HashMap<_, _> = env_flag_options(env).into_iter().collect();
        assert_eq!(options["c_args"], vec!["-DX", "-O2", "-ffile-prefix-map=/w=."]);
        assert_eq!(options["cpp_args"], vec!["-DX"]);
        assert_eq!(options["c_link_args"], vec!["-Wl,-z,now"]);
        assert_eq!(options["objcpp_link_args"], vec!["-Wl,-z,now"]);
        assert!(env_flag_options(|_| None).is_empty());
    }
}

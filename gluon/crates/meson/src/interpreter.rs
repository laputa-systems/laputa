/// High-level interpreter that ties together lexer, parser, compiler, and VM.
use std::path::Path;

use crate::builtins;
use crate::compiler::Compiler;
use crate::lexer::Lexer;
use crate::options;
use crate::parser::Parser;
use crate::vm::VM;

pub struct Interpreter {
    pub vm: VM,
}

impl Interpreter {
    pub fn new(source_root: &str, build_root: &str) -> Self {
        let mut vm = VM::new();
        vm.source_root = source_root.to_string();
        vm.build_root = build_root.to_string();
        vm.top_source_root = source_root.to_string();
        vm.top_build_root = build_root.to_string();
        builtins::register_all(&mut vm);
        Self { vm }
    }

    pub fn set_options(&mut self, opts: &[(String, String)]) {
        // Options known to be array-typed in Meson
        const ARRAY_OPTIONS: &[&str] = &[
            "c_args",
            "cpp_args",
            "c_link_args",
            "cpp_link_args",
            "rust_args",
            "objc_args",
            "objcpp_args",
            "objc_link_args",
            "objcpp_link_args",
        ];
        for (key, value) in opts {
            let obj = if options::builtin_option_key(key).is_some() {
                options::parse_builtin_option_value(key, value)
            } else {
                options::parse_option_value(value)
            };
            // Wrap scalar values in arrays for known array-type options
            let obj = if ARRAY_OPTIONS.contains(&key.as_str()) {
                match obj {
                    crate::objects::Object::Array(_) => obj,
                    single => crate::objects::Object::Array(vec![single]),
                }
            } else {
                obj
            };
            self.vm.options.insert(key.clone(), obj);
            self.vm.cmdline_option_keys.insert(key.clone());
        }
    }

    pub fn load_options_file(&mut self, source_root: &str) {
        // Try meson.options first, then meson_options.txt
        let options_file = format!("{}/meson.options", source_root);
        let legacy_options = format!("{}/meson_options.txt", source_root);

        let path = if Path::new(&options_file).exists() {
            Some(options_file)
        } else if Path::new(&legacy_options).exists() {
            Some(legacy_options)
        } else {
            None
        };

        if let Some(path) = path {
            if let Ok(source) = std::fs::read_to_string(&path) {
                options::parse_options_file(&source, &mut self.vm.options);
            }
        }
    }

    pub fn run(&mut self, source: &str) -> Result<(), String> {
        let mut lexer = Lexer::new(source);
        let tokens = lexer.tokenize()?;
        let mut parser = Parser::new(tokens);
        let program = parser.parse()?;
        let mut compiler = Compiler::new();
        compiler.compile(&program)?;
        match self.vm.execute(&compiler.chunk) {
            Ok(_) => Ok(()),
            Err(e) if e == "SUBDIR_DONE" => Ok(()),
            Err(e) => Err(e),
        }
    }

    pub fn print_summary(&self) {
        if self.vm.summary.is_empty() {
            return;
        }
        eprintln!();
        for (section, items) in &self.vm.summary {
            if !section.is_empty() {
                eprintln!("  {}:", section);
            }
            for (key, value) in items {
                eprintln!("    {:<30} : {}", key, value);
            }
        }
        eprintln!();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_src(source: &str) -> Result<(), String> {
        let mut interp = Interpreter::new(".", ".");
        interp.run(source)
    }

    #[test]
    fn version_matches_the_meson_pin() {
        let pins = include_str!("../../../tests/upstream/PINS");
        let pinned = pins
            .lines()
            .find_map(|line| line.strip_prefix("MESON_VERSION="))
            .expect("MESON_VERSION pin");
        assert_eq!(crate::VERSION, pinned);
    }

    #[test]
    fn project_rejects_a_newer_meson_requirement() {
        let err = run_src("project('p', meson_version: '>=99')\n").unwrap_err();
        assert!(err.contains("99"), "{err}");
    }

    #[test]
    fn project_accepts_an_older_requirement_and_reports_one_version() {
        run_src(&format!(
            "project('p', meson_version: '>=1.0')\nassert(meson.version().version_compare('=={}'))\n",
            crate::VERSION
        ))
        .unwrap();
        run_src("project('p')\n").unwrap();
    }
}

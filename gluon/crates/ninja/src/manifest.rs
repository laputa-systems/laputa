//! Parser for `build.ninja` files.
//!
//! Implements the subset of the format needed by the upstream
//! `output_test.py` suite: `rule`, `build`, `default`, top-level `var = ...`
//! bindings, and indented per-edge bindings.
//!
//! The parser is intentionally tolerant: unknown statements at the top
//! level are reported as errors with a line number.

use crate::graph::{Edge, Rule, State};
use std::collections::HashMap;

/// Visible names in one manifest scope. `include` extends the enclosing
/// scope in place; `subninja` parses into a child scope that inherits a
/// copy, so its rules and variables never leak back to the includer.
///
/// Rule definitions are always stored in `State::rules` under a
/// qualified key: the bare name at top level, or `name@<scope>` inside a
/// subninja. Edges are rewritten to that key while parsing, which keeps
/// lookup at build time a plain map hit while making a subninja rule
/// invisible to its parent.
struct Scope {
    rules: HashMap<String, String>,
    bindings: HashMap<String, String>,
    qualifier: Option<String>,
}

impl Scope {
    fn top_level() -> Self {
        Self {
            rules: HashMap::new(),
            bindings: HashMap::new(),
            qualifier: None,
        }
    }

    fn child(&self, id: usize) -> Self {
        Self {
            rules: self.rules.clone(),
            bindings: self.bindings.clone(),
            qualifier: Some(id.to_string()),
        }
    }

    fn rule_key(&self, name: &str) -> String {
        match &self.qualifier {
            Some(q) => format!("{name}@{q}"),
            None => name.to_string(),
        }
    }
}

#[allow(dead_code)]
pub fn parse(src: &str) -> Result<State, String> {
    let mut state = State::default();
    let mut scope = Scope::top_level();
    let mut next_scope = 0;
    parse_into(
        &mut state,
        &mut scope,
        src,
        std::path::Path::new("."),
        &mut next_scope,
    )?;
    state.bindings = scope.bindings;
    Ok(state)
}

/// Read and parse a manifest from disk. Recursively follows
/// `include` / `subninja` directives relative to the file’s parent
/// directory — enough for CMake-generated trees that split rules
/// across `CMakeFiles/rules.ninja`.
pub fn parse_file(path: &str) -> Result<State, String> {
    let mut state = State::default();
    let p = std::path::Path::new(path);
    let base = p.parent().unwrap_or_else(|| std::path::Path::new("."));
    let src = std::fs::read_to_string(path).map_err(|e| format!("loading '{path}': {e}"))?;
    let mut scope = Scope::top_level();
    let mut next_scope = 0;
    parse_into(&mut state, &mut scope, &src, base, &mut next_scope)?;
    state.bindings = scope.bindings;
    Ok(state)
}

/// Parse `src` (the contents of a manifest file located in `base_dir`)
/// into the existing `state` and `scope`. Splits out from `parse` so that
/// `include` / `subninja` can recurse with a new `base_dir`.
fn parse_into(
    state: &mut State,
    scope: &mut Scope,
    src: &str,
    base_dir: &std::path::Path,
    next_scope: &mut usize,
) -> Result<(), String> {
    let builds = count_build_stmts(src);
    state.edges.reserve(builds);
    state.producers.reserve(builds);
    let mut p = Parser::new(src);
    while !p.eof() {
        p.skip_blank_and_comments();
        if p.eof() {
            break;
        }
        let line_no = p.line;
        if let Some(edge) = p
            .try_simple_build(scope)
            .map_err(|e| with_line(line_no, &e))?
        {
            let idx = state.edges.len();
            state.producers.insert(edge.outputs[0].clone(), idx);
            state.edges.push(edge);
            continue;
        }
        let word = p.word();
        match word.as_str() {
            "rule" => {
                let r = p.parse_rule().map_err(|e| with_line(line_no, &e))?;
                let key = scope.rule_key(&r.name);
                scope.rules.insert(r.name.clone(), key.clone());
                state.rules.insert(key, r);
            }
            "build" => {
                let edge = p
                    .parse_build(&*state, scope)
                    .map_err(|e| with_line(line_no, &e))?;
                let idx = state.edges.len();
                for o in &edge.outputs {
                    state.producers.insert(o.clone(), idx);
                }
                for o in &edge.implicit_outputs {
                    state.producers.insert(o.clone(), idx);
                }
                state.edges.push(edge);
            }
            "default" => {
                let mut targets = Vec::new();
                while let Some(t) = p.next_path()? {
                    targets.push(expand_simple(&t, &scope.bindings, None, None));
                }
                p.expect_newline()?;
                state.defaults.extend(targets);
            }
            "pool" => {
                // Pool declaration: capture the `depth = N` body so the
                // scheduler can cap concurrent edges by pool name.
                let pool_name = p.word();
                p.expect_newline()?;
                let mut depth: Option<usize> = None;
                while p.peek_indent() {
                    p.skip_spaces();
                    let key = p.word();
                    if key.is_empty() {
                        p.skip_line();
                        continue;
                    }
                    p.skip_spaces();
                    if p.peek() != Some('=') {
                        p.skip_line();
                        continue;
                    }
                    p.bump();
                    let raw = p.read_value();
                    let value = expand_simple(raw.trim(), &scope.bindings, None, None);
                    if key == "depth" {
                        depth = value.parse().ok();
                    }
                }
                if !pool_name.is_empty()
                    && let Some(d) = depth
                {
                    state.pools.insert(pool_name, d);
                }
            }
            kw @ ("include" | "subninja") => {
                // Resolve the include target against the *current*
                // file’s directory (gcc/CMake-generated trees rely on
                // this — `include CMakeFiles/rules.ninja` from a
                // `build.ninja` in `build/` must read
                // `build/CMakeFiles/rules.ninja`).
                let raw = p.read_value();
                let path_str = expand_simple(raw.trim(), &scope.bindings, None, None);
                let nested_path = base_dir.join(&path_str);
                let nested_base = nested_path
                    .parent()
                    .unwrap_or_else(|| std::path::Path::new("."))
                    .to_path_buf();
                let nested_src = std::fs::read_to_string(&nested_path).map_err(|e| {
                    with_line(line_no, &format!("{kw} '{}' - {e}", nested_path.display()))
                })?;
                if kw == "include" {
                    // `include` extends the current scope in place: rules
                    // and variables it declares stay visible here.
                    parse_into(state, scope, &nested_src, &nested_base, next_scope)?;
                } else {
                    // `subninja` opens a child scope that inherits the
                    // current one. Definitions made inside stay in the
                    // child; the parent scope is left untouched.
                    let mut child = scope.child(*next_scope);
                    *next_scope += 1;
                    parse_into(state, &mut child, &nested_src, &nested_base, next_scope)?;
                }
            }
            "" => {
                // Stray blank line after skip_blank_and_comments shouldn't happen.
                break;
            }
            other => {
                // Top-level binding: `name = value`
                p.skip_spaces();
                if p.peek() == Some('=') {
                    p.bump();
                    let value = p.read_value();
                    let expanded = expand_simple(&value, &scope.bindings, None, None);
                    scope.bindings.insert(other.to_string(), expanded);
                } else {
                    return Err(with_line(
                        line_no,
                        &format!("expected statement, got '{other}'"),
                    ));
                }
            }
        }
    }
    Ok(())
}

fn with_line(line: usize, msg: &str) -> String {
    format!("line {line}: {msg}")
}

fn count_build_stmts(src: &str) -> usize {
    let bytes = src.as_bytes();
    let mut n = 0usize;
    let mut i = 0usize;
    while i < bytes.len() {
        let at_line = i == 0 || bytes[i - 1] == b'\n';
        if at_line
            && (bytes[i..].starts_with(b"build ") || bytes[i..].starts_with(b"build\t"))
        {
            n += 1;
        }
        i += 1;
    }
    n
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
    line: usize,
}

impl<'a> Parser<'a> {
    fn new(s: &'a str) -> Self {
        Self {
            bytes: s.as_bytes(),
            pos: 0,
            line: 1,
        }
    }

    fn eof(&self) -> bool {
        self.pos >= self.bytes.len()
    }

    fn peek(&self) -> Option<char> {
        self.bytes.get(self.pos).map(|&b| b as char)
    }

    fn peek_at(&self, off: usize) -> Option<char> {
        self.bytes.get(self.pos + off).map(|&b| b as char)
    }

    fn bump(&mut self) -> Option<char> {
        let c = self.peek()?;
        self.pos += 1;
        if c == '\n' {
            self.line += 1;
        }
        Some(c)
    }

    fn skip_spaces(&mut self) {
        while matches!(self.peek(), Some(' ' | '\t')) {
            self.pos += 1;
        }
    }

    fn skip_line(&mut self) {
        while let Some(c) = self.peek() {
            self.bump();
            if c == '\n' {
                break;
            }
        }
    }

    fn skip_blank_and_comments(&mut self) {
        loop {
            self.skip_spaces();
            match self.peek() {
                Some('\n') => {
                    self.bump();
                }
                Some('#') => self.skip_line(),
                _ => break,
            }
        }
    }

    /// Reads the next bareword (identifier-ish). Stops at whitespace, `=`,
    /// `:`, `|`, or newline.
    fn word(&mut self) -> String {
        self.skip_spaces();
        let start = self.pos;
        while let Some(c) = self.peek() {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.' {
                self.pos += 1;
            } else {
                break;
            }
        }
        std::str::from_utf8(&self.bytes[start..self.pos])
            .unwrap_or("")
            .to_string()
    }

    /// Reads the value of a `name = value` line up to (but not including)
    /// the terminating newline. Handles `$\n` line continuations and
    /// trims trailing whitespace.
    fn read_value(&mut self) -> String {
        self.skip_spaces();
        let mut out = String::new();
        while let Some(c) = self.peek() {
            if c == '$' && self.peek_at(1) == Some('\n') {
                self.pos += 2;
                self.line += 1;
                self.skip_spaces();
                continue;
            }
            if c == '\n' {
                self.bump();
                break;
            }
            out.push(c);
            self.pos += 1;
        }
        // Trim trailing spaces but preserve internal spacing.
        while out.ends_with(' ') || out.ends_with('\t') {
            out.pop();
        }
        out
    }

    fn expect_newline(&mut self) -> Result<(), String> {
        self.skip_spaces();
        match self.peek() {
            Some('\n') => {
                self.bump();
                Ok(())
            }
            None => Ok(()),
            Some(c) => Err(format!("expected newline, got '{c}'")),
        }
    }

    /// Returns true if the current line begins with a leading space/tab,
    /// indicating an indented continuation of the previous block.
    fn peek_indent(&self) -> bool {
        matches!(self.bytes.get(self.pos), Some(b' ' | b'\t'))
    }

    fn try_simple_build(&mut self, scope: &Scope) -> Result<Option<Edge>, String> {
        let saved_pos = self.pos;
        let saved_line = self.line;
        match self.simple_build(scope) {
            Ok(None) => {
                self.pos = saved_pos;
                self.line = saved_line;
                Ok(None)
            }
            other => other,
        }
    }

    fn simple_build(&mut self, scope: &Scope) -> Result<Option<Edge>, String> {
        let bytes = self.bytes;
        if self.pos >= bytes.len()
            || !(bytes[self.pos..].starts_with(b"build ")
                || bytes[self.pos..].starts_with(b"build\t"))
        {
            return Ok(None);
        }
        self.pos += 5;
        self.skip_spaces();
        let Some(out) = self.plain_token() else {
            return Ok(None);
        };
        self.skip_spaces();
        if self.peek() != Some(':') {
            return Ok(None);
        }
        self.bump();
        self.skip_spaces();
        let Some(rule) = self.plain_word() else {
            return Ok(None);
        };
        self.skip_spaces();
        let Some(inp) = self.plain_token() else {
            return Ok(None);
        };
        self.skip_spaces();
        match self.peek() {
            Some('\n') => {
                self.bump();
            }
            None => {}
            _ => return Ok(None),
        }
        if self.peek_indent() {
            return Ok(None);
        }
        let rule_key = if rule == "phony" {
            rule
        } else {
            scope
                .rules
                .get(&rule)
                .cloned()
                .ok_or_else(|| format!("unknown build rule '{rule}'"))?
        };
        Ok(Some(Edge {
            rule: rule_key,
            outputs: vec![out],
            implicit_outputs: vec![],
            inputs: vec![inp],
            implicit_inputs: vec![],
            order_only_inputs: vec![],
            bindings: HashMap::new(),
            dyndep: None,
        }))
    }

    fn plain_token(&mut self) -> Option<String> {
        let start = self.pos;
        let bytes = self.bytes;
        let mut i = start;
        while i < bytes.len() {
            match bytes[i] {
                b' ' | b'\t' | b'\n' | b':' | b'|' | b'$' => break,
                _ => i += 1,
            }
        }
        if i == start {
            return None;
        }
        let s = std::str::from_utf8(&bytes[start..i]).ok()?;
        self.pos = i;
        Some(s.to_string())
    }

    fn plain_word(&mut self) -> Option<String> {
        let start = self.pos;
        let bytes = self.bytes;
        let mut i = start;
        while i < bytes.len() {
            let c = bytes[i];
            if c.is_ascii_alphanumeric() || c == b'_' || c == b'-' || c == b'.' {
                i += 1;
            } else {
                break;
            }
        }
        if i == start {
            return None;
        }
        let s = std::str::from_utf8(&bytes[start..i]).ok()?;
        self.pos = i;
        Some(s.to_string())
    }

    /// Reads the next path-ish token on a build line. Returns None when
    /// it hits `:`, `|`, `||`, or end of line.
    fn next_path(&mut self) -> Result<Option<String>, String> {
        self.skip_spaces();
        match self.peek() {
            None | Some('\n' | ':' | '|') => return Ok(None),
            _ => {}
        }
        let mut out = String::new();
        while let Some(c) = self.peek() {
            match c {
                ' ' | '\t' | '\n' | ':' | '|' => break,
                '$' => {
                    self.pos += 1;
                    match self.peek() {
                        Some(' ') | Some(':') | Some('$') | Some('|') => {
                            out.push(self.peek().unwrap());
                            self.pos += 1;
                        }
                        Some('\n') => {
                            self.line += 1;
                            self.pos += 1;
                            self.skip_spaces();
                        }
                        _ => out.push('$'),
                    }
                }
                _ => {
                    out.push(c);
                    self.pos += 1;
                }
            }
        }
        Ok(Some(out))
    }

    fn parse_rule(&mut self) -> Result<Rule, String> {
        let name = self.word();
        if name.is_empty() {
            return Err("rule needs a name".into());
        }
        self.expect_newline()?;
        let mut bindings = HashMap::new();
        while self.peek_indent() {
            self.skip_spaces();
            let key = self.word();
            if key.is_empty() {
                self.skip_line();
                continue;
            }
            self.skip_spaces();
            if self.peek() != Some('=') {
                return Err(format!("expected '=' after '{key}'"));
            }
            self.bump();
            bindings.insert(key, self.read_value());
        }
        Ok(Rule { name, bindings })
    }

    fn parse_build(&mut self, state: &State, scope: &Scope) -> Result<Edge, String> {
        let mut outputs = Vec::new();
        let mut implicit_outputs = Vec::new();
        let mut implicit = false;
        while let Some(p) = self.next_path()? {
            if implicit {
                implicit_outputs.push(p);
            } else {
                outputs.push(p);
            }
            self.skip_spaces();
            if self.peek() == Some('|') && self.peek_at(1) != Some('|') {
                self.bump();
                implicit = true;
            }
        }
        self.skip_spaces();
        if self.peek() != Some(':') {
            return Err("expected ':' after build outputs".into());
        }
        self.bump();
        let rule = self.word();
        if rule.is_empty() {
            return Err("expected rule name in build".into());
        }
        // Resolve the rule in the current scope. Rules declared in a
        // subninja are stored under a qualified key and are not in the
        // parent's visible set, so referencing one here is an error —
        // exactly like reference ninja's "unknown build rule".
        let rule_key = if rule == "phony" {
            rule.clone()
        } else {
            scope
                .rules
                .get(&rule)
                .cloned()
                .ok_or_else(|| format!("unknown build rule '{rule}'"))?
        };
        let mut inputs = Vec::new();
        while let Some(p) = self.next_path()? {
            inputs.push(p);
        }
        let mut implicit_inputs = Vec::new();
        let mut order_only_inputs = Vec::new();
        loop {
            self.skip_spaces();
            match (self.peek(), self.peek_at(1)) {
                (Some('|'), Some('|')) => {
                    self.bump();
                    self.bump();
                    while let Some(p) = self.next_path()? {
                        order_only_inputs.push(p);
                    }
                }
                (Some('|'), _) => {
                    self.bump();
                    while let Some(p) = self.next_path()? {
                        implicit_inputs.push(p);
                    }
                }
                _ => break,
            }
        }
        self.expect_newline()?;
        let mut bindings = HashMap::new();
        while self.peek_indent() {
            self.skip_spaces();
            let key = self.word();
            if key.is_empty() {
                self.skip_line();
                continue;
            }
            self.skip_spaces();
            if self.peek() != Some('=') {
                return Err(format!("expected '=' after '{key}'"));
            }
            self.bump();
            let raw = self.read_value();
            let value = expand(&raw, &|name| bindings.get(name).cloned().or_else(|| scope.bindings.get(name).cloned()));
            bindings.insert(key, value);
        }
        // Expand paths against file-scope bindings.
        let expand_all = |v: Vec<String>| {
            v.into_iter()
                .map(|s| {
                    if s.as_bytes().contains(&b'$') {
                        expand_simple(&s, &scope.bindings, None, None)
                    } else {
                        s
                    }
                })
                .collect()
        };
        // \`dyndep = ...\` may live on the edge OR be inherited from
        // the rule (the test_issue_2621 plan declares it on the rule).
        // Resolve via the standard layered lookup so per-edge bindings
        // shadow rule bindings.
        let rule_obj = state.rules.get(&rule_key);
        let dyndep_raw = bindings
            .get("dyndep")
            .cloned()
            .or_else(|| rule_obj.and_then(|r| r.bindings.get("dyndep").cloned()));
        let dyndep = dyndep_raw.map(|s| {
            expand_simple(
                &s,
                &scope.bindings,
                Some(&bindings),
                rule_obj.map(|r| &r.bindings),
            )
        });
        Ok(Edge {
            rule: rule_key,
            outputs: expand_all(outputs),
            implicit_outputs: expand_all(implicit_outputs),
            inputs: expand_all(inputs),
            implicit_inputs: expand_all(implicit_inputs),
            order_only_inputs: expand_all(order_only_inputs),
            bindings,
            dyndep,
        })
    }
}

/// Variable expansion. Supports `$var`, `${var}`, escapes `$$`, `$ `, `$:`,
/// `$|`, and `$\n` line continuations. Lookups walk:
///   1. per-edge bindings (if provided)
///   2. rule bindings (if provided)
///   3. file-scope bindings
///
/// Special names `in`, `out` are resolved by the caller via the rule path —
/// here they fall through to file-scope. The full edge-context expansion
/// lives in `build::expand_edge_command`.
pub fn expand_simple(
    s: &str,
    file_scope: &HashMap<String, String>,
    edge_bindings: Option<&HashMap<String, String>>,
    rule_bindings: Option<&HashMap<String, String>>,
) -> String {
    expand(s, &|name| {
        if let Some(b) = edge_bindings
            && let Some(v) = b.get(name)
        {
            return Some(v.clone());
        }
        if let Some(b) = rule_bindings
            && let Some(v) = b.get(name)
        {
            // Rule values may themselves reference file-scope vars, but
            // not other rule vars at this level. Recurse against file
            // scope only to avoid loops.
            return Some(expand_simple(v, file_scope, None, None));
        }
        file_scope.get(name).cloned()
    })
}

/// Generic expansion driver: replaces `$var` / `${var}` using `lookup`.
pub fn expand<F: Fn(&str) -> Option<String>>(s: &str, lookup: &F) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i] as char;
        if c != '$' {
            out.push(c);
            i += 1;
            continue;
        }
        i += 1;
        if i >= bytes.len() {
            out.push('$');
            break;
        }
        let n = bytes[i] as char;
        match n {
            '$' | ' ' | ':' | '|' => {
                out.push(n);
                i += 1;
            }
            '\n' => {
                i += 1;
                while matches!(bytes.get(i), Some(b' ' | b'\t')) {
                    i += 1;
                }
            }
            '{' => {
                i += 1;
                let start = i;
                while i < bytes.len() && bytes[i] != b'}' {
                    i += 1;
                }
                let name = std::str::from_utf8(&bytes[start..i]).unwrap_or("");
                if i < bytes.len() {
                    i += 1; // skip '}'
                }
                if let Some(v) = lookup(name) {
                    out.push_str(&v);
                }
            }
            c if c.is_ascii_alphanumeric() || c == '_' || c == '-' => {
                // Ninja variable names are restricted to
                // [A-Za-z0-9_-]. Crucially `.` is NOT part of a name,
                // so `$out.d` expands `$out` and leaves `.d` literal —
                // matching the behavior gcc-emitting depfile rules
                // depend on.
                let start = i;
                while i < bytes.len() {
                    let cc = bytes[i];
                    if cc.is_ascii_alphanumeric() || cc == b'_' || cc == b'-' {
                        i += 1;
                    } else {
                        break;
                    }
                }
                let name = std::str::from_utf8(&bytes[start..i]).unwrap_or("");
                if let Some(v) = lookup(name) {
                    out.push_str(&v);
                }
            }
            _ => {
                out.push('$');
                out.push(n);
                i += 1;
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_bindings_are_evaluated_when_parsed() {
        let src = "root = /r\nrule link\n  command = cc $FLAGS $LIBS\nbuild app: link a.o\n  FLAGS = -Wl,-rpath,\"\\$$ORIGIN/../lib\" lit$$x\n  LIBS = $root/lib $FLAGS\n";
        let state = parse(src).unwrap();
        assert_eq!(state.edges[0].bindings["FLAGS"], "-Wl,-rpath,\"\\$ORIGIN/../lib\" lit$x");
        assert_eq!(state.edges[0].bindings["LIBS"], "/r/lib -Wl,-rpath,\"\\$ORIGIN/../lib\" lit$x");
        let edge = &state.edges[0];
        let command = crate::build::expand_in_edge_pub(&state, edge, &state.rules["link"].bindings["command"]);
        assert_eq!(command, "cc -Wl,-rpath,\"\\$ORIGIN/../lib\" lit$x /r/lib -Wl,-rpath,\"\\$ORIGIN/../lib\" lit$x");
    }

    #[test]
    fn plain_build_paths_round_trip() {
        let src = "rule cc\n  command = cc\nbuild foo.o: cc foo.c\n";
        let state = parse(src).unwrap();
        assert_eq!(state.edges[0].outputs, vec!["foo.o".to_string()]);
        assert_eq!(state.edges[0].inputs, vec!["foo.c".to_string()]);
        assert_eq!(state.producers.get("foo.o"), Some(&0));
    }

    #[test]
    fn build_edge_binding_and_extra_input_use_the_general_parser() {
        let src = "rule cc\n  command = cc\nbuild foo.o: cc a.c b.c\n  depfile = foo.d\n";
        let state = parse(src).unwrap();
        assert_eq!(
            state.edges[0].inputs,
            vec!["a.c".to_string(), "b.c".to_string()]
        );
        assert_eq!(
            state.edges[0].bindings.get("depfile").map(String::as_str),
            Some("foo.d")
        );
    }

    #[test]
    fn build_paths_expand_file_scope_and_escaped_space() {
        let src = "rule cc\n  command = cc\nname = foo\nbuild $name.o: cc $name.c foo$ bar.c\n";
        let state = parse(src).unwrap();
        assert_eq!(state.edges[0].outputs, vec!["foo.o".to_string()]);
        assert_eq!(
            state.edges[0].inputs,
            vec!["foo.c".to_string(), "foo bar.c".to_string()]
        );
    }
}

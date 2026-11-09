use std::collections::HashMap;

#[derive(Debug, Default)]
pub struct Interner {
    map: HashMap<String, u32>,
    vec: Vec<String>,
}

impl Interner {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn intern(&mut self, s: &str) -> u32 {
        if let Some(&id) = self.map.get(s) {
            return id;
        }
        let id = self.vec.len() as u32;
        self.vec.push(s.to_string());
        self.map.insert(s.to_string(), id);
        id
    }

    pub fn resolve(&self, id: u32) -> Option<&str> {
        self.vec.get(id as usize).map(String::as_str)
    }

    pub fn len(&self) -> usize {
        self.vec.len()
    }

    pub fn is_empty(&self) -> bool {
        self.vec.is_empty()
    }
}

/// Handle into an arena allocation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Handle(u32);

#[derive(Debug)]
pub struct Arena<T> {
    vec: Vec<T>,
}

impl<T> Default for Arena<T> {
    fn default() -> Self {
        Self { vec: Vec::new() }
    }
}

impl<T> Arena<T> {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, v: T) -> Handle {
        let h = Handle(self.vec.len() as u32);
        self.vec.push(v);
        h
    }

    pub fn get(&self, h: Handle) -> Option<&T> {
        self.vec.get(h.0 as usize)
    }

    pub fn get_mut(&mut self, h: Handle) -> Option<&mut T> {
        self.vec.get_mut(h.0 as usize)
    }

    pub fn len(&self) -> usize {
        self.vec.len()
    }

    pub fn is_empty(&self) -> bool {
        self.vec.is_empty()
    }
}

#[derive(Debug, Clone, Default)]
pub struct Command {
    pub shell: String,
    pub argv: Vec<String>,
}

impl Command {
    pub fn from_shell(shell: &str) -> Self {
        let argv = shell.split_whitespace().map(|w| w.to_string()).collect();
        Self {
            shell: shell.to_string(),
            argv,
        }
    }
}

#[derive(Debug, Default)]
pub struct State {
    pub bindings: HashMap<String, String>,
    pub rules: HashMap<String, Rule>,
    pub edges: Vec<Edge>,
    pub producers: HashMap<String, usize>,
    pub defaults: Vec<String>,
    pub pools: HashMap<String, usize>,
}

#[derive(Debug, Default, Clone)]
pub struct Rule {
    pub name: String,
    pub bindings: HashMap<String, String>,
}

#[derive(Debug, Clone)]
pub struct Edge {
    pub rule: String,
    pub outputs: Vec<String>,
    pub implicit_outputs: Vec<String>,
    pub inputs: Vec<String>,
    pub implicit_inputs: Vec<String>,
    pub order_only_inputs: Vec<String>,
    pub bindings: HashMap<String, String>,
    pub dyndep: Option<String>,
}

impl Edge {
    pub fn is_phony(&self) -> bool {
        self.rule == "phony"
    }

    pub fn command(&self) -> Option<&str> {
        self.bindings.get("command").map(String::as_str)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interner_dedupes() {
        let mut i = Interner::new();
        let a = i.intern("a.o");
        let b = i.intern("a.o");
        assert_eq!(a, b);
        assert_eq!(i.resolve(a), Some("a.o"));
        assert_eq!(i.len(), 1);
    }

    #[test]
    fn arena_handles() {
        let mut a = Arena::new();
        let h = a.push(42);
        assert_eq!(a.get(h), Some(&42));
    }

    #[test]
    fn command_argv_populated() {
        let c = Command::from_shell("cc -c a.c -o a.o");
        assert_eq!(c.shell, "cc -c a.c -o a.o");
        assert_eq!(c.argv.len(), 5);
    }
}

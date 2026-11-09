//! Target resolution + dependency-order scheduling.
//!
//! Produces a topological order over the edges needed to satisfy the
//! requested build targets. Phony edges are kept in the plan so the
//! runner can correctly count them as "done" without dispatching work.

use crate::cli::Options;
use crate::graph::State;
use std::collections::HashSet;

/// Pick which targets to build:
///   1. explicit CLI targets, if any
///   2. else `default` statements
///   3. else every output node not consumed as input (the "root" set)
pub fn resolve_targets(state: &State, opts: &Options) -> Vec<String> {
    if !opts.targets.is_empty() {
        return opts.targets.clone();
    }
    if !state.defaults.is_empty() {
        return state.defaults.clone();
    }
    let mut consumed = HashSet::new();
    for e in &state.edges {
        for i in e
            .inputs
            .iter()
            .chain(&e.implicit_inputs)
            .chain(&e.order_only_inputs)
        {
            consumed.insert(i.clone());
        }
    }
    let mut roots = Vec::new();
    for e in &state.edges {
        for o in &e.outputs {
            if !consumed.contains(o) {
                roots.push(o.clone());
            }
        }
    }
    roots
}

/// Topologically order the edges needed to produce `targets`. Returns
/// edge indices; phony edges are kept (the runner skips dispatch for
/// them) so accounting and dependency wiring stay consistent.
pub fn build_plan(state: &State, targets: &[String]) -> Result<Vec<usize>, String> {
    let mut order = Vec::new();
    let mut seen = HashSet::new();
    let mut on_stack = HashSet::new();
    for t in targets {
        visit(state, t, &mut order, &mut seen, &mut on_stack)?;
    }
    Ok(order)
}

fn visit(
    state: &State,
    target: &str,
    order: &mut Vec<usize>,
    seen: &mut HashSet<usize>,
    on_stack: &mut HashSet<usize>,
) -> Result<(), String> {
    let Some(&idx) = state.producers.get(target) else {
        return Ok(()); // source file
    };
    if on_stack.contains(&idx) {
        return Err(format!("dependency cycle through '{target}'"));
    }
    if !seen.insert(idx) {
        return Ok(());
    }
    on_stack.insert(idx);
    let edge = &state.edges[idx];
    for inp in edge
        .inputs
        .iter()
        .chain(&edge.implicit_inputs)
        .chain(&edge.order_only_inputs)
    {
        visit(state, inp, order, seen, on_stack)?;
    }
    // The dyndep file (if any) must be produced before this edge runs,
    // so include its producer in the plan as a real dependency.
    if let Some(dd) = &edge.dyndep {
        visit(state, dd, order, seen, on_stack)?;
    }
    on_stack.remove(&idx);
    order.push(idx);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graph::Edge;
    use std::collections::HashMap;

    fn edge(out: &str, input: &str) -> Edge {
        Edge {
            rule: "phony".to_string(),
            outputs: vec![out.to_string()],
            implicit_outputs: vec![],
            inputs: vec![input.to_string()],
            implicit_inputs: vec![],
            order_only_inputs: vec![],
            bindings: HashMap::new(),
            dyndep: None,
        }
    }

    fn state_of(edges: Vec<Edge>) -> State {
        let mut state = State::default();
        for (idx, edge) in edges.iter().enumerate() {
            state.producers.insert(edge.outputs[0].clone(), idx);
        }
        state.edges = edges;
        state
    }

    #[test]
    fn cycle_is_rejected() {
        let state = state_of(vec![edge("a", "b"), edge("b", "a")]);
        let err = build_plan(&state, &["a".to_string()]).unwrap_err();
        assert!(err.contains("cycle"), "{err}");
    }

    #[test]
    fn self_cycle_is_rejected() {
        let state = state_of(vec![edge("a", "a")]);
        let err = build_plan(&state, &["a".to_string()]).unwrap_err();
        assert!(err.contains("cycle"), "{err}");
    }

    #[test]
    fn shared_dependency_is_not_a_cycle() {
        let state = state_of(vec![
            edge("c", "src"),
            edge("a", "c"),
            edge("b", "c"),
            Edge {
                rule: "phony".to_string(),
                outputs: vec!["top".to_string()],
                implicit_outputs: vec![],
                inputs: vec!["a".to_string(), "b".to_string()],
                implicit_inputs: vec![],
                order_only_inputs: vec![],
                bindings: HashMap::new(),
                dyndep: None,
            },
        ]);
        let order = build_plan(&state, &["top".to_string()]).unwrap();
        assert_eq!(order, vec![0, 1, 2, 3]);
    }
}

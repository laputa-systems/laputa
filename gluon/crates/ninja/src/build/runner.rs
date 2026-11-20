//! Per-edge subprocess execution and the parallel scheduler.
//!
//! The scheduler is dependency-driven: at any moment it dispatches every
//! ready edge (all of its inputs already produced or absent from the
//! plan) up to a `-j N` cap. Edge stdout/stderr is captured and handed
//! to the `Status` printer in completion order so logs interleave
//! correctly.
//!
//! Pool depth limits are honored: each edge whose rule (or per-edge
//! binding) sets `pool = name` is dispatched only while the pool's
//! in-flight count is below its declared `depth`. The implicit `console`
//! pool defaults to depth 1.

use super::depfile;
use super::deps_log::DepsLog;
use super::dyndep;
use super::expand::{edge_binding, expand_in_edge, is_generator, lookup_either};
use super::jobserver::{self, Slot};
use super::log;
use super::plan::{build_plan, build_plan_with_producers, resolve_targets};
use crate::cli::Options;
use crate::graph::{Edge, State};
use crate::status::{Mode, Status};
use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::io::ErrorKind;
use std::sync::mpsc;
use std::thread;
use std::time::SystemTime;

pub struct RunReport {
    pub code: u8,
    /// True when at least one real (non-phony) edge was dispatched. Used
    /// by the manifest-regeneration pass to decide whether the manifest
    /// must be reloaded before the main build.
    pub ran: bool,
}

pub fn run(state: &State, opts: &Options) -> Result<u8, String> {
    Ok(run_targets(state, opts, None, true)?.code)
}

/// Run `targets_override` (or the normal resolved targets when `None`).
/// `announce_no_work` suppresses the trailing "no work to do" line for
/// the manifest-regeneration pass, which must stay silent when the
/// manifest is already up to date.
pub fn run_targets(
    state: &State,
    opts: &Options,
    targets_override: Option<&[String]>,
    announce_no_work: bool,
) -> Result<RunReport, String> {
    let (code, work) = run_selection(state, opts, targets_override, announce_no_work)?;
    Ok(RunReport {
        code,
        ran: work && !opts.dry_run,
    })
}

pub(crate) fn run_selection(
    state: &State,
    opts: &Options,
    targets_override: Option<&[String]>,
    announce_no_work: bool,
) -> Result<(u8, bool), String> {
    let targets = match targets_override {
        Some(t) => t.to_vec(),
        None => resolve_targets(state, opts),
    };
    if targets.is_empty() {
        if !opts.quiet && announce_no_work {
            println!("ninja: no work to do.");
        }
        return Ok((0, false));
    }
    // Surface unknown explicit targets the way ninja does — an error to
    // stdout, exit 1. Source files (no producer) are accepted only when
    // they're listed as inputs of some edge.
    for t in &targets {
        if !state.producers.contains_key(t) {
            let known = state.edges.iter().any(|e| {
                e.inputs.iter().any(|i| i == t)
                    || e.implicit_inputs.iter().any(|i| i == t)
                    || e.order_only_inputs.iter().any(|i| i == t)
            });
            if !known {
                println!("ninja: error: unknown target '{t}'");
                return Ok((1, false));
            }
        }
    }

    let BuildPlan {
        order: plan,
        producers,
    } = validate_plan(state, &targets)?;
    if plan.is_empty() {
        if !opts.quiet && announce_no_work {
            println!("ninja: no work to do.");
        }
        return Ok((0, false));
    }

    let real_count = plan.iter().filter(|&&i| !state.edges[i].is_phony()).count();
    let mode = Mode::detect();
    let mut status = Status::new(mode, opts.quiet, opts.verbose, real_count);
    schedule(
        state,
        opts,
        &plan,
        &producers,
        &mut status,
        announce_no_work,
    )
}

struct BuildPlan<'a> {
    order: Vec<usize>,
    producers: Cow<'a, HashMap<String, usize>>,
}

fn validate_plan<'a>(state: &'a State, targets: &[String]) -> Result<BuildPlan<'a>, String> {
    let mut plan = build_plan(state, targets)?;
    let mut producers = Cow::Borrowed(&state.producers);
    let mut existing_sources = HashSet::new();
    let mut inspected_dyndeps = HashSet::new();
    let mut previous_logs = None;
    loop {
        let consumed = plan.iter().flat_map(|&index| {
            let edge = &state.edges[index];
            edge.inputs
                .iter()
                .chain(&edge.implicit_inputs)
                .chain(&edge.order_only_inputs)
                .chain(&edge.dyndep)
                .map(move |input| (input.as_str(), edge.outputs.first()))
        });
        let requested = targets.iter().map(|target| (target.as_str(), None));
        let mut missing = None;
        for (input, owner) in requested.chain(consumed) {
            if producers.contains_key(input) || existing_sources.contains(input) {
                continue;
            }
            match std::fs::metadata(input) {
                Ok(_) => {
                    existing_sources.insert(input);
                }
                Err(error)
                    if matches!(error.kind(), ErrorKind::NotFound | ErrorKind::NotADirectory) =>
                {
                    missing = Some((input, owner));
                    break;
                }
                Err(error) => return Err(format!("error: stat '{input}': {error}")),
            }
        }
        let Some((input, owner)) = missing else {
            return Ok(BuildPlan { order: plan, producers });
        };

        let previous_count = producers.len();
        for path in plan
            .iter()
            .filter_map(|&index| state.edges[index].dyndep.as_deref())
        {
            if !inspected_dyndeps.insert(path) || !std::path::Path::new(path).is_file() {
                continue;
            }
            if state.producers.contains_key(path) {
                let (build_log, deps_log) = previous_logs
                    .get_or_insert_with(|| (log::load(".ninja_log"), DepsLog::load(".ninja_deps")));
                if !producer_is_ready(state, path, build_log, deps_log, &mut HashSet::new())? {
                    continue;
                }
            }
            let dyndep = read_dyndep(path)?;
            let mut inspected_edges = HashSet::new();
            for output in dyndep.entries.keys() {
                let Some(&index) = state.producers.get(output) else {
                    continue;
                };
                let edge = &state.edges[index];
                if edge.dyndep.as_deref() == Some(path)
                    && inspected_edges.insert(index)
                    && let Some(entry) = dyndep.entry_for(&edge.outputs)
                {
                    for implicit in &entry.implicit_outputs {
                        if producers.to_mut().insert(implicit.clone(), index).is_some() {
                            return Err(format!("multiple rules generate {implicit}"));
                        }
                    }
                }
            }
        }
        if producers.len() == previous_count {
            let context = owner.map_or_else(String::new, |out| format!(", needed by '{out}',"));
            return Err(format!("error: '{input}'{context} missing and no known rule to make it"));
        }
        plan = build_plan_with_producers(state, targets, &producers)?;
    }
}

fn producer_is_ready(
    state: &State,
    path: &str,
    build_log: &log::BuildLog,
    deps_log: &DepsLog,
    checking: &mut HashSet<String>,
) -> Result<bool, String> {
    if !checking.insert(path.to_string()) {
        return Err(format!("dependency cycle through '{path}'"));
    }
    let plan = build_plan(state, &[path.to_string()])?;
    let mut phony_mtimes = HashMap::new();
    let mut dirty = HashMap::new();
    for index in plan {
        let mut edge = Cow::Borrowed(&state.edges[index]);
        if let Some(path) = edge.dyndep.as_deref() {
            if !std::path::Path::new(path).is_file() {
                return Ok(false);
            }
            let file = read_dyndep(path)?;
            if let Some(entry) = file.entry_for(&edge.outputs) {
                for input in &entry.implicit_inputs {
                    let producer = if state.producers.contains_key(input) {
                        Some(input)
                    } else {
                        file.entries.iter().find_map(|(output, declaration)| {
                            let &index = state.producers.get(output)?;
                            (state.edges[index].dyndep.as_deref() == Some(path)
                                && declaration.implicit_outputs.contains(input))
                            .then_some(output)
                        })
                    };
                    if let Some(producer) = producer
                        && !producer_is_ready(state, producer, build_log, deps_log, checking)?
                    {
                        return Ok(false);
                    }
                }
                let edge = edge.to_mut();
                edge.implicit_inputs.extend_from_slice(&entry.implicit_inputs);
                edge.implicit_outputs.extend_from_slice(&entry.implicit_outputs);
                if entry.restat {
                    edge.bindings.insert("restat".to_string(), "1".to_string());
                }
            }
        }
        if edge
            .inputs
            .iter()
            .chain(&edge.implicit_inputs)
            .chain(&edge.order_only_inputs)
            .any(|input| !state.producers.contains_key(input) && mtime_of(input).is_none())
        {
            return Ok(false);
        }
        if edge.is_phony() {
            let mtime = newest_input_mtime(&edge, &phony_mtimes);
            for output in edge.outputs.iter().chain(&edge.implicit_outputs) {
                phony_mtimes.insert(output.clone(), mtime);
                if edge.inputs.is_empty() && edge.implicit_inputs.is_empty() {
                    dirty.insert(output.clone(), true);
                }
            }
            continue;
        }
        let Some(rule) = state.rules.get(&edge.rule) else {
            return Ok(false);
        };
        let command = rule.bindings.get("command").map(String::as_str).unwrap_or("");
        let hash = log::hash_command(&expand_in_edge(state, &edge, command));
        if !is_generator(state, &edge)
            && edge.outputs.iter().chain(&edge.implicit_outputs).any(|output| {
                !build_log.entries.get(output).is_some_and(|entry| entry.command_hash == hash)
            })
        {
            return Ok(false);
        }
        mark_depfile_dirty(state, &edge, deps_log, &mut dirty);
        if edge_needs_run(
            state,
            &edge,
            &dirty,
            &phony_mtimes,
            build_log,
            rule_has_restat(state, &edge),
        ) {
            return Ok(false);
        }
    }
    checking.remove(path);
    Ok(true)
}

/// Dependency-driven scheduler. Walks the topologically-ordered plan and
/// keeps up to `-j N` edges in flight at once. Phony edges complete
/// instantly without spawning a subprocess.
fn schedule(
    state: &State,
    opts: &Options,
    plan: &[usize],
    planned_producers: &HashMap<String, usize>,
    status: &mut Status,
    announce_no_work: bool,
) -> Result<(u8, bool), String> {
    let jobs = opts.jobs_count().max(1);
    let explain = opts.explain();

    // GNU make jobserver client. We only consult MAKEFLAGS when the
    // user did *not* pass `-j N` explicitly — `-j N` always wins,
    // matching reference ninja. A pipe-mode jobserver is rejected
    // with a friendly stderr warning and we fall back to local `-j`.
    let mut jobserver_client = if !opts.dry_run && opts.jobs.is_none() {
        match jobserver::detect_from_env() {
            Ok(c) => c,
            Err(msg) => {
                eprintln!("ninja: warning: {msg}");
                None
            }
        }
    } else {
        None
    };
    // When a jobserver is active, defer to the pool — the local `-j`
    // cap is effectively unlimited so the only thing throttling us is
    // token availability. Otherwise keep the GuessParallelism cap.
    let jobs = if jobserver_client.is_some() {
        usize::MAX
    } else {
        jobs
    };
    // Held tokens, indexed by plan slot. The implicit slot is taken
    // first; explicit slots are written back to the FIFO on release.
    let mut held_slots: Vec<Option<Slot>> = (0..plan.len()).map(|_| None).collect();

    let in_plan: HashSet<usize> = plan.iter().copied().collect();
    let mut dependents = vec![Vec::new(); plan.len()];
    let mut remaining = vec![0; plan.len()];
    let mut idx_in_plan = std::collections::HashMap::with_capacity(plan.len());
    for (slot, &edge_idx) in plan.iter().enumerate() {
        idx_in_plan.insert(edge_idx, slot);
    }
    for (slot, &edge_idx) in plan.iter().enumerate() {
        let edge = &state.edges[edge_idx];
        let dyndep_iter = edge.dyndep.iter();
        let mut seen_dep = HashSet::new();
        for inp in edge
            .inputs
            .iter()
            .chain(&edge.implicit_inputs)
            .chain(&edge.order_only_inputs)
            .chain(dyndep_iter)
        {
            if let Some(&prod) = planned_producers.get(inp)
                && in_plan.contains(&prod)
                && let Some(&dep_slot) = idx_in_plan.get(&prod)
                && seen_dep.insert(dep_slot)
            {
                dependents[dep_slot].push(slot);
                remaining[slot] += 1;
            }
        }
    }

    let mut done = vec![false; plan.len()];
    let mut started = vec![false; plan.len()];
    let mut blocked = vec![false; plan.len()];
    let mut in_flight = 0usize;
    let (tx, rx) = mpsc::channel::<(EdgeOutcome, SystemTime)>();
    // We treat any non-zero exit as a "failure" and stop launching new
    // edges once `failure_count` reaches the user's `-k N` threshold.
    // The first failure code is preserved as the process exit status.
    let mut hard_failure: Option<u8> = None;
    let mut failure_count: usize = 0;
    let failure_limit = opts.failure_limit();
    let mut interrupted = false;
    // Per-pool in-flight counts. Edges whose rule (or per-edge binding)
    // sets `pool = name` may not start while `pool_in_flight[name] >=
    // pools[name]`. The implicit `console` pool has depth 1.
    let mut pool_in_flight: HashMap<String, usize> = HashMap::new();
    let pool_depths: &HashMap<String, usize> = &state.pools;
    // Tracks whether we actually dispatched any subprocess work. If
    // every edge in the plan was skipped (clean / phony) we still owe
    // the user the canonical "ninja: no work to do." message.
    let mut any_real_work = false;
    let mut preview = Vec::new();
    let mut preview_failure = None;
    // Per-edge mutable copies so dyndep merges (extra outputs/inputs)
    // can land on the right edge before dispatch.
    let mut edges: Vec<Edge> = state.edges.to_vec();
    // Authoritative output → producing-edge map. Seeded from the
    // manifest, then extended as dyndep files are loaded. A duplicate
    // insert is the "multiple rules generate X" error.
    let mut producers: HashMap<String, usize> = state.producers.clone();
    // Cache of parsed dyndep files keyed by path so we only read each
    // one once even if multiple edges reference the same file.
    let mut dyndep_cache: HashMap<String, dyndep::DyndepFile> = HashMap::new();
    let mut dyndep_failure: Option<String> = None;
    // Edge indices whose dyndep file has already been merged in. Without
    // this we'd re-merge (and re-collide-against-self) every loop turn.
    let mut dyndep_loaded: HashSet<usize> = HashSet::new();

    // Cross-invocation persistence via `.ninja_log`. We load whatever the
    // last run wrote so a header touch (or command change) two builds ago
    // still triggers a rebuild today, then keep a writer open to append
    // fresh entries as edges complete.
    let prev_log = log::load(".ninja_log");
    let mut log_writer = (!opts.dry_run).then(|| log::Writer::new(".ninja_log"));
    // Cross-invocation depfile cache. After a successful gcc/msvc edge
    // we store its discovered headers here and unlink the depfile, so
    // the next ninja invocation can answer "is this output stale?"
    // even though the depfile itself is gone.
    let mut deps_log = DepsLog::load(".ninja_deps");

    // Per-edge expanded command (used for both hashing and dispatch). We
    // compute it up front so we can both seed cross-invocation dirtiness
    // and avoid re-expanding the same command at completion time.
    let mut command_hashes: Vec<u64> = vec![0; plan.len()];
    for (slot, &edge_idx) in plan.iter().enumerate() {
        let edge = &edges[edge_idx];
        if edge.is_phony() {
            continue;
        }
        let Some(rule) = state.rules.get(&edge.rule) else {
            continue;
        };
        let raw = rule
            .bindings
            .get("command")
            .map(|s| s.as_str())
            .unwrap_or("");
        let cmd = expand_in_edge(state, edge, raw);
        command_hashes[slot] = log::hash_command(&cmd);
    }

    // Initial node dirtiness — kept deliberately minimal:
    //   - phony outputs whose edge has no inputs ('.FORCE'-style nodes)
    //     are always dirty;
    //   - everything else starts clean and the dispatch-time
    //      check (combined with each completed edge's
    //     dirty-output update) decides whether downstream work fires.
    let mut dirty: HashMap<String, bool> = HashMap::new();
    let mut phony_mtimes = HashMap::new();
    for &edge_idx in plan.iter() {
        let edge = &edges[edge_idx];
        if edge.is_phony() && edge.inputs.is_empty() && edge.implicit_inputs.is_empty() {
            for o in edge.outputs.iter().chain(&edge.implicit_outputs) {
                dirty.insert(o.clone(), true);
            }
        }
    }

    for &edge_idx in plan.iter() {
        mark_depfile_dirty(state, &edges[edge_idx], &deps_log, &mut dirty);
    }

    // Compare output times at dispatch, after the dyndep file has supplied
    // any restat binding and additional inputs for the edge.
    for (slot, &edge_idx) in plan.iter().enumerate() {
        let edge = &edges[edge_idx];
        if edge.is_phony() || is_generator(state, edge) {
            continue;
        }
        let new_hash = command_hashes[slot];
        for out in edge.outputs.iter().chain(&edge.implicit_outputs) {
            if !prev_log
                .entries
                .get(out)
                .is_some_and(|entry| entry.command_hash == new_hash)
            {
                dirty.insert(out.clone(), true);
            }
        }
    }

    loop {
        // Dispatch every ready edge up to the parallelism cap. We stop
        // launching new work once a hard failure or interruption fires
        // — let in-flight jobs drain so their output is preserved.
        let stop_dispatching =
            failure_count >= failure_limit || interrupted || dyndep_failure.is_some();
        let mut dyndep_producer_completed_inline = false;
        if !stop_dispatching {
            // Eagerly merge every loadable dyndep file before deciding
            // which edges to dispatch. Loading them up-front means a
            // "multiple rules generate X" collision is detected as
            // soon as the producing files exist on disk, and *before*
            // either consumer commits to running.
            for (slot, &edge_idx) in plan.iter().enumerate() {
                if blocked[slot] {
                    continue;
                }
                if let Some(dd_path) = edges[edge_idx].dyndep.clone()
                    && !dyndep_loaded.contains(&edge_idx)
                    && state
                        .producers
                        .get(&dd_path)
                        .and_then(|producer| idx_in_plan.get(producer))
                        .is_none_or(|&slot| done[slot])
                    && std::path::Path::new(&dd_path).exists()
                {
                    match merge_dyndep(
                        &mut edges,
                        edge_idx,
                        &dd_path,
                        &mut producers,
                        &mut dyndep_cache,
                    ) {
                        Ok(()) => {
                            dyndep_loaded.insert(edge_idx);
                        }
                        Err(e) => {
                            dyndep_failure = Some(e);
                            break;
                        }
                    }
                }
            }
            if dyndep_failure.is_some() {
                continue;
            }
            // Detect dyndep collisions before dispatching ordinary consumers.
            // A producer with its own dyndep must be able to run once that
            // dependency is ready.
            let pending_dyndep_producers: HashSet<usize> = edges
                .iter()
                .filter_map(|e| e.dyndep.as_deref())
                .filter_map(|p| state.producers.get(p))
                .copied()
                .filter(|prod| {
                    in_plan.contains(prod)
                        && idx_in_plan.get(prod).is_some_and(|s| !done[*s] && !blocked[*s])
                })
                .collect();

            for slot in 0..plan.len() {
                if started[slot] || blocked[slot] || remaining[slot] > 0 {
                    continue;
                }
                if in_flight >= jobs {
                    break;
                }
                let edge_idx = plan[slot];
                if let Some(path) = &edges[edge_idx].dyndep {
                    let waiting_for_metadata = state
                        .producers
                        .get(path)
                        .is_some_and(|producer| pending_dyndep_producers.contains(producer));
                    if waiting_for_metadata
                        || (!pending_dyndep_producers.is_empty()
                            && !pending_dyndep_producers.contains(&edge_idx))
                    {
                        continue;
                    }
                    if !dyndep_loaded.contains(&edge_idx) {
                        if opts.dry_run {
                            preview_failure.get_or_insert_with(|| (preview.len(), path.clone()));
                        } else {
                            dyndep_failure =
                                Some(format!("error: loading '{path}': dyndep file is missing"));
                            break;
                        }
                    }
                }
                // Pool capacity check. Only real (non-phony) edges
                // count against a pool — phonies don't spawn work.
                let pool_name = pool_for_edge(state, &edges[edge_idx]);
                if let Some(name) = pool_name.as_deref()
                    && !edges[edge_idx].is_phony()
                {
                    let cap = pool_depths.get(name).copied().unwrap_or(if name == "console" {
                        1
                    } else {
                        usize::MAX
                    });
                    let cur = pool_in_flight.get(name).copied().unwrap_or(0);
                    if cur >= cap {
                        continue;
                    }
                }
                // Console-pool gate: a console edge must own the
                // terminal exclusively. Wait until every in-flight
                // async edge has drained before taking it. Conversely,
                // a non-console edge must never start while the
                // console is locked (defensive — synchronous console
                // execution makes this unreachable in practice).
                let is_console_now =
                    !edges[edge_idx].is_phony() && is_console_edge(state, &edges[edge_idx]);
                if is_console_now && in_flight > 0 {
                    continue;
                }
                if !is_console_now && !edges[edge_idx].is_phony() && status.console_locked() {
                    continue;
                }
                let edge = edges[edge_idx].clone();
                if edge.is_phony() {
                    let newest_input = newest_input_mtime(&edge, &phony_mtimes);
                    let input_dirty = edge
                        .inputs
                        .iter()
                        .chain(&edge.implicit_inputs)
                        .any(|input| dirty.get(input) == Some(&true));
                    for output in edge.outputs.iter().chain(&edge.implicit_outputs) {
                        phony_mtimes.insert(output.clone(), newest_input);
                        if input_dirty {
                            dirty.insert(output.clone(), true);
                        }
                    }
                    // Phony "completes" instantly; mark done inline so we
                    // can dispatch its dependents on this same loop turn.
                    started[slot] = true;
                    dyndep_producer_completed_inline |= pending_dyndep_producers.contains(&edge_idx);
                    complete_slot(slot, &dependents, &mut done, &mut remaining);
                    continue;
                }
                let restat = rule_has_restat(state, &edge);
                let needs = edge_needs_run(state, &edge, &dirty, &phony_mtimes, &prev_log, restat);
                if !needs || opts.dry_run {
                    if needs {
                        let (_, shown) = describe_command(state, &edge, opts)?;
                        preview.push(shown);
                    }
                    started[slot] = true;
                    for o in edge.outputs.iter().chain(&edge.implicit_outputs) {
                        dirty.insert(o.clone(), needs);
                    }
                    dyndep_producer_completed_inline |= pending_dyndep_producers.contains(&edge_idx);
                    complete_slot(slot, &dependents, &mut done, &mut remaining);
                    continue;
                }
                let acquired_slot = if let Some(c) = jobserver_client.as_mut() {
                    match c.try_acquire() {
                        Some(s) => Some(s),
                        None => continue,
                    }
                } else {
                    None
                };
                started[slot] = true;
                held_slots[slot] = acquired_slot;
                in_flight += 1;
                any_real_work = true;
                if let Some(name) = pool_name.as_deref() {
                    *pool_in_flight.entry(name.to_string()).or_insert(0) += 1;
                }
                let prepared = prepare(state, &edge, opts)?;
                // Capture explain lines for dirty inputs of this edge.
                let explain_lines: Vec<String> = if explain {
                    let mut seen = HashSet::new();
                    edge.inputs
                        .iter()
                        .chain(&edge.implicit_inputs)
                        .chain(&edge.order_only_inputs)
                        .filter(|i| *dirty.get(i.as_str()).unwrap_or(&false))
                        .filter(|i| seen.insert((*i).clone()))
                        .map(|i| format!("ninja explain: {i} is dirty"))
                        .collect()
                } else {
                    Vec::new()
                };
                let outputs = edge
                    .outputs
                    .iter()
                    .chain(&edge.implicit_outputs)
                    .map(|path| OutputBeforeRun {
                        path: path.clone(),
                        mtime: if restat {
                            BeforeMtime::Observed(mtime_of(path))
                        } else {
                            BeforeMtime::Unobserved
                        },
                    })
                    .collect();
                if is_console_now {
                    status.build_started_console(&prepared.shown);
                } else {
                    status.build_started(&prepared.shown);
                }
                let tx = tx.clone();
                let cmd_hash = command_hashes[slot];
                let send_outcome = move |run_command: fn(&Prepared) -> OutcomeKind| {
                    let command_started = SystemTime::now();
                    let kind = run_command(&prepared);
                    let outcome = EdgeOutcome {
                        slot,
                        shown: prepared.shown,
                        kind,
                        explain: explain_lines,
                        outputs,
                        command_hash: cmd_hash,
                    };
                    let _ = tx.send((outcome, command_started));
                };
                if is_console_now {
                    // Console-pool edges run synchronously on the main
                    // thread with inherited stdio so the child can
                    // draw progress bars / read stdin. The status
                    // printer is locked for the duration so any
                    // non-console completion that arrives mid-run is
                    // buffered and drained at unlock time. We still
                    // inject the outcome through `tx` so the unified
                    // reap path handles bookkeeping (dirtiness,
                    // .ninja_log, deps_log, pool/jobserver release).
                    status.lock_console();
                    send_outcome(execute_console);
                } else {
                    thread::spawn(move || send_outcome(execute));
                }
            }
        }

        if in_flight == 0 {
            let unstarted = started.iter().any(|s| !*s);
            if unstarted && dyndep_producer_completed_inline {
                continue;
            }
            if unstarted && held_slots.iter().any(|s| s.is_some()) {
                if let Some(c) = jobserver_client.as_mut() {
                    for held in &mut held_slots {
                        if let Some(token) = held.take() {
                            c.release(token);
                        }
                    }
                }
                continue;
            }
            break;
        }

        // Wait for the next completion, then opportunistically drain
        // any other already-arrived completions before re-entering the
        // dispatch loop. This keeps pacing deterministic and — more
        // importantly — lets us load *all* freshly-written dyndep files
        // before deciding which dependent edges to dispatch, so a
        // "multiple rules generate X" collision is detected before
        // either consumer commits to running.
        let mut batch = match rx.recv() {
            Ok(o) => vec![o],
            Err(_) => break,
        };
        while let Ok(more) = rx.try_recv() {
            batch.push(more);
        }
        // Sort batched completions by plan slot so output ordering is
        // deterministic when several short edges finish nearly
        // simultaneously. Edges that finish in a different batch
        // i.e. distinct rx.recv() blocks still appear in completion
        // order, preserving the interleaving asserted by test_issue_1418.
        batch.sort_by_key(|(outcome, _)| outcome.slot);
        for (outcome, command_started) in batch {
            in_flight -= 1;
            let slot = outcome.slot;
            // Release the pool slot this edge held, if any.
            if let Some(name) = pool_for_edge(state, &edges[plan[slot]])
                && !edges[plan[slot]].is_phony()
                && let Some(c) = pool_in_flight.get_mut(&name)
            {
                *c = c.saturating_sub(1);
            }
            // Return the jobserver token, if any, before reaping the
            // next batch — other clients (or our own next dispatch
            // pass) can then claim it.
            if let (Some(c), Some(slot_token)) =
                (jobserver_client.as_mut(), held_slots[slot].take())
            {
                c.release(slot_token);
            }
            // Update dirty status for the outputs based on restat.
            let outputs_dirty = outcome.outputs.iter().any(|output| match output.mtime {
                BeforeMtime::Observed(Some(before)) => mtime_of(&output.path) != Some(before),
                BeforeMtime::Observed(None) | BeforeMtime::Unobserved => true,
            });
            for output in &outcome.outputs {
                dirty.insert(output.path.clone(), outputs_dirty);
            }
            // Print any captured explain lines just before the
            // corresponding `[N/T]` status line. Doing it here keeps the
            // pair tightly grouped even when multiple edges complete in
            // the same batch.
            for line in &outcome.explain {
                println!("{line}");
            }
            let edge_was_console =
                is_console_edge(state, &edges[plan[slot]]) && !edges[plan[slot]].is_phony();
            match outcome.kind {
                OutcomeKind::Ok { combined } => {
                    complete_slot(slot, &dependents, &mut done, &mut remaining);
                    if edge_was_console {
                        status.build_finished_console(&outcome.shown);
                    } else {
                        status.build_finished(&outcome.shown, &combined);
                    }
                    let started_ns = log::mtime_to_ns(Some(command_started));
                    let finished_ns = log::mtime_to_ns(Some(SystemTime::now()));
                    for output in &outcome.outputs {
                        let out = &output.path;
                        let observed = mtime_of(out);
                        let observed_ns = log::mtime_to_ns(observed);
                        let recorded_ns = match output.mtime {
                            BeforeMtime::Observed(before) if before == observed => started_ns,
                            BeforeMtime::Observed(_) => started_ns.max(observed_ns),
                            BeforeMtime::Unobserved => observed_ns,
                        };
                        let entry = log::LogEntry {
                            start_ms: (started_ns / 1_000_000) as u64,
                            end_ms: (finished_ns / 1_000_000) as u64,
                            mtime_ns: recorded_ns,
                            command_hash: outcome.command_hash,
                        };
                        if let Some(writer) = &mut log_writer {
                            writer.record(std::slice::from_ref(out), &entry);
                        }
                    }
                    // For `deps = gcc|msvc` edges: parse the freshly
                    // dropped depfile, persist the discovered headers
                    // into `.ninja_deps`, then unlink the depfile.
                    // Reference ninja consumes the depfile this way
                    // so the next invocation can answer dirtiness
                    // questions purely from `.ninja_deps`.
                    let edge_idx = plan[slot];
                    let edge_ref = &edges[edge_idx];
                    if let Some(rule) = state.rules.get(&edge_ref.rule) {
                        let deps_kind = lookup_either(edge_ref, rule, "deps");
                        let depfile = edge_binding(state, edge_ref, rule, "depfile");
                        if matches!(deps_kind.as_deref(), Some("gcc") | Some("msvc"))
                            && let Some(df_path) = depfile
                            && !df_path.is_empty()
                                && let Ok(text) = std::fs::read_to_string(&df_path)
                            {
                                let parsed = depfile::parse(&text);
                                for out in edge_ref.outputs.iter().chain(&edge_ref.implicit_outputs)
                                {
                                    if let Some(deps_list) = parsed.targets.get(out) {
                                        let mtime_ns = log::mtime_to_ns(mtime_of(out)) as u64;
                                        let _ = deps_log.record(out, mtime_ns, deps_list);
                                    }
                                }
                                let _ = std::fs::remove_file(&df_path);
                            }
                    }
                }
                OutcomeKind::Failed { code, combined } => {
                    // A failed edge never releases its dependents. Mark the
                    // subtree as blocked as well, so blocked dyndep producers
                    // do not prevent independent metadata from being loaded.
                    let mut pending = vec![slot];
                    while let Some(failed) = pending.pop() {
                        if !blocked[failed] {
                            blocked[failed] = true;
                            pending.extend(&dependents[failed]);
                        }
                    }
                    if edge_was_console {
                        // The child wrote any failure detail directly
                        // to the terminal; we still emit the
                        // FAILED:/header that execute_console
                        // assembled so the user sees the exit code
                        // and the failing command.
                        status.build_finished_console(&outcome.shown);
                        let mut stdout = std::io::stdout().lock();
                        use std::io::Write as _;
                        let _ = stdout.write_all(&combined);
                        let _ = stdout.flush();
                    } else {
                        status.build_finished(&outcome.shown, &combined);
                    }
                    if hard_failure.is_none() {
                        hard_failure = Some(code);
                    }
                    failure_count += 1;
                }
                OutcomeKind::Interrupted => {
                    interrupted = true;
                }
                OutcomeKind::SpawnError(e) => return Err(e),
            }
        }
    }

    if opts.dry_run {
        let mut status = Status::new(Mode::detect(), opts.quiet, opts.verbose, preview.len());
        let (visible, missing) = match &preview_failure {
            Some((visible, path)) => (*visible, Some(path)),
            None => (preview.len(), None),
        };
        for shown in &preview[..visible] {
            status.build_finished(shown, &[]);
        }
        status.finish();
        if let Some(path) = missing {
            println!("ninja: build stopped: loading '{path}': No such file or directory.");
            return Ok((1, visible != 0));
        }
        any_real_work = visible != 0;
    }
    status.finish();
    if interrupted {
        println!("ninja: build stopped: interrupted by user.");
        return Ok((130, any_real_work));
    }
    if let Some(msg) = dyndep_failure {
        // Match upstream wording exactly:
        //   ninja: build stopped: multiple rules generate X.
        eprintln!("ninja: build stopped: {msg}.");
        return Ok((1, any_real_work));
    }
    if let Some(code) = hard_failure {
        eprintln!("ninja: build stopped: subcommand failed.");
        return Ok((code, any_real_work));
    }
    if !any_real_work && !opts.quiet && announce_no_work {
        // Every edge in the plan was either phony or skipped because
        // its outputs were already up to date — match reference ninja
        // and tell the user there's nothing to do.
        println!("ninja: no work to do.");
    }
    Ok((0, any_real_work))
}

fn complete_slot(slot: usize, dependents: &[Vec<usize>], done: &mut [bool], remaining: &mut [usize]) {
    done[slot] = true;
    for &dependent in &dependents[slot] {
        if !done[dependent] {
            remaining[dependent] -= 1;
        }
    }
}

/// Decide whether the edge still needs to run *right now*. An edge
/// needs to run if any of its outputs is missing on disk, any of its
/// outputs has been flagged dirty, or any of its inputs is currently
/// flagged dirty.
fn edge_needs_run(
    state: &State,
    edge: &Edge,
    dirty: &HashMap<String, bool>,
    phony_mtimes: &HashMap<String, Option<SystemTime>>,
    previous_log: &log::BuildLog,
    restat: bool,
) -> bool {
    if edge
        .inputs
        .iter()
        .chain(&edge.implicit_inputs)
        .any(|input| dirty.get(input) == Some(&true))
    {
        return true;
    }
    let mut newest_input = None;
    let check_observed_mtime = !restat && !is_generator(state, edge);
    for o in edge.outputs.iter().chain(&edge.implicit_outputs) {
        if dirty.get(o) == Some(&true) {
            return true;
        }
        let Some(observed) = mtime_of(o) else {
            return true;
        };
        let observed_ns = log::mtime_to_ns(Some(observed));
        let entry = previous_log.entries.get(o);
        if check_observed_mtime && entry.is_some_and(|entry| entry.mtime_ns != observed_ns) {
            return true;
        }
        let output_mtime = if restat {
            entry.map_or(observed_ns, |entry| entry.mtime_ns)
        } else {
            observed_ns
        };
        let input_mtime = *newest_input
            .get_or_insert_with(|| log::mtime_to_ns(newest_input_mtime(edge, phony_mtimes)));
        if output_mtime < input_mtime {
            return true;
        }
    }
    false
}

fn newest_input_mtime(
    edge: &Edge,
    phony_mtimes: &HashMap<String, Option<SystemTime>>,
) -> Option<SystemTime> {
    edge.inputs
        .iter()
        .chain(&edge.implicit_inputs)
        .filter_map(|input| match phony_mtimes.get(input) {
            Some(mtime) => *mtime,
            None => mtime_of(input),
        })
        .max()
}

fn mark_depfile_dirty(
    state: &State,
    edge: &Edge,
    deps_log: &DepsLog,
    dirty: &mut HashMap<String, bool>,
) {
    let Some(rule) = state.rules.get(&edge.rule) else {
        return;
    };
    let uses_deps_cache = matches!(
        lookup_either(edge, rule, "deps").as_deref(),
        Some("gcc") | Some("msvc")
    );
    let Some(path) = edge_binding(state, edge, rule, "depfile").filter(|path| !path.is_empty()) else {
        return;
    };
    if uses_deps_cache
        && let Some(out) = edge.outputs.first()
        && !deps_log.records.contains_key(out)
    {
        dirty.insert(out.clone(), true);
    }
    let text = std::fs::read_to_string(path).ok();
    let parsed = text.as_deref().map(depfile::parse);
    for out in edge.outputs.iter().chain(&edge.implicit_outputs) {
        let deps = parsed
            .as_ref()
            .and_then(|depfile| depfile.targets.get(out))
            .map(Vec::as_slice)
            .or_else(|| {
                if uses_deps_cache {
                    deps_log.records.get(out).map(|record| record.deps.as_slice())
                } else {
                    None
                }
            });
        if let Some(deps) = deps {
            let output_mtime = mtime_of(out);
            if deps.iter().any(|dep| match (mtime_of(dep), output_mtime) {
                (Some(input), Some(output)) => input > output,
                _ => true,
            }) {
                dirty.insert(out.clone(), true);
            }
        }
    }
}

fn rule_has_restat(state: &State, edge: &Edge) -> bool {
    if let Some(v) = edge.bindings.get("restat") {
        return matches!(v.as_str(), "1" | "true");
    }
    if let Some(rule) = state.rules.get(&edge.rule)
        && let Some(v) = rule.bindings.get("restat")
    {
        return matches!(v.as_str(), "1" | "true");
    }
    false
}

/// Resolve the pool name for an edge by walking the standard binding
/// chain: per-edge bindings first, then the rule's bindings. Empty or
/// missing means "no pool" (unbounded).
fn pool_for_edge(state: &State, edge: &Edge) -> Option<String> {
    if let Some(v) = edge.bindings.get("pool")
        && !v.is_empty()
    {
        return Some(v.clone());
    }
    if let Some(rule) = state.rules.get(&edge.rule)
        && let Some(v) = rule.bindings.get("pool")
        && !v.is_empty()
    {
        return Some(v.clone());
    }
    None
}

/// True when this edge is bound to the implicit `console` pool, in
/// which case it must run with stdin/stdout/stderr inherited from
/// ninja and own the terminal exclusively for the duration.
fn is_console_edge(state: &State, edge: &Edge) -> bool {
    pool_for_edge(state, edge).as_deref() == Some("console")
}

fn mtime_of(path: &str) -> Option<SystemTime> {
    std::fs::metadata(path).ok().and_then(|m| m.modified().ok())
}

/// Load (or fetch from cache) the dyndep file at `path`, locate the
/// entry whose explicit output matches one of `edges[idx]`'s outputs,
/// and merge the discovered implicit outputs + inputs into the edge.
/// On a duplicate output a "multiple rules generate X" string is
/// returned so the scheduler can short-circuit.
fn merge_dyndep(
    edges: &mut [Edge],
    idx: usize,
    path: &str,
    producers: &mut HashMap<String, usize>,
    cache: &mut HashMap<String, dyndep::DyndepFile>,
) -> Result<(), String> {
    if !cache.contains_key(path) {
        cache.insert(path.to_string(), read_dyndep(path)?);
    }
    let ddf = &cache[path];
    let edge = &mut edges[idx];
    let Some(entry) = ddf.entry_for(&edge.outputs) else {
        return Ok(());
    };
    for new_out in &entry.implicit_outputs {
        if producers.contains_key(new_out) {
            return Err(format!("multiple rules generate {new_out}"));
        }
        producers.insert(new_out.clone(), idx);
        edge.implicit_outputs.push(new_out.clone());
    }
    for new_in in &entry.implicit_inputs {
        edge.implicit_inputs.push(new_in.clone());
    }
    if entry.restat {
        edge.bindings.insert("restat".to_string(), "1".to_string());
    }
    Ok(())
}

fn read_dyndep(path: &str) -> Result<dyndep::DyndepFile, String> {
    let source =
        std::fs::read_to_string(path).map_err(|e| format!("loading dyndep '{path}': {e}"))?;
    dyndep::parse(&source).map_err(|e| format!("dyndep '{path}': {e}"))
}

/// Everything needed to run an edge in a worker thread, pre-resolved on
/// the main thread so the worker does no graph access.
struct Prepared {
    shown: String,
    command: String,
    shell: super::command::ShellPolicy,
    outputs: String,
    rspfile: Option<(String, String)>,
}

fn describe_command(state: &State, edge: &Edge, opts: &Options) -> Result<(String, String), String> {
    let rule = state
        .rules
        .get(&edge.rule)
        .ok_or_else(|| format!("unknown rule '{}'", edge.rule))?;
    let command = expand_in_edge(
        state,
        edge,
        rule.bindings
            .get("command")
            .map(|s| s.as_str())
            .unwrap_or(""),
    );
    let description = rule
        .bindings
        .get("description")
        .map(|d| expand_in_edge(state, edge, d))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| command.clone());
    let shown = if opts.verbose {
        command.clone()
    } else {
        description
    };
    Ok((command, shown))
}

fn prepare(state: &State, edge: &Edge, opts: &Options) -> Result<Prepared, String> {
    let (command, shown) = describe_command(state, edge, opts)?;
    let rule = &state.rules[&edge.rule];
    // Output and depfile parent dirs are created up-front so commands can
    // assume the output directory exists. Matches
    // `test_depfile_directory_creation`.
    for out in edge.outputs.iter().chain(&edge.implicit_outputs) {
        ensure_parent_dir(out);
    }
    if let Some(path) = edge_binding(state, edge, rule, "depfile")
        && !path.is_empty() {
            ensure_parent_dir(&path);
        }

    let rspfile = edge_binding(state, edge, rule, "rspfile")
        .filter(|s| !s.is_empty())
        .map(|path| {
            let content = edge_binding(state, edge, rule, "rspfile_content")
                .unwrap_or_default();
            (path, content)
        });

    Ok(Prepared {
        shown,
        command,
        shell: super::command::ShellPolicy::from_env(),
        outputs: edge.outputs.join(" "),
        rspfile,
    })
}

enum BeforeMtime {
    Unobserved,
    Observed(Option<SystemTime>),
}

struct OutputBeforeRun {
    path: String,
    mtime: BeforeMtime,
}

struct EdgeOutcome {
    slot: usize,
    shown: String,
    kind: OutcomeKind,
    explain: Vec<String>,
    outputs: Vec<OutputBeforeRun>,
    /// Hash of the command we ran for this edge. Carried into the
    /// completion handler so it can be appended to `.ninja_log`.
    command_hash: u64,
}

enum OutcomeKind {
    Ok { combined: Vec<u8> },
    Failed { code: u8, combined: Vec<u8> },
    Interrupted,
    SpawnError(String),
}

/// Worker-side: write the rspfile, spawn the command, capture output,
/// remove the rspfile. Decides whether the exit code maps to Ok, Failed,
/// or Interrupted (SIGINT).
fn execute(p: &Prepared) -> OutcomeKind {
    if let Some((path, content)) = &p.rspfile {
        ensure_parent_dir(path);
        if let Err(e) = std::fs::write(path, content) {
            return OutcomeKind::SpawnError(format!("rspfile '{path}': {e}"));
        }
    }

    let result = super::command::output(&p.command, p.shell);

    if let Some((path, _)) = &p.rspfile {
        let _ = std::fs::remove_file(path);
    }

    let output = match result {
        Ok(o) => o,
        Err(e) => return OutcomeKind::SpawnError(format!("failed to spawn: {e}")),
    };

    let mut combined = output.stdout;
    combined.extend_from_slice(&output.stderr);

    if output.status.success() {
        return OutcomeKind::Ok { combined };
    }

    let raw = output.status.code().unwrap_or(-1);
    if raw == 130 {
        return OutcomeKind::Interrupted;
    }
    let code: u8 = if !(0..=255).contains(&raw) {
        1
    } else {
        raw as u8
    };
    // Prepend the standard `FAILED: [code=N] outputs\ncommand\n` block
    // so it shows up between the status line and any captured output.
    let header = format!("FAILED: [code={raw}] {} \n{}\n", p.outputs, p.command);
    let mut buf = header.into_bytes();
    buf.extend_from_slice(&combined);
    OutcomeKind::Failed { code, combined: buf }
}

/// Console-pool variant of `execute`: spawns the subprocess with
/// stdin/stdout/stderr inherited from ninja so the child owns the
/// terminal. Returns an `OutcomeKind` with empty `combined` on success
/// (the child's output went straight to the terminal); failures still
/// carry a synthetic `FAILED: [code=N] outputs\ncommand\n` header so
/// the eventual reap path can replay it after the console unlocks.
fn execute_console(p: &Prepared) -> OutcomeKind {
    if let Some((path, content)) = &p.rspfile {
        ensure_parent_dir(path);
        if let Err(e) = std::fs::write(path, content) {
            return OutcomeKind::SpawnError(format!("rspfile '{path}': {e}"));
        }
    }

    let result = super::command::status(&p.command, p.shell);

    if let Some((path, _)) = &p.rspfile {
        let _ = std::fs::remove_file(path);
    }

    let status = match result {
        Ok(s) => s,
        Err(e) => return OutcomeKind::SpawnError(format!("failed to spawn: {e}")),
    };

    if status.success() {
        return OutcomeKind::Ok {
            combined: Vec::new(),
        };
    }

    let raw = status.code().unwrap_or(-1);
    if raw == 130 {
        return OutcomeKind::Interrupted;
    }
    let code: u8 = if !(0..=255).contains(&raw) {
        1
    } else {
        raw as u8
    };
    let header = format!("FAILED: [code={raw}] {} \n{}\n", p.outputs, p.command);
    OutcomeKind::Failed {
        code,
        combined: header.into_bytes(),
    }
}

fn ensure_parent_dir(path: &str) {
    if let Some(parent) = std::path::Path::new(path).parent()
        && !parent.as_os_str().is_empty()
    {
        let _ = std::fs::create_dir_all(parent);
    }
}

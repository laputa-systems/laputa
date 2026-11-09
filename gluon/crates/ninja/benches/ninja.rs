#[global_allocator]
static ALLOC: rustybench::AllocProfiler = rustybench::AllocProfiler::system();

fn main() { rustybench::main(); }

fn gen_text(n: usize) -> String {
    let mut s = String::from("rule cc\n  command = cc -c $in -o $out\n");
    for i in 1..=n {
        s.push_str(&format!("build o{i}.o: cc a{i}.c\n"));
    }
    s
}

fn parse_and_plan(n: usize) -> (graph::State, Vec<usize>) {
    let text = gen_text(n);
    let state = ninja::manifest::parse(&text).unwrap();
    let targets = ninja::build::plan::resolve_targets(&state, &ninja::cli::Options::default());
    let order = ninja::build::plan::build_plan(&state, &targets).unwrap();
    assert_eq!(order.len(), n);
    (state, order)
}

#[rustybench::bench(sample_count = 5, sample_size = 1)]
fn manifest_parse_1k(bencher: rustybench::Bencher) {
    let text = gen_text(1_000);
    bencher.bench_local(|| {
        let state = ninja::manifest::parse(rustybench::black_box(&text)).unwrap();
        assert_eq!(state.edges.len(), 1_000);
        rustybench::black_box(state);
    });
}

#[rustybench::bench(sample_count = 3, sample_size = 1)]
fn manifest_parse_100k(bencher: rustybench::Bencher) {
    let text = gen_text(100_000);
    bencher.bench_local(|| {
        let state = ninja::manifest::parse(rustybench::black_box(&text)).unwrap();
        assert_eq!(state.edges.len(), 100_000);
        rustybench::black_box(state);
    });
}

#[rustybench::bench(sample_count = 5, sample_size = 1)]
fn plan_10k(bencher: rustybench::Bencher) {
    let (state, _order) = parse_and_plan(10_000);
    let targets = ninja::build::plan::resolve_targets(&state, &ninja::cli::Options::default());
    bencher.bench_local(|| {
        let order = ninja::build::plan::build_plan(rustybench::black_box(&state), rustybench::black_box(&targets)).unwrap();
        assert_eq!(order.len(), 10_000);
        rustybench::black_box(order);
    });
}

#[rustybench::bench(sample_count = 10, sample_size = 1)]
fn expand_in_edge_compiles(bencher: rustybench::Bencher) {
    let text = gen_text(100);
    let state = ninja::manifest::parse(&text).unwrap();
    let edge = &state.edges[0];
    bencher.bench_local(|| {
        let out = ninja::build::expand_in_edge_pub(&state, rustybench::black_box(edge), "cc -c $in -o $out");
        assert!(out.contains("cc"));
        rustybench::black_box(out);
    });
}

#[rustybench::bench(sample_count = 10, sample_size = 1)]
fn log_hash_100k(bencher: rustybench::Bencher) {
    let cmds: Vec<String> = (0..100_000).map(|i| format!("cc -c a{i}.c -o o{i}.o")).collect();
    bencher.bench_local(|| {
        let mut sum = 0u64;
        for c in rustybench::black_box(&cmds).iter() {
            sum = sum.wrapping_add(state::log::hash_command(c));
        }
        assert_ne!(sum, 0);
        rustybench::black_box(sum);
    });
}

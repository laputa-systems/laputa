#[global_allocator]
static ALLOC: rustybench::AllocProfiler = rustybench::AllocProfiler::system();

fn main() { rustybench::main(); }

#[rustybench::bench(sample_count = 5, sample_size = 1)]
fn intern_paths_typical(bencher: rustybench::Bencher) {
    // Realistic libplacebo-ish path corpus (mix of src/include, build outputs).
    let paths: Vec<String> = (0..1000)
        .map(|i| format!("src/libplacebo.module_{i}.c"))
        .collect();
    bencher.bench_local(|| {
        let mut interner = graph::Interner::new();
        for p in rustybench::black_box(&paths).iter() {
            interner.intern(rustybench::black_box(p.as_str()));
        }
        assert_eq!(interner.len(), 1000);
        rustybench::black_box(interner);
    });
}

#[rustybench::bench(sample_count = 5, sample_size = 1)]
fn intern_repeated_heavy(bencher: rustybench::Bencher) {
    let paths: Vec<String> = (0..500).map(|i| format!("src/shaders/film_grain_{i}.h")).collect();
    bencher.bench_local(|| {
        let mut interner = graph::Interner::new();
        for _ in 0..10 {
            for p in rustybench::black_box(&paths).iter() {
                let _ = interner.intern(rustybench::black_box(p.as_str()));
            }
        }
        assert_eq!(interner.len(), 500);
        rustybench::black_box(interner);
    });
}

#[rustybench::bench(sample_count = 5, sample_size = 1)]
fn arena_push_10k(bencher: rustybench::Bencher) {
    bencher.bench_local(|| {
        let mut arena = graph::Arena::new();
        for i in 0..rustybench::black_box(10_000) {
            arena.push(i);
        }
        assert_eq!(arena.len(), 10_000);
        rustybench::black_box(arena);
    });
}

#[rustybench::bench(sample_count = 5, sample_size = 1)]
fn producers_lookup_100k(bencher: rustybench::Bencher) {
    let mut state = graph::State::default();
    for i in 0..100_000 {
        state.producers.insert(format!("o{i}.o"), i);
    }
    bencher.bench_local(|| {
        for i in 0..100_000 {
            let k = format!("o{i}.o");
            let v = state.producers.get(rustybench::black_box(&k));
            assert!(v.is_some());
        }
        rustybench::black_box(&state);
    });
}

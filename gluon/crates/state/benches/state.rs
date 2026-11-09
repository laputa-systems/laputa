#[global_allocator]
static ALLOC: rustybench::AllocProfiler = rustybench::AllocProfiler::system();

fn main() { rustybench::main(); }

fn tmp() -> std::path::PathBuf { std::env::temp_dir().join(format!("gluon-bench-state-{}", std::process::id())) }

#[rustybench::bench(sample_count = 3, sample_size = 1)]
fn log_roundtrip_1k(bencher: rustybench::Bencher) {
    let dir = tmp(); std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(".ninja_log").to_string_lossy().to_string();
    let mut w = state::log::Writer::new(&path);
    for i in 0..1_000 {
        w.record(&[format!("o{i}.o")], &state::log::LogEntry { start_ms: 0, end_ms: 0, mtime_ns: 1, command_hash: state::log::hash_command(&format!("cc o{i}")) });
    }
    drop(w);
    bencher.bench_local(|| {
        let log = state::log::load(rustybench::black_box(&path));
        assert_eq!(log.entries.len(), 1_000);
        rustybench::black_box(log);
    });
    let _ = std::fs::remove_dir_all(&dir);
}

#[rustybench::bench(sample_count = 3, sample_size = 1)]
fn deps_log_roundtrip_1k(bencher: rustybench::Bencher) {
    let dir = tmp(); std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(".ninja_deps").to_string_lossy().to_string();
    let mut log = state::deps_log::DepsLog::load(&path);
    for i in 0..1_000 {
        log.record(&format!("o{i}.o"), 1, &[format!("a{i}.h")]).unwrap();
    }
    bencher.bench_local(|| {
        let loaded = state::deps_log::DepsLog::load(rustybench::black_box(&path));
        assert_eq!(loaded.records.len(), 1_000);
        rustybench::black_box(loaded);
    });
    let _ = std::fs::remove_dir_all(&dir);
}

#[rustybench::bench(sample_count = 5, sample_size = 1)]
fn depfile_parse_realistic(bencher: rustybench::Bencher) {
    let text = "o1.o: a1.c a1.h a2.h \\\n a3.h\n";
    bencher.bench_local(|| {
        let deps = state::depfile::parse(rustybench::black_box(text));
        assert!(!deps.targets.is_empty());
        rustybench::black_box(deps);
    });
}

#[rustybench::bench(sample_count = 5, sample_size = 1)]
fn snapshot_write_read(bencher: rustybench::Bencher) {
    use state::SnapshotWrite;
    let dir = tmp(); std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("build.ninja"), "build a.o: cc a.c\n").unwrap();
    let s = state::Snapshot { build_ninja_mtime: u64::MAX, edge_count: 1, output_count: 1 };
    bencher.bench_local(|| {
        s.write_snapshot(rustybench::black_box(&dir)).unwrap();
        let r = state::Snapshot::read_snapshot(rustybench::black_box(&dir)).unwrap();
        assert_eq!(r.edge_count, 1);
        rustybench::black_box(r);
    });
    let _ = std::fs::remove_dir_all(&dir);
}

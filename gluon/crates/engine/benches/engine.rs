#[global_allocator]
static ALLOC: rustybench::AllocProfiler = rustybench::AllocProfiler::system();

fn main() { rustybench::main(); }

#[rustybench::bench(sample_count = 5, sample_size = 1)]
fn queue_push_pop_10k(bencher: rustybench::Bencher) {
    bencher.bench_local(|| {
        let mut q = engine::QueueScheduler::new(10_000);
        for i in 0..10_000 {
            q.push_ready(rustybench::black_box(i));
        }
        let mut n = 0usize;
        while let Some(idx) = q.pop() {
            n += idx;
            rustybench::black_box(idx);
        }
        assert!(n > 0);
        rustybench::black_box(q);
    });
}

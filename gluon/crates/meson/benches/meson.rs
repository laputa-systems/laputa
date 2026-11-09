#[global_allocator]
static ALLOC: rustybench::AllocProfiler = rustybench::AllocProfiler::system();

fn main() { rustybench::main(); }

#[rustybench::bench(sample_count = 5, sample_size = 1)]
fn lexer_parser_trivial(bencher: rustybench::Bencher) {
    let src = "project('trivial', 'c')\nexecutable('hello', 'main.c')\n";
    bencher.bench_local(|| {
        let mut lexer = meson::lexer::Lexer::new(rustybench::black_box(src));
        let tokens = lexer.tokenize().unwrap();
        let mut parser = meson::parser::Parser::new(tokens);
        let prog = parser.parse().unwrap();
        rustybench::black_box(prog);
    });
}

#[rustybench::bench(sample_count = 3, sample_size = 1)]
fn lexer_parser_typical_libplacebo_snippet(bencher: rustybench::Bencher) {
    // Representative dict + warning multiline snippet from libplacebo (with realistic nesting).
    let src = r#"
project('libplacebo', 'c', version: '7.387.0')
foreach k : ['a', 'b']
  message(k)
endforeach
warning('hello ' +
        'world')
x = join_paths('a', 'b')
"#;
    bencher.bench_local(|| {
        let mut lexer = meson::lexer::Lexer::new(rustybench::black_box(src));
        let tokens = lexer.tokenize().unwrap();
        let mut parser = meson::parser::Parser::new(tokens);
        let prog = parser.parse().unwrap();
        rustybench::black_box(prog);
    });
}

fn setup_trivial(dir: &std::path::Path) {
    let src = dir.join("src");
    std::fs::create_dir_all(&src).unwrap();
    std::fs::write(
        src.join("meson.build"),
        "project('trivial', 'c')\nexecutable('hello', 'main.c')\n",
    )
    .unwrap();
    std::fs::write(src.join("main.c"), "int main(void){return 0;}\n").unwrap();
}

#[test]
fn trivial_generated_manifest_parses() {
    let base = std::env::temp_dir().join(format!(
        "gluon-equiv-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&base);
    setup_trivial(&base);
    let src = base.join("src").to_string_lossy().to_string();
    let build = base.join("build").to_string_lossy().to_string();

    let mut interp = meson::interpreter::Interpreter::new(&src, &build);
    let build_src = std::fs::read_to_string(format!("{}/meson.build", src)).unwrap();
    interp.run(&build_src).expect("interpret trivial meson.build");

    let project = interp.vm.project.clone().expect("project set");
    let backend = meson::backend::NinjaBackend::new(&src, &build);
    let text = backend.generate(&interp.vm.build_data, &project).unwrap();
    let reparsed = ninja::manifest::parse(&text).unwrap();

    assert!(!reparsed.edges.is_empty());
    assert_eq!(reparsed.edges.len(), 3, "compile, link, and all edges");
    assert!(reparsed.defaults.iter().any(|d| d == "all"), "default is all");
    for edge in &reparsed.edges {
        assert!(!edge.outputs.is_empty());
        assert!(!edge.rule.is_empty());
    }
    let _ = std::fs::remove_dir_all(&base);
}

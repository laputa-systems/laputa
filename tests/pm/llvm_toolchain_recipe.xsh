##! Checks the installed compiler and binary-tool wrappers as standalone XSH programs.
use packages.llvm-toolchain.PKGBUILD as llvm_recipe

proc wrapper_checker() -> Result[Path] {
  let configured = e"XSH_HOST" ?? ""
  let runner = if configured != "" { fp"{configured}" } else { process.which("xsh")? }
  fp"{runner.parent()}/xsht"
}

test installed_llvm_wrappers_pass_the_language_checker [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "llvm wrappers")?
  llvm_recipe.install_wrappers(root)
  let checker = wrapper_checker()?

  for wrapper in fs.files(fp"{root}/usr/bin")? {
    let checked = run.capture --text $checker "check" ${wrapper.path}
    assert checked.status.ok, f"{wrapper.name} is invalid XSH:\n{checked.stderr}"
  }
}

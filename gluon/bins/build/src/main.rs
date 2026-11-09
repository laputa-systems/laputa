use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() >= 2 && args[1] == "--version" {
        println!("{}", meson::VERSION);
        return ExitCode::SUCCESS;
    }
    if args.len() >= 2 && args[1] == "ninja" {
        return ninja::main_from(ninja_argv(&args));
    }
    if args.len() >= 2 && args[1] == "meson" {
        let mut synthetic = vec!["meson".to_string()];
        synthetic.extend(args[2..].iter().cloned());
        let cli = meson::Cli::parse_args_from(synthetic);
        return ExitCode::from(cli.run() as u8);
    }
    if args.len() == 1 {
        println!("{}", meson::VERSION);
        return ExitCode::SUCCESS;
    }
    eprintln!("usage: gluon-build [meson|ninja] [args...] | --version");
    ExitCode::from(1)
}

fn ninja_argv(args: &[String]) -> Vec<String> {
    let mut synthetic = vec![args[0].clone()];
    synthetic.extend(args[2..].iter().cloned());
    synthetic
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ninja_subcommand_is_not_a_target() {
        let args = ["gluon-build", "ninja", "-C", "dir", "app"]
            .map(str::to_string)
            .to_vec();
        let opts = ninja::cli::parse(&ninja_argv(&args)).unwrap();
        assert_eq!(opts.chdir.as_deref(), Some("dir"));
        assert_eq!(opts.targets, vec!["app".to_string()]);
    }
}

fn main() {
    let cli = meson::Cli::parse_args();
    std::process::exit(cli.run());
}

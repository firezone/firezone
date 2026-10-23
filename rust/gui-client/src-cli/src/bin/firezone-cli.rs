//! The `firezone-cli` binary: the GUI remote control under its own name,
//! kept as an alias of the `firezone` binary's subcommands.

fn main() -> std::process::ExitCode {
    firezone_cli::main()
}

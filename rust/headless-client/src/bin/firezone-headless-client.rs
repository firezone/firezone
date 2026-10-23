//! The `firezone-headless-client` binary: an alias of `firezone` kept so
//! existing installs and scripts keep working.

fn main() -> std::process::ExitCode {
    firezone_headless_client::main()
}

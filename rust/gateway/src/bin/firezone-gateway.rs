//! The `firezone-gateway` binary: an alias of `firezone`, kept under the
//! Gateway's old name for the installs and images that start it.

fn main() -> std::process::ExitCode {
    firezone_headless_client::main()
}

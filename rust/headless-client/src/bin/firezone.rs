//! The `firezone` binary: the headless Client under the name every Linux
//! install will use.

fn main() -> std::process::ExitCode {
    firezone_headless_client::main()
}

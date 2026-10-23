//! The `firezone-gateway` binary, kept under its own name for the installs
//! that start it; `firezone run --role gateway` is the same program.

#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

fn main() -> std::process::ExitCode {
    firezone_gateway::main()
}

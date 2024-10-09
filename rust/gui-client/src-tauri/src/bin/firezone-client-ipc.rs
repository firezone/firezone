fn main() -> anyhow::Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Calling `install_default` only once per process should always succeed");

    set_umask();

    firezone_headless_client::run_only_ipc_service()
}

/// Sets the umask for the tunnel daemon / IPC service
///
/// Duplicated from `firezone-client-ipc.service`. Setting it
/// here allows smoke tests and debugging to match the behavior of the systemd service unit.
#[cfg(target_os = "linux")]
pub(crate) fn set_umask() {
    nix::sys::stat::umask(
        nix::sys::stat::Mode::from_bits(0o077).expect("Hard-coded umask should always be valid."),
    );
}

/// Does nothing on Windows, needed to match Linux signatures
#[cfg(not(target_os = "linux"))]
pub(crate) fn set_umask() {}

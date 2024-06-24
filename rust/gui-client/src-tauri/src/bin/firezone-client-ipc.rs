fn main() -> anyhow::Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Calling `install_default` only once per process always succeeds");

    firezone_headless_client::run_only_ipc_service()
}

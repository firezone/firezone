fn main() -> anyhow::Result<()> {
    firezone_headless_client::imp::run_only_ipc_service()
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    firezone_headless_client::run_only_ipc_service().await
}

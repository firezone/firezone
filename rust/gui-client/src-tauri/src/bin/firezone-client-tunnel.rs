#[tokio::main]
async fn main() -> anyhow::Result<()> {
    firezone_headless_client::run().await
}

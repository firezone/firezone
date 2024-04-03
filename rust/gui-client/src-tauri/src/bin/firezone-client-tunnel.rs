#[tokio::main]
async fn main() -> anyhow::Result<()> {
    firezone_client_tunnel::run().await
}

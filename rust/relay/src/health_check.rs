use anyhow::Result;
use axum::routing::get;
use axum::Router;
use std::net::SocketAddr;

pub async fn serve(addr: impl Into<SocketAddr>) -> Result<()> {
    let addr = addr.into();

    let service = Router::new()
        .route("/healthz", get(|| async { "" }))
        .into_make_service();

    axum::serve(tokio::net::TcpListener::bind(addr).await?, service).await?;

    Ok(())
}

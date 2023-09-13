use anyhow::Result;
use axum::routing::get;
use axum::{Router, Server};
use std::net::SocketAddr;

pub async fn serve(addr: impl Into<SocketAddr>) -> Result<()> {
    let addr = addr.into();

    let service = Router::new()
        .route("/healthz", get(|| async { "" }))
        .into_make_service();

    Server::try_bind(&addr)?.serve(service).await?;

    Ok(())
}

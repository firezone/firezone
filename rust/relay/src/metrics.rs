use anyhow::Result;
use axum::extract::State;
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Router, Server};
use prometheus_client::registry::Registry;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

const CONTENT_TYPE: &str = "application/openmetrics-text;charset=utf-8;version=1.0.0";
const PORT: u16 = 8080;

pub async fn serve(addr: impl Into<IpAddr>, registry: Registry) -> Result<()> {
    let addr = addr.into();
    let addr = SocketAddr::new(addr, PORT);

    let service = Router::new()
        .route("/metrics", get(metrics))
        .with_state(Arc::new(registry))
        .into_make_service();

    let url = format!("http://{addr}/metrics");
    tracing::info!(%url, "Now serving metrics");

    Server::try_bind(&addr)?.serve(service).await?;

    Ok(())
}

async fn metrics(State(registry): State<Arc<Registry>>) -> Result<impl IntoResponse, StatusCode> {
    let mut metrics = String::new();
    prometheus_client::encoding::text::encode(&mut metrics, &registry)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(([(header::CONTENT_TYPE, CONTENT_TYPE)], metrics))
}

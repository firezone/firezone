use anyhow::{Context, Result};
use axum::{
    Router,
    body::{Body, Bytes},
    extract::Query,
    http::Response,
    response::IntoResponse,
    routing::get,
};
use futures::StreamExt;
use std::{convert::Infallible, net::Ipv4Addr};
use tokio::net::TcpListener;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let port = std::env::var("PORT")
        .context("Missing env var `PORT`")?
        .parse::<u16>()?;

    let router = Router::new().route("/bytes", get(byte_stream));
    let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, port)).await?;

    axum::serve(listener, router).await?;

    Ok(())
}

#[derive(serde::Deserialize)]
struct Params {
    num: usize,
}

async fn byte_stream(Query(params): Query<Params>) -> impl IntoResponse {
    let body = Body::from_stream(
        futures::stream::repeat(0)
            .take(params.num)
            .chunks(100)
            .map(|slice| Bytes::copy_from_slice(&slice))
            .map(Result::<_, Infallible>::Ok),
    );

    Response::new(body)
}

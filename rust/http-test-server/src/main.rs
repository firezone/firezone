use anyhow::{Context, Result};
use axum::{
    body::{Body, Bytes},
    extract::Query,
    http::Response,
    response::IntoResponse,
    routing::get,
    Router,
};
use futures::StreamExt;
use std::{convert::Infallible, net::Ipv4Addr};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let port = std::env::var("PORT")
        .context("Missing env var `PORT`")?
        .parse::<u16>()?;

    // build our application with a single route
    let app = Router::new().route("/bytes", get(byte_stream));

    // run our app with hyper, listening globally on port 3000
    let listener = tokio::net::TcpListener::bind((Ipv4Addr::UNSPECIFIED, port)).await?;
    axum::serve(listener, app).await?;

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

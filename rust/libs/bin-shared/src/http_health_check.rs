use axum::Router;
use axum::http::StatusCode;
use axum::routing::get;
use std::net::SocketAddr;

/// Runs an HTTP server that responds to `GET /healthz` with 200 OK or 400 BAD REQUEST, depending on the return value of `is_healthy`.
pub async fn serve(
    addr: impl Into<SocketAddr>,
    is_healthy: impl Fn() -> bool + Clone + Send + Sync + 'static,
) -> std::io::Result<()> {
    let addr = addr.into();

    let service = Router::new()
        .route(
            "/healthz",
            get(move || async move {
                if is_healthy() {
                    StatusCode::OK
                } else {
                    StatusCode::BAD_REQUEST
                }
            }),
        )
        .into_make_service();

    axum::serve(tokio::net::TcpListener::bind(addr).await?, service).await?;

    Ok(())
}

#[derive(clap::Args, Debug, Clone)]
pub struct HealthCheckArgs {
    /// The address of the local interface where we should serve our health-check endpoint.
    ///
    /// The actual health-check endpoint will be at `http://<health_check_addr>/healthz`.
    #[arg(long, env, hide = true, default_value = "0.0.0.0:8080")]
    pub health_check_addr: SocketAddr,
}

use axum::routing::get;
use axum::Router;
use std::net::SocketAddr;

/// Serves an HTTP serves that always responds to `GET /healthz` with 200 OK.
///
/// To signal an unhealthy state, simply stop the task.
pub async fn serve(addr: impl Into<SocketAddr>) -> std::io::Result<()> {
    let addr = addr.into();

    let service = Router::new()
        .route("/healthz", get(|| async { "" }))
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

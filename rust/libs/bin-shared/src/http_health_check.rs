use axum::Router;
use axum::http::StatusCode;
use axum::routing::get;
use std::net::SocketAddr;

/// Runs an HTTP server with health check endpoints:
/// - `GET /healthz` - Always returns 200 OK (liveness check)
/// - `GET /readyz` - Returns 200 OK if `is_ready` returns true, 503 SERVICE UNAVAILABLE otherwise (readiness check)
pub async fn serve(
    addr: impl Into<SocketAddr>,
    is_ready: impl Fn() -> bool + Clone + Send + Sync + 'static,
) -> std::io::Result<()> {
    let addr = addr.into();
    let service = router(is_ready).into_make_service();

    axum::serve(tokio::net::TcpListener::bind(addr).await?, service).await?;

    Ok(())
}

fn router(is_ready: impl Fn() -> bool + Clone + Send + Sync + 'static) -> Router {
    Router::new()
        .route("/healthz", get(|| async { StatusCode::OK }))
        .route(
            "/readyz",
            get(move || async move {
                if is_ready() {
                    StatusCode::OK
                } else {
                    StatusCode::SERVICE_UNAVAILABLE
                }
            }),
        )
}

#[derive(clap::Args, Debug, Clone)]
pub struct HealthCheckArgs {
    /// The address of the local interface where we should serve our health-check endpoints.
    ///
    /// - Liveness: `http://<health_check_addr>/healthz` (always returns 200)
    /// - Readiness: `http://<health_check_addr>/readyz` (returns 200 only when connected to portal)
    #[arg(long, env, hide = true, default_value = "0.0.0.0:8080")]
    pub health_check_addr: SocketAddr,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    async fn spawn_server(
        is_ready: impl Fn() -> bool + Clone + Send + Sync + 'static,
    ) -> SocketAddr {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        tokio::spawn(async move {
            axum::serve(listener, router(is_ready).into_make_service())
                .await
                .unwrap();
        });

        addr
    }

    #[tokio::test]
    async fn healthz_always_returns_200() {
        let addr = spawn_server(|| false).await;

        let response = reqwest::get(format!("http://{addr}/healthz"))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn readyz_returns_200_when_connected() {
        let addr = spawn_server(|| true).await;

        let response = reqwest::get(format!("http://{addr}/readyz")).await.unwrap();

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn readyz_returns_503_when_not_connected() {
        let addr = spawn_server(|| false).await;

        let response = reqwest::get(format!("http://{addr}/readyz")).await.unwrap();

        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    }

    #[tokio::test]
    async fn readyz_reflects_connection_state_changes() {
        let is_connected = Arc::new(AtomicBool::new(false));
        let is_connected_clone = is_connected.clone();

        let addr = spawn_server(move || is_connected_clone.load(Ordering::Relaxed)).await;

        // Initially not connected
        let response = reqwest::get(format!("http://{addr}/readyz")).await.unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);

        // Simulate connection
        is_connected.store(true, Ordering::Relaxed);

        let response = reqwest::get(format!("http://{addr}/readyz")).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        // Simulate disconnection
        is_connected.store(false, Ordering::Relaxed);

        let response = reqwest::get(format!("http://{addr}/readyz")).await.unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    }
}

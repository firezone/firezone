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
    use axum::body::Body;
    use http::Request;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use tower::ServiceExt;

    #[tokio::test]
    async fn healthz_always_returns_200() {
        let app = router(|| false);

        let response = app
            .oneshot(Request::get("/healthz").body(Body::empty()).unwrap())
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn readyz_returns_200_when_ready() {
        let app = router(|| true);

        let response = app
            .oneshot(Request::get("/readyz").body(Body::empty()).unwrap())
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn readyz_returns_503_when_not_ready() {
        let app = router(|| false);

        let response = app
            .oneshot(Request::get("/readyz").body(Body::empty()).unwrap())
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    }

    #[tokio::test]
    async fn readyz_reflects_readiness_state_changes() {
        let is_ready = Arc::new(AtomicBool::new(false));
        let is_ready_clone = is_ready.clone();
        let app = router(move || is_ready_clone.load(Ordering::Relaxed));

        // Initially not ready
        let response = app
            .clone()
            .oneshot(Request::get("/readyz").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);

        // Simulate becoming ready
        is_ready.store(true, Ordering::Relaxed);

        let response = app
            .clone()
            .oneshot(Request::get("/readyz").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        // Simulate becoming not ready
        is_ready.store(false, Ordering::Relaxed);

        let response = app
            .oneshot(Request::get("/readyz").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    }
}

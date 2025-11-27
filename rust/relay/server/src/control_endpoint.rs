use axum::Router;
use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::routing::post;
use logging::FilterReloadHandle;
use std::net::SocketAddr;
use std::sync::Arc;

/// Runs an HTTP server that responds to `POST /log_filter?directives=` and sets the given directives as the new log-filter.
pub async fn serve(
    addr: impl Into<SocketAddr>,
    filter_reload_handle: FilterReloadHandle,
) -> std::io::Result<()> {
    let addr = addr.into();

    let service = Router::new()
        .route("/log_filter", post(set_log_filter))
        .with_state(AppState {
            handle: Arc::new(filter_reload_handle),
        })
        .into_make_service();

    axum::serve(tokio::net::TcpListener::bind(addr).await?, service).await?;

    Ok(())
}

async fn set_log_filter(Query(params): Query<QueryParams>, state: State<AppState>) -> StatusCode {
    let directives = params.directives;

    match state.handle.reload(&directives) {
        Ok(()) => {
            tracing::info!(%directives, "Applied new logging directives");

            StatusCode::OK
        }
        Err(e) => {
            tracing::info!(%directives, "Failed to set log filter to new directives: {e}");

            StatusCode::BAD_REQUEST
        }
    }
}

#[derive(Clone)]
struct AppState {
    handle: Arc<FilterReloadHandle>,
}

#[derive(serde::Deserialize)]
struct QueryParams {
    directives: String,
}

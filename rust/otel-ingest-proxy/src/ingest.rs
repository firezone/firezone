use anyhow::{Context as _, Result};
use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::StatusCode;
use axum::http::header::{
    AUTHORIZATION, CONTENT_ENCODING, CONTENT_TYPE, HeaderMap, HeaderValue, RETRY_AFTER,
};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use http_body_util::{BodyExt as _, LengthLimitError, Limited};
use opentelemetry::KeyValue;
use opentelemetry::metrics::Histogram;
use opentelemetry_proto::tonic::collector::metrics::v1::{
    ExportMetricsServiceRequest, ExportMetricsServiceResponse,
};
use otel_azure_export::{ManagedIdentity, OtlpAuth};
use prost::Message as _;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tower::limit::ConcurrencyLimitLayer;
use url::Url;

use crate::auth::{Claims, Verifier};
use crate::rate_limit::RateLimiter;
use crate::sanitize::{count_data_points, sanitize};

const PROTOBUF: &str = "application/x-protobuf";
const BODY_READ_TIMEOUT: Duration = Duration::from_secs(10);
const UPSTREAM_TIMEOUT: Duration = Duration::from_secs(5);

pub struct Ingest {
    pub verifier: Verifier,
    pub device_limiter: RateLimiter,
    pub account_limiter: RateLimiter,
    pub max_body_bytes: usize,
    pub upstream: Upstream,
    pub metrics: Metrics,
}

pub fn router(ingest: Arc<Ingest>, max_concurrent_requests: usize) -> Router {
    Router::new()
        .route("/v1/metrics", post(export_metrics))
        .layer(ConcurrencyLimitLayer::new(max_concurrent_requests))
        .with_state(ingest)
}

async fn export_metrics(
    State(ingest): State<Arc<Ingest>>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    let start = Instant::now();

    let outcome = ingest.handle(&headers, body).await;

    ingest.metrics.duration.record(
        start.elapsed().as_secs_f64(),
        &[KeyValue::new("outcome", outcome.as_str())],
    );

    outcome.into_response()
}

impl Ingest {
    async fn handle(&self, headers: &HeaderMap, body: Body) -> Outcome {
        let Some(claims) = self.authenticate(headers) else {
            return Outcome::Unauthorized;
        };

        let now = Instant::now();
        if let Err(retry_after) = self.device_limiter.check(&claims.device_id, now) {
            return Outcome::RateLimitedDevice(retry_after);
        }
        if let Err(retry_after) = self.account_limiter.check(&claims.account_id, now) {
            return Outcome::RateLimitedAccount(retry_after);
        }

        if !is_uncompressed_protobuf(headers) {
            return Outcome::UnsupportedMediaType;
        }

        let body = match tokio::time::timeout(
            BODY_READ_TIMEOUT,
            Limited::new(body, self.max_body_bytes).collect(),
        )
        .await
        {
            Ok(Ok(body)) => body.to_bytes(),
            Ok(Err(e)) if e.is::<LengthLimitError>() => return Outcome::TooLarge,
            Ok(Err(e)) => {
                tracing::debug!("Failed to read request body: {e}");

                return Outcome::BadRequest;
            }
            Err(_) => {
                tracing::debug!("Timed out reading request body");

                return Outcome::BadRequest;
            }
        };

        let request = match ExportMetricsServiceRequest::decode(body) {
            Ok(request) => request,
            Err(e) => {
                tracing::debug!("Failed to decode metrics: {e}");

                return Outcome::BadRequest;
            }
        };
        self.metrics.data_points.record(
            count_data_points(&request),
            &[KeyValue::new("stage", "received")],
        );

        let Some(request) = sanitize(request, &claims) else {
            return Outcome::FilteredEmpty;
        };
        let data_points = count_data_points(&request);
        let encoded = request.encode_to_vec();
        drop(request);

        if let Err(e) = self.upstream.forward(encoded).await {
            tracing::debug!("Failed to forward metrics: {e:#}");

            return Outcome::UpstreamError;
        }
        self.metrics
            .data_points
            .record(data_points, &[KeyValue::new("stage", "forwarded")]);

        Outcome::Forwarded
    }

    fn authenticate(&self, headers: &HeaderMap) -> Option<Claims> {
        let (scheme, token) = headers.get(AUTHORIZATION)?.to_str().ok()?.split_once(' ')?;
        if !scheme.eq_ignore_ascii_case("bearer") {
            return None;
        }

        self.verifier
            .verify(token.trim())
            .inspect_err(|e| tracing::debug!("Rejected token: {e}"))
            .ok()
    }
}

fn is_uncompressed_protobuf(headers: &HeaderMap) -> bool {
    let is_protobuf = headers
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .is_some_and(|mime| mime.trim().eq_ignore_ascii_case(PROTOBUF));

    is_protobuf && !headers.contains_key(CONTENT_ENCODING)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Outcome {
    Forwarded,
    FilteredEmpty,
    Unauthorized,
    RateLimitedDevice(Duration),
    RateLimitedAccount(Duration),
    UnsupportedMediaType,
    TooLarge,
    BadRequest,
    UpstreamError,
}

impl Outcome {
    fn as_str(&self) -> &'static str {
        match self {
            Outcome::Forwarded => "forwarded",
            Outcome::FilteredEmpty => "filtered_empty",
            Outcome::Unauthorized => "unauthorized",
            Outcome::RateLimitedDevice(_) => "rate_limited_device",
            Outcome::RateLimitedAccount(_) => "rate_limited_account",
            Outcome::UnsupportedMediaType => "unsupported_media_type",
            Outcome::TooLarge => "too_large",
            Outcome::BadRequest => "bad_request",
            Outcome::UpstreamError => "upstream_error",
        }
    }
}

impl IntoResponse for Outcome {
    fn into_response(self) -> Response {
        match self {
            Outcome::Forwarded => success(),
            Outcome::FilteredEmpty => success(),
            Outcome::Unauthorized => StatusCode::UNAUTHORIZED.into_response(),
            Outcome::RateLimitedDevice(retry_after) => too_many_requests(retry_after),
            Outcome::RateLimitedAccount(retry_after) => too_many_requests(retry_after),
            Outcome::UnsupportedMediaType => StatusCode::UNSUPPORTED_MEDIA_TYPE.into_response(),
            Outcome::TooLarge => StatusCode::PAYLOAD_TOO_LARGE.into_response(),
            Outcome::BadRequest => StatusCode::BAD_REQUEST.into_response(),
            Outcome::UpstreamError => StatusCode::SERVICE_UNAVAILABLE.into_response(),
        }
    }
}

fn success() -> Response {
    (
        [(CONTENT_TYPE, PROTOBUF)],
        ExportMetricsServiceResponse::default().encode_to_vec(),
    )
        .into_response()
}

fn too_many_requests(retry_after: Duration) -> Response {
    let seconds = (retry_after.as_secs_f64().ceil() as u64).max(1);

    (
        StatusCode::TOO_MANY_REQUESTS,
        [(RETRY_AFTER, HeaderValue::from(seconds))],
    )
        .into_response()
}

pub struct Upstream {
    client: reqwest::Client,
    endpoint: Url,
    managed_identity: Option<ManagedIdentity>,
}

impl Upstream {
    pub fn new(endpoint: Url, auth: Option<OtlpAuth>) -> Result<Self> {
        let client = reqwest::Client::builder()
            .timeout(UPSTREAM_TIMEOUT)
            .retry(reqwest::retry::never())
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .build()
            .context("Failed to build upstream HTTP client")?;
        let managed_identity = match auth {
            Some(OtlpAuth::AzureManagedIdentity) => Some(ManagedIdentity::new()?),
            None => None,
        };

        Ok(Self {
            client,
            endpoint,
            managed_identity,
        })
    }

    async fn forward(&self, body: Vec<u8>) -> Result<()> {
        let mut request = self
            .client
            .post(self.endpoint.clone())
            .header(CONTENT_TYPE, PROTOBUF)
            .body(body);
        if let Some(managed_identity) = &self.managed_identity {
            request = request.header(AUTHORIZATION, managed_identity.authorization().await?);
        }

        let response = request.send().await.context("Failed to send request")?;
        let status = response.status();

        if status == reqwest::StatusCode::UNAUTHORIZED
            && let Some(managed_identity) = &self.managed_identity
        {
            managed_identity.invalidate().await;
        }

        let response = response.error_for_status()?;
        response
            .bytes()
            .await
            .context("Failed to read upstream response")?;

        Ok(())
    }
}

pub struct Metrics {
    duration: Histogram<f64>,
    data_points: Histogram<u64>,
}

impl Metrics {
    pub fn new() -> Self {
        let meter = opentelemetry::global::meter("otel-ingest-proxy");

        Self {
            duration: meter
                .f64_histogram("otel_ingest_proxy.request.duration")
                .with_description("Duration of OTLP metrics export requests.")
                .with_unit("s")
                .build(),
            data_points: meter
                .u64_histogram("otel_ingest_proxy.request.data_points")
                .with_description("Number of data points per OTLP metrics export request.")
                .with_unit("{data_point}")
                .build(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::tests::{PUBLIC_KEY, token};
    use crate::sanitize::tests::request;
    use axum::http::Request;
    use std::num::NonZeroU32;
    use tokio::sync::mpsc;
    use tower::ServiceExt as _;

    #[tokio::test]
    async fn forwards_sanitized_metrics() {
        let (upstream, mut forwarded) = mock_upstream(StatusCode::OK).await;
        let app = app(upstream);

        let response = app
            .oneshot(export(&token(&["connlib.*"]), &["connlib.a", "tunnel.b"]))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let forwarded =
            ExportMetricsServiceRequest::decode(forwarded.recv().await.unwrap()).unwrap();
        let metrics = &forwarded.resource_metrics[0].scope_metrics[0].metrics;
        assert_eq!(metrics.len(), 1);
        assert_eq!(metrics[0].name, "connlib.a");
    }

    #[tokio::test]
    async fn filtered_out_metrics_are_not_forwarded() {
        let (upstream, mut forwarded) = mock_upstream(StatusCode::OK).await;
        let app = app(upstream);

        let response = app
            .oneshot(export(&token(&["connlib.*"]), &["tunnel.b"]))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        assert!(forwarded.try_recv().is_err());
    }

    #[tokio::test]
    async fn rejects_invalid_token() {
        let (upstream, _forwarded) = mock_upstream(StatusCode::OK).await;
        let app = app(upstream);

        let response = app
            .oneshot(export("not.a.token", &["connlib.a"]))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn rate_limits_device() {
        let (upstream, _forwarded) = mock_upstream(StatusCode::OK).await;
        let app = app(upstream);
        let token = token(&["connlib.*"]);
        app.clone()
            .oneshot(export(&token, &["connlib.a"]))
            .await
            .unwrap();

        let response = app.oneshot(export(&token, &["connlib.a"])).await.unwrap();

        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert!(response.headers().contains_key(RETRY_AFTER));
    }

    #[tokio::test]
    async fn rejects_compressed_body() {
        let (upstream, _forwarded) = mock_upstream(StatusCode::OK).await;
        let app = app(upstream);
        let mut request = export(&token(&["*"]), &["connlib.a"]);
        request
            .headers_mut()
            .insert(CONTENT_ENCODING, HeaderValue::from_static("gzip"));

        let response = app.oneshot(request).await.unwrap();

        assert_eq!(response.status(), StatusCode::UNSUPPORTED_MEDIA_TYPE);
    }

    #[tokio::test]
    async fn rejects_too_large_body() {
        let (upstream, _forwarded) = mock_upstream(StatusCode::OK).await;
        let app = app(upstream);
        let mut request = export(&token(&["*"]), &[]);
        *request.body_mut() = Body::from(vec![0; 1025]);

        let response = app.oneshot(request).await.unwrap();

        assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
    }

    #[tokio::test]
    async fn rejects_undecodable_body() {
        let (upstream, _forwarded) = mock_upstream(StatusCode::OK).await;
        let app = app(upstream);
        let mut request = export(&token(&["*"]), &[]);
        *request.body_mut() = Body::from(vec![0xff; 16]);

        let response = app.oneshot(request).await.unwrap();

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn reports_upstream_failure() {
        let (upstream, _forwarded) = mock_upstream(StatusCode::INTERNAL_SERVER_ERROR).await;
        let app = app(upstream);

        let response = app
            .oneshot(export(&token(&["*"]), &["connlib.a"]))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    }

    fn app(upstream: Url) -> Router {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let ingest = Ingest {
            verifier: Verifier::from_ed_pem(PUBLIC_KEY).unwrap(),
            device_limiter: RateLimiter::new(
                NonZeroU32::new(1).unwrap(),
                NonZeroU32::new(1).unwrap(),
                10,
            ),
            account_limiter: RateLimiter::new(
                NonZeroU32::new(60).unwrap(),
                NonZeroU32::new(10).unwrap(),
                10,
            ),
            max_body_bytes: 1024,
            upstream: Upstream::new(upstream, None).unwrap(),
            metrics: Metrics::new(),
        };

        router(Arc::new(ingest), 1)
    }

    fn export(token: &str, metrics: &[&str]) -> Request<Body> {
        Request::post("/v1/metrics")
            .header(AUTHORIZATION, format!("Bearer {token}"))
            .header(CONTENT_TYPE, PROTOBUF)
            .body(Body::from(request(&[metrics]).encode_to_vec()))
            .unwrap()
    }

    async fn mock_upstream(
        status: StatusCode,
    ) -> (Url, mpsc::UnboundedReceiver<axum::body::Bytes>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let app = Router::new().route(
            "/v1/metrics",
            post(move |body: axum::body::Bytes| {
                let tx = tx.clone();

                async move {
                    tx.send(body).unwrap();

                    status
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = Url::parse(&format!(
            "http://{}/v1/metrics",
            listener.local_addr().unwrap()
        ))
        .unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

        (url, rx)
    }
}

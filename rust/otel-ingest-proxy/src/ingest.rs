use anyhow::Result;
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
use prost::Message as _;
use std::num::NonZeroU32;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tower::limit::ConcurrencyLimitLayer;
use url::Url;

use crate::auth::{Claims, Verifier};
use crate::rate_limit::RateLimiter;
use crate::sanitize::{count_data_points, sanitize};

const PROTOBUF: &str = "application/x-protobuf";
const BODY_READ_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_BODY_BYTES: usize = 64 * 1024;
const MAX_CONCURRENT_REQUESTS: usize = 256;

const DEVICE_REQUESTS_PER_MINUTE: NonZeroU32 = NonZeroU32::new(12).expect("12 > 0");
const DEVICE_BURST: NonZeroU32 = NonZeroU32::new(6).expect("6 > 0");
const MAX_RATE_LIMITED_DEVICES: usize = 100_000;
const ACCOUNT_REQUESTS_PER_MINUTE: NonZeroU32 = NonZeroU32::new(30_000).expect("30000 > 0");
const ACCOUNT_BURST: NonZeroU32 = NonZeroU32::new(3_000).expect("3000 > 0");
const MAX_RATE_LIMITED_ACCOUNTS: usize = 10_000;

pub struct Ingest {
    verifier: Verifier,
    device_limiter: RateLimiter,
    account_limiter: RateLimiter,
    upstream: otel_azure_export::Client,
    metrics: Metrics,
}

pub fn router(ingest: Arc<Ingest>) -> Router {
    Router::new()
        .route("/v1/metrics", post(export_metrics))
        .layer(ConcurrencyLimitLayer::new(MAX_CONCURRENT_REQUESTS))
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
    /// Creates an [`Ingest`] that forwards the metrics a device's token allows to `endpoint`.
    pub fn new(verifier: Verifier, endpoint: &Url) -> Result<Self> {
        Ok(Self {
            verifier,
            device_limiter: RateLimiter::new(
                DEVICE_REQUESTS_PER_MINUTE,
                DEVICE_BURST,
                MAX_RATE_LIMITED_DEVICES,
            ),
            account_limiter: RateLimiter::new(
                ACCOUNT_REQUESTS_PER_MINUTE,
                ACCOUNT_BURST,
                MAX_RATE_LIMITED_ACCOUNTS,
            ),
            upstream: otel_azure_export::Client::new(endpoint)?,
            metrics: Metrics::new(),
        })
    }

    pub fn evict_idle_rate_limits(&self, now: Instant) {
        self.device_limiter.evict_idle(now);
        self.account_limiter.evict_idle(now);
    }

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
            Limited::new(body, MAX_BODY_BYTES).collect(),
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

        if let Err(e) = self.upstream.export(request).await {
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

struct Metrics {
    duration: Histogram<f64>,
    data_points: Histogram<u64>,
}

impl Metrics {
    fn new() -> Self {
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

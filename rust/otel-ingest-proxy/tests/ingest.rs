#![allow(clippy::unwrap_used)]

mod common;

use axum::Router;
use axum::body::Body;
use axum::http::header::{AUTHORIZATION, CONTENT_ENCODING, CONTENT_TYPE, RETRY_AFTER};
use axum::http::{HeaderValue, Request, StatusCode};
use common::{EDDSA_HEADER, PUBLIC_KEY, claims, sign};
use firezone_otel_ingest_proxy::{Ingest, Verifier, router};
use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use opentelemetry_proto::tonic::metrics::v1::{Metric, ResourceMetrics, ScopeMetrics};
use prost::Message as _;
use std::sync::Arc;
use tower::ServiceExt as _;
use url::Url;

#[tokio::test]
async fn accepts_but_drops_metrics_the_token_does_not_allow() {
    let app = app();

    let response = app
        .oneshot(export(&token(&["connlib.*"]), &["tunnel.b"]))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn rejects_invalid_token() {
    let app = app();

    let response = app
        .oneshot(export("not.a.token", &["connlib.a"]))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn rate_limits_device_after_burst() {
    let app = app();
    let token = token(&["connlib.*"]);
    for _ in 0..6 {
        let response = app
            .clone()
            .oneshot(export(&token, &["tunnel.b"]))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }

    let response = app.oneshot(export(&token, &["tunnel.b"])).await.unwrap();

    assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
    assert!(response.headers().contains_key(RETRY_AFTER));
}

#[tokio::test]
async fn rejects_compressed_body() {
    let app = app();
    let mut request = export(&token(&["*"]), &["connlib.a"]);
    request
        .headers_mut()
        .insert(CONTENT_ENCODING, HeaderValue::from_static("gzip"));

    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::UNSUPPORTED_MEDIA_TYPE);
}

#[tokio::test]
async fn rejects_too_large_body() {
    let app = app();
    let mut request = export(&token(&["*"]), &[]);
    *request.body_mut() = Body::from(vec![0; 64 * 1024 + 1]);

    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
}

#[tokio::test]
async fn rejects_undecodable_body() {
    let app = app();
    let mut request = export(&token(&["*"]), &[]);
    *request.body_mut() = Body::from(vec![0xff; 16]);

    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

fn app() -> Router {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let ingest = Ingest::new(
        Verifier::from_ed_pem(PUBLIC_KEY).unwrap(),
        &Url::parse("https://127.0.0.1:1/v1/metrics").unwrap(),
    )
    .unwrap();

    router(Arc::new(ingest))
}

fn token(metrics: &[&str]) -> String {
    let mut claims = claims();
    claims["metrics"] = serde_json::json!(metrics);

    sign(EDDSA_HEADER, &claims)
}

fn export(token: &str, metrics: &[&str]) -> Request<Body> {
    let request = ExportMetricsServiceRequest {
        resource_metrics: vec![ResourceMetrics {
            scope_metrics: vec![ScopeMetrics {
                metrics: metrics
                    .iter()
                    .map(|name| Metric {
                        name: name.to_string(),
                        ..Default::default()
                    })
                    .collect(),
                ..Default::default()
            }],
            ..Default::default()
        }],
    };

    Request::post("/v1/metrics")
        .header(AUTHORIZATION, format!("Bearer {token}"))
        .header(CONTENT_TYPE, "application/x-protobuf")
        .body(Body::from(request.encode_to_vec()))
        .unwrap()
}

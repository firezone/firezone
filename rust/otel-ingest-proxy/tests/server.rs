#![allow(clippy::unwrap_used)]

mod common;

use axum::http::StatusCode;
use axum::http::header::CONTENT_TYPE;
use common::{EDDSA_HEADER, PUBLIC_KEY, claims, sign};
use firezone_otel_ingest_proxy::{CertResolver, Ingest, Verifier, router, serve};
use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use opentelemetry_proto::tonic::metrics::v1::{Metric, ResourceMetrics, ScopeMetrics};
use prost::Message as _;
use reqwest::Certificate;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::Path;
use std::sync::Arc;
use tokio::net::TcpListener;
use url::Url;

#[tokio::test]
async fn accepts_but_drops_metrics_the_token_does_not_allow() {
    let dir = tempfile::tempdir().unwrap();
    let cert = write_certificate(dir.path());
    let (addr, _) = start(dir.path()).await;

    let response = client(addr, &cert)
        .post("https://localhost/v1/metrics")
        .bearer_auth(sign(EDDSA_HEADER, &claims()))
        .header(CONTENT_TYPE, "application/x-protobuf")
        .body(export("tunnel.b"))
        .send()
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn serves_plaintext_without_tls() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let ingest = Ingest::new(
        Verifier::from_ed_pem(PUBLIC_KEY).unwrap(),
        &Url::parse("https://127.0.0.1:1/v1/metrics").unwrap(),
    )
    .unwrap();
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(serve(listener, None, router(Arc::new(ingest))));

    let response = reqwest::Client::new()
        .post(format!("http://{addr}/v1/metrics"))
        .bearer_auth(sign(EDDSA_HEADER, &claims()))
        .header(CONTENT_TYPE, "application/x-protobuf")
        .body(export("tunnel.b"))
        .send()
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn serves_reloaded_certificate() {
    let dir = tempfile::tempdir().unwrap();
    let old = write_certificate(dir.path());
    let (addr, resolver) = start(dir.path()).await;

    let new = write_certificate(dir.path());
    resolver.reload().unwrap();

    let old_result = client(addr, &old)
        .get("https://localhost/v1/metrics")
        .send()
        .await;
    let new_result = client(addr, &new)
        .get("https://localhost/v1/metrics")
        .send()
        .await;

    assert!(old_result.is_err());
    assert!(new_result.is_ok());
}

async fn start(dir: &Path) -> (SocketAddr, Arc<CertResolver>) {
    let _ = rustls::crypto::ring::default_provider().install_default();

    let resolver = CertResolver::load(dir.join("cert.pem"), dir.join("key.pem")).unwrap();
    let ingest = Ingest::new(
        Verifier::from_ed_pem(PUBLIC_KEY).unwrap(),
        &Url::parse("https://127.0.0.1:1/v1/metrics").unwrap(),
    )
    .unwrap();
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let addr = listener.local_addr().unwrap();

    tokio::spawn(serve(
        listener,
        Some(resolver.acceptor()),
        router(Arc::new(ingest)),
    ));

    (addr, resolver)
}

fn write_certificate(dir: &Path) -> Certificate {
    let certified = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()]).unwrap();
    let cert = certified.cert.pem();
    std::fs::write(dir.join("cert.pem"), &cert).unwrap();
    std::fs::write(dir.join("key.pem"), certified.signing_key.serialize_pem()).unwrap();

    Certificate::from_pem(cert.as_bytes()).unwrap()
}

fn client(addr: SocketAddr, cert: &Certificate) -> reqwest::Client {
    reqwest::Client::builder()
        .tls_certs_only([cert.clone()])
        .resolve("localhost", addr)
        .build()
        .unwrap()
}

fn export(metric: &str) -> Vec<u8> {
    ExportMetricsServiceRequest {
        resource_metrics: vec![ResourceMetrics {
            scope_metrics: vec![ScopeMetrics {
                metrics: vec![Metric {
                    name: metric.to_owned(),
                    ..Default::default()
                }],
                ..Default::default()
            }],
            ..Default::default()
        }],
    }
    .encode_to_vec()
}

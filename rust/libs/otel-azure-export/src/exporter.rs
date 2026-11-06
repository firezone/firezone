use anyhow::{Context as _, Result, bail};
use opentelemetry_http::{Bytes, HttpClient, HttpError, Request, Response};
use opentelemetry_otlp::{Protocol, WithExportConfig as _, WithHttpConfig as _};
use opentelemetry_sdk::metrics::{
    Aggregation, Instrument, InstrumentKind, MeterProviderBuilder, Stream, Temporality,
};
use reqwest::header::AUTHORIZATION;
use std::fmt;
use std::sync::Mutex;
use std::time::Duration;
use url::Url;

use crate::managed_identity::{self, Token};

#[derive(clap::ValueEnum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum OtlpAuth {
    AzureManagedIdentity,
}

/// Adds a periodic OTLP/HTTP exporter to `endpoint` that aggregates all histograms exponentially.
///
/// The exporter uses a blocking HTTP client, which starts its own runtime: call it outside of an async context.
pub fn with_exporter(
    builder: MeterProviderBuilder,
    endpoint: &Url,
    auth: Option<OtlpAuth>,
) -> Result<MeterProviderBuilder> {
    check_endpoint(endpoint)?;

    let client = ExportHttpClient::new(endpoint, auth)?;
    let exporter = opentelemetry_otlp::MetricExporter::builder()
        .with_http()
        .with_endpoint(endpoint.as_str())
        .with_protocol(Protocol::HttpBinary)
        .with_http_client(client)
        .with_temporality(Temporality::Delta)
        .build()
        .context("Failed to build OTLP metrics exporter")?;

    let builder = builder
        .with_periodic_exporter(exporter)
        .with_view(exponential_histograms);

    tracing::trace!("Successfully initialized OTLP metrics exporter");

    Ok(builder)
}

/// Ensures that `endpoint` is an HTTPS URL without credentials or a fragment.
pub fn check_endpoint(endpoint: &Url) -> Result<()> {
    if endpoint.scheme() != "https"
        || !endpoint.username().is_empty()
        || endpoint.password().is_some()
        || endpoint.fragment().is_some()
    {
        bail!("OTLP metrics endpoint must be an HTTPS URL without credentials or a fragment");
    }

    Ok(())
}

fn exponential_histograms(instrument: &Instrument) -> Option<Stream> {
    if instrument.kind() != InstrumentKind::Histogram {
        return None;
    }

    Stream::builder()
        .with_aggregation(Aggregation::Base2ExponentialHistogram {
            max_size: 160,
            max_scale: 20,
            record_min_max: true,
        })
        .build()
        .ok()
}

struct ExportHttpClient {
    endpoint: Url,
    client: reqwest::blocking::Client,
    auth: Option<OtlpAuth>,
    token: Mutex<Option<Token>>,
}

impl fmt::Debug for ExportHttpClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ExportHttpClient")
            .field("endpoint", &self.endpoint)
            .field("auth", &self.auth)
            .finish_non_exhaustive()
    }
}

#[async_trait::async_trait]
impl HttpClient for ExportHttpClient {
    async fn send_bytes(&self, mut request: Request<Bytes>) -> Result<Response<Bytes>, HttpError> {
        if request.uri() != self.endpoint.as_str() {
            return Err("OTLP metrics export destination changed".into());
        }

        match self.auth {
            Some(OtlpAuth::AzureManagedIdentity) => {
                let mut token = self.token.lock().map_err(|_| "Azure token lock poisoned")?;
                let authorization =
                    managed_identity::blocking_authorization(&self.client, &mut token)?;
                request.headers_mut().insert(AUTHORIZATION, authorization);
            }
            None => {}
        }

        let response = self.client.send_bytes(request).await?;

        if self.auth.is_some() && response.status() == reqwest::StatusCode::UNAUTHORIZED {
            let mut token = self.token.lock().map_err(|_| "Azure token lock poisoned")?;
            *token = None;
        }

        Ok(response)
    }
}

impl ExportHttpClient {
    fn new(endpoint: &Url, auth: Option<OtlpAuth>) -> Result<Self> {
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(5))
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .context("Failed to build OTLP metrics HTTP client")?;

        Ok(Self {
            endpoint: endpoint.clone(),
            client,
            auth,
            token: Mutex::new(None),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read as _, Write as _};
    use std::net::TcpListener;

    #[test]
    fn without_auth_forwards_request_headers_and_fetches_no_token() {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = Url::parse(&format!(
            "http://{}/v1/metrics",
            listener.local_addr().unwrap()
        ))
        .unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let head = read_request_head(&mut stream);
            stream
                .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
                .unwrap();

            head
        });
        let client = ExportHttpClient::new(&endpoint, None).unwrap();
        let request = Request::post(endpoint.as_str())
            .header("x-api-key", "secret")
            .body(Bytes::new())
            .unwrap();

        let response = futures::executor::block_on(client.send_bytes(request)).unwrap();

        let head = server.join().unwrap().to_ascii_lowercase();
        assert_eq!(response.status(), 200);
        assert!(head.contains("x-api-key: secret\r\n"));
        assert!(!head.contains("authorization:"));
    }

    fn read_request_head(stream: &mut std::net::TcpStream) -> String {
        let mut head = Vec::new();
        let mut byte = [0];

        while !head.ends_with(b"\r\n\r\n") {
            stream.read_exact(&mut byte).unwrap();
            head.push(byte[0]);
        }

        String::from_utf8(head).unwrap()
    }
}

//! Exports OpenTelemetry metrics over OTLP/HTTP, authenticated with the host's Azure managed identity.

mod client;

use anyhow::{Context as _, Result, bail};
use opentelemetry_http::{Bytes, HttpClient, HttpError, Request, Response};
use opentelemetry_otlp::{Protocol, WithExportConfig as _, WithHttpConfig as _};
use opentelemetry_sdk::metrics::{
    Aggregation, Instrument, InstrumentKind, MeterProviderBuilder, Stream, Temporality,
};
use reqwest::header::{AUTHORIZATION, HeaderValue};
use serde::Deserialize;
use std::fmt;
use std::io::Read as _;
use std::sync::Mutex;
use std::time::{Duration, SystemTime};
use url::Url;

pub use client::Client;

const TOKEN_URL: &str = "http://169.254.169.254/metadata/identity/oauth2/token";
const TOKEN_QUERY: [(&str, &str); 2] = [
    ("api-version", "2018-02-01"),
    ("resource", "https://monitor.azure.com/"),
];
const MAX_TOKEN_RESPONSE_BYTES: usize = 64 * 1024;

/// Debug builds also accept plaintext HTTP, e.g. for a local collector, and send it no token.
#[cfg(debug_assertions)]
const ENDPOINT_SCHEMES: &[&str] = &["https", "http"];
#[cfg(not(debug_assertions))]
const ENDPOINT_SCHEMES: &[&str] = &["https"];

pub fn with_exporter(
    builder: MeterProviderBuilder,
    endpoint: &Url,
) -> Result<MeterProviderBuilder> {
    check_endpoint(endpoint)?;

    let client = ExportHttpClient::new(endpoint)?;
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

fn check_endpoint(endpoint: &Url) -> Result<()> {
    if !ENDPOINT_SCHEMES.contains(&endpoint.scheme())
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
    token: Mutex<Option<Token>>,
}

impl fmt::Debug for ExportHttpClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ExportHttpClient")
            .field("endpoint", &self.endpoint)
            .finish_non_exhaustive()
    }
}

#[async_trait::async_trait]
impl HttpClient for ExportHttpClient {
    async fn send_bytes(&self, mut request: Request<Bytes>) -> Result<Response<Bytes>, HttpError> {
        if request.uri() != self.endpoint.as_str() {
            return Err("OTLP metrics export destination changed".into());
        }

        if self.endpoint.scheme() == "https" {
            let authorization = self.authorization()?;
            request.headers_mut().insert(AUTHORIZATION, authorization);
        }

        let response = self.client.send_bytes(request).await?;

        if response.status() == reqwest::StatusCode::UNAUTHORIZED {
            let mut token = self.token.lock().map_err(|_| "Azure token lock poisoned")?;
            *token = None;
        }

        Ok(response)
    }
}

impl ExportHttpClient {
    fn new(endpoint: &Url) -> Result<Self> {
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(5))
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .context("Failed to build OTLP metrics HTTP client")?;

        Ok(Self {
            endpoint: endpoint.clone(),
            client,
            token: Mutex::new(None),
        })
    }

    fn authorization(&self) -> Result<HeaderValue> {
        let mut token = self
            .token
            .lock()
            .map_err(|_| anyhow::anyhow!("Azure token lock poisoned"))?;

        if let Some(authorization) = token.as_ref().and_then(Token::fresh_authorization) {
            return Ok(authorization);
        }

        let response = self
            .client
            .get(TOKEN_URL)
            .query(&TOKEN_QUERY)
            .header("Metadata", "true")
            .send()
            .context("Failed to request Azure managed identity token")?
            .error_for_status()
            .context("Azure managed identity token request failed")?;
        let response = serde_json::from_reader::<_, TokenResponse>(
            response.take(MAX_TOKEN_RESPONSE_BYTES as u64),
        )
        .context("Invalid Azure managed identity token response")?;
        let new_token = Token::new(response)?;
        let authorization = new_token.authorization.clone();
        *token = Some(new_token);

        Ok(authorization)
    }
}

struct Token {
    authorization: HeaderValue,
    expires_at: SystemTime,
}

impl Token {
    fn new(response: TokenResponse) -> Result<Self> {
        if response.expires_on <= SystemTime::now() {
            bail!("Azure managed identity returned an expired token");
        }

        let mut authorization =
            HeaderValue::from_str(&format!("Bearer {}", response.access_token))?;
        authorization.set_sensitive(true);

        Ok(Self {
            authorization,
            expires_at: response.expires_on,
        })
    }

    fn fresh_authorization(&self) -> Option<HeaderValue> {
        (self.expires_at > SystemTime::now() + Duration::from_secs(60))
            .then(|| self.authorization.clone())
    }
}

#[serde_with::serde_as]
#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    #[serde_as(as = "serde_with::TimestampSeconds<String>")]
    expires_on: SystemTime,
}

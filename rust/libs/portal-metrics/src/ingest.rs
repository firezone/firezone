//! The HTTP side of reporting: the connection to the portal's OTLP endpoint and
//! the requests made over it.

use std::sync::Arc;

use anyhow::{Context as _, Result};
use bytes::Bytes;
use http::header;
use http_client::HttpClient;
use secrecy::{ExposeSecret as _, SecretString};
use socket_factory::{SocketFactory, TcpSocket};
use url::Url;

const METRICS_PATH: &str = "/v1/metrics";
/// How much of a rejected report's body to log.
const MAX_LOGGED_BODY: usize = 512;

/// Builds the OTLP metrics endpoint from the portal's base API URL.
pub fn metrics_endpoint(base_url: &str) -> Result<Url> {
    let url = Url::parse(base_url)
        .and_then(|base| base.join(METRICS_PATH))
        .with_context(|| format!("Invalid metrics API URL `{base_url}`"))?;

    Ok(url)
}

/// POSTs one OTLP/HTTP JSON report, authorized by `token`.
pub async fn report(
    url: &Url,
    token: &SecretString,
    body: Bytes,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> Result<()> {
    let http = connect(url, socket_factory).await?;

    let request = http::Request::builder()
        .method(http::Method::POST)
        .uri(url.as_str())
        .header(
            header::AUTHORIZATION,
            format!("Bearer {}", token.expose_secret()),
        )
        .header(header::CONTENT_TYPE, "application/json")
        .body(body)
        .context("Failed to build metrics request")?;

    let response = http.send_request(request)?.await?;
    let status = response.status();

    anyhow::ensure!(
        status.is_success(),
        "Portal rejected metrics report with {status}: {}",
        truncated_body(&response)
    );

    Ok(())
}

/// Opens a tunnel-bypassing HTTP client to the metrics host, re-resolved on every
/// connect so address changes are picked up.
///
/// Resolution goes through [`tunnel_bypass_resolver`]: while a session owns
/// the system resolver, `getaddrinfo` would loop back through connlib.
async fn connect(
    url: &Url,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> Result<HttpClient> {
    let host = url.host_str().context("Metrics URL has no host")?.to_owned();

    let addresses = tunnel_bypass_resolver::resolve(&host).await?;

    let client = HttpClient::new(host, addresses, socket_factory)
        .await
        .context("Failed to connect to metrics host")?;

    Ok(client)
}

fn truncated_body(response: &http::Response<Bytes>) -> String {
    String::from_utf8_lossy(response.body())
        .chars()
        .take(MAX_LOGGED_BODY)
        .collect()
}

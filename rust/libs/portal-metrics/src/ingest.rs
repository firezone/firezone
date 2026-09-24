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

/// POSTs one OTLP/HTTP protobuf report, authorized by `token`.
pub async fn report(
    api_url: &Url,
    token: &SecretString,
    body: Bytes,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> Result<()> {
    let url = api_url
        .join(METRICS_PATH)
        .with_context(|| format!("Invalid metrics API URL `{api_url}`"))?;
    let http = connect(&url, socket_factory).await?;
    let request = request(&url, token, body)?;

    let response = http.send_request(request)?.await?;
    let status = response.status();

    anyhow::ensure!(
        status.is_success(),
        "Portal rejected metrics report with {status}: {}",
        truncated_body(&response)
    );

    Ok(())
}

fn request(url: &Url, token: &SecretString, body: Bytes) -> Result<http::Request<Bytes>> {
    http::Request::builder()
        .method(http::Method::POST)
        .uri(url.as_str())
        .header(
            header::AUTHORIZATION,
            format!("Bearer {}", token.expose_secret()),
        )
        .header(header::CONTENT_TYPE, "application/x-protobuf")
        .body(body)
        .context("Failed to build metrics request")
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
    let host = url
        .host_str()
        .context("Metrics URL has no host")?
        .to_owned();

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_are_sent_as_otlp_protobuf() {
        let url = "https://telemetry.firezone.dev/v1/metrics".parse().unwrap();

        let request = request(
            &url,
            &SecretString::from("token"),
            Bytes::from_static(b"body"),
        )
        .unwrap();

        assert_eq!(request.method(), http::Method::POST);
        assert_eq!(request.uri(), "https://telemetry.firezone.dev/v1/metrics");
        assert_eq!(
            request.headers()[header::CONTENT_TYPE],
            "application/x-protobuf"
        );
        assert_eq!(request.headers()[header::AUTHORIZATION], "Bearer token");
        assert_eq!(request.body().as_ref(), b"body");
    }
}

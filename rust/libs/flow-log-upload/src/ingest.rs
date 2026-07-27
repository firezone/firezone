//! The HTTP side of uploading: the connection to the portal's ingest API and the
//! requests made over it.

use std::{sync::Arc, time::Duration};

use anyhow::{Context as _, Result};
use bytes::Bytes;
use http::header;
use http_client::HttpClient;
use socket_factory::{SocketFactory, TcpSocket};
use url::Url;

/// Prevent a broken or malicious endpoint from trapping an upload in a redirect loop.
const MAX_REDIRECTS: usize = 5;
const INGEST_PATH: &str = "/ingestion/flow_logs";

/// An ingest connection and its current endpoint.
///
/// [`HttpClient`] is tied to one host, so following a cross-host redirect must
/// also replace the underlying connection.
pub struct IngestClient {
    http: HttpClient,
    url: Url,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    redirects: usize,
}

impl IngestClient {
    pub async fn connect(
        url: Url,
        socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    ) -> Result<Self> {
        let http = connect(&url, socket_factory.clone()).await?;

        Ok(Self {
            http,
            url,
            socket_factory,
            redirects: 0,
        })
    }

    pub fn is_closed(&self) -> bool {
        self.http.is_closed()
    }

    /// POSTs `body` to the current endpoint, authorized by `token`.
    pub async fn send(&self, token: &str, body: Bytes) -> Result<http::Response<Bytes>> {
        let request = http::Request::builder()
            .method(http::Method::POST)
            .uri(self.url.as_str())
            .header(header::AUTHORIZATION, format!("Bearer {token}"))
            .header(header::CONTENT_TYPE, "application/json")
            .body(body)
            .context("Failed to build flow-log request")?;
        let response = self.http.send_request(request)?.await?;

        Ok(response)
    }

    /// Points the client at the redirect's `Location`, reconnecting when it moves
    /// to another host.
    ///
    /// Errs once [`MAX_REDIRECTS`] have been followed.
    pub async fn follow_redirect(&mut self, response: &http::Response<Bytes>) -> Result<()> {
        anyhow::ensure!(
            self.redirects < MAX_REDIRECTS,
            "Flow-log upload exceeded {MAX_REDIRECTS} redirects"
        );

        let redirected = redirect_url(&self.url, response)?;

        if redirected.host_str() != self.url.host_str() {
            self.http = connect(&redirected, self.socket_factory.clone()).await?;
        }

        tracing::info!(from = %self.url, to = %redirected, "Following flow-log upload redirect");

        self.url = redirected;
        self.redirects += 1;

        Ok(())
    }
}

/// Builds the ingest endpoint from the portal's base API URL.
pub fn ingest_endpoint(base_url: &str) -> Result<Url> {
    Url::parse(base_url)
        .and_then(|base| base.join(INGEST_PATH))
        .with_context(|| format!("Invalid flow-log API URL `{base_url}`"))
}

pub fn retry_after(response: &http::Response<Bytes>) -> Option<Duration> {
    let seconds = response
        .headers()
        .get(header::RETRY_AFTER)?
        .to_str()
        .ok()?
        .parse::<u64>()
        .ok()?;

    Some(Duration::from_secs(seconds))
}

pub fn body_string(response: &http::Response<Bytes>) -> String {
    String::from_utf8_lossy(response.body()).into_owned()
}

/// Opens a tunnel-bypassing HTTP client to the ingest host, re-resolved on every
/// connect so address changes are picked up.
///
/// Resolution goes through [`tunnel_bypass_resolver`]: while a session owns
/// the system resolver, `getaddrinfo` would loop back through connlib.
async fn connect(
    url: &Url,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> Result<HttpClient> {
    let host = url.host_str().context("Ingest URL has no host")?.to_owned();

    let addresses = tunnel_bypass_resolver::resolve(&host).await?;

    HttpClient::new(host, addresses, socket_factory)
        .await
        .context("Failed to connect to ingest host")
}

/// Resolves a redirect's `Location` against the current endpoint.
///
/// Only an origin we would have dialled ourselves is accepted: uploads carry a
/// Bearer token, so a redirect must not downgrade the transport or hand the token
/// to an endpoint the [`HttpClient`] could not have reached.
fn redirect_url(current: &Url, response: &http::Response<Bytes>) -> Result<Url> {
    let location = response
        .headers()
        .get(header::LOCATION)
        .context("Flow-log upload redirect has no Location header")?
        .to_str()
        .context("Flow-log upload redirect has an invalid Location header")?;
    let mut redirected = current
        .join(location)
        .context("Invalid flow-log upload redirect URL")?;

    anyhow::ensure!(
        redirected.scheme() == "https",
        "Flow-log upload redirect must use HTTPS"
    );
    anyhow::ensure!(
        redirected.port_or_known_default() == Some(443),
        "Flow-log upload redirect must use port 443"
    );
    anyhow::ensure!(
        redirected.username().is_empty() && redirected.password().is_none(),
        "Flow-log upload redirect must not contain credentials"
    );

    redirected.set_fragment(None);

    Ok(redirected)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn current_url() -> Url {
        Url::parse("https://flow-api.firezone.dev/ingestion/flow_logs").unwrap()
    }

    fn response(headers: &[(header::HeaderName, &str)]) -> http::Response<Bytes> {
        headers
            .iter()
            .fold(http::Response::builder(), |builder, (name, value)| {
                builder.header(name, *value)
            })
            .body(Bytes::new())
            .unwrap()
    }

    fn redirect_to(location: &str) -> Result<Url> {
        redirect_url(&current_url(), &response(&[(header::LOCATION, location)]))
    }

    #[test]
    fn ingest_endpoint_appends_the_ingest_path() {
        assert_eq!(
            ingest_endpoint("https://flow-api.firezone.dev/")
                .unwrap()
                .as_str(),
            "https://flow-api.firezone.dev/ingestion/flow_logs"
        );
        assert!(ingest_endpoint("not a url").is_err());
    }

    #[test]
    fn redirect_url_resolves_absolute_and_relative_locations() {
        assert_eq!(
            redirect_to("https://rest-api.firezone.dev/ingestion/flow_logs")
                .unwrap()
                .as_str(),
            "https://rest-api.firezone.dev/ingestion/flow_logs"
        );
        assert_eq!(
            redirect_to("/v2/flow_logs").unwrap().as_str(),
            "https://flow-api.firezone.dev/v2/flow_logs"
        );
    }

    #[test]
    fn redirect_url_rejects_missing_or_unsafe_locations() {
        assert!(redirect_url(&current_url(), &response(&[])).is_err());
        assert!(redirect_to("http://rest-api.firezone.dev/ingestion/flow_logs").is_err());
        assert!(redirect_to("https://rest-api.firezone.dev:8443/ingestion/flow_logs").is_err());
        assert!(
            redirect_to("https://user:secret@rest-api.firezone.dev/ingestion/flow_logs").is_err()
        );
    }

    #[test]
    fn retry_after_parses_the_seconds_header() {
        assert_eq!(
            retry_after(&response(&[(header::RETRY_AFTER, "30")])),
            Some(Duration::from_secs(30))
        );
        assert_eq!(retry_after(&response(&[])), None);
        assert_eq!(
            retry_after(&response(&[(header::RETRY_AFTER, "soon")])),
            None
        );
    }
}

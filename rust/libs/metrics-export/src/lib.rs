//! Exports OpenTelemetry metrics to the portal's OTLP/HTTP endpoint.
//!
//! [`meter_provider`] wraps the provider a binary installs globally so that its
//! instruments also record into an SDK pipeline owned by this crate. An
//! [`Exporter`] collects from that pipeline on the portal's interval and POSTs
//! the result with the portal's token, on its own thread.

#![cfg_attr(test, allow(clippy::unwrap_used))]

mod pipeline;

use std::{
    io,
    pin::pin,
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result};
use bytes::Bytes;
use futures::future::{Either, select};
use http::{StatusCode, header};
use http_client::{HttpClient, TlsConfig};
use opentelemetry_sdk::Resource;
use secrecy::{ExposeSecret as _, SecretString};
use socket_factory::{SocketFactory, TcpSocket};
use tokio::sync::watch;
use url::{Origin, Url};

pub use pipeline::{TeeMeterProvider, meter_provider};

const EXPORT_PATH: &str = "v1/metrics";
const MIN_EXPORT_INTERVAL: Duration = Duration::from_secs(10);
const EXPORT_TIMEOUT: Duration = Duration::from_secs(10);

/// Handle to the thread exporting metrics to the portal.
///
/// Dropping it stops the thread.
pub struct Exporter {
    config: watch::Sender<Option<Config>>,
}

impl Exporter {
    /// Spawns the export thread, which stays idle until [`Exporter::configure`] provides a token.
    ///
    /// `resource` describes this device in every export.
    pub fn spawn(
        resource: Resource,
        socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    ) -> io::Result<Self> {
        let (config, rx) = watch::channel(None);

        std::thread::Builder::new()
            .name("fz-metrics".to_owned())
            .spawn(move || {
                let runtime = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(runtime) => runtime,
                    Err(e) => {
                        tracing::error!("Failed to build metrics export runtime: {e}");
                        return;
                    }
                };

                runtime.block_on(run(rx, resource, socket_factory));
                pipeline::set_recording(false);
            })?;

        Ok(Self { config })
    }

    /// Applies the portal's metrics config; a `None` token stops exporting.
    pub fn configure(&self, api_url: &str, export_interval_secs: u64, token: Option<SecretString>) {
        let config = match token
            .map(|token| Config::new(api_url, export_interval_secs, token))
            .transpose()
        {
            Ok(config) => config,
            Err(e) => {
                tracing::warn!("Invalid metrics config: {e:#}");

                None
            }
        };

        self.config.send_replace(config);
    }

    /// Stops exporting until the next [`Exporter::configure`] with a token.
    pub fn disable(&self) {
        self.config.send_replace(None);
    }
}

#[derive(Clone)]
struct Config {
    endpoint: Url,
    interval: Duration,
    token: SecretString,
}

impl Config {
    fn new(api_url: &str, export_interval_secs: u64, token: SecretString) -> Result<Self> {
        let endpoint = Url::parse(api_url)
            .and_then(|url| url.join(EXPORT_PATH))
            .with_context(|| format!("Invalid metrics API URL `{api_url}`"))?;
        anyhow::ensure!(
            endpoint.scheme() == "https",
            "Metrics API URL must use HTTPS"
        );

        Ok(Self {
            endpoint,
            interval: Duration::from_secs(export_interval_secs).max(MIN_EXPORT_INTERVAL),
            token,
        })
    }
}

async fn run(
    mut config: watch::Receiver<Option<Config>>,
    resource: Resource,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) {
    let mut connection = Connection {
        socket_factory,
        client: None,
    };
    let mut last_export = Instant::now();
    let mut retry_at = Instant::now();

    loop {
        let Some(current) = config.borrow_and_update().clone() else {
            pipeline::set_recording(false);
            pipeline::discard();

            if config.changed().await.is_err() {
                return;
            }

            last_export = Instant::now();
            continue;
        };

        pipeline::set_recording(true);

        let deadline = (last_export + current.interval).max(retry_at);

        match wait_until(deadline, &mut config).await {
            Wake::Deadline => {}
            Wake::ConfigChanged => continue,
            Wake::Closed => return,
        }

        last_export = Instant::now();

        let response = match export(&current, &resource, &mut connection).await {
            Ok(Some(response)) => response,
            Ok(None) => continue,
            Err(e) => {
                tracing::debug!("Failed to export metrics: {e:#}");
                continue;
            }
        };

        match Outcome::from_response(&response) {
            Outcome::Exported => {
                tracing::trace!("Exported metrics");
            }
            Outcome::TokenRejected => {
                tracing::debug!("Portal rejected metrics token; waiting for a new one");

                if config.changed().await.is_err() {
                    return;
                }
            }
            Outcome::RateLimited(retry_after) => {
                tracing::debug!(?retry_after, "Metrics export was rate limited");

                retry_at = Instant::now() + retry_after.unwrap_or(current.interval);
            }
            Outcome::Failed(status) => {
                tracing::debug!(%status, body = %String::from_utf8_lossy(response.body()), "Failed to export metrics");
            }
        }
    }
}

enum Wake {
    Deadline,
    ConfigChanged,
    Closed,
}

async fn wait_until(deadline: Instant, config: &mut watch::Receiver<Option<Config>>) -> Wake {
    let sleep = pin!(tokio::time::sleep_until(deadline.into()));
    let changed = pin!(config.changed());

    match select(sleep, changed).await {
        Either::Left(((), _)) => Wake::Deadline,
        Either::Right((Ok(()), _)) => Wake::ConfigChanged,
        Either::Right((Err(_), _)) => Wake::Closed,
    }
}

/// POSTs everything recorded since the last export.
///
/// Returns `None` if nothing was recorded.
async fn export(
    config: &Config,
    resource: &Resource,
    connection: &mut Connection,
) -> Result<Option<http::Response<Bytes>>> {
    let Some(body) = pipeline::collect(resource)? else {
        return Ok(None);
    };

    let request = http::Request::builder()
        .method(http::Method::POST)
        .uri(config.endpoint.as_str())
        .header(
            header::AUTHORIZATION,
            format!("Bearer {}", config.token.expose_secret()),
        )
        .header(header::CONTENT_TYPE, "application/x-protobuf")
        .body(body)
        .context("Failed to build metrics request")?;

    let response = tokio::time::timeout(EXPORT_TIMEOUT, connection.send(&config.endpoint, request))
        .await
        .context("Metrics export timed out")??;

    Ok(Some(response))
}

#[derive(Debug, PartialEq)]
enum Outcome {
    Exported,
    TokenRejected,
    RateLimited(Option<Duration>),
    Failed(StatusCode),
}

impl Outcome {
    fn from_response(response: &http::Response<Bytes>) -> Self {
        match response.status() {
            status if status.is_success() => Self::Exported,
            StatusCode::UNAUTHORIZED => Self::TokenRejected,
            StatusCode::TOO_MANY_REQUESTS => Self::RateLimited(retry_after(response)),
            status => Self::Failed(status),
        }
    }
}

fn retry_after(response: &http::Response<Bytes>) -> Option<Duration> {
    let seconds = response
        .headers()
        .get(header::RETRY_AFTER)?
        .to_str()
        .ok()?
        .parse::<u64>()
        .ok()?;

    Some(Duration::from_secs(seconds))
}

/// A tunnel-bypassing connection to the metrics endpoint, re-established on demand.
struct Connection {
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    client: Option<(Origin, HttpClient)>,
}

impl Connection {
    async fn send(
        &mut self,
        endpoint: &Url,
        request: http::Request<Bytes>,
    ) -> Result<http::Response<Bytes>> {
        let client = self.client(endpoint).await?;
        let response = client.send_request(request)?.await;

        if response.is_err() {
            self.client = None;
        }

        response
    }

    async fn client(&mut self, endpoint: &Url) -> Result<HttpClient> {
        let origin = endpoint.origin();

        if let Some((_, client)) = self
            .client
            .as_ref()
            .filter(|(o, client)| *o == origin && !client.is_closed())
        {
            return Ok(client.clone());
        }

        let host = endpoint
            .host_str()
            .context("Metrics endpoint has no host")?
            .to_owned();
        let port = endpoint
            .port_or_known_default()
            .context("Metrics endpoint has no port")?;
        let addresses = tunnel_bypass_resolver::resolve(&host).await?;

        let client = HttpClient::new(
            host,
            port,
            addresses,
            TlsConfig::webpki_roots(),
            self.socket_factory.clone(),
        )
        .await
        .context("Failed to connect to metrics endpoint")?;
        self.client = Some((origin, client.clone()));

        Ok(client)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_appends_the_export_path() {
        let config = Config::new("https://otlp.firezone.dev/", 60, token()).unwrap();

        assert_eq!(
            config.endpoint.as_str(),
            "https://otlp.firezone.dev/v1/metrics"
        );
        assert_eq!(config.interval, Duration::from_secs(60));
    }

    #[test]
    fn config_rejects_plain_http_and_clamps_the_interval() {
        assert!(Config::new("http://otlp.firezone.dev/", 60, token()).is_err());
        assert_eq!(
            Config::new("https://otlp.firezone.dev/", 0, token())
                .unwrap()
                .interval,
            MIN_EXPORT_INTERVAL
        );
    }

    #[test]
    fn outcome_reflects_the_portal_response() {
        assert_eq!(
            Outcome::from_response(&response(200, &[])),
            Outcome::Exported
        );
        assert_eq!(
            Outcome::from_response(&response(401, &[])),
            Outcome::TokenRejected
        );
        assert_eq!(
            Outcome::from_response(&response(429, &[(header::RETRY_AFTER, "30")])),
            Outcome::RateLimited(Some(Duration::from_secs(30)))
        );
        assert_eq!(
            Outcome::from_response(&response(413, &[])),
            Outcome::Failed(StatusCode::PAYLOAD_TOO_LARGE)
        );
    }

    fn token() -> SecretString {
        SecretString::from("token")
    }

    fn response(status: u16, headers: &[(header::HeaderName, &str)]) -> http::Response<Bytes> {
        headers
            .iter()
            .fold(
                http::Response::builder().status(status),
                |builder, (name, value)| builder.header(name, *value),
            )
            .body(Bytes::new())
            .unwrap()
    }
}

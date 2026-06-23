use std::{
    sync::{Arc, LazyLock},
    time::Duration,
};

use bytes::Bytes;
use http::{Method, Request, Response, StatusCode, header};
use sentry::{
    ClientOptions, Envelope, Transport,
    transports::{RateLimiter, TokioTransportThread},
};

use crate::ingest;

pub(crate) const INGEST_HOST: &str = "sentry.firezone.dev";

static CLIENT: LazyLock<ingest::Client> = LazyLock::new(|| ingest::Client::new(INGEST_HOST));

/// Seeds the Sentry ingest-host addresses via the system resolver.
pub(crate) fn init_addresses() {
    CLIENT.init_addresses();
}

/// Drops the current connection so the next request reconnects.
pub(crate) fn reset() {
    CLIENT.reset();
}

/// Creates [`SentryTransport`]s for the Sentry SDK.
#[derive(Clone)]
pub(crate) struct Factory;

impl sentry::TransportFactory for Factory {
    fn create_transport(&self, options: &ClientOptions) -> Arc<dyn Transport> {
        Arc::new(SentryTransport::new(options))
    }
}

/// A Sentry [`Transport`] that sends envelopes through our [`ingest::Client`].
///
/// Sending and rate-limiting are driven by sentry's own [`TokioTransportThread`],
/// so the queueing, back-pressure and rate-limit handling are identical to the
/// reqwest-based transport; only the HTTP send is swapped for our loop-free,
/// self-healing [`ingest::Client`].
struct SentryTransport {
    thread: TokioTransportThread,
}

impl SentryTransport {
    fn new(options: &ClientOptions) -> Self {
        let dsn = options
            .dsn
            .as_ref()
            .expect("Sentry DSN to be set when starting telemetry");
        let auth = dsn.to_auth(Some(&options.user_agent)).to_string();
        let url = dsn.envelope_api_url().to_string();

        let thread = TokioTransportThread::new(move |envelope, mut rate_limiter| {
            // The request is built outside the async block so that `url` and `auth`
            // can be borrowed from the reused closure.
            let request = build_request(&url, &auth, &envelope);

            async move {
                match request {
                    Ok(request) => match CLIENT.send_request(request).await {
                        Ok(response) => update_rate_limits(&mut rate_limiter, &response),
                        Err(e) => tracing::debug!("Failed to send envelope to Sentry: {e:#}"),
                    },
                    Err(e) => tracing::debug!("Failed to build Sentry request: {e:#}"),
                }

                rate_limiter
            }
        });

        Self { thread }
    }
}

impl Transport for SentryTransport {
    fn send_envelope(&self, envelope: Envelope) {
        self.thread.send(envelope);
    }

    fn flush(&self, timeout: Duration) -> bool {
        self.thread.flush(timeout)
    }

    fn shutdown(&self, timeout: Duration) -> bool {
        self.flush(timeout)
    }
}

fn build_request(url: &str, auth: &str, envelope: &Envelope) -> anyhow::Result<Request<Bytes>> {
    let mut body = Vec::new();
    envelope.to_writer(&mut body)?;

    let request = Request::builder()
        .method(Method::POST)
        .uri(url)
        .header("X-Sentry-Auth", auth)
        .body(Bytes::from(body))?;

    Ok(request)
}

fn update_rate_limits(rate_limiter: &mut RateLimiter, response: &Response<Bytes>) {
    let headers = response.headers();

    if let Some(value) = headers
        .get("x-sentry-rate-limits")
        .and_then(|value| value.to_str().ok())
    {
        rate_limiter.update_from_sentry_header(value);
    } else if let Some(value) = headers
        .get(header::RETRY_AFTER)
        .and_then(|value| value.to_str().ok())
    {
        rate_limiter.update_from_retry_after(value);
    } else if response.status() == StatusCode::TOO_MANY_REQUESTS {
        rate_limiter.update_from_429();
    }
}

use std::{
    net::IpAddr,
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context, ErrorExt as _, Result};
use bytes::{BufMut as _, Bytes, BytesMut};
use circuit_breaker::CircuitBreaker;
use http_client::HttpClient;
use sentry::Envelope;
use socket_factory::{SocketFactory, TcpSocket};

use crate::INGEST_HOST;

pub struct SentryHttpClient {
    cb: CircuitBreaker,
    maybe_client: Option<HttpClient>,
    options: sentry::ClientOptions,
    addresses: Vec<IpAddr>,
    sf: Arc<dyn SocketFactory<TcpSocket>>,
}

impl SentryHttpClient {
    pub fn new(
        options: &sentry::ClientOptions,
        addresses: Vec<IpAddr>,
        sf: Arc<dyn SocketFactory<TcpSocket>>,
    ) -> Self {
        Self {
            cb: CircuitBreaker::new("Sentry HTTP transport", 5, 2, Duration::from_secs(10)),
            maybe_client: None,
            options: options.clone(),
            addresses,
            sf,
        }
    }

    pub async fn send(&mut self, envelope: Envelope) -> Result<http::Response<Bytes>> {
        let dsn = self.options.dsn.as_ref().expect("DSN must be set");
        let user_agent = self.options.user_agent.clone();
        let url = dsn.envelope_api_url().to_string();
        let auth = dsn.to_auth(Some(&user_agent)).to_string();

        let client = match self.maybe_client.as_ref() {
            Some(c) => c,
            None => loop {
                match self.cb.request_token(Instant::now()) {
                    Ok(token) => {
                        let result = HttpClient::new(
                            INGEST_HOST.to_owned(),
                            self.addresses.clone(),
                            self.sf.clone(),
                        )
                        .await;

                        let client = token
                            .result(result, Instant::now())
                            .context("Failed to create Sentry transport HTTP client")?;

                        break self.maybe_client.get_or_insert(client);
                    }
                    Err(e) => tokio::time::sleep(e.retry_after).await,
                };
            },
        };

        let mut body = BytesMut::new().writer();
        envelope
            .to_writer(&mut body)
            .context("Failed to write envelope to buffer")?;

        let req = http::Request::builder()
            .uri(url.clone())
            .method(http::Method::POST)
            .header("X-Sentry-Auth", &auth)
            .body(body.into_inner().freeze())
            .context("Failed to create HTTP request from Sentry envelope")?;

        let token = loop {
            match self.cb.request_token(Instant::now()) {
                Ok(t) => break t,
                Err(e) => tokio::time::sleep(e.retry_after).await,
            }
        };

        let response = token
            .result(client.send_request(req), Instant::now())
            .inspect_err(|e| {
                if e.any_is::<http_client::Closed>() {
                    self.maybe_client = None;
                }
            })?
            .await?;

        Ok(response)
    }
}

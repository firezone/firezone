use anyhow::{Context as _, Result, bail};
use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use prost::Message as _;
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE, HeaderValue};
use std::time::Duration;
use url::Url;

use crate::{MAX_TOKEN_RESPONSE_BYTES, TOKEN_QUERY, TOKEN_URL, Token, TokenResponse};

/// Sends OTLP/HTTP metrics export requests to an endpoint.
pub struct Client {
    endpoint: Url,
    client: reqwest::Client,
    token: tokio::sync::Mutex<Option<Token>>,
}

impl Client {
    pub fn new(endpoint: &Url) -> Result<Self> {
        crate::check_endpoint(endpoint)?;

        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .retry(reqwest::retry::never())
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .context("Failed to build OTLP metrics HTTP client")?;

        Ok(Self {
            endpoint: endpoint.clone(),
            client,
            token: tokio::sync::Mutex::new(None),
        })
    }

    /// Sends `request` to the endpoint, authenticated with the host's Azure managed identity.
    pub async fn export(&self, request: ExportMetricsServiceRequest) -> Result<()> {
        let body = request.encode_to_vec();
        drop(request);

        let response = self
            .client
            .post(self.endpoint.clone())
            .header(CONTENT_TYPE, "application/x-protobuf")
            .header(AUTHORIZATION, self.authorization().await?)
            .body(body)
            .send()
            .await
            .context("Failed to send OTLP metrics")?;

        if response.status() == reqwest::StatusCode::UNAUTHORIZED {
            *self.token.lock().await = None;
        }

        response
            .error_for_status()?
            .bytes()
            .await
            .context("Failed to read OTLP metrics response")?;

        Ok(())
    }

    /// Holds the lock while fetching a new token so that concurrent exports share one request.
    async fn authorization(&self) -> Result<HeaderValue> {
        let mut token = self.token.lock().await;

        if let Some(authorization) = token.as_ref().and_then(Token::fresh_authorization) {
            return Ok(authorization);
        }

        let mut response = self
            .client
            .get(TOKEN_URL)
            .query(&TOKEN_QUERY)
            .header("Metadata", "true")
            .send()
            .await
            .context("Failed to request Azure managed identity token")?
            .error_for_status()
            .context("Azure managed identity token request failed")?;

        let mut body = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .context("Failed to read Azure managed identity token response")?
        {
            if body.len() + chunk.len() > MAX_TOKEN_RESPONSE_BYTES {
                bail!("Azure managed identity token response is too large");
            }

            body.extend_from_slice(&chunk);
        }

        let response = serde_json::from_slice::<TokenResponse>(&body)
            .context("Invalid Azure managed identity token response")?;
        let new_token = Token::new(response)?;
        let authorization = new_token.authorization.clone();
        *token = Some(new_token);

        Ok(authorization)
    }
}

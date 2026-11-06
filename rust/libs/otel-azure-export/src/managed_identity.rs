use anyhow::{Context as _, Result, bail};
use reqwest::header::HeaderValue;
use serde::Deserialize;
use std::io::Read as _;
use std::time::{Duration, SystemTime};

const TOKEN_URL: &str = "http://169.254.169.254/metadata/identity/oauth2/token";
const TOKEN_QUERY: [(&str, &str); 2] = [
    ("api-version", "2018-02-01"),
    ("resource", "https://monitor.azure.com/"),
];
const MAX_RESPONSE_BYTES: usize = 64 * 1024;
const REFRESH_BEFORE_EXPIRY: Duration = Duration::from_secs(60);

/// Hands out bearer tokens for Azure Monitor, obtained from the Azure instance metadata service.
///
/// A token is cached until a minute before it expires.
pub struct ManagedIdentity {
    client: reqwest::Client,
    token: tokio::sync::Mutex<Option<Token>>,
}

impl ManagedIdentity {
    pub fn new() -> Result<Self> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .context("Failed to build Azure managed identity HTTP client")?;

        Ok(Self {
            client,
            token: tokio::sync::Mutex::new(None),
        })
    }

    /// Returns the value for an `Authorization` header.
    pub async fn authorization(&self) -> Result<HeaderValue> {
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
            if body.len() + chunk.len() > MAX_RESPONSE_BYTES {
                bail!("Azure managed identity token response is too large");
            }

            body.extend_from_slice(&chunk);
        }

        let new_token = Token::parse(&body)?;
        let authorization = new_token.authorization.clone();
        *token = Some(new_token);

        Ok(authorization)
    }

    /// Discards the cached token, e.g. after it got rejected.
    pub async fn invalidate(&self) {
        *self.token.lock().await = None;
    }
}

pub(crate) fn blocking_authorization(
    client: &reqwest::blocking::Client,
    token: &mut Option<Token>,
) -> Result<HeaderValue> {
    if let Some(authorization) = token.as_ref().and_then(Token::fresh_authorization) {
        return Ok(authorization);
    }

    let response = client
        .get(TOKEN_URL)
        .query(&TOKEN_QUERY)
        .header("Metadata", "true")
        .send()
        .context("Failed to request Azure managed identity token")?
        .error_for_status()
        .context("Azure managed identity token request failed")?;

    let mut body = Vec::new();
    response
        .take(MAX_RESPONSE_BYTES as u64)
        .read_to_end(&mut body)
        .context("Failed to read Azure managed identity token response")?;

    let new_token = Token::parse(&body)?;
    let authorization = new_token.authorization.clone();
    *token = Some(new_token);

    Ok(authorization)
}

pub(crate) struct Token {
    authorization: HeaderValue,
    expires_at: SystemTime,
}

impl Token {
    fn parse(body: &[u8]) -> Result<Self> {
        let response = serde_json::from_slice::<TokenResponse>(body)
            .context("Invalid Azure managed identity token response")?;
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
        (self.expires_at > SystemTime::now() + REFRESH_BEFORE_EXPIRY)
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

use anyhow::{Context as _, Result, bail};
use reqwest::RequestBuilder;
use serde::de::DeserializeOwned;

pub async fn json<T>(request: RequestBuilder, action: &str) -> Result<T>
where
    T: DeserializeOwned,
{
    let response = request
        .send()
        .await
        .with_context(|| format!("Failed to {action}"))?;
    let status = response.status();
    let body = response
        .bytes()
        .await
        .with_context(|| format!("Failed to read response while trying to {action}"))?;

    if !status.is_success() {
        bail!("Failed to {action}: {status}: {}", error_body(&body));
    }

    let value = serde_json::from_slice(&body)
        .with_context(|| format!("Failed to decode response while trying to {action}"))?;

    Ok(value)
}

pub async fn empty(request: RequestBuilder, action: &str) -> Result<()> {
    let response = request
        .send()
        .await
        .with_context(|| format!("Failed to {action}"))?;
    let status = response.status();

    if status.is_success() {
        return Ok(());
    }

    let body = response
        .bytes()
        .await
        .with_context(|| format!("Failed to read response while trying to {action}"))?;
    bail!("Failed to {action}: {status}: {}", error_body(&body));
}

fn error_body(body: &[u8]) -> String {
    String::from_utf8_lossy(body).chars().take(2_000).collect()
}

use anyhow::{Context as _, Result, bail};
use serde::Serialize;

use crate::{Env, posthog::RUNTIME};

pub fn new_session(distinct_id: String, api_url: String) {
    RUNTIME.spawn(async move {
        if let Err(e) = capture(
            "new_session",
            distinct_id,
            api_url.clone(),
            NewSessionProperties { api_url },
        )
        .await
        {
            tracing::debug!("Failed to log `new_session` event: {e:#}");
        }
    });
}

/// Associate several properties with a particular "distinct_id" in PostHog.
pub fn identify(distinct_id: String, api_url: String, release: String) {
    RUNTIME.spawn(async move {
        if let Err(e) = capture(
            "$identify",
            distinct_id,
            api_url,
            IdentifyProperties {
                set: PersonProperties {
                    release,
                    os: std::env::consts::OS.to_owned(),
                },
            },
        )
        .await
        {
            tracing::debug!("Failed to log `$identify` event: {e:#}");
        }
    });
}

async fn capture<P>(
    event: impl Into<String>,
    distinct_id: String,
    api_url: String,
    properties: P,
) -> Result<()>
where
    P: Serialize,
{
    let event = event.into();

    let env = Env::from_api_url(&api_url);
    let Some(api_key) = crate::posthog::api_key_for_env(env) else {
        tracing::debug!(%event, %env, "Not sending event because we don't have an API key");

        return Ok(());
    };

    let response = reqwest::ClientBuilder::new()
        .connection_verbose(true)
        .build()?
        .post("https://us.i.posthog.com/i/v0/e/")
        .json(&CaptureRequest {
            api_key: api_key.to_string(),
            distinct_id,
            event,
            properties,
        })
        .send()
        .await
        .context("Failed to send POST request")?;

    let status = response.status();

    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();

        bail!("Failed to capture event; status={status}, body={body}")
    }

    Ok(())
}

#[derive(serde::Serialize)]
struct CaptureRequest<P> {
    event: String,
    distinct_id: String,
    api_key: String,
    properties: P,
}

#[derive(serde::Serialize)]
struct NewSessionProperties {
    api_url: String,
}

#[derive(serde::Serialize)]
struct IdentifyProperties {
    #[serde(rename = "$set")]
    set: PersonProperties,
}

#[derive(serde::Serialize)]
struct PersonProperties {
    release: String,
    #[serde(rename = "$os")]
    os: String,
}

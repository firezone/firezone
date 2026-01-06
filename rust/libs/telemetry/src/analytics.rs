use std::str::FromStr;

use anyhow::{Context as _, Result, bail};
use serde::Serialize;
use sha2::Digest as _;

use crate::{ApiUrl, Env, Telemetry, posthog};

/// Records a `new_session` event for a particular user and API url.
///
/// This purposely does not use the existing telemetry session because we also want to capture sessions from self-hosted users.
pub fn new_session(maybe_legacy_id: String, api_url: String) {
    let distinct_id = if uuid::Uuid::from_str(&maybe_legacy_id).is_ok() {
        hex::encode(sha2::Sha256::digest(&maybe_legacy_id))
    } else {
        maybe_legacy_id
    };

    posthog::RUNTIME.spawn(async move {
        if let Err(e) = capture(
            "new_session",
            distinct_id,
            ApiUrl::new(&api_url),
            NewSessionProperties {
                api_url: api_url.clone(),
            },
        )
        .await
        {
            tracing::debug!("Failed to log `new_session` event: {e:#}");
        }
    });
}

/// Associate several properties with the current telemetry user.
pub fn identify(release: String, account_slug: Option<String>) {
    let Some(env) = Telemetry::current_env() else {
        tracing::debug!("Cannot send $identify: Unknown env");
        return;
    };
    let Some(distinct_id) = Telemetry::current_user() else {
        tracing::debug!("Cannot send $identify: Unknown user");
        return;
    };

    posthog::RUNTIME.spawn({
        async move {
            if let Err(e) = capture(
                "$identify",
                distinct_id,
                env,
                IdentifyProperties {
                    set: PersonProperties {
                        release,
                        account_slug,
                        os: std::env::consts::OS.to_owned(),
                    },
                },
            )
            .await
            {
                tracing::debug!("Failed to log `$identify` event: {e:#}");
            }
        }
    });
}

pub fn feature_flag_called(name: impl Into<String>) {
    let Some(env) = Telemetry::current_env() else {
        tracing::debug!("Cannot send $feature_flag_called: Unknown env");
        return;
    };
    let Some(distinct_id) = Telemetry::current_user() else {
        tracing::debug!("Cannot send $feature_flag_called: Unknown user");
        return;
    };
    let feature_flag = name.into();

    posthog::RUNTIME.spawn({
        async move {
            if let Err(e) = capture(
                "$feature_flag_called",
                distinct_id,
                env,
                FeatureFlagCalledProperties {
                    feature_flag,
                    feature_flag_response: "true".to_owned(),
                },
            )
            .await
            {
                tracing::debug!("Failed to log `$feature_flag_called` event: {e:#}");
            }
        }
    });
}

async fn capture<P>(
    event: impl Into<String>,
    distinct_id: String,
    env: impl Into<Env>,
    properties: P,
) -> Result<()>
where
    P: Serialize,
{
    let event = event.into();
    let env = env.into();

    let Some(api_key) = crate::posthog::api_key_for_env(env) else {
        tracing::debug!(%event, %env, "Not sending event because we don't have an API key");

        return Ok(());
    };

    let response = posthog::CLIENT
        .as_ref()?
        .post(format!("https://{}/i/v0/e/", posthog::INGEST_HOST))
        .json(&CaptureRequest {
            api_key: api_key.to_string(),
            distinct_id,
            event: event.clone(),
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

    tracing::debug!(%event);

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
    #[serde(skip_serializing_if = "Option::is_none")]
    account_slug: Option<String>,
    #[serde(rename = "$os")]
    os: String,
}

#[derive(serde::Serialize)]
struct FeatureFlagCalledProperties {
    #[serde(rename = "$feature_flag")]
    feature_flag: String,
    #[serde(rename = "$feature_flag_response")]
    feature_flag_response: String,
}

use anyhow::{Context as _, Result, bail};
use serde::Serialize;

use crate::{ApiUrl, Env, current_env, current_user, ingest, posthog};

/// Records a `new_session` event for a particular user and API url.
///
/// This purposely does not use the existing telemetry session because we also want to capture sessions from self-hosted users.
pub fn new_session(maybe_legacy_id: String, api_url: String) {
    let distinct_id = crate::maybe_hash_device_id(maybe_legacy_id);

    ingest::RUNTIME.spawn(async move {
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
    let Some(env) = current_env() else {
        tracing::debug!("Cannot send $identify: Unknown env");
        return;
    };
    let Some(distinct_id) = current_user() else {
        tracing::debug!("Cannot send $identify: Unknown user");
        return;
    };

    ingest::RUNTIME.spawn({
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

    let response = posthog::post_json(
        "/i/v0/e/",
        &CaptureRequest {
            api_key: api_key.to_string(),
            distinct_id,
            event: event.clone(),
            properties,
        },
    )
    .await
    .context("Failed to send POST request")?;

    let status = response.status();

    if !status.is_success() {
        let body = String::from_utf8_lossy(response.body());

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

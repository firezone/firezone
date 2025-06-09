use std::{sync::LazyLock, time::Duration};

use anyhow::{Context as _, Result, bail};
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};

use crate::{
    Env,
    posthog::{POSTHOG_API_KEY_PROD, POSTHOG_API_KEY_STAGING, RUNTIME},
};

pub(crate) const RE_EVAL_DURATION: Duration = Duration::from_secs(5 * 60);

// Process-wide storage of enabled feature flags.
//
// Defaults to everything off.
static FEATURE_FLAGS: LazyLock<RwLock<FeatureFlags>> = LazyLock::new(RwLock::default);

pub fn icmp_unreachable_instead_of_nat64() -> bool {
    FEATURE_FLAGS.read().icmp_unreachable_instead_of_nat64
}

pub fn drop_llmnr_nxdomain_responses() -> bool {
    FEATURE_FLAGS.read().drop_llmnr_nxdomain_responses
}

pub(crate) fn reevaluate(user_id: String, env: &str) {
    let api_key = match env.parse() {
        Ok(Env::Production) => POSTHOG_API_KEY_PROD,
        Ok(Env::Staging) => POSTHOG_API_KEY_STAGING,
        Ok(Env::OnPrem | Env::DockerCompose) | Err(_) => return,
    };

    RUNTIME.spawn(async move {
        let flags = decide(user_id, api_key.to_owned())
            .await
            .inspect_err(|e| tracing::debug!("Failed to evaluate feature flags: {e:#}"))
            .unwrap_or_default();

        tracing::debug!(?flags, "Evaluated feature-flags");

        *FEATURE_FLAGS.write() = flags;

        sentry::Hub::main().configure_scope(|scope| {
            scope.set_context("flags", sentry_flag_context(flags));
        });
    });
}

pub(crate) async fn reeval_timer() {
    loop {
        tokio::time::sleep(RE_EVAL_DURATION).await;

        let Some(client) = sentry::Hub::main().client() else {
            continue;
        };

        let Some(env) = client.options().environment.as_ref() else {
            continue; // Nothing to do if we don't have an environment set.
        };

        let Some(user_id) =
            sentry::Hub::main().configure_scope(|scope| scope.user().and_then(|u| u.id.clone()))
        else {
            continue; // Nothing to do if we don't have a user-id set.
        };

        reevaluate(user_id, env);
    }
}

async fn decide(distinct_id: String, api_key: String) -> Result<FeatureFlags> {
    let response = reqwest::ClientBuilder::new()
        .connection_verbose(true)
        .build()?
        .post("https://us.i.posthog.com/decide?v=3")
        .json(&DecideRequest {
            api_key,
            distinct_id,
        })
        .send()
        .await
        .context("Failed to send POST request")?;

    let status = response.status();

    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();

        bail!("Failed to get feature flags; status={status}, body={body}")
    }

    let json = response
        .json::<DecideResponse>()
        .await
        .context("Failed to deserialize response")?;

    Ok(json.feature_flags)
}

#[derive(Debug, Serialize)]
struct DecideRequest {
    api_key: String,
    distinct_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DecideResponse {
    feature_flags: FeatureFlags,
}

#[derive(Debug, Deserialize, Default, Clone, Copy)]
#[serde(rename_all = "kebab-case")]
struct FeatureFlags {
    #[serde(default)]
    icmp_unreachable_instead_of_nat64: bool,
    #[serde(default)]
    drop_llmnr_nxdomain_responses: bool,
}

fn sentry_flag_context(flags: FeatureFlags) -> sentry::protocol::Context {
    #[derive(Debug, serde::Serialize)]
    #[serde(tag = "flag", rename_all = "snake_case")]
    enum SentryFlag {
        IcmpUnreachableInsteadOfNat64 { result: bool },
        DropLlmnrNxdomainResponses { result: bool },
    }

    // Exhaustive destruction so we don't forget to update this when we add a flag.
    let FeatureFlags {
        icmp_unreachable_instead_of_nat64,
        drop_llmnr_nxdomain_responses,
    } = flags;

    let value = serde_json::json!({
        "values": [
            SentryFlag::IcmpUnreachableInsteadOfNat64 {
                result: icmp_unreachable_instead_of_nat64,
            },
            SentryFlag::DropLlmnrNxdomainResponses { result: drop_llmnr_nxdomain_responses },
        ]
    });

    sentry::protocol::Context::Other(serde_json::from_value(value).expect("to and from json works"))
}

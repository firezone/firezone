use std::{
    str::FromStr as _,
    sync::{
        LazyLock,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use anyhow::{Context as _, Result, bail};
use serde::{Deserialize, Serialize};
use sha2::Digest as _;

use crate::{
    Env,
    posthog::{POSTHOG_API_KEY_PROD, POSTHOG_API_KEY_STAGING, RUNTIME},
};

pub(crate) const RE_EVAL_DURATION: Duration = Duration::from_secs(5 * 60);

// Process-wide storage of enabled feature flags.
//
// Defaults to everything off.
static FEATURE_FLAGS: LazyLock<FeatureFlags> = LazyLock::new(FeatureFlags::default);

pub fn icmp_unreachable_instead_of_nat64() -> bool {
    FEATURE_FLAGS.icmp_unreachable_instead_of_nat64()
}

pub fn drop_llmnr_nxdomain_responses() -> bool {
    FEATURE_FLAGS.drop_llmnr_nxdomain_responses()
}

pub fn stream_logs() -> bool {
    FEATURE_FLAGS.stream_logs()
}

pub fn map_enobufs_to_would_block() -> bool {
    FEATURE_FLAGS.map_enobufs_to_wouldblock()
}

pub fn export_metrics() -> bool {
    false // Placeholder until we actually deploy an OTEL collector.
}

pub(crate) async fn evaluate_now(user_id: String, env: Env) {
    if user_id.is_empty() {
        return;
    }

    let api_key = match env {
        Env::Production => POSTHOG_API_KEY_PROD,
        Env::Staging => POSTHOG_API_KEY_STAGING,
        Env::OnPrem | Env::DockerCompose | Env::Localhost => return,
    };

    let flags = decide(user_id, api_key.to_owned())
        .await
        .inspect_err(|e| tracing::debug!("Failed to evaluate feature flags: {e:#}"))
        .unwrap_or_default();

    FEATURE_FLAGS.update(flags);

    sentry::Hub::main().configure_scope(|scope| {
        scope.set_context("flags", sentry_flag_context(flags));
    });

    tracing::debug!(%env, flags = ?FEATURE_FLAGS, "Evaluated feature-flags");
}

pub(crate) fn reevaluate(user_id: String, env: &str) {
    let Ok(env) = env.parse() else {
        return;
    };

    RUNTIME.spawn(evaluate_now(user_id, env));
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

async fn decide(maybe_legacy_id: String, api_key: String) -> Result<FeatureFlagsResponse> {
    let distinct_id = if uuid::Uuid::from_str(&maybe_legacy_id).is_ok() {
        hex::encode(sha2::Sha256::digest(&maybe_legacy_id))
    } else {
        maybe_legacy_id
    };

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
    feature_flags: FeatureFlagsResponse,
}

#[derive(Debug, Deserialize, Default, Clone, Copy)]
#[serde(rename_all = "kebab-case")]
struct FeatureFlagsResponse {
    #[serde(default)]
    icmp_unreachable_instead_of_nat64: bool,
    #[serde(default)]
    drop_llmnr_nxdomain_responses: bool,
    #[serde(default)]
    stream_logs: bool,
    #[serde(default)]
    map_enobufs_to_wouldblock: bool,
}

#[derive(Debug, Default)]
struct FeatureFlags {
    icmp_unreachable_instead_of_nat64: AtomicBool,
    drop_llmnr_nxdomain_responses: AtomicBool,
    stream_logs: AtomicBool,
    map_enobufs_to_wouldblock: AtomicBool,
}

/// Accessors to the actual feature flags.
///
/// All atomic operations are implemented with relaxed ordering for maximum efficiency.
/// Feature flags may be accessed in very busy loops and therefore need to be fast.
///
/// At the same time, we don't care about the ordering as long as it the value gets updated eventually.
impl FeatureFlags {
    fn update(
        &self,
        FeatureFlagsResponse {
            icmp_unreachable_instead_of_nat64,
            drop_llmnr_nxdomain_responses,
            stream_logs,
            map_enobufs_to_wouldblock,
        }: FeatureFlagsResponse,
    ) {
        self.icmp_unreachable_instead_of_nat64
            .store(icmp_unreachable_instead_of_nat64, Ordering::Relaxed);
        self.drop_llmnr_nxdomain_responses
            .store(drop_llmnr_nxdomain_responses, Ordering::Relaxed);
        self.stream_logs.store(stream_logs, Ordering::Relaxed);
        self.map_enobufs_to_wouldblock
            .store(map_enobufs_to_wouldblock, Ordering::Relaxed);
    }

    fn icmp_unreachable_instead_of_nat64(&self) -> bool {
        self.icmp_unreachable_instead_of_nat64
            .load(Ordering::Relaxed)
    }

    fn drop_llmnr_nxdomain_responses(&self) -> bool {
        self.drop_llmnr_nxdomain_responses.load(Ordering::Relaxed)
    }

    fn stream_logs(&self) -> bool {
        self.stream_logs.load(Ordering::Relaxed)
    }

    fn map_enobufs_to_wouldblock(&self) -> bool {
        self.map_enobufs_to_wouldblock.load(Ordering::Relaxed)
    }
}

fn sentry_flag_context(flags: FeatureFlagsResponse) -> sentry::protocol::Context {
    #[derive(Debug, serde::Serialize)]
    #[serde(tag = "flag", rename_all = "snake_case")]
    enum SentryFlag {
        IcmpUnreachableInsteadOfNat64 { result: bool },
        DropLlmnrNxdomainResponses { result: bool },
        StreamLogs { result: bool },
        MapENOBUFSToWouldBlock { result: bool },
    }

    // Exhaustive destruction so we don't forget to update this when we add a flag.
    let FeatureFlagsResponse {
        icmp_unreachable_instead_of_nat64,
        drop_llmnr_nxdomain_responses,
        stream_logs,
        map_enobufs_to_wouldblock,
    } = flags;

    let value = serde_json::json!({
        "values": [
            SentryFlag::IcmpUnreachableInsteadOfNat64 {
                result: icmp_unreachable_instead_of_nat64,
            },
            SentryFlag::DropLlmnrNxdomainResponses { result: drop_llmnr_nxdomain_responses },
            SentryFlag::StreamLogs { result: stream_logs },
            SentryFlag::MapENOBUFSToWouldBlock { result: map_enobufs_to_wouldblock },
        ]
    });

    sentry::protocol::Context::Other(serde_json::from_value(value).expect("to and from json works"))
}

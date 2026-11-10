use std::{
    fmt,
    str::FromStr as _,
    sync::{
        LazyLock,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use anyhow::{Context as _, Result, bail};
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use tracing::{Metadata, level_filters::LevelFilter};
use tracing_subscriber::filter::Targets;

use crate::{Env, ingest, posthog};

pub(crate) const RE_EVAL_DURATION: Duration = Duration::from_secs(5 * 60);

// Process-wide storage of enabled feature flags.
//
// Defaults to everything off unless the env variables say otherwise.
static FEATURE_FLAGS: LazyLock<FeatureFlags> = LazyLock::new(|| {
    let flags = FeatureFlags::default();
    let from_env = update_from_env(FeatureFlagsResponse::default());

    flags.update(from_env, FeatureFlagPayloadsResponse::default());

    flags
});

pub fn icmp_unreachable_instead_of_nat64() -> bool {
    FEATURE_FLAGS.icmp_unreachable_instead_of_nat64()
}

pub fn drop_llmnr_nxdomain_responses() -> bool {
    FEATURE_FLAGS.drop_llmnr_nxdomain_responses()
}

pub fn stream_logs(metadata: &Metadata<'_>) -> bool {
    FEATURE_FLAGS.stream_logs(metadata)
}

/// Returns whether log streaming is currently active (i.e. `stream_logs` flag is on
/// and has non-empty directives).
pub fn stream_logs_active() -> bool {
    !FEATURE_FLAGS.stream_logs.read().directives.is_empty()
}

pub fn wintun_tcp_coalescing() -> bool {
    FEATURE_FLAGS.wintun_tcp_coalescing()
}

/// The current value of every feature flag, by name.
pub(crate) fn current() -> impl IntoIterator<Item = (&'static str, bool)> {
    // Exhaustive destruction so we don't forget to update this when we add a flag.
    let FeatureFlags {
        icmp_unreachable_instead_of_nat64,
        drop_llmnr_nxdomain_responses,
        stream_logs,
        wintun_tcp_coalescing,
    } = &*FEATURE_FLAGS;

    [
        (
            "icmp_unreachable_instead_of_nat64",
            icmp_unreachable_instead_of_nat64.load(Ordering::Relaxed),
        ),
        (
            "drop_llmnr_nxdomain_responses",
            drop_llmnr_nxdomain_responses.load(Ordering::Relaxed),
        ),
        ("stream_logs", !stream_logs.read().directives.is_empty()),
        (
            "wintun_tcp_coalescing",
            wintun_tcp_coalescing.load(Ordering::Relaxed),
        ),
    ]
}

pub(crate) async fn evaluate_now(user_id: String, env: Env) {
    if user_id.is_empty() {
        return;
    }

    let api_key = match env {
        Env::Production => posthog::API_KEY_PROD,
        Env::Staging => posthog::API_KEY_STAGING,
        Env::Entrypoint | Env::OnPrem | Env::DockerCompose | Env::Localhost => return,
    };

    let (flags, payloads) = decide(user_id, api_key.to_owned())
        .await
        .inspect_err(|e| tracing::debug!("Failed to evaluate feature flags: {e:#}"))
        .unwrap_or_default();

    let flags = update_from_env(flags);

    FEATURE_FLAGS.update(flags, payloads);

    tracing::debug!(%env, flags = ?FEATURE_FLAGS, "Evaluated feature-flags");
}

/// Re-evaluates feature flags using the current telemetry user and environment.
///
/// Does nothing until telemetry is active and both are known. Lets us refresh
/// flags promptly when the network situation changes instead of waiting for the
/// next periodic re-evaluation.
pub(crate) fn reevaluate_current() {
    let Some((user_id, env)) = crate::current_identity() else {
        return;
    };

    ingest::RUNTIME.spawn(evaluate_now(user_id, env));
}

pub(crate) async fn reeval_timer() {
    loop {
        tokio::time::sleep(RE_EVAL_DURATION).await;

        reevaluate_current();
    }
}

/// Re-evaluates feature flags whenever the tunnel-bypass resolver is swapped:
/// flags may have been unfetchable while (working) resolvers were missing.
pub(crate) async fn reeval_on_resolver_change() {
    let mut changes = tunnel_bypass_resolver::changes();

    while changes.changed().await.is_ok() {
        reevaluate_current();
    }
}

async fn decide(
    maybe_legacy_id: String,
    api_key: String,
) -> Result<(FeatureFlagsResponse, FeatureFlagPayloadsResponse)> {
    let distinct_id = crate::maybe_hash_device_id(maybe_legacy_id);

    let response = posthog::post_json(
        "/decide?v=3",
        &DecideRequest {
            api_key,
            distinct_id,
        },
    )
    .await
    .context("Failed to send POST request")?;

    let status = response.status();
    let body = response.into_body();

    if !status.is_success() {
        bail!(
            "Failed to get feature flags; status={status}, body={}",
            String::from_utf8_lossy(&body)
        )
    }

    let decide_response = serde_json::from_slice::<DecideResponse>(&body)
        .context("Failed to deserialize response")?;

    Ok((
        decide_response.feature_flags,
        decide_response.feature_flag_payloads,
    ))
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
    feature_flag_payloads: FeatureFlagPayloadsResponse,
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
    wintun_tcp_coalescing: bool,
}

#[derive(Debug, Deserialize, Default, Clone)]
#[serde(rename_all = "kebab-case")]
struct FeatureFlagPayloadsResponse {
    #[serde(default)]
    stream_logs: String,
}

#[derive(Debug, Default)]
struct FeatureFlags {
    icmp_unreachable_instead_of_nat64: AtomicBool,
    drop_llmnr_nxdomain_responses: AtomicBool,
    stream_logs: RwLock<LogFilter>,
    wintun_tcp_coalescing: AtomicBool,
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
            wintun_tcp_coalescing,
        }: FeatureFlagsResponse,
        payloads: FeatureFlagPayloadsResponse,
    ) {
        self.icmp_unreachable_instead_of_nat64
            .store(icmp_unreachable_instead_of_nat64, Ordering::Relaxed);
        self.drop_llmnr_nxdomain_responses
            .store(drop_llmnr_nxdomain_responses, Ordering::Relaxed);
        self.wintun_tcp_coalescing
            .store(wintun_tcp_coalescing, Ordering::Relaxed);

        let log_filter = if stream_logs {
            LogFilter::parse(payloads.stream_logs)
        } else {
            LogFilter::default()
        };

        *self.stream_logs.write() = log_filter;
    }

    fn icmp_unreachable_instead_of_nat64(&self) -> bool {
        self.icmp_unreachable_instead_of_nat64
            .load(Ordering::Relaxed)
    }

    fn drop_llmnr_nxdomain_responses(&self) -> bool {
        self.drop_llmnr_nxdomain_responses.load(Ordering::Relaxed)
    }

    fn stream_logs(&self, metadata: &Metadata<'_>) -> bool {
        self.stream_logs.read().enabled(metadata)
    }

    fn wintun_tcp_coalescing(&self) -> bool {
        self.wintun_tcp_coalescing.load(Ordering::Relaxed)
    }
}

fn update_from_env(flags: FeatureFlagsResponse) -> FeatureFlagsResponse {
    FeatureFlagsResponse {
        icmp_unreachable_instead_of_nat64: env_or(
            "FZFF_ICMP_UNREACHABLE_INSTEAD_OF_NAT64",
            flags.icmp_unreachable_instead_of_nat64,
        ),
        drop_llmnr_nxdomain_responses: env_or(
            "FZFF_DROP_LLMNR_NXDOMAIN_RESPONSES",
            flags.drop_llmnr_nxdomain_responses,
        ),
        stream_logs: env_or("FZFF_stream_logs", flags.stream_logs),
        wintun_tcp_coalescing: env_or("FZFF_WINTUN_TCP_COALESCING", flags.wintun_tcp_coalescing),
    }
}

fn env_or(key: &str, fallback: bool) -> bool {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(fallback)
}

struct LogFilter {
    directives: String,
    targets: Targets,
}

impl Default for LogFilter {
    fn default() -> Self {
        Self {
            directives: String::default(),
            targets: Targets::new(),
        }
    }
}

impl LogFilter {
    fn parse(directives: String) -> Self {
        let directives = match serde_json::from_str::<String>(&directives) {
            Ok(directives) => directives,
            Err(e) => {
                tracing::debug!("Failed to parse directives from JSON: {e}");

                String::from("debug")
            }
        };

        let targets = Targets::from_str(&directives).unwrap_or_else(|e| {
            tracing::debug!(%directives, "Failed to parse env-filter: {e}");

            Targets::new().with_default(LevelFilter::DEBUG)
        });

        Self {
            directives,
            targets,
        }
    }

    fn enabled(&self, md: &Metadata<'_>) -> bool {
        self.targets.would_enable(md.target(), md.level())
    }
}

impl fmt::Debug for LogFilter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.directives.fmt(f)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filter_parses_from_nested_json() {
        let filter = LogFilter::parse("\"debug,is::ice_::pair=trace\"".to_owned());

        assert_eq!(filter.directives, "debug,is::ice_::pair=trace");
    }

    #[test]
    fn wintun_tcp_coalescing_defaults_to_disabled() {
        let flags = FeatureFlags::default();

        assert!(!flags.wintun_tcp_coalescing());

        flags.update(
            FeatureFlagsResponse {
                wintun_tcp_coalescing: true,
                ..Default::default()
            },
            FeatureFlagPayloadsResponse::default(),
        );

        assert!(flags.wintun_tcp_coalescing());
    }

    #[test]
    fn parses_wintun_tcp_coalescing_from_posthog() {
        let flags =
            serde_json::from_str::<FeatureFlagsResponse>(r#"{"wintun-tcp-coalescing":true}"#)
                .unwrap();

        assert!(flags.wintun_tcp_coalescing);
    }
}

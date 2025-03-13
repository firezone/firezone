#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    sync::{Arc, LazyLock},
    time::Duration,
};

use anyhow::{bail, Context, Result};
use env::ON_PREM;
use parking_lot::RwLock;
use sentry::protocol::SessionStatus;
use serde::{Deserialize, Serialize};

pub struct Dsn(&'static str);

// TODO: Dynamic DSN
// Sentry docs say this does not need to be protected:
// > DSNs are safe to keep public because they only allow submission of new events and related event data; they do not allow read access to any information.
// <https://docs.sentry.io/concepts/key-terms/dsn-explainer/#dsn-utilization>

pub const ANDROID_DSN: Dsn = Dsn("https://928a6ee1f6af9734100b8bc89b2dc87d@o4507971108339712.ingest.us.sentry.io/4508175126233088");
pub const APPLE_DSN: Dsn = Dsn("https://66c71f83675f01abfffa8eb977bcbbf7@o4507971108339712.ingest.us.sentry.io/4508175177023488");
pub const GATEWAY_DSN: Dsn = Dsn("https://f763102cc3937199ec483fbdae63dfdc@o4507971108339712.ingest.us.sentry.io/4508162914451456");
pub const GUI_DSN: Dsn = Dsn("https://2e17bf5ed24a78c0ac9e84a5de2bd6fc@o4507971108339712.ingest.us.sentry.io/4508008945549312");
pub const HEADLESS_DSN: Dsn = Dsn("https://bc27dca8bb37be0142c48c4f89647c13@o4507971108339712.ingest.us.sentry.io/4508010028728320");
pub const RELAY_DSN: Dsn = Dsn("https://9d5f664d8f8f7f1716d4b63a58bcafd5@o4507971108339712.ingest.us.sentry.io/4508373298970624");
pub const TESTING: Dsn = Dsn("https://55ef451fca9054179a11f5d132c02f45@o4507971108339712.ingest.us.sentry.io/4508792604852224");

const POSTHOG_API_KEY: &str = "phc_uXXl56plyvIBHj81WwXBLtdPElIRbm7keRTdUCmk8ll";

// Process-wide storage of enabled feature flags.
//
// Defaults to everything off.
static FEATURE_FLAGS: LazyLock<RwLock<FeatureFlags>> = LazyLock::new(RwLock::default);

/// Exposes all feature flags as public, static functions.
///
/// These only ever hit an in-memory location so can even be called from hot paths.
pub mod feature_flags {
    use crate::*;

    pub fn icmp_unreachable_instead_of_nat64() -> bool {
        FEATURE_FLAGS.read().icmp_unreachable_instead_of_nat64
    }
}

mod env {
    use std::borrow::Cow;

    pub const PRODUCTION: Cow<'static, str> = Cow::Borrowed("production");
    pub const STAGING: Cow<'static, str> = Cow::Borrowed("staging");
    pub const ON_PREM: Cow<'static, str> = Cow::Borrowed("on-prem");
}

#[derive(Default)]
pub struct Telemetry {
    inner: Option<sentry::ClientInitGuard>,
}

impl Drop for Telemetry {
    fn drop(&mut self) {
        if self.inner.is_none() {
            return;
        }

        // Conclude telemetry session as "abnormal" if we get dropped without closing it properly first.
        sentry::end_session_with_status(SessionStatus::Abnormal);
    }
}

impl Telemetry {
    pub fn start(&mut self, api_url: &str, release: &str, dsn: Dsn) {
        // Can't use URLs as `environment` directly, because Sentry doesn't allow slashes in environments.
        // <https://docs.sentry.io/platforms/rust/configuration/environments/>
        let environment = match api_url {
            "wss://api.firezone.dev" | "wss://api.firezone.dev/" => env::PRODUCTION,
            "wss://api.firez.one" | "wss://api.firez.one/" => env::STAGING,
            _ => env::ON_PREM,
        };

        if self
            .inner
            .as_ref()
            .and_then(|i| i.options().environment.as_ref())
            .is_some_and(|env| env == &environment)
        {
            tracing::debug!(%environment, "Telemetry already initialised");

            return;
        }

        // Stop any previous telemetry session.
        if let Some(inner) = self.inner.take() {
            tracing::debug!("Stopping previous telemetry session");

            sentry::end_session();
            drop(inner);

            set_current_user(None);
        }

        if environment == ON_PREM {
            tracing::debug!(%api_url, "Telemetry won't start in unofficial environment");
            return;
        }

        tracing::info!(%environment, "Starting telemetry");

        let inner = sentry::init((
            dsn.0,
            sentry::ClientOptions {
                environment: Some(environment),
                // We can't get the release number ourselves because we don't know if we're embedded in a GUI Client or a Headless Client.
                release: Some(release.to_owned().into()),
                traces_sampler: Some(Arc::new(|tx| {
                    // Only submit `telemetry` spans to Sentry.
                    // Those get sampled at creation time (to save CPU power) so we want to submit all of them.
                    if tx.name() == "telemetry" {
                        1.0
                    } else {
                        0.0
                    }
                })),
                max_breadcrumbs: 500,
                ..Default::default()
            },
        ));
        // Configure scope on the main hub so that all threads will get the tags
        sentry::Hub::main().configure_scope(|scope| {
            scope.set_tag("api_url", api_url);
            let ctx = sentry::integrations::contexts::utils::device_context();
            scope.set_context("device", ctx);
            let ctx = sentry::integrations::contexts::utils::rust_context();
            scope.set_context("rust", ctx);

            if let Some(ctx) = sentry::integrations::contexts::utils::os_context() {
                scope.set_context("os", ctx);
            }
        });
        self.inner.replace(inner);
        sentry::start_session();
    }

    /// Flushes events to sentry.io and drops the guard
    pub async fn stop(&mut self) {
        self.end_session(SessionStatus::Exited).await;
    }

    pub async fn stop_on_crash(&mut self) {
        self.end_session(SessionStatus::Crashed).await;
    }

    async fn end_session(&mut self, status: SessionStatus) {
        let Some(inner) = self.inner.take() else {
            return;
        };
        tracing::info!("Stopping telemetry");
        sentry::end_session_with_status(status);

        // Sentry uses blocking IO for flushing ..
        let _ = tokio::task::spawn_blocking(move || {
            if !inner.flush(Some(Duration::from_secs(5))) {
                tracing::error!("Failed to flush telemetry events to sentry.io");
                return;
            };

            tracing::debug!("Flushed telemetry");
        })
        .await;
    }

    pub fn set_account_slug(slug: String) {
        update_user(|user| {
            user.other.insert("account_slug".to_owned(), slug.into());
        });
    }

    pub fn set_firezone_id(id: String) {
        update_user({
            let id = id.clone();
            |user| user.id = Some(id)
        });

        std::thread::spawn(|| {
            let flags = evaluate_feature_flags(id)
                .inspect_err(|e| tracing::debug!("Failed to evaluate feature flags: {e:#}"))
                .unwrap_or_default();

            tracing::debug!(?flags, "Evaluated feature-flags");

            *FEATURE_FLAGS.write() = flags;

            sentry::Hub::main().configure_scope(|scope| {
                scope.set_context("flags", sentry_flag_context(flags));
            });
        });
    }
}

fn update_user(update: impl FnOnce(&mut sentry::User)) {
    sentry::Hub::main().configure_scope(|scope| {
        let mut user = scope.user().cloned().unwrap_or_default();
        update(&mut user);

        scope.set_user(Some(user));
    });
}

fn set_current_user(user: Option<sentry::User>) {
    sentry::Hub::main().configure_scope(|scope| scope.set_user(user));
}

fn evaluate_feature_flags(distinct_id: String) -> Result<FeatureFlags> {
    let response = reqwest::blocking::ClientBuilder::new()
        .connection_verbose(true)
        .build()?
        .post("https://us.i.posthog.com/decide?v=3")
        .json(&DecideRequest {
            api_key: POSTHOG_API_KEY.to_string(),
            distinct_id,
        })
        .send()
        .context("Failed to send POST request")?;

    let status = response.status();

    if !status.is_success() {
        let body = response.text().unwrap_or_default();

        bail!("Failed to get feature flags; status={status}, body={body}")
    }

    let json = response
        .json::<DecideResponse>()
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
}

fn sentry_flag_context(flags: FeatureFlags) -> sentry::protocol::Context {
    #[derive(Debug, serde::Serialize)]
    #[serde(tag = "flag", rename_all = "snake_case")]
    enum SentryFlag {
        IcmpUnreachableInsteadOfNat64 { result: bool },
    }

    // Exhaustive destruction so we don't forget to update this when we add a flag.
    let FeatureFlags {
        icmp_unreachable_instead_of_nat64,
    } = flags;

    let value = serde_json::json!({
        "values": [
            SentryFlag::IcmpUnreachableInsteadOfNat64 {
                result: icmp_unreachable_instead_of_nat64,
            }
        ]
    });

    sentry::protocol::Context::Other(serde_json::from_value(value).expect("to and from json works"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn starting_session_for_unsupported_env_disables_current_one() {
        let mut telemetry = Telemetry::default();
        telemetry.start("wss://api.firez.one", "1.0.0", TESTING);
        telemetry.start("wss://example.com", "1.0.0", TESTING);

        assert!(telemetry.inner.is_none());
    }
}

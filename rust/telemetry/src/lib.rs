#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{borrow::Cow, collections::BTreeMap, fmt, str::FromStr, sync::Arc, time::Duration};

use anyhow::{Result, bail};
use sentry::{
    BeforeCallback, User,
    protocol::{Event, Log, LogAttribute, SessionStatus},
};
use sha2::Digest as _;

pub mod analytics;
pub mod cpu_monitor;
pub mod feature_flags;
pub mod otel;

mod posthog;

pub struct Dsn(&'static str);

// TODO: Dynamic DSN
// Sentry docs say this does not need to be protected:
// > DSNs are safe to keep public because they only allow submission of new events and related event data; they do not allow read access to any information.
// <https://docs.sentry.io/concepts/key-terms/dsn-explainer/#dsn-utilization>

pub const ANDROID_DSN: Dsn = Dsn(
    "https://928a6ee1f6af9734100b8bc89b2dc87d@o4507971108339712.ingest.us.sentry.io/4508175126233088",
);
pub const APPLE_DSN: Dsn = Dsn(
    "https://66c71f83675f01abfffa8eb977bcbbf7@o4507971108339712.ingest.us.sentry.io/4508175177023488",
);
pub const GATEWAY_DSN: Dsn = Dsn(
    "https://f763102cc3937199ec483fbdae63dfdc@o4507971108339712.ingest.us.sentry.io/4508162914451456",
);
pub const GUI_DSN: Dsn = Dsn(
    "https://2e17bf5ed24a78c0ac9e84a5de2bd6fc@o4507971108339712.ingest.us.sentry.io/4508008945549312",
);
pub const HEADLESS_DSN: Dsn = Dsn(
    "https://bc27dca8bb37be0142c48c4f89647c13@o4507971108339712.ingest.us.sentry.io/4508010028728320",
);
pub const RELAY_DSN: Dsn = Dsn(
    "https://9d5f664d8f8f7f1716d4b63a58bcafd5@o4507971108339712.ingest.us.sentry.io/4508373298970624",
);
pub const TESTING: Dsn = Dsn(
    "https://55ef451fca9054179a11f5d132c02f45@o4507971108339712.ingest.us.sentry.io/4508792604852224",
);

#[derive(Debug, PartialEq, Clone, Copy)]
pub(crate) enum Env {
    Production,
    Staging,
    DockerCompose,
    Localhost,
    OnPrem,
}

impl Env {
    pub(crate) fn from_api_url(api_url: &str) -> Self {
        match api_url.trim_end_matches('/') {
            "wss://api.firezone.dev" => Self::Production,
            "wss://api.firez.one" => Self::Staging,
            "ws://api:8081" => Self::DockerCompose,
            "ws://localhost:8081" => Self::DockerCompose,
            _ => Self::OnPrem,
        }
    }

    pub(crate) fn as_str(&self) -> &'static str {
        match self {
            Env::Production => "production",
            Env::Staging => "staging",
            Env::DockerCompose => "docker-compose",
            Env::Localhost => "localhost",
            Env::OnPrem => "on-prem",
        }
    }
}

impl FromStr for Env {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "production" => Ok(Self::Production),
            "staging" => Ok(Self::Staging),
            "docker-compose" => Ok(Self::DockerCompose),
            "localhost" => Ok(Self::Localhost),
            "on-prem" => Ok(Self::OnPrem),
            other => bail!("Unknown env `{other}`"),
        }
    }
}

impl fmt::Display for Env {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.as_str().fmt(f)
    }
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
    pub async fn start(&mut self, api_url: &str, release: &str, dsn: Dsn, firezone_id: String) {
        // Can't use URLs as `environment` directly, because Sentry doesn't allow slashes in environments.
        // <https://docs.sentry.io/platforms/rust/configuration/environments/>
        let environment = Env::from_api_url(api_url);

        if self
            .inner
            .as_ref()
            .and_then(|i| i.options().environment.as_ref())
            .is_some_and(|env| env == environment.as_str())
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

        if environment == Env::OnPrem {
            tracing::debug!(%api_url, "Telemetry won't start in unofficial environment");
            return;
        }

        // Important: Evaluate feature flags before checking `stream_logs` to avoid hitting the default.
        feature_flags::evaluate_now(firezone_id.clone(), environment).await;
        tracing::info!(%environment, "Starting telemetry");

        let inner = sentry::init((
            dsn.0,
            sentry::ClientOptions {
                environment: Some(Cow::Borrowed(environment.as_str())),
                // We can't get the release number ourselves because we don't know if we're embedded in a GUI Client or a Headless Client.
                release: Some(release.to_owned().into()),
                max_breadcrumbs: 500,
                before_send: Some(event_rate_limiter(Duration::from_secs(60 * 5))),
                enable_logs: true,
                before_send_log: Some(Arc::new(append_tracing_fields_to_message)),
                ..Default::default()
            },
        ));
        // Configure scope on the main hub so that all threads will get the tags
        sentry::Hub::main().configure_scope(move |scope| {
            scope.set_tag("api_url", api_url);
            let ctx = sentry::integrations::contexts::utils::device_context();
            scope.set_context("device", ctx);
            let ctx = sentry::integrations::contexts::utils::rust_context();
            scope.set_context("rust", ctx);

            if let Some(ctx) = sentry::integrations::contexts::utils::os_context() {
                scope.set_context("os", ctx);
            }

            scope.set_user(Some(compute_user(firezone_id)));
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

        // Sentry uses blocking IO for flushing ..
        let _ = tokio::task::spawn_blocking(move || {
            if !inner.flush(Some(Duration::from_secs(5))) {
                tracing::error!("Failed to flush telemetry events to sentry.io");
                return;
            };

            tracing::debug!("Flushed telemetry");
        })
        .await;

        sentry::end_session_with_status(status);
    }

    pub fn set_account_slug(slug: String) {
        update_user(|user| {
            user.other.insert("account_slug".to_owned(), slug.into());
        });
    }
}

/// Computes the [`User`] scope based on the contents of `firezone_id`.
///
/// If `firezone_id` looks like a UUID, we hash and hex-encode it.
/// This will align the ID with what we see in the portal.
///
/// If it is not a UUID, it is already from a newer installation of Firezone
/// where the ID is sent as-is.
///
/// As a result, this will allow us to always filter the user by the hex-encoded ID.
fn compute_user(firezone_id: String) -> User {
    if uuid::Uuid::from_str(&firezone_id).is_ok() {
        let encoded_id = hex::encode(sha2::Sha256::digest(firezone_id));

        return User {
            id: Some(encoded_id.clone()),
            other: BTreeMap::from([("uuid".to_owned(), serde_json::Value::String(encoded_id))]),
            ..User::default()
        };
    }

    User {
        id: Some(firezone_id),
        ..User::default()
    }
}

fn event_rate_limiter(timeout: Duration) -> BeforeCallback<Event<'static>> {
    let cache = moka::sync::CacheBuilder::<String, (), _>::default()
        .max_capacity(10_000)
        .time_to_live(timeout)
        .build();

    Arc::new(move |event: Event<'static>| {
        let Some(message) = &event.message else {
            return Some(event);
        };

        if cache.contains_key(message) {
            return None;
        }

        cache.insert(message.clone(), ());

        Some(event)
    })
}

/// Appends all but certain attributes from a sentry [`Log`] to the message body.
///
/// Sentry stores all [`tracing`] fields as attributes and only renders the message.
/// Within Firezone, we make extensive use of attributes to provide contextual information.
/// We want to see these attributes inline with the message which is why we emulate the behaviour of `tracing_subscriber::fmt` here.
#[expect(
    clippy::unnecessary_wraps,
    reason = "We need to match Sentry's config signature."
)]
fn append_tracing_fields_to_message(mut log: Log) -> Option<Log> {
    const IGNORED_ATTRS: &[&str] = &[
        "os.",
        "sentry.",
        "tracing.",
        "server.",
        "user.",
        "log.",
        "parent_span_id",
    ];

    for (key, attribute) in &log.attributes {
        let LogAttribute(serde_json::Value::String(attr_string)) = &attribute else {
            continue;
        };

        if IGNORED_ATTRS.iter().any(|attr| key.starts_with(attr)) {
            continue;
        }

        log.body.push_str(&format!(" {key}={attr_string}"));
    }

    Some(log)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn starting_session_for_unsupported_env_disables_current_one() {
        let mut telemetry = Telemetry::default();
        telemetry
            .start("wss://api.firez.one", "1.0.0", TESTING, String::new())
            .await;
        telemetry
            .start("wss://example.com", "1.0.0", TESTING, String::new())
            .await;

        assert!(telemetry.inner.is_none());
    }

    #[test]
    fn rate_limits_events_with_same_message() {
        let before_send = event_rate_limiter(Duration::from_secs(1));

        let event1 = event("foo");
        let event2 = event("bar");

        assert!(before_send(event1.clone()).is_some());
        assert!(before_send(event2.clone()).is_some());
        assert!(before_send(event1.clone()).is_none());

        std::thread::sleep(Duration::from_secs(1));

        assert!(before_send(event1.clone()).is_some());
    }

    fn event(msg: &str) -> Event<'static> {
        Event {
            message: Some(msg.to_owned()),
            ..Default::default()
        }
    }
}

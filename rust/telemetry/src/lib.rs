#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    borrow::Cow,
    collections::BTreeMap,
    fmt, mem,
    net::{SocketAddr, ToSocketAddrs as _},
    str::FromStr,
    sync::Arc,
    time::Duration,
};

use anyhow::{Context, Result, anyhow, bail};
use api_url::ApiUrl;
use sentry::{
    BeforeCallback, User,
    protocol::{Event, Log, LogAttribute, SessionStatus},
    transports::ReqwestHttpTransport,
};
use sha2::Digest as _;

pub mod analytics;
pub mod feature_flags;
pub mod otel;

mod api_url;
mod maybe_push_metrics_exporter;
mod noop_push_metrics_exporter;
mod posthog;

pub use maybe_push_metrics_exporter::MaybePushMetricsExporter;
pub use noop_push_metrics_exporter::NoopPushMetricsExporter;

pub struct Dsn {
    public_key: &'static str,
    project_id: u64,
}

// TODO: Dynamic DSN
// Sentry docs say this does not need to be protected:
// > DSNs are safe to keep public because they only allow submission of new events and related event data; they do not allow read access to any information.
// <https://docs.sentry.io/concepts/key-terms/dsn-explainer/#dsn-utilization>

const INGEST_HOST: &str = "sentry.firezone.dev";

pub const ANDROID_DSN: Dsn = Dsn {
    public_key: "928a6ee1f6af9734100b8bc89b2dc87d",
    project_id: 4508175126233088,
};
pub const APPLE_DSN: Dsn = Dsn {
    public_key: "66c71f83675f01abfffa8eb977bcbbf7",
    project_id: 4508175177023488,
};
pub const GATEWAY_DSN: Dsn = Dsn {
    public_key: "f763102cc3937199ec483fbdae63dfdc",
    project_id: 4508162914451456,
};
pub const GUI_DSN: Dsn = Dsn {
    public_key: "2e17bf5ed24a78c0ac9e84a5de2bd6fc",
    project_id: 4508008945549312,
};
pub const HEADLESS_DSN: Dsn = Dsn {
    public_key: "bc27dca8bb37be0142c48c4f89647c13",
    project_id: 4508010028728320,
};
pub const RELAY_DSN: Dsn = Dsn {
    public_key: "9d5f664d8f8f7f1716d4b63a58bcafd5",
    project_id: 4508373298970624,
};
pub const TESTING: Dsn = Dsn {
    public_key: "55ef451fca9054179a11f5d132c02f45",
    project_id: 4508792604852224,
};

impl fmt::Display for Dsn {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "https://{}@{INGEST_HOST}/{}",
            self.public_key, self.project_id
        )
    }
}

#[derive(Debug, PartialEq, Clone, Copy)]
pub(crate) enum Env {
    Production,
    Staging,
    DockerCompose,
    Localhost,
    OnPrem,
}

impl From<ApiUrl<'_>> for Env {
    fn from(value: ApiUrl) -> Self {
        match value {
            ApiUrl::PROD => Self::Production,
            ApiUrl::STAGING => Self::Staging,
            ApiUrl::DOCKER_COMPOSE | ApiUrl::LOCALHOST => Self::DockerCompose,
            _ => Self::OnPrem,
        }
    }
}

impl Env {
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

pub struct Telemetry {
    inner: Option<sentry::ClientInitGuard>,
    transport: TransportFactory,
}

impl Default for Telemetry {
    fn default() -> Self {
        Self::new()
    }
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
    pub fn new() -> Self {
        Self {
            inner: Default::default(),
            transport: TransportFactory::resolve_ingest_host().unwrap_or_else(|e| {
                tracing::debug!("Failed to create telemetry transport factory: {e:#}");

                TransportFactory::without_addresses()
            }),
        }
    }

    pub fn disabled() -> Self {
        Self {
            inner: None,
            transport: TransportFactory::without_addresses(),
        }
    }

    pub async fn start(&mut self, api_url: &str, release: &str, dsn: Dsn, firezone_id: String) {
        // Can't use URLs as `environment` directly, because Sentry doesn't allow slashes in environments.
        // <https://docs.sentry.io/platforms/rust/configuration/environments/>
        let environment = Env::from(ApiUrl::new(api_url));

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

        if [Env::OnPrem, Env::Localhost, Env::DockerCompose].contains(&environment) {
            tracing::debug!(%api_url, "Telemetry won't start in unofficial environment");
            return;
        }

        // Important: Evaluate feature flags before checking `stream_logs` to avoid hitting the default.
        feature_flags::evaluate_now(firezone_id.clone(), environment).await;
        tracing::info!(%environment, "Starting telemetry");

        let client_options = sentry::ClientOptions {
            environment: Some(Cow::Borrowed(environment.as_str())),
            // We can't get the release number ourselves because we don't know if we're embedded in a GUI Client or a Headless Client.
            release: Some(release.to_owned().into()),
            max_breadcrumbs: 500,
            before_send: Some(event_rate_limiter(Duration::from_secs(60 * 5))),
            enable_logs: true,
            before_send_log: Some(Arc::new(|log| {
                let log = insert_user_account_slug(log);
                let log = append_tracing_fields_to_message(log);

                Some(log)
            })),
            ..Default::default()
        };
        let inner = sentry::init((
            dsn.to_string(),
            sentry::ClientOptions {
                transport: Some(Arc::new(self.transport.clone())),
                ..client_options
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
        if let Err(e) = self.end_session(SessionStatus::Exited).await {
            tracing::error!("Failed to stop Sentry session on graceful exit: {e:#}")
        }
    }

    pub async fn stop_on_crash(&mut self) {
        if let Err(e) = self.end_session(SessionStatus::Crashed).await {
            tracing::error!("Failed to stop Sentry session on crash: {e:#}")
        }
    }

    async fn end_session(&mut self, status: SessionStatus) -> Result<()> {
        let Some(inner) = self.inner.take() else {
            return Ok(());
        };
        tracing::info!("Stopping telemetry");

        // Sentry uses blocking IO for flushing ..
        let task = tokio::task::spawn_blocking(move || {
            if !inner.flush(Some(Duration::from_secs(1))) {
                return Err(anyhow!("Failed to flush telemetry events to sentry.io"));
            };

            tracing::debug!("Flushed telemetry");

            sentry::end_session_with_status(status);

            Ok(())
        });

        tokio::time::timeout(Duration::from_secs(1), task)
            .await
            .context("Failed to end session within 1s")???;

        Ok(())
    }

    pub fn set_account_slug(slug: String) {
        update_user(|user| {
            user.other.insert("account_slug".to_owned(), slug.into());
        });
    }

    pub(crate) fn current_env() -> Option<Env> {
        let client = sentry::Hub::main().client()?;
        let env = client.options().environment.as_deref()?;
        let env = Env::from_str(env).ok()?;

        Some(env)
    }

    pub(crate) fn current_user() -> Option<String> {
        sentry::Hub::main().configure_scope(|s| s.user()?.id.clone())
    }

    fn current_account_slug() -> Option<String> {
        sentry::Hub::main()
            .configure_scope(|s| Some(s.user()?.other.get("account_slug")?.as_str()?.to_owned()))
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
fn append_tracing_fields_to_message(mut log: Log) -> Log {
    const IGNORED_ATTRS: &[&str] = &[
        "os.",
        "sentry.",
        "tracing.",
        "server.",
        "user.",
        "log.",
        "code.",
        "parent_span_id",
    ];

    for (key, attribute) in mem::take(&mut log.attributes) {
        let LogAttribute(serde_json::Value::String(attr_string)) = &attribute else {
            continue;
        };

        if IGNORED_ATTRS.iter().any(|attr| key.starts_with(attr)) {
            log.attributes.insert(key, attribute);

            continue;
        }

        let key = match key.rsplit_once(':') {
            Some((_, key)) => key,
            None => &key,
        };

        if log.attributes.contains_key(key) {
            continue;
        }

        log.body.push_str(&format!(" {key}={attr_string}"));
        log.attributes.insert(key.to_owned(), attribute);
    }

    log
}

fn insert_user_account_slug(mut log: Log) -> Log {
    let Some(account_slug) = Telemetry::current_account_slug() else {
        return log;
    };

    log.attributes.insert(
        "user.account_slug".to_owned(),
        LogAttribute::from(account_slug),
    );

    log
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

#[derive(Debug, Clone)]
pub struct TransportFactory {
    ingest_domain_addresses: Vec<SocketAddr>,
}

impl TransportFactory {
    pub fn resolve_ingest_host() -> Result<Self> {
        let resolved_addresses = (INGEST_HOST, 443u16)
            .to_socket_addrs()
            .with_context(|| format!("Failed to resolve {INGEST_HOST}"))?
            .collect();

        tracing::debug!(host = %INGEST_HOST, addresses = ?resolved_addresses, "Resolved ingest host IPs");

        Ok(Self {
            ingest_domain_addresses: resolved_addresses,
        })
    }

    fn without_addresses() -> Self {
        Self {
            ingest_domain_addresses: Default::default(),
        }
    }
}

impl sentry::TransportFactory for TransportFactory {
    fn create_transport(&self, options: &sentry::ClientOptions) -> Arc<dyn sentry::Transport> {
        let mut builder = reqwest::ClientBuilder::new()
            .http2_prior_knowledge()
            .http2_keep_alive_while_idle(true)
            .http2_keep_alive_timeout(Duration::from_secs(1))
            .http2_keep_alive_interval(Duration::from_secs(5)); // Ensure we detect broken connections, i.e. when enabling / disabling the Internet Resource.

        if !self.ingest_domain_addresses.is_empty() {
            builder = builder.resolve_to_addrs(INGEST_HOST, &self.ingest_domain_addresses);
        } else {
            tracing::debug!(host = %INGEST_HOST, "No addresses were pre-resolved for ingest host");
        }

        let client = builder.build().expect("Failed to build HTTP client");

        Arc::new(ReqwestHttpTransport::with_client(options, client))
    }
}

#[cfg(test)]
mod tests {
    use std::time::SystemTime;

    use super::*;

    #[tokio::test]
    async fn starting_session_for_unsupported_env_disables_current_one() {
        let mut telemetry = Telemetry::new();
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

    #[test]
    fn trims_name_of_span_from_field_before_pushing_to_message() {
        let log = log(
            "Foobar",
            &[
                ("handle_input:class", "success response"),
                ("handle_input:from", "1.1.1.1:3478"),
                ("handle_input:method", "binding"),
            ],
        );

        let log = append_tracing_fields_to_message(log);

        assert_eq!(
            log.body,
            "Foobar class=success response from=1.1.1.1:3478 method=binding"
        )
    }

    #[test]
    fn does_not_append_same_attribute_twice() {
        let log = log("Foobar", &[("handle_input:cid", "1234"), ("cid", "1234")]);

        let log = append_tracing_fields_to_message(log);

        assert_eq!(log.body, "Foobar cid=1234")
    }

    #[test]
    fn trims_name_of_span_from_attribute() {
        let log = log(
            "Foobar",
            &[
                ("handle_input:class", "success response"),
                ("handle_input:from", "1.1.1.1:3478"),
                ("handle_input:method", "binding"),
            ],
        );

        let log = append_tracing_fields_to_message(log);

        assert_eq!(
            log.attributes,
            BTreeMap::from([
                (
                    "class".to_owned(),
                    LogAttribute(serde_json::Value::String("success response".to_owned()))
                ),
                (
                    "from".to_owned(),
                    LogAttribute(serde_json::Value::String("1.1.1.1:3478".to_owned()))
                ),
                (
                    "method".to_owned(),
                    LogAttribute(serde_json::Value::String("binding".to_owned()))
                )
            ])
        )
    }

    fn event(msg: &str) -> Event<'static> {
        Event {
            message: Some(msg.to_owned()),
            ..Default::default()
        }
    }

    fn log(msg: &str, attrs: &[(&str, &str)]) -> Log {
        Log {
            level: sentry::protocol::LogLevel::Info,
            body: msg.to_owned(),
            trace_id: None,
            timestamp: SystemTime::now(),
            severity_number: None,
            attributes: attrs
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_owned().into()))
                .collect(),
        }
    }
}

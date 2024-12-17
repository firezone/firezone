use std::{sync::Arc, time::Duration};

use sentry::protocol::SessionStatus;

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
pub const IPC_SERVICE_DSN: Dsn = Dsn("https://0590b89fd4479494a1e7ffa4dc705001@o4507971108339712.ingest.us.sentry.io/4508008896069632");
pub const RELAY_DSN: Dsn = Dsn("https://9d5f664d8f8f7f1716d4b63a58bcafd5@o4507971108339712.ingest.us.sentry.io/4508373298970624");

#[derive(Default)]
pub struct Telemetry {
    inner: Option<sentry::ClientInitGuard>,

    account_slug: Option<String>,
    firezone_id: Option<String>,
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
            "wss://api.firezone.dev" | "wss://api.firezone.dev/" => "production",
            "wss://api.firez.one" | "wss://api.firez.one/" => "staging",
            _ => {
                tracing::debug!(%api_url, "Telemetry won't start in unofficial environment");

                return;
            }
        };

        if self.inner.is_some() {
            return;
        }

        tracing::info!("Starting telemetry");
        let inner = sentry::init((
            dsn.0,
            sentry::ClientOptions {
                environment: Some(environment.into()),
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

        self.update_user_context();
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

    pub fn set_account_slug(&mut self, slug: String) {
        self.account_slug = Some(slug);
        self.update_user_context();
    }

    pub fn set_firezone_id(&mut self, id: String) {
        self.firezone_id = Some(id);
        self.update_user_context();
    }

    fn update_user_context(&self) {
        let mut user = sentry::User {
            id: self.firezone_id.clone(),
            ..Default::default()
        };

        user.other.extend(
            self.account_slug
                .clone()
                .map(|slug| ("account_slug".to_owned(), slug.into())),
        );

        sentry::Hub::main().configure_scope(|scope| scope.set_user(Some(user)));
    }
}

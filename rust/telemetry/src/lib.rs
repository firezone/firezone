use std::time::Duration;

use sentry::protocol::SessionStatus;
pub use sentry_anyhow::capture_anyhow;

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

#[derive(Default)]
pub struct Telemetry {
    /// The sentry guard itself
    ///
    /// `arc_swap` is used here because the borrowing for the GUI process is
    /// complex. If the user has already consented to using telemetry, we want
    /// to start Sentry as soon as possible inside `main`, and keep the guard
    /// alive there. But sentry's `Drop` hook will never get called during
    /// normal GUI operation because Tauri internally calls `std::process::exit`
    /// to bail out of its Tao event loop. So we want the GUI controller to
    /// be able to gracefully close down Sentry, even though it won't have
    /// a mutable handle to it, and even though `main` is actually what holds
    /// the handle. Wrapping it all in `ArcSwap` makes it simpler.
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
        // Since it's `arc_swap` and not `Option`, there is a TOCTOU here,
        // but in practice it should never trigger
        if self.inner.is_some() {
            return;
        }

        // Can't use URLs as `environment` directly, because Sentry doesn't allow slashes in environments.
        // <https://docs.sentry.io/platforms/rust/configuration/environments/>
        let environment = match api_url {
            "wss://api.firezone.dev" | "wss://api.firezone.dev/" => "production",
            "wss://api.firez.one" | "wss://api.firez.one/" => "staging",
            "ws://api:8081" | "ws://api:8081/" => "docker-compose",
            _ => "self-hosted",
        };

        tracing::info!("Starting telemetry");
        let inner = sentry::init((
            dsn.0,
            sentry::ClientOptions {
                environment: Some(environment.into()),
                // We can't get the release number ourselves because we don't know if we're embedded in a GUI Client or a Headless Client.
                release: Some(release.to_owned().into()),
                // We submit all spans but only send the ones with `target: telemetry`.
                // Those spans are created further down and are throttled at creation time to save CPU.
                traces_sample_rate: 1.0,
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
            // `flush`'s return value is flipped from the docs
            // <https://github.com/getsentry/sentry-rust/issues/677>
            if inner.flush(Some(Duration::from_secs(5))) {
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

#[cfg(test)]
mod tests {
    use super::*;

    const ENV: &str = "unit test";

    // To avoid problems with global mutable state, we run unrelated tests in the same test case.
    #[tokio::test]
    async fn sentry() {
        // Smoke-test Sentry itself by turning it on and off a couple times
        {
            let mut tele = Telemetry::default();

            // Expect no telemetry because the telemetry module needs to be enabled before it can do anything
            negative_error("X7X4CKH3");

            tele.start("test", ENV, HEADLESS_DSN);
            // Expect telemetry because the user opted in.
            sentry::add_breadcrumb(sentry::Breadcrumb {
                ty: "test_crumb".into(),
                message: Some("This breadcrumb may appear before error #QELADAGH".into()),
                ..Default::default()
            });
            error("QELADAGH");
            tele.stop().await;

            // Expect no telemetry because the user opted back out.
            negative_error("2RSIYAPX");

            tele.start("test", ENV, HEADLESS_DSN);
            // Cycle one more time to be sure.
            error("S672IOBZ");
            tele.stop().await;

            // Expect no telemetry after the module is closed.
            negative_error("W57GJKUO");
        }

        // Test starting up with the choice opted-in
        {
            {
                let mut tele = Telemetry::default();
                negative_error("4H7HFTNX");
                tele.start("test", ENV, HEADLESS_DSN);
            }
            {
                negative_error("GF46D6IL");
                let mut tele = Telemetry::default();
                tele.start("test", ENV, HEADLESS_DSN);
                error("OKOEUKSW");
            }
        }
    }

    #[derive(Debug, thiserror::Error)]
    enum Error {
        #[error("Test error #{0}, this should appear in the sentry.io portal")]
        Positive(&'static str),
        #[error("Negative #{0} - You should NEVER see this")]
        Negative(&'static str),
    }

    fn error(code: &'static str) {
        sentry::capture_error(&Error::Positive(code));
    }

    fn negative_error(code: &'static str) {
        sentry::capture_error(&Error::Negative(code));
    }
}

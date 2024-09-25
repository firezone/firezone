use arc_swap::ArcSwapOption;
use std::time::Duration;

pub use sentry::{
    add_breadcrumb, capture_error, end_session, end_session_with_status, start_transaction,
    types::protocol::v7::SessionStatus, Breadcrumb, TransactionContext,
};

pub struct Dsn(&'static str);

// TODO: Dynamic DSN
// Sentry docs say this does not need to be protected:
// > DSNs are safe to keep public because they only allow submission of new events and related event data; they do not allow read access to any information.
// <https://docs.sentry.io/concepts/key-terms/dsn-explainer/#dsn-utilization>

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
    inner: ArcSwapOption<sentry::ClientInitGuard>,
}

impl Clone for Telemetry {
    fn clone(&self) -> Self {
        Self {
            inner: ArcSwapOption::new(self.inner.load().clone()),
        }
    }
}

impl Telemetry {
    /// Flushes events to sentry.io and drops the guard.
    pub fn close(&self) {
        self.stop_sentry()
    }

    /// Allows users to opt in or out arbitrarily at run time.
    pub fn set_enabled(&self, dsn: Option<Dsn>) {
        if let Some(dsn) = dsn {
            self.start_sentry(dsn)
        } else {
            self.stop_sentry()
        }
    }

    fn start_sentry(&self, dsn: Dsn) {
        // Since it's `arc_swap` and not `Option`, there is a TOCTOU here,
        // but in practice it should never trigger
        if self.inner.load().is_some() {
            return;
        }
        let inner = sentry::init((
            dsn.0,
            sentry::ClientOptions {
                release: sentry::release_name!(),
                traces_sample_rate: 1.0,
                ..Default::default()
            },
        ));
        self.inner.swap(Some(inner.into()));
        sentry::start_session();
    }

    fn stop_sentry(&self) {
        let Some(inner) = self.inner.swap(None) else {
            return;
        };
        sentry::end_session();
        if !inner.flush(Some(Duration::from_secs(5))) {
            tracing::error!("Failed to flush telemetry events to sentry.io");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // To avoid problems with global mutable state, we run unrelated tests in the same test case.
    #[test]
    fn sentry() {
        // Test this flush problem
        {
            let telemetry = sentry::init((
                HEADLESS_DSN.0,
                sentry::ClientOptions {
                    release: sentry::release_name!(),
                    traces_sample_rate: 1.0,
                    ..Default::default()
                },
            ));
            sentry::start_session();
            sentry::end_session();
            assert!(telemetry.flush(Some(Duration::from_secs(5))));
        }

        // Smoke-test Sentry itself by turning it on and off a couple times
        {
            let tele = Telemetry::default();

            // Expect no telemetry because the telemetry module needs to be enabled before it can do anything
            negative_error("X7X4CKH3");

            tele.set_enabled(Some(HEADLESS_DSN));
            // Expect telemetry because the user opted in.
            sentry::add_breadcrumb(sentry::Breadcrumb {
                ty: "test_crumb".into(),
                message: Some("This breadcrumb may appear before error #QELADAGH".into()),
                ..Default::default()
            });
            error("QELADAGH");
            tele.set_enabled(None);

            // Expect no telemetry because the user opted back out.
            negative_error("2RSIYAPX");

            tele.set_enabled(Some(HEADLESS_DSN));
            // Cycle one more time to be sure.
            error("S672IOBZ");
            tele.close();

            // Expect no telemetry after the module is closed.
            negative_error("W57GJKUO");
        }

        // Test starting up with the choice opted-in
        {
            {
                let tele = Telemetry::default();
                negative_error("4H7HFTNX");
                tele.set_enabled(Some(HEADLESS_DSN));
            }
            {
                negative_error("GF46D6IL");
                let tele = Telemetry::default();
                tele.set_enabled(Some(HEADLESS_DSN));
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

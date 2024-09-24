use std::time::Duration;

// TODO: Dynamic DSN
const DSN: &str = "https://db4f1661daac806240fce8bcec36fa2a@o4507971108339712.ingest.us.sentry.io/4507980445908992";

#[derive(Default)]
pub(crate) struct Telemetry {
    inner: Option<sentry::ClientInitGuard>,
}

impl Drop for Telemetry {
    fn drop(&mut self) {
        self.close();
    }
}

impl Telemetry {
    /// Flushes events to sentry.io and drops the guard.
    /// Any calls to other methods are invalid after this.
    pub(crate) fn close(&mut self) {
        self.stop_sentry()
    }

    /// Allows users to opt in or out arbitrarily at run time.
    pub(crate) fn set_enabled(&mut self, enabled: bool) {
        if enabled {
            self.start_sentry()
        } else {
            self.stop_sentry()
        }
    }

    fn start_sentry(&mut self) {
        if self.inner.is_some() {
            return;
        }
        let inner = sentry::init((
            DSN,
            sentry::ClientOptions {
                release: sentry::release_name!(),
                ..Default::default()
            },
        ));
        self.inner = Some(inner);
        sentry::start_session();
    }

    fn stop_sentry(&mut self) {
        let Some(inner) = self.inner.take() else {
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
        // Smoke-test Sentry itself by turning it on and off a couple times
        {
            let mut tele = Telemetry::default();

            // Expect no telemetry because the telemetry module needs to be enabled before it can do anything
            negative_error("X7X4CKH3");

            tele.set_enabled(true);
            // Expect telemetry because the user opted in.
            error("QELADAGH");
            tele.set_enabled(false);

            // Expect no telemetry because the user opted back out.
            negative_error("2RSIYAPX");

            tele.set_enabled(true);
            // Cycle one more time to be sure.
            error("S672IOBZ");
            tele.close();

            // Expect no telemetry after the module is closed.
            negative_error("W57GJKUO");
        }

        // Test starting up with the choice opted-in
        {
            {
                let mut tele = Telemetry::default();
                negative_error("4H7HFTNX");
                tele.set_enabled(true);
            }
            {
                negative_error("GF46D6IL");
                let mut tele = Telemetry::default();
                tele.set_enabled(true);
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

use anyhow::{Context as _, Result};
use arc_swap::ArcSwapOption;
use atomicwrites::{AtomicFile, OverwriteBehavior};
use serde::{Deserialize, Serialize};
use std::{fs, io::Write as _, path::PathBuf, sync::Arc, time::Duration};

// TODO: Dynamic DSN
const DSN: &str = "https://db4f1661daac806240fce8bcec36fa2a@o4507971108339712.ingest.us.sentry.io/4507980445908992";

struct Telemetry {
    inner: ArcSwapOption<sentry::ClientInitGuard>,
}

impl Telemetry {
    /// Reads the choice file and starts sentry.io if needed
    ///
    /// If any errors happen, then we don't start sentry.io.
    pub fn new() -> Self {
        let this = Self {
            inner: Default::default(),
        };
        let choice = get().unwrap_or_default();
        if choice.enabled {
            this.start_sentry();
        }
        this
    }

    /// Flushes events to sentry.io and drops the guard.
    /// Any calls to other methods are invalid after this.
    pub fn close(&self) {
        self.stop_sentry()
    }

    /// Allows users to opt in or out arbitrarily at run time.
    pub fn set_enabled(&self, enabled: bool) -> Result<()> {
        if enabled {
            self.start_sentry()
        } else {
            self.stop_sentry()
        }
        set(Choice { enabled })?;
        Ok(())
    }

    fn start_sentry(&self) {
        let inner = sentry::init((
            DSN,
            sentry::ClientOptions {
                release: sentry::release_name!(),
                ..Default::default()
            },
        ));
        self.inner.swap(Some(Arc::new(inner)));
        sentry::start_session();
    }

    fn stop_sentry(&self) {
        let inner = self.inner.swap(None);
        if let Some(inner) = inner {
            sentry::end_session();
            if !inner.flush(Some(Duration::from_secs(5))) {
                tracing::error!("Failed to flush telemetry events to sentry.io");
            }
        }
    }
}

/// Returns the user's choice for telemetry.
fn get() -> Result<Choice> {
    let path = path()?;
    let text = fs::read_to_string(path)?;
    Ok(serde_json::from_str(&text)?)
}

fn set(choice: Choice) -> Result<()> {
    let path = path()?;
    let dir = path
        .parent()
        .context("telemetry choice path should always have a parent")?;
    fs::create_dir_all(dir)?;

    let f = AtomicFile::new(&path, OverwriteBehavior::AllowOverwrite);
    f.write(|f| f.write_all(serde_json::to_string(&choice)?.as_bytes()))?;

    Ok(())
}

/// Represents the users's choice(s) for opt-in telemetry.
///
/// If we want something like "Turn on telemetry for only 1 week"
/// in the future, we can add it in here.
#[derive(Default, Deserialize, Serialize)]
struct Choice {
    /// If true, use sentry.io for telemetry.
    ///
    /// Must default to false if the file is not present or the user hasn't made a choice yet.
    enabled: bool,
}

fn path() -> Result<PathBuf> {
    let dir =
        firezone_headless_client::known_dirs::session().context("Couldn't find session dir")?;
    Ok(dir.join("telemetry_choice.txt"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::anyhow;

    // Mutates the choice file.
    //
    // To avoid problems with global mutable state, we run unrelated tests in the same test case.
    #[test]
    fn sentry() {
        // Smoke-test Sentry itself by turning it on and off a couple times
        {
            reset_choice();
            let tele = Telemetry::new();

            // Expect no telemetry because we reset the choice file
            negative_error("X7X4CKH3");

            tele.set_enabled(true).unwrap();
            // Expect telemetry because the user opted in.
            error("QELADAGH");
            tele.set_enabled(false).unwrap();

            // Expect no telemetry because the user opted back out.
            negative_error("2RSIYAPX");

            tele.set_enabled(true).unwrap();
            // Cycle one more time to be sure.
            error("S672IOBZ");
            tele.close();

            // Expect no telemetry after the module is closed.
            negative_error("W57GJKUO");
        }

        // Test starting up with the choice opted-in
        {
            reset_choice();
            // Error because the file is missing
            assert!(get().is_err());
            {
                let tele = Telemetry::new();
                negative_error("4H7HFTNX");
                tele.set_enabled(true);
            }
            {
                negative_error("GF46D6IL");
                let _tele = Telemetry::new();
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

    fn reset_choice() {
        fs::remove_file(path().unwrap()).ok();
    }
}

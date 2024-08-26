//! Module to check the Github repo for new releases

use crate::client::{
    about::get_cargo_version,
    gui::{ControllerRequest, CtlrTx},
};
use anyhow::{Context, Result};
use rand::{thread_rng, Rng as _};
use semver::Version;
use serde::{Deserialize, Serialize};
use std::{io::Write, path::PathBuf, str::FromStr, time::Duration};
use url::Url;

/// GUI-friendly release struct
///
/// Serialize is derived for debugging
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub(crate) struct Release {
    pub download_url: url::Url,
    pub version: Version,
}

pub(crate) async fn checker_task(ctlr_tx: CtlrTx) -> Result<()> {
    let mut fsm = Checker::new(current_version()?);
    let interval_in_seconds = 86_400;
    let mut interval = tokio::time::interval(Duration::from_secs(interval_in_seconds));
    let rand_time = thread_rng().gen_range(0..interval_in_seconds);

    loop {
        match fsm.poll() {
            CheckerStep::CheckFile => match read_latest_release_file().await {
                None => fsm.handle_failed_check(),
                Some(release) => {
                    if let Some(release) = fsm.handle_check(release) {
                        ctlr_tx
                            .send(ControllerRequest::UpdateAvailable(release))
                            .await?;
                    }
                }
            },
            CheckerStep::WaitRandom => {
                tokio::time::sleep(Duration::from_secs(rand_time)).await;
                interval.reset();
                fsm.handle_wake();
            }
            CheckerStep::CheckNetwork => {
                let release = match check().await {
                    Ok(x) => x,
                    Err(error) => {
                        tracing::error!(?error, "Couldn't check website for update");
                        fsm.handle_failed_check();
                        continue;
                    }
                };
                if let Some(release) = fsm.handle_check(release) {
                    ctlr_tx
                        .send(ControllerRequest::UpdateAvailable(release.clone()))
                        .await?;
                    write_latest_release_file(release).await?;
                }
            }
            CheckerStep::WaitInterval => {
                interval.tick().await;
                fsm.handle_wake();
            }
        }
    }
}

async fn read_latest_release_file() -> Option<Release> {
    tokio::fs::read_to_string(version_file_path().ok()?)
        .await
        .ok()
        .as_deref()
        .map(serde_json::from_str)
        .transpose()
        .ok()
        .flatten()
}

async fn write_latest_release_file(release: Release) -> Result<()> {
    // `atomicwrites` is sync so use `spawn_blocking` so we don't block an
    // executor thread
    tokio::task::spawn_blocking(move || {
        let f = atomicwrites::AtomicFile::new(
            version_file_path()?,
            atomicwrites::OverwriteBehavior::AllowOverwrite,
        );
        f.write(|f| f.write_all(serde_json::to_string(&release)?.as_bytes()))?;
        Ok::<_, anyhow::Error>(())
    })
    .await??;
    Ok(())
}

struct Checker {
    latest_seen: Option<Version>,
    ours: Version,
    state: CheckerStep,
}

/// Output events for I/O and internal state of the update checker state machine.
///
/// The machine is simple enough that they happen to be identical:
///
/// - CheckFile
/// - WaitRandom
/// - CheckNetwork
/// - WaitInterval
/// - (Loop back to CheckNetwork)
#[derive(Clone, Copy)]
enum CheckerStep {
    /// Check the disk to see what was the latest version we remember seeing.
    /// This allows us to show the notification quicker without hitting the network right at startup.
    CheckFile,
    /// Wait a random amount of time to break up thundering herds.
    WaitRandom,
    /// Check the latest version from the Firezone website and write it to disk.
    CheckNetwork,
    /// Wait approximately a day using `tokio::time::interval`.
    WaitInterval,
}

impl Checker {
    fn new(ours: Version) -> Self {
        Self {
            latest_seen: None,
            ours,
            state: CheckerStep::CheckFile,
        }
    }

    /// Call this when we just checked the network or the file
    ///
    /// Returns the release if we should alert the UI about this release
    #[must_use]
    fn handle_check(&mut self, release: Release) -> Option<Release> {
        match self.state {
            // After startup and checking the file, wait a random amount of time.
            CheckerStep::CheckFile => self.state = CheckerStep::WaitRandom,
            // Always wait a full interval after a network check
            CheckerStep::CheckNetwork => self.state = CheckerStep::WaitInterval,
            // If we weren't waiting on an I/O check, something is wrong
            CheckerStep::WaitRandom | CheckerStep::WaitInterval => {
                panic!("Impossible, got `handle_check` when update checker was waiting for wakeup")
            }
        }

        let newer_than_ours = release.version > self.ours;
        let newer_than_latest_seen = match &self.latest_seen {
            None => true,
            Some(latest_seen) => release.version > *latest_seen,
        };
        self.latest_seen = Some(release.version.clone());
        if newer_than_ours && newer_than_latest_seen {
            Some(release)
        } else {
            None
        }
    }

    /// Call this when the file is missing or invalid, or the network response is invalid or the network is unreachable.
    fn handle_failed_check(&mut self) {
        match self.state {
            // After startup and checking the file, wait a random amount of time.
            CheckerStep::CheckFile => self.state = CheckerStep::WaitRandom,
            // Always wait a full interval after a network check
            CheckerStep::CheckNetwork => self.state = CheckerStep::WaitInterval,
            // If we weren't waiting on an I/O check, something is wrong
            CheckerStep::WaitRandom | CheckerStep::WaitInterval => {
                panic!("Impossible, got `handle_failed_check` when update checker was waiting for wakeup")
            }
        }
    }

    /// Call this when we just woke up from sleeping
    fn handle_wake(&mut self) {
        match self.state {
            CheckerStep::CheckFile | CheckerStep::CheckNetwork => {
                panic!("Impossible, got `handle_wake` when update checker was waiting for I/O")
            }
            CheckerStep::WaitRandom | CheckerStep::WaitInterval => {
                self.state = CheckerStep::CheckNetwork
            }
        }
    }

    fn poll(&self) -> CheckerStep {
        self.state
    }
}

fn version_file_path() -> Result<PathBuf> {
    Ok(firezone_headless_client::known_dirs::session()
        .context("Couldn't find session dir")?
        .join("latest_version_seen.txt"))
}

/// Returns the latest release, even if ours is already newer
pub(crate) async fn check() -> Result<Release> {
    // Don't follow any redirects, just tell us what the Firezone site says the URL is
    // If we follow multiple redirects, we'll end up with a messier URL like
    // ```
    // https://objects.githubusercontent.com/github-production-release-asset-2e65be/257787813/b3816cc1-87e4-42ae-b354-2dbb7f98721c?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=releaseassetproduction%2F20240627%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20240627T210330Z&X-Amz-Expires=300&X-Amz-Signature=fd367bcdc7e64ffac0b318ab710dd5f673dd5b5ac3a9ccdc621adf5d304df557&X-Amz-SignedHeaders=host&actor_id=0&key_id=0&repo_id=257787813&response-content-disposition=attachment%3B%20filename%3Dfirezone-client-gui-windows_1.1.0_x86_64.msi&response-content-type=application%2Foctet-stream
    // ```
    // The version number is still in there, but it's easier to just disable redirects
    // and parse the number from the Firezone website, instead of making multiple HTTP requests
    // and then hoping Github and Amazon's APIs don't change.
    //
    // When we need to do auto-updates later, we can leave redirects enabled for those.
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()?;
    let arch = std::env::consts::ARCH;
    let os = std::env::consts::OS;

    // We used to send this to Github, couldn't hurt to send it to our own site, too
    let user_agent = format!("Firezone Client/{:?} ({os}; {arch})", current_version());

    let mut update_url = url::Url::parse("https://www.firezone.dev")
        .context("Impossible: Hard-coded URL should always be parsable")?;
    update_url.set_path(&format!("/dl/firezone-client-gui-{os}/latest/{arch}"));

    let response = client
        .head(update_url.clone())
        .header("User-Agent", user_agent)
        .send()
        .await?;
    let status = response.status();
    if status != reqwest::StatusCode::TEMPORARY_REDIRECT {
        anyhow::bail!("HTTP status: {status} from update URL `{update_url}`");
    }
    let download_url = response
        .headers()
        .get(reqwest::header::LOCATION)
        .context("this URL should always have a redirect")?
        .to_str()?;
    tracing::debug!(?download_url);
    let download_url = Url::parse(download_url)?;
    let version = parse_version_from_url(&download_url)?;
    Ok(Release {
        download_url,
        version,
    })
}

#[allow(clippy::print_stderr)]
fn parse_version_from_url(url: &Url) -> Result<Version> {
    let filename = url
        .path_segments()
        .context("URL must have a path")?
        .last()
        .context("URL path must have a last segment")?;
    let version_str = filename
        .split('_')
        .nth(1)
        .context("Filename must have 3 parts separated by underscores")?;
    Ok(Version::parse(version_str)?)
}

pub(crate) fn current_version() -> Result<Version> {
    Version::from_str(&get_cargo_version()).context("Impossible, our version is invalid")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checker_happy_path() {
        let mut fsm = Checker::new(Version::new(1, 0, 0));
        assert!(matches!(fsm.poll(), CheckerStep::CheckFile));

        // We check the file and there's no file, this is a new system, so do nothing
        fsm.handle_failed_check();

        // We don't check the network right at startup, we wait first
        assert!(matches!(fsm.poll(), CheckerStep::WaitRandom));

        fsm.handle_wake();

        // After waking we always check the network
        assert!(matches!(fsm.poll(), CheckerStep::CheckNetwork));

        // We check the network and the network's down, so do nothing
        fsm.handle_failed_check();

        // After network checks we always sleep a full interval
        assert!(matches!(fsm.poll(), CheckerStep::WaitInterval));

        // Tell the checker when we wake up
        fsm.handle_wake();

        // Back to step 1
        assert!(matches!(fsm.poll(), CheckerStep::CheckNetwork));

        // We're on the latest version, so do nothing
        assert_eq!(fsm.handle_check(release(1, 0, 0)), None);
        assert!(matches!(fsm.poll(), CheckerStep::WaitInterval));
        fsm.handle_wake();
        assert!(matches!(fsm.poll(), CheckerStep::CheckNetwork));

        // There's a new version, so tell the UI
        assert_eq!(fsm.handle_check(release(1, 0, 1)), Some(release(1, 0, 1)));
        assert!(matches!(fsm.poll(), CheckerStep::WaitInterval));
        fsm.handle_wake();
        assert!(matches!(fsm.poll(), CheckerStep::CheckNetwork));

        // We already told the UI about this version, don't tell it again.
        assert_eq!(fsm.handle_check(release(1, 0, 1)), None);
        assert!(matches!(fsm.poll(), CheckerStep::WaitInterval));
        fsm.handle_wake();
        assert!(matches!(fsm.poll(), CheckerStep::CheckNetwork));

        // There's an even newer version, so tell the UI
        assert_eq!(fsm.handle_check(release(1, 0, 2)), Some(release(1, 0, 2)));
    }

    #[test]
    fn checker_existing_system() {
        let mut fsm = Checker::new(Version::new(1, 0, 0));
        assert!(matches!(fsm.poll(), CheckerStep::CheckFile));

        // We check the file and we're already up to date, so do nothing
        assert_eq!(fsm.handle_check(release(1, 0, 0)), None);
        assert!(matches!(fsm.poll(), CheckerStep::WaitRandom));
        fsm.handle_wake();
        assert!(matches!(fsm.poll(), CheckerStep::CheckNetwork));

        // We're on the latest version, so do nothing
        assert_eq!(fsm.handle_check(release(1, 0, 0)), None);
        assert!(matches!(fsm.poll(), CheckerStep::WaitInterval));
        fsm.handle_wake();
        assert!(matches!(fsm.poll(), CheckerStep::CheckNetwork));
    }

    #[test]
    fn checker_ignored_update() {
        let mut fsm = Checker::new(Version::new(1, 0, 0));
        assert!(matches!(fsm.poll(), CheckerStep::CheckFile));

        // We check the file and Firezone has restarted when we already knew about an update, so immediately notify
        assert_eq!(fsm.handle_check(release(1, 0, 1)), Some(release(1, 0, 1)));
        assert!(matches!(fsm.poll(), CheckerStep::WaitRandom));
        fsm.handle_wake();
        assert!(matches!(fsm.poll(), CheckerStep::CheckNetwork));

        // We already notified, don't notify again
        assert_eq!(fsm.handle_check(release(1, 0, 1)), None);
        assert!(matches!(fsm.poll(), CheckerStep::WaitInterval));
        fsm.handle_wake();
        assert!(matches!(fsm.poll(), CheckerStep::CheckNetwork));

        // There's an even newer version, so tell the UI
        assert_eq!(fsm.handle_check(release(1, 0, 2)), Some(release(1, 0, 2)));
    }

    fn release(major: u64, minor: u64, patch: u64) -> Release {
        let version = Version::new(major, minor, patch);
        let download_url = format!("https://www.github.com/firezone/firezone/releases/download/{version}/firezone-client-gui-windows_{version}_x86_64.msi");
        let download_url = Url::parse(&download_url).unwrap();
        Release {
            download_url,
            version,
        }
    }

    #[test]
    fn parse_version_from_url() {
        for (input, expected) in [
            ("https://www.github.com/firezone/firezone/releases/download/1.0.0/firezone-client-gui-windows_1.0.0_x86_64.msi", Some((1, 0, 0))),
            ("https://www.github.com/firezone/firezone/releases/download/1.0.1/firezone-client-gui-linux_1.0.1_x86_64.deb", Some((1, 0, 1))),
            ("https://www.github.com/firezone/firezone/releases/download/1.0.1/firezone-client-gui-linux_x86_64.deb", None),
        ] {
            let input = Url::parse(input).unwrap();
            let expected = expected.map(|(a, b, c)| Version::new(a, b, c));
            let actual = super::parse_version_from_url(&input).ok();
            assert_eq!(actual, expected);
        }
    }

    #[test]
    fn pick_asset() {
        let asset_names = [
            "firezone-client-gui-linux_1.0.0-pre.14_aarch64.deb",
            "firezone-client-gui-linux_1.0.0-pre.14_x86_64.deb",
            "firezone-client-gui-windows_1.0.0-pre.14_aarch64.msi",
            "firezone-client-gui-windows_1.0.0-pre.14_x86_64.msi",
            "firezone-client-headless-linux_1.0.0-pre.14_aarch64.deb",
            "firezone-client-headless-linux_1.0.0-pre.14_x86_64.deb",
            "firezone-client-headless-windows_1.0.0-pre.14_aarch64.msi",
            "firezone-client-headless-windows_1.0.0-pre.14_x86_64.msi",
            "firezone-gateway-linux_1.0.0-pre.14_aarch64.deb",
            "firezone-gateway-linux_1.0.0-pre.14_x86_64.deb",
            "firezone-gateway-windows_1.0.0-pre.14_aarch64.msi",
            "firezone-gateway-windows_1.0.0-pre.14_x86_64.msi",
        ];

        let product = "client-gui";
        let arch = "x86_64";
        let os = "windows";
        let package = "msi";

        let prefix = format!("firezone-{product}-{os}_");
        let suffix = format!("_{arch}.{package}");

        let mut iter = asset_names
            .into_iter()
            .filter(|x| x.starts_with(&prefix) && x.ends_with(&suffix));
        let asset_name = iter.next().unwrap();
        assert!(iter.next().is_none());

        assert_eq!(
            asset_name,
            "firezone-client-gui-windows_1.0.0-pre.14_x86_64.msi"
        );
    }
}

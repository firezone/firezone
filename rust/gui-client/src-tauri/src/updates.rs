//! Module to check the Github repo for new releases

use anyhow::{Context, Result};
use rand::{Rng as _, thread_rng};
use semver::Version;
use serde::{Deserialize, Serialize};
use std::{io::Write, path::PathBuf, str::FromStr, time::Duration};
use tokio::sync::mpsc;
use url::Url;

#[derive(Clone, Debug, PartialEq)]
pub struct Notification {
    pub release: Release,
    /// If true, show a pop-up notification and set the dot. If false, only set the dot.
    pub tell_user: bool,
}

/// GUI-friendly release struct
///
/// Serialize is derived for debugging
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct Release {
    pub download_url: url::Url,
    pub version: Version,
}

pub async fn checker_task(
    ctlr_tx: mpsc::Sender<Option<Notification>>,
    debug_mode: bool,
) -> Result<()> {
    let (current_version, interval_in_seconds) = if debug_mode {
        (Version::new(1, 0, 0), 30)
    } else {
        (current_version()?, 86_400)
    };

    // Always check the file first, then wait a random amount of time before entering the loop.
    let latest_seen = read_latest_release_file().await;
    let mut fsm = Checker::new(current_version, latest_seen);
    let mut interval = tokio::time::interval(Duration::from_secs(interval_in_seconds));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        match fsm.poll() {
            Event::CheckNetwork => {
                tracing::debug!("CheckNetwork");
                match check().await {
                    Ok(release) => fsm.handle_check(release),
                    Err(e) => tracing::debug!("Couldn't check website for update: {e:#}"),
                }
            }
            Event::WaitInterval => {
                tracing::debug!("WaitInterval");
                interval.tick().await;
            }
            Event::WaitRandom => {
                tracing::debug!("WaitRandom");
                let rand_time = thread_rng().gen_range(0..interval_in_seconds);
                tokio::time::sleep(Duration::from_secs(rand_time)).await;
                // Discard the first interval, which always elapses instantly
                interval.reset();
            }
            Event::Notify(notification) => {
                tracing::debug!("Notify");
                write_latest_release_file(notification.as_ref().map(|n| &n.release)).await?;
                ctlr_tx.send(notification).await?;
            }
        }
    }
}

/// Reads the latest version and download URL we've seen, from disk
///
/// The URL is not used but the code was near merging so I didn't
/// want to remove it and break compat with my dev systems.
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

async fn write_latest_release_file(release: Option<&Release>) -> Result<()> {
    let path = version_file_path()?;
    let Some(release) = release else {
        let _ = tokio::fs::remove_file(&path).await;
        return Ok(());
    };

    // `atomicwrites` is sync so use `spawn_blocking` so we don't block an
    // executor thread
    let s = serde_json::to_string(release)?;
    tokio::task::spawn_blocking(move || {
        std::fs::create_dir_all(
            path.parent()
                .context("release file path should always have a parent.")?,
        )?;
        let f =
            atomicwrites::AtomicFile::new(&path, atomicwrites::OverwriteBehavior::AllowOverwrite);
        f.write(|f| f.write_all(s.as_bytes()))?;
        Ok::<_, anyhow::Error>(())
    })
    .await??;
    Ok(())
}

struct Checker {
    ours: Version,
    state: State,
    /// The last notification we pushed to the GUI
    notification: Option<Notification>,
    /// Have we changed our desired notification since we last told the GUI about it?
    notification_dirty: bool,
}

#[derive(Debug, PartialEq)]
enum Event {
    /// Check the latest version from the Firezone website and write it to disk.
    CheckNetwork,
    /// Wait approximately a day using `tokio::time::interval`.
    WaitInterval,
    /// Wait a random amount of time up to the full interval, to avoid the thundering herd problem. This is only used at startup.
    WaitRandom,
    /// Set / clear a GUI notification.
    Notify(Option<Notification>),
}

enum State {
    /// Need to check the network.
    CheckNetwork,
    /// Need to wait before the next network check.
    WaitInterval,
    /// Need to wait a random time before the first network check
    WaitRandom,
}

impl Checker {
    fn new(ours: Version, latest_seen: Option<Release>) -> Self {
        let notification = match &latest_seen {
            Some(latest_seen) if latest_seen.version > ours => {
                Some(Notification {
                    release: latest_seen.clone(),
                    // Never show a pop-up right at startup.
                    tell_user: false,
                })
            }
            Some(_) => None,
            None => None,
        };
        let notification_dirty = notification.is_some();

        Self {
            ours,
            state: State::WaitRandom,
            notification,
            notification_dirty,
        }
    }

    /// Call this when we just checked the network
    fn handle_check(&mut self, release: Release) {
        let different_than_latest_notified = match &self.notification {
            None => release.version != self.ours,
            Some(notification) => release.version != notification.release.version,
        };

        if different_than_latest_notified {
            self.notification_dirty = true;
            self.notification = if release.version == self.ours {
                None
            } else {
                Some(Notification {
                    release,
                    tell_user: true,
                })
            };
        }
    }

    #[must_use]
    fn poll(&mut self) -> Event {
        if self.notification_dirty {
            self.notification_dirty = false;
            return Event::Notify(self.notification.clone());
        }
        match self.state {
            State::CheckNetwork => {
                self.state = State::WaitInterval;
                Event::CheckNetwork
            }
            State::WaitInterval => {
                self.state = State::CheckNetwork;
                Event::WaitInterval
            }
            State::WaitRandom => {
                self.state = State::CheckNetwork;
                Event::WaitRandom
            }
        }
    }
}

fn version_file_path() -> Result<PathBuf> {
    Ok(bin_shared::known_dirs::session()
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

fn parse_version_from_url(url: &Url) -> Result<Version> {
    let filename = url
        .path_segments()
        .context("URL must have a path")?
        .next_back()
        .context("URL path must have a last segment")?;
    let version_str = filename
        .split('_')
        .nth(1)
        .context("Filename must have 3 parts separated by underscores")?;
    Ok(Version::parse(version_str)?)
}

pub(crate) fn current_version() -> Result<Version> {
    Version::from_str(env!("CARGO_PKG_VERSION")).context("Impossible, our version is invalid")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checker_happy_path() {
        // There's no file, this is a new system
        let mut fsm = Checker::new(Version::new(1, 0, 0), None);
        // After our initial random sleep we always check the network
        assert_eq!(fsm.poll(), Event::WaitRandom);
        assert_eq!(fsm.poll(), Event::CheckNetwork);

        // We check the network and the network's down, so do nothing

        // After network checks we always sleep a full interval
        assert_eq!(fsm.poll(), Event::WaitInterval);

        // Back to step 1
        assert_eq!(fsm.poll(), Event::CheckNetwork);

        // We're on the latest version, so do nothing
        fsm.handle_check(release(1, 0, 0));
        assert_eq!(fsm.poll(), Event::WaitInterval);
        assert_eq!(fsm.poll(), Event::CheckNetwork);

        // There's a new version, so tell the UI
        fsm.handle_check(release(1, 0, 1));
        assert_eq!(fsm.poll(), Event::Notify(Some(notification(1, 0, 1))));
        assert_eq!(fsm.poll(), Event::WaitInterval);
        assert_eq!(fsm.poll(), Event::CheckNetwork);

        // We already told the UI about this version, don't tell it again.
        fsm.handle_check(release(1, 0, 1));
        assert_eq!(fsm.poll(), Event::WaitInterval);
        assert_eq!(fsm.poll(), Event::CheckNetwork);

        // There's an even newer version, so tell the UI
        fsm.handle_check(release(1, 0, 2));
        assert_eq!(fsm.poll(), Event::Notify(Some(notification(1, 0, 2))));
    }

    #[test]
    fn checker_existing_system() {
        // We check the file and we're already up to date, so do nothing
        let mut fsm = Checker::new(Version::new(1, 0, 0), Some(release(1, 0, 0)));
        assert_eq!(fsm.poll(), Event::WaitRandom);
        assert_eq!(fsm.poll(), Event::CheckNetwork);

        // We're on the latest version, so do nothing
        fsm.handle_check(release(1, 0, 0));
        assert_eq!(fsm.poll(), Event::WaitInterval);
        assert_eq!(fsm.poll(), Event::CheckNetwork);
    }

    #[test]
    fn checker_ignored_update() {
        // We check the file and Firezone has restarted when we already knew about an update, but we don't tell the user for that, we just show the dot
        let mut fsm = Checker::new(Version::new(1, 0, 0), Some(release(1, 0, 1)));
        assert_eq!(
            fsm.poll(),
            Event::Notify(Some(Notification {
                release: release(1, 0, 1),
                tell_user: false,
            }))
        );
        assert_eq!(fsm.poll(), Event::WaitRandom);
        assert_eq!(fsm.poll(), Event::CheckNetwork);

        // Don't notify since we already have the dot up.
        fsm.handle_check(release(1, 0, 1));
        assert_eq!(fsm.poll(), Event::WaitInterval);
        assert_eq!(fsm.poll(), Event::CheckNetwork);

        // There's an even newer version, so tell the user
        fsm.handle_check(release(1, 0, 2));
        assert_eq!(fsm.poll(), Event::Notify(Some(notification(1, 0, 2))));
    }

    #[test]
    fn checker_rollback() {
        let mut fsm = Checker::new(Version::new(1, 0, 0), Some(release(1, 0, 0)));
        assert_eq!(fsm.poll(), Event::WaitRandom);

        // We first hear about 1.0.2 and notify for that
        assert_eq!(fsm.poll(), Event::CheckNetwork);
        fsm.handle_check(release(1, 0, 2));
        assert_eq!(fsm.poll(), Event::Notify(Some(notification(1, 0, 2))));
        assert_eq!(fsm.poll(), Event::WaitInterval);

        // Then we hear it's actually just 1.0.1, we still notify
        assert_eq!(fsm.poll(), Event::CheckNetwork);
        fsm.handle_check(release(1, 0, 1));
        assert_eq!(fsm.poll(), Event::Notify(Some(notification(1, 0, 1))));
        assert_eq!(fsm.poll(), Event::WaitInterval);

        // When we hear about 1.0.2 again, we notify again.
        assert_eq!(fsm.poll(), Event::CheckNetwork);
        fsm.handle_check(release(1, 0, 2));
        assert_eq!(fsm.poll(), Event::Notify(Some(notification(1, 0, 2))));
        assert_eq!(fsm.poll(), Event::WaitInterval);

        // But if we hear about 1.0.0, our own version, we remove the notification
        assert_eq!(fsm.poll(), Event::CheckNetwork);
        fsm.handle_check(release(1, 0, 0));
        assert_eq!(fsm.poll(), Event::Notify(None));
        assert_eq!(fsm.poll(), Event::WaitInterval);
    }

    fn notification(major: u64, minor: u64, patch: u64) -> Notification {
        Notification {
            release: release(major, minor, patch),
            tell_user: true,
        }
    }

    fn release(major: u64, minor: u64, patch: u64) -> Release {
        let version = Version::new(major, minor, patch);
        let download_url = format!(
            "https://www.github.com/firezone/firezone/releases/download/{version}/firezone-client-gui-windows_{version}_x86_64.msi"
        );
        let download_url = Url::parse(&download_url).unwrap();
        Release {
            download_url,
            version,
        }
    }

    #[test]
    fn parse_version_from_url() {
        for (input, expected) in [
            (
                "https://www.github.com/firezone/firezone/releases/download/1.0.0/firezone-client-gui-windows_1.0.0_x86_64.msi",
                Some((1, 0, 0)),
            ),
            (
                "https://www.github.com/firezone/firezone/releases/download/1.0.1/firezone-client-gui-linux_1.0.1_x86_64.deb",
                Some((1, 0, 1)),
            ),
            (
                "https://www.github.com/firezone/firezone/releases/download/1.0.1/firezone-client-gui-linux_x86_64.deb",
                None,
            ),
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

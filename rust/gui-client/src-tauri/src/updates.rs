//! Module to check the Firezone website API for new releases

use anyhow::{Context, Result};
use rand::RngExt as _;
use semver::Version;
use serde::{Deserialize, Serialize};
use std::{str::FromStr, time::Duration};
use tokio::sync::mpsc;

const BASE_URL: &str = "https://www.firezone.dev";

/// GUI-friendly release struct
///
/// Serialize is derived for debugging
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Release {
    pub download_url: url::Url,
    pub version: Version,
}

/// Response from the /api/releases endpoint
#[derive(Debug, Deserialize)]
struct ApiReleasesResponse {
    gui: Version,
}

/// Periodically checks the website for newer releases and notifies the GUI.
///
/// The last version we notified about is only kept in memory, so the user
/// is reminded about a pending update once per GUI session.
pub async fn checker_task(ctlr_tx: mpsc::Sender<Option<Release>>, debug_mode: bool) -> Result<()> {
    delete_legacy_version_file().await;

    let (current_version, interval_in_seconds) = if debug_mode {
        (Version::new(1, 0, 0), 30)
    } else {
        (current_version()?, 86_400)
    };

    let mut fsm = Checker::new(current_version);
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
                let rand_time = rand::rng().random_range(0..interval_in_seconds);
                tokio::time::sleep(Duration::from_secs(rand_time)).await;
                // Discard the first interval, which always elapses instantly
                interval.reset();
            }
            Event::Notify(notification) => {
                tracing::debug!("Notify");
                ctlr_tx.send(notification).await?;
            }
        }
    }
}

/// Deletes the file where previous versions persisted the last version we notified about.
// TODO: Remove this after a few releases.
async fn delete_legacy_version_file() {
    let Some(path) = known_dirs::session().map(|dir| dir.join("latest_version_seen.txt")) else {
        return;
    };

    match tokio::fs::remove_file(&path).await {
        Ok(()) => tracing::debug!(path = %path.display(), "Deleted legacy version file"),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => tracing::debug!("Failed to delete legacy version file: {e}"),
    }
}

struct Checker {
    ours: Version,
    state: State,
    /// The last release we notified the GUI about
    notification: Option<Release>,
    /// Have we changed our desired notification since we last told the GUI about it?
    notification_dirty: bool,
}

#[derive(Debug, PartialEq)]
enum Event {
    /// Check the latest version from the Firezone website.
    CheckNetwork,
    /// Wait approximately a day using `tokio::time::interval`.
    WaitInterval,
    /// Wait a random amount of time up to the full interval, to avoid the thundering herd problem. This is only used at startup.
    WaitRandom,
    /// Set / clear a GUI notification.
    Notify(Option<Release>),
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
    fn new(ours: Version) -> Self {
        Self {
            ours,
            state: State::WaitRandom,
            notification: None,
            notification_dirty: false,
        }
    }

    /// Call this when we just checked the network
    fn handle_check(&mut self, release: Release) {
        let desired = (release.version > self.ours).then_some(release);

        if desired != self.notification {
            self.notification = desired;
            self.notification_dirty = true;
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

/// Returns the latest release, even if ours is already newer
pub(crate) async fn check() -> Result<Release> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()?;
    let arch = std::env::consts::ARCH;
    let os = std::env::consts::OS;

    let user_agent = format!("Firezone Client/{:?} ({os}; {arch})", current_version());

    let api_url = format!("{BASE_URL}/api/releases");

    let response = client
        .get(&api_url)
        .header("User-Agent", &user_agent)
        .header("Accept", "application/json")
        .send()
        .await?;

    let response_status = response.status();

    if !response_status.is_success() {
        anyhow::bail!("HTTP status: {response_status} from API URL `{api_url}`");
    }

    let api_response: ApiReleasesResponse = response
        .json()
        .await
        .context("Failed to parse JSON response from /api/releases")?;
    let version = api_response.gui;
    tracing::debug!(?version, "Latest GUI version from API");

    let download_url = download_url_for(os, arch, package_suffix(), &version)?;

    Ok(Release {
        download_url,
        version,
    })
}

fn download_url_for(
    os: &str,
    arch: &str,
    package_suffix: &str,
    version: &Version,
) -> Result<url::Url> {
    let url = url::Url::parse(&format!(
        "{BASE_URL}/dl/firezone-client-gui-{os}/{version}/{arch}{package_suffix}"
    ))
    .context("Failed to construct download URL")?;

    Ok(url)
}

/// The package-specific suffix of the download URL.
///
/// Linux is the only OS where a release consists of more than one package
/// format per architecture: a `.deb` and an `.rpm`.
#[cfg(target_os = "linux")]
fn package_suffix() -> &'static str {
    // `/etc/os-release` takes precedence but is allowed to be absent:
    // <https://www.freedesktop.org/software/systemd/man/latest/os-release.html>
    let os_release = std::fs::read_to_string("/etc/os-release")
        .or_else(|_| std::fs::read_to_string("/usr/lib/os-release"));

    match os_release {
        Ok(os_release) if is_rpm_based(&os_release) => ".rpm",
        Ok(_) => ".deb",
        Err(_) => ".deb",
    }
}

#[cfg(not(target_os = "linux"))]
fn package_suffix() -> &'static str {
    ""
}

/// Whether the given [`os-release`] contents describe an RPM-based distribution.
///
/// [`os-release`]: https://www.freedesktop.org/software/systemd/man/latest/os-release.html
#[cfg(target_os = "linux")]
fn is_rpm_based(os_release: &str) -> bool {
    os_release
        .lines()
        .filter_map(|line| line.split_once('='))
        .filter(|(key, _)| matches!(*key, "ID" | "ID_LIKE"))
        .flat_map(|(_, value)| value.trim_matches('"').split_whitespace())
        .any(|id| matches!(id, "fedora" | "rhel" | "centos" | "suse") || id.starts_with("opensuse"))
}

pub(crate) fn current_version() -> Result<Version> {
    Version::from_str(env!("CARGO_PKG_VERSION")).context("Impossible, our version is invalid")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checker_happy_path() {
        let mut fsm = Checker::new(Version::new(1, 0, 0));
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
        assert_eq!(fsm.poll(), Event::Notify(Some(release(1, 0, 1))));
        assert_eq!(fsm.poll(), Event::WaitInterval);
        assert_eq!(fsm.poll(), Event::CheckNetwork);

        // We already told the UI about this version, don't tell it again.
        fsm.handle_check(release(1, 0, 1));
        assert_eq!(fsm.poll(), Event::WaitInterval);
        assert_eq!(fsm.poll(), Event::CheckNetwork);

        // There's an even newer version, so tell the UI
        fsm.handle_check(release(1, 0, 2));
        assert_eq!(fsm.poll(), Event::Notify(Some(release(1, 0, 2))));
    }

    #[test]
    fn checker_rollback() {
        let mut fsm = Checker::new(Version::new(1, 0, 0));
        assert_eq!(fsm.poll(), Event::WaitRandom);

        // We first hear about 1.0.2 and notify for that
        assert_eq!(fsm.poll(), Event::CheckNetwork);
        fsm.handle_check(release(1, 0, 2));
        assert_eq!(fsm.poll(), Event::Notify(Some(release(1, 0, 2))));
        assert_eq!(fsm.poll(), Event::WaitInterval);

        // Then we hear it's actually just 1.0.1, we still notify
        assert_eq!(fsm.poll(), Event::CheckNetwork);
        fsm.handle_check(release(1, 0, 1));
        assert_eq!(fsm.poll(), Event::Notify(Some(release(1, 0, 1))));
        assert_eq!(fsm.poll(), Event::WaitInterval);

        // When we hear about 1.0.2 again, we notify again.
        assert_eq!(fsm.poll(), Event::CheckNetwork);
        fsm.handle_check(release(1, 0, 2));
        assert_eq!(fsm.poll(), Event::Notify(Some(release(1, 0, 2))));
        assert_eq!(fsm.poll(), Event::WaitInterval);

        // But if we hear about 1.0.0, our own version, we remove the notification
        assert_eq!(fsm.poll(), Event::CheckNetwork);
        fsm.handle_check(release(1, 0, 0));
        assert_eq!(fsm.poll(), Event::Notify(None));
        assert_eq!(fsm.poll(), Event::WaitInterval);
    }

    #[test]
    fn checker_ignores_older_release() {
        let mut fsm = Checker::new(Version::new(1, 0, 1));
        assert_eq!(fsm.poll(), Event::WaitRandom);
        assert_eq!(fsm.poll(), Event::CheckNetwork);

        // The website may advertise an older release than ours, e.g. right after we shipped a new one; don't notify.
        fsm.handle_check(release(1, 0, 0));
        assert_eq!(fsm.poll(), Event::WaitInterval);
    }

    fn release(major: u64, minor: u64, patch: u64) -> Release {
        let version = Version::new(major, minor, patch);
        let arch = std::env::consts::ARCH;
        let os = std::env::consts::OS;
        let download_url = url::Url::parse(&format!(
            "{BASE_URL}/dl/firezone-client-gui-{os}/{version}/{arch}"
        ))
        .unwrap();
        Release {
            download_url,
            version,
        }
    }

    #[test]
    fn api_releases_response_parsing() {
        // Test that we can parse a valid JSON response with the "gui" field
        let json_str = r#"{"apple":"1.2.3","android":"1.2.4","gui":"1.5.9","headless":"1.5.6","gateway":"1.4.19"}"#;
        let response: ApiReleasesResponse = serde_json::from_str(json_str).unwrap();

        assert_eq!(response.gui, Version::new(1, 5, 9));
    }

    #[test]
    fn api_releases_response_missing_gui_field() {
        // Test that we handle missing "gui" field appropriately
        let json_str = r#"{"apple":"1.2.3","android":"1.2.4"}"#;
        let result: Result<ApiReleasesResponse, _> = serde_json::from_str(json_str);

        assert!(result.is_err());
    }

    #[test]
    fn download_url_construction() {
        assert_eq!(
            download_url_for("windows", "x86_64", "", &Version::new(1, 5, 9))
                .unwrap()
                .as_str(),
            "https://www.firezone.dev/dl/firezone-client-gui-windows/1.5.9/x86_64"
        );
        assert_eq!(
            download_url_for("linux", "x86_64", ".rpm", &Version::new(1, 5, 9))
                .unwrap()
                .as_str(),
            "https://www.firezone.dev/dl/firezone-client-gui-linux/1.5.9/x86_64.rpm"
        );
        assert_eq!(
            download_url_for("linux", "aarch64", ".deb", &Version::new(1, 5, 9))
                .unwrap()
                .as_str(),
            "https://www.firezone.dev/dl/firezone-client-gui-linux/1.5.9/aarch64.deb"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn rpm_detection() {
        // Fedora has no `ID_LIKE`.
        assert!(is_rpm_based("NAME=\"Fedora Linux\"\nID=fedora\n"));
        // Derivatives reference their ancestry via `ID_LIKE`.
        assert!(is_rpm_based(
            "ID=\"rocky\"\nID_LIKE=\"rhel centos fedora\"\n"
        ));
        assert!(is_rpm_based(
            "ID=\"opensuse-tumbleweed\"\nID_LIKE=\"opensuse suse\"\n"
        ));
        assert!(is_rpm_based(
            "ID=almalinux\nID_LIKE=\"rhel centos fedora\"\n"
        ));

        assert!(!is_rpm_based("ID=ubuntu\nID_LIKE=debian\n"));
        assert!(!is_rpm_based("ID=debian\n"));
        assert!(!is_rpm_based(""));
    }
}

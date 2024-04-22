//! Module to check the Github repo for new releases

use crate::client::about::get_cargo_version;
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::str::FromStr;
use url::Url;

/// GUI-friendly release struct
///
/// Serialize is derived for debugging
#[derive(Deserialize, Serialize)]
pub(crate) struct Release {
    /// All assets in a given release
    assets: Vec<Asset>,
    /// Git tag name
    ///
    /// e.g. 1.0.0-pre.8
    pub tag_name: semver::Version,
}

#[derive(Deserialize, Serialize)]
struct Asset {
    browser_download_url: Url,
    /// Name of the asset, e.g. `firezone-client-gui-windows-x86_64.msi`
    name: String,
}

impl Release {
    /// Download URL for current OS and arch
    pub fn download_url(&self) -> Option<&Url> {
        self.download_url_for(std::env::consts::ARCH, std::env::consts::OS)
    }

    /// Download URL for the first asset that matches the given arch, OS, and package type
    fn download_url_for(&self, arch: &str, os: &str) -> Option<&Url> {
        let package = match os {
            "linux" => "deb",
            "macos" => "dmg", // Unused in practice
            "windows" => "msi",
            _ => panic!("Don't know what package this OS uses"),
        };

        let prefix = format!("firezone-client-gui-{os}_");
        let suffix = format!("_{arch}.{package}");

        let mut iter = self
            .assets
            .iter()
            .filter(|x| x.name.starts_with(&prefix) && x.name.ends_with(&suffix));
        iter.next().map(|asset| &asset.browser_download_url)
    }
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum Error {
    #[error(transparent)]
    JsonParse(#[from] serde_json::Error),
    #[error("Our own semver in the exe is invalid, this should be impossible")]
    OurVersionIsInvalid(semver::Error),
    #[error(transparent)]
    Request(#[from] reqwest::Error),
}

const LATEST_RELEASE_API_URL: &str =
    "https://api.github.com/repos/firezone/firezone/releases/latest";

/// <https://docs.github.com/en/rest/about-the-rest-api/api-versions?apiVersion=2022-11-28>
const GITHUB_API_VERSION: &str = "2022-11-28";

/// Returns the latest release, even if ours is already newer
pub(crate) async fn check() -> Result<Release> {
    let client = reqwest::Client::builder().build()?;
    let arch = std::env::consts::ARCH;
    let os = std::env::consts::OS;

    // <https://docs.github.com/en/rest/using-the-rest-api/getting-started-with-the-rest-api?apiVersion=2022-11-28#user-agent-required>
    let user_agent = format!("Firezone Client/{:?} ({os}; {arch})", current_version());

    // Reqwest follows up to 10 redirects by default
    // https://docs.rs/reqwest/latest/reqwest/struct.ClientBuilder.html#method.redirect
    // https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api?apiVersion=2022-11-28#follow-redirects
    let response = client
        .get(LATEST_RELEASE_API_URL)
        .header("User-Agent", user_agent)
        .header("X-GitHub-Api-Version", GITHUB_API_VERSION)
        .send()
        .await?;
    let status = response.status();
    if status != reqwest::StatusCode::OK {
        anyhow::bail!("HTTP status: {status}");
    }

    let response = response.text().await?;
    Ok(serde_json::from_str(&response)?)
}

// TODO: DRY with about.rs
pub(crate) fn current_version() -> Result<semver::Version, Error> {
    semver::Version::from_str(&get_cargo_version()).map_err(Error::OurVersionIsInvalid)
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    #[test]
    fn new_format() {
        let s = r#"
        {
            "tag_name": "1.0.0-pre.14",
            "assets": [
                {
                    "name": "firezone-client-gui-linux_1.0.0-pre.14_aarch64.deb",
                    "browser_download_url": "https://github.com/firezone/firezone/releases/download/1.0.0-pre.14/firezone-client-gui-linux_1.0.0-pre.14_aarch64.deb"
                },
                {
                    "name": "firezone-client-gui-linux_1.0.0-pre.14_x86_64.deb",
                    "browser_download_url": "https://github.com/firezone/firezone/releases/download/1.0.0-pre.14/firezone-client-gui-linux_1.0.0-pre.14_x86_64.deb"
                },
                {
                    "name": "firezone-client-gui-windows_1.0.0-pre.14_aarch64.msi",
                    "browser_download_url": "https://github.com/firezone/firezone/releases/download/1.0.0-pre.14/firezone-client-gui-windows_1.0.0-pre.14_aarch64.msi"
                },
                {
                    "name": "firezone-client-gui-windows_1.0.0-pre.14_x86_64.msi",
                    "browser_download_url": "https://github.com/firezone/firezone/releases/download/1.0.0-pre.14/firezone-client-gui-windows_1.0.0-pre.14_x86_64.msi"
                },

                {
                    "name": "firezone-client-headless-linux_1.0.0-pre.14_aarch64.deb",
                    "browser_download_url": "https://github.com/firezone/firezone/releases/download/1.0.0-pre.14/firezone-client-headless-linux_1.0.0-pre.14_aarch64.deb"
                },
                {
                    "name": "firezone-client-headless-linux_1.0.0-pre.14_x86_64.deb",
                    "browser_download_url": "https://github.com/firezone/firezone/releases/download/1.0.0-pre.14/firezone-client-headless-linux_1.0.0-pre.14_x86_64.deb"
                },
                {
                    "name": "firezone-client-headless-windows_1.0.0-pre.14_aarch64.msi",
                    "browser_download_url": "https://github.com/firezone/firezone/releases/download/1.0.0-pre.14/firezone-client-headless-windows_1.0.0-pre.14_aarch64.msi"
                },
                {
                    "name": "firezone-client-headless-windows_1.0.0-pre.14_x86_64.msi",
                    "browser_download_url": "https://github.com/firezone/firezone/releases/download/1.0.0-pre.14/firezone-client-headless-windows_1.0.0-pre.14_x86_64.msi"
                }
            ]
        }"#;

        let release: super::Release = serde_json::from_str(s).unwrap();
        let expected_url = "https://github.com/firezone/firezone/releases/download/1.0.0-pre.14/firezone-client-gui-windows_1.0.0-pre.14_x86_64.msi";
        assert_eq!(
            release
                .download_url_for("x86_64", "windows")
                .unwrap()
                .to_string(),
            expected_url
        );
        assert_eq!(release.tag_name.to_string(), "1.0.0-pre.14");

        assert!(
            semver::Version::from_str("1.0.0").unwrap()
                > semver::Version::from_str("1.0.0-pre.14").unwrap()
        );
        assert!(
            semver::Version::from_str("1.0.0-pre.14").unwrap()
                > semver::Version::from_str("0.7.0").unwrap()
        );

        assert!(super::current_version().is_ok());
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

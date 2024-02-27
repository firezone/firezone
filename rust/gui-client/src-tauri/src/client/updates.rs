//! Module to check the Github repo for new releases

use crate::client::about::get_cargo_version;
use std::{fmt, str::FromStr};
use url::Url;

/// GUI-friendly release struct
#[derive(serde::Serialize)]
pub(crate) struct Release {
    /// URL that will instantly try to download the MSI to disk
    ///
    /// e.g. <https://github.com/firezone/firezone/releases/download/1.0.0-pre.8/gui-client-x64.msi>
    pub browser_download_url: Url,
    /// Git tag name
    ///
    /// e.g. 1.0.0-pre.8
    pub tag_name: semver::Version,
}

impl Release {
    /// Parses the release JSON, finds the MSI asset, and returns info about the latest MSI
    fn from_str(s: &str) -> Result<Self, Error> {
        let ReleaseDetails { assets, tag_name } = serde_json::from_str(s)?;
        let asset = assets
            .into_iter()
            .find(|asset| asset.name == ASSET_NAME)
            .ok_or(Error::NoSuchAsset)?;

        Ok(Release {
            browser_download_url: asset.browser_download_url,
            tag_name,
        })
    }
}

impl fmt::Debug for Release {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Release")
            .field(
                "browser_download_url",
                &self.browser_download_url.to_string(),
            )
            .field("tag_name", &self.tag_name.to_string())
            .finish()
    }
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum Error {
    #[error("Non-OK HTTP status")]
    HttpStatus(reqwest::StatusCode),
    #[error(transparent)]
    JsonParse(#[from] serde_json::Error),
    #[error("No such asset `{ASSET_NAME}` in the latest release")]
    NoSuchAsset,
    #[error("Our own semver in the exe is invalid, this should be impossible")]
    OurVersionIsInvalid(semver::Error),
    #[error(transparent)]
    Request(#[from] reqwest::Error),
}

const LATEST_RELEASE_API_URL: &str =
    "https://api.github.com/repos/firezone/firezone/releases/latest";

/// <https://docs.github.com/en/rest/about-the-rest-api/api-versions?apiVersion=2022-11-28>
const GITHUB_API_VERSION: &str = "2022-11-28";

/// The name of the Windows MSI asset.
///
/// This ultimately comes from `cd.yml`, `git grep WCPYPXZF`
#[cfg(target_os = "linux")]
const ASSET_NAME: &str = "firezone-linux-gui-client_amd64.AppImage";

#[cfg(target_os = "windows")]
const ASSET_NAME: &str = "firezone-windows-client-x64.msi";

/// Returns the latest release, even if ours is already newer
pub(crate) async fn check() -> Result<Release, Error> {
    let client = reqwest::Client::builder().build()?;

    // <https://docs.github.com/en/rest/using-the-rest-api/getting-started-with-the-rest-api?apiVersion=2022-11-28#user-agent-required>
    // This would change for aarch64 support
    let user_agent = format!(
        // TODO: remove 'windows'
        "Firezone Client/{:?} (Windows; Win64; x64)",
        current_version()
    );

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
        return Err(Error::HttpStatus(status));
    }

    let response = response.text().await?;
    Release::from_str(&response)
}

// TODO: DRY with about.rs
pub(crate) fn current_version() -> Result<semver::Version, Error> {
    semver::Version::from_str(&get_cargo_version()).map_err(Error::OurVersionIsInvalid)
}

/// Deserializable struct that matches Github's JSON
#[derive(serde::Deserialize)]
struct ReleaseDetails {
    assets: Vec<Asset>,
    tag_name: semver::Version,
}

#[derive(serde::Deserialize)]
struct Asset {
    browser_download_url: Url,
    /// Name of the asset, e.g. `firezone-windows-client-x64.msi`
    name: String,
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    /// A cut-down example of the real JSON from Github's API
    ///
    /// The real one is about 32 KB, most of which is details about the assets,
    /// so it'll get bigger over time if new assets are added.
    ///
    /// The GraphQL API couldn't be used because it needs a token.
    const RELEASES_LATEST_JSON: &str = r#"
    {
        "url": "https://api.github.com/repos/firezone/firezone/releases/138228264",
        "assets_url": "https://api.github.com/repos/firezone/firezone/releases/138228264/assets",
        "upload_url": "https://uploads.github.com/repos/firezone/firezone/releases/138228264/assets{?name,label}",
        "html_url": "https://github.com/firezone/firezone/releases/tag/1.0.0-pre.8",
        "id": 138228264,
        "author": {
            "login": "github-actions[bot]",
            "id": 41898282,
            "node_id": "MDM6Qm90NDE4OTgyODI=",
            "avatar_url": "https://avatars.githubusercontent.com/in/15368?v=4",
            "gravatar_id": "",
            "url": "https://api.github.com/users/github-actions%5Bbot%5D",
            "html_url": "https://github.com/apps/github-actions",
            "followers_url": "https://api.github.com/users/github-actions%5Bbot%5D/followers",
            "following_url": "https://api.github.com/users/github-actions%5Bbot%5D/following{/other_user}",
            "gists_url": "https://api.github.com/users/github-actions%5Bbot%5D/gists{/gist_id}",
            "starred_url": "https://api.github.com/users/github-actions%5Bbot%5D/starred{/owner}{/repo}",
            "subscriptions_url": "https://api.github.com/users/github-actions%5Bbot%5D/subscriptions",
            "organizations_url": "https://api.github.com/users/github-actions%5Bbot%5D/orgs",
            "repos_url": "https://api.github.com/users/github-actions%5Bbot%5D/repos",
            "events_url": "https://api.github.com/users/github-actions%5Bbot%5D/events{/privacy}",
            "received_events_url": "https://api.github.com/users/github-actions%5Bbot%5D/received_events",
            "type": "Bot",
            "site_admin": false
        },
        "node_id": "RE_kwDOD12Hpc4IPTIo",
        "tag_name": "1.0.0-pre.8",
        "target_commitish": "refs/heads/main",
        "name": "1.0.0-pre.8",
        "draft": false,
        "prerelease": false,
        "created_at": "2024-01-24T00:23:23Z",
        "published_at": "2024-01-24T04:34:44Z",
        "assets": [
            {
                "url": "https://api.github.com/repos/firezone/firezone/releases/assets/147443613",
                "id": 147443613,
                "node_id": "RA_kwDOD12Hpc4Iyc-c",
                "name": "firezone-linux-gui-client_amd64.AppImage",
                "label": "",
                "uploader": {
                    "login": "github-actions[bot]",
                    "id": 41898282,
                    "node_id": "MDM6Qm90NDE4OTgyODI=",
                    "avatar_url": "https://avatars.githubusercontent.com/in/15368?v=4",
                    "gravatar_id": "",
                    "url": "https://api.github.com/users/github-actions%5Bbot%5D",
                    "html_url": "https://github.com/apps/github-actions",
                    "followers_url": "https://api.github.com/users/github-actions%5Bbot%5D/followers",
                    "following_url": "https://api.github.com/users/github-actions%5Bbot%5D/following{/other_user}",
                    "gists_url": "https://api.github.com/users/github-actions%5Bbot%5D/gists{/gist_id}",
                    "starred_url": "https://api.github.com/users/github-actions%5Bbot%5D/starred{/owner}{/repo}",
                    "subscriptions_url": "https://api.github.com/users/github-actions%5Bbot%5D/subscriptions",
                    "organizations_url": "https://api.github.com/users/github-actions%5Bbot%5D/orgs",
                    "repos_url": "https://api.github.com/users/github-actions%5Bbot%5D/repos",
                    "events_url": "https://api.github.com/users/github-actions%5Bbot%5D/events{/privacy}",
                    "received_events_url": "https://api.github.com/users/github-actions%5Bbot%5D/received_events",
                    "type": "Bot",
                    "site_admin": false
                },
                "content_type": "application/octet-stream",
                "state": "uploaded",
                "size": 8376320,
                "download_count": 10,
                "created_at": "2024-01-24T04:33:53Z",
                "updated_at": "2024-01-24T04:33:53Z",
                "browser_download_url": "https://github.com/firezone/firezone/releases/download/1.0.0-pre.8/firezone-linux-gui-client_amd64.AppImage"
            },
            {
                "url": "https://api.github.com/repos/firezone/firezone/releases/assets/147443612",
                "id": 147443612,
                "node_id": "RA_kwDOD12Hpc4Iyc-c",
                "name": "firezone-windows-client-x64.msi",
                "label": "",
                "uploader": {
                    "login": "github-actions[bot]",
                    "id": 41898282,
                    "node_id": "MDM6Qm90NDE4OTgyODI=",
                    "avatar_url": "https://avatars.githubusercontent.com/in/15368?v=4",
                    "gravatar_id": "",
                    "url": "https://api.github.com/users/github-actions%5Bbot%5D",
                    "html_url": "https://github.com/apps/github-actions",
                    "followers_url": "https://api.github.com/users/github-actions%5Bbot%5D/followers",
                    "following_url": "https://api.github.com/users/github-actions%5Bbot%5D/following{/other_user}",
                    "gists_url": "https://api.github.com/users/github-actions%5Bbot%5D/gists{/gist_id}",
                    "starred_url": "https://api.github.com/users/github-actions%5Bbot%5D/starred{/owner}{/repo}",
                    "subscriptions_url": "https://api.github.com/users/github-actions%5Bbot%5D/subscriptions",
                    "organizations_url": "https://api.github.com/users/github-actions%5Bbot%5D/orgs",
                    "repos_url": "https://api.github.com/users/github-actions%5Bbot%5D/repos",
                    "events_url": "https://api.github.com/users/github-actions%5Bbot%5D/events{/privacy}",
                    "received_events_url": "https://api.github.com/users/github-actions%5Bbot%5D/received_events",
                    "type": "Bot",
                    "site_admin": false
                },
                "content_type": "application/octet-stream",
                "state": "uploaded",
                "size": 8376320,
                "download_count": 10,
                "created_at": "2024-01-24T04:33:53Z",
                "updated_at": "2024-01-24T04:33:53Z",
                "browser_download_url": "https://github.com/firezone/firezone/releases/download/1.0.0-pre.8/firezone-windows-client-x64.msi"
            }
        ]
    }"#;

    #[test]
    fn test() {
        let asset_name = super::ASSET_NAME;
        let release = super::Release::from_str(RELEASES_LATEST_JSON).unwrap();
        let expected_url = format!(
            "https://github.com/firezone/firezone/releases/download/1.0.0-pre.8/{asset_name}"
        );
        assert_eq!(release.browser_download_url.to_string(), expected_url);
        assert_eq!(release.tag_name.to_string(), "1.0.0-pre.8");

        assert!(
            semver::Version::from_str("1.0.0").unwrap()
                > semver::Version::from_str("1.0.0-pre.8").unwrap()
        );
        assert!(
            semver::Version::from_str("1.0.0-pre.8").unwrap()
                > semver::Version::from_str("0.7.0").unwrap()
        );

        assert!(super::current_version().is_ok());
    }
}

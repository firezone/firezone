//! Module to check the Github repo for new releases

use crate::client::about::get_cargo_version;
use std::str::FromStr;
use url::Url;

#[derive(Debug, serde::Deserialize)]
pub(crate) struct Release {
    /// e.g. <https://github.com/firezone/firezone/releases/tag/1.0.0-pre.8>
    pub html_url: Url,
    /// e.g. 1.0.0-pre.8
    pub tag_name: semver::Version,
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum Error {
    #[error("Non-OK HTTP status")]
    HttpStatus(reqwest::StatusCode),
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

/// <https://docs.github.com/en/rest/using-the-rest-api/getting-started-with-the-rest-api?apiVersion=2022-11-28#user-agent-required>
const USER_AGENT: &str = "Firezone Windows Client";

/// Returns the latest release, even if ours is already newer
pub(crate) async fn check() -> Result<Release, Error> {
    let client = reqwest::Client::builder().build()?;

    // Reqwest follows up to 10 redirects by default
    // https://docs.rs/reqwest/latest/reqwest/struct.ClientBuilder.html#method.redirect
    // https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api?apiVersion=2022-11-28#follow-redirects
    let response = client
        .get(LATEST_RELEASE_API_URL)
        .header("User-Agent", USER_AGENT)
        .header("X-GitHub-Api-Version", GITHUB_API_VERSION)
        .send()
        .await?;
    let status = response.status();
    if status != reqwest::StatusCode::OK {
        return Err(Error::HttpStatus(status));
    }

    let response = response.text().await?;

    let release: Release = serde_json::from_str(&response)?;
    Ok(release)
}

// TODO: DRY with about.rs
pub(crate) fn get_our_version() -> Result<semver::Version, Error> {
    semver::Version::from_str(&get_cargo_version()).map_err(Error::OurVersionIsInvalid)
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
        "published_at": "2024-01-24T04:34:44Z"
    }"#;

    #[test]
    fn test() {
        let release: super::Release = serde_json::from_str(RELEASES_LATEST_JSON).unwrap();
        assert_eq!(
            release.html_url.to_string(),
            "https://github.com/firezone/firezone/releases/tag/1.0.0-pre.8"
        );
        assert_eq!(release.tag_name.to_string(), "1.0.0-pre.8");

        assert!(
            semver::Version::from_str("1.0.0").unwrap()
                > semver::Version::from_str("1.0.0-pre.8").unwrap()
        );
        assert!(
            semver::Version::from_str("1.0.0-pre.8").unwrap()
                > semver::Version::from_str("0.7.0").unwrap()
        );

        assert!(super::get_our_version().is_ok());
    }
}

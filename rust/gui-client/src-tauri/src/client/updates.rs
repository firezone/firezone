//! Module to check the Github repo for new releases

use crate::client::about::get_cargo_version;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::str::FromStr;
use url::Url;

/// GUI-friendly release struct
///
/// Serialize is derived for debugging
#[derive(Debug, Deserialize, Serialize)]
pub(crate) struct Release {
    pub download_url: url::Url,
    pub version: semver::Version,
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
fn parse_version_from_url(url: &Url) -> Result<semver::Version> {
    let filename = url
        .path_segments()
        .context("URL must have a path")?
        .last()
        .context("URL path must have a last segment")?;
    let version_str = filename
        .split('_')
        .nth(1)
        .context("Filename must have 3 parts separated by underscores")?;
    Ok(semver::Version::parse(version_str)?)
}

// TODO: DRY with about.rs
pub(crate) fn current_version() -> Result<semver::Version> {
    semver::Version::from_str(&get_cargo_version()).context("Our version is invalid")
}

#[cfg(test)]
mod tests {
    #[test]
    fn parse_version_from_url() {
        for (input, expected) in [
            ("https://www.github.com/firezone/firezone/releases/download/1.0.0/firezone-client-gui-windows_1.0.0_x86_64.msi", Some((1, 0, 0))),
            ("https://www.github.com/firezone/firezone/releases/download/1.0.1/firezone-client-gui-linux_1.0.1_x86_64.deb", Some((1, 0, 1))),
            ("https://www.github.com/firezone/firezone/releases/download/1.0.1/firezone-client-gui-linux_x86_64.deb", None),
        ] {
            let input = url::Url::parse(input).unwrap();
            let expected = expected.map(|(a, b, c)| semver::Version::new(a, b, c));
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

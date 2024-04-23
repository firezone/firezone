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
    let client = reqwest::Client::builder().build()?;
    let arch = std::env::consts::ARCH;
    let os = std::env::consts::OS;

    // We used to send this to Github, couldn't hurt to send it to our own site, too
    let user_agent = format!("Firezone Client/{:?} ({os}; {arch})", current_version());

    let mut latest_url = url::Url::parse("https://www.firezone.dev").context("Impossible: Hard-coded URL should always be parsable")?;
    latest_url.set_path(&format!("/dl/firezone-client-gui-{os}/latest/{arch}"));

    let response = client.head(latest_url).header("User-Agent", user_agent).send().await?;
    let status = response.status();
    if status != reqwest::StatusCode::OK {
        // Should be 200 OK after all the redirects are followed
        anyhow::bail!("HTTP status: {status}");
    }
    // Reqwest follows up to 10 redirects by default, so just grab the final URL
    let download_url = response.url().clone();
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
    let version_str = filename.split('_').nth(1).context("Filename must have 3 parts separated by underscores")?;
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
}

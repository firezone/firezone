//! A module for registering, catching, and parsing deep links that are sent over to the app's already-running instance

use crate::{
    auth,
    gui::{self, ServerMsg},
};
use anyhow::{Context as _, Result, bail};
use secrecy::SecretString;
use url::Url;

#[cfg(any(target_os = "linux", target_os = "windows"))]
pub(crate) const FZ_SCHEME: &str = "firezone-fd0020211111";

#[cfg(target_os = "linux")]
#[path = "deep_link/linux.rs"]
mod imp;

// Stub only
#[cfg(target_os = "macos")]
#[path = "deep_link/macos.rs"]
mod imp;

#[cfg(target_os = "windows")]
#[path = "deep_link/windows.rs"]
mod imp;

pub use imp::register;

pub async fn open(url: url::Url) -> Result<()> {
    let response = gui::request(gui::ClientMsg::Deeplink(url)).await?;

    anyhow::ensure!(response == ServerMsg::Ack);

    tracing::info!("Primary instance acknowledged deep-link, goodbye!");

    Ok(())
}

/// Parses a deep-link URL into a struct.
///
/// e.g. `firezone-fd0020211111://handle_client_sign_in_callback/?state=secret&fragment=secret&account_name=Firezone&identity_provider_identifier=secret`
pub(crate) fn parse_auth_callback(url: &Url) -> Result<auth::Response> {
    if Some(url::Host::Domain("handle_client_sign_in_callback")) != url.host() {
        bail!("URL host should be `handle_client_sign_in_callback`");
    }
    // Sometimes I get an empty path, might be a glitch in Firefox Linux aarch64?
    match url.path() {
        "/" => {}
        "" => {}
        _ => bail!("URL path should be `/` or empty"),
    }

    let mut fragment = None;
    let mut state = None;

    // There's probably a way to get serde to do this
    for (key, value) in url.query_pairs() {
        match key.as_ref() {
            "fragment" => {
                if fragment.is_some() {
                    bail!("`fragment` should appear exactly once");
                }
                fragment = Some(SecretString::from(value.as_ref()));
            }
            "state" => {
                if state.is_some() {
                    bail!("`state` should appear exactly once");
                }
                state = Some(SecretString::from(value.as_ref()));
            }
            _ => {}
        }
    }

    Ok(auth::Response {
        fragment: fragment.context("URL should have `fragment`")?,
        state: state.context("URL should have `state`")?,
    })
}

/// Transforms the real auth URL (from [`auth::Request::to_url`]) into the
/// deep-link callback the portal would send back, reusing its `state`.
///
/// The inverse of [`parse_auth_callback`] for a fabricated [`auth::Response`].
/// Used by `--skip-portal-auth` to synthesize the URL we'd otherwise receive
/// from the browser. Debug builds only.
#[cfg(debug_assertions)]
pub(crate) fn fake_callback_url(real_auth_url: &SecretString) -> Result<Url> {
    use secrecy::ExposeSecret as _;

    let state = Url::parse(real_auth_url.expose_secret())
        .context("Failed to parse generated auth URL")?
        .query_pairs()
        .find(|(key, _)| &**key == "state")
        .map(|(_, value)| value.into_owned())
        .context("Generated auth URL is missing `state`")?;

    let response = auth::Response::fake(SecretString::from(state));

    let mut url = Url::parse("firezone-fd0020211111://handle_client_sign_in_callback/")
        .context("Static deep-link URL should be valid")?;
    url.query_pairs_mut()
        .append_pair("fragment", response.fragment.expose_secret())
        .append_pair("state", response.state.expose_secret());
    Ok(url)
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::Result;
    use secrecy::ExposeSecret;

    #[test]
    fn parse_auth_callback() -> Result<()> {
        // Positive cases
        let input = "firezone://handle_client_sign_in_callback/?fragment=a_very_secret_string&state=a_less_secret_string&identity_provider_identifier=12345";
        let actual = parse_callback_wrapper(input)?;

        assert_eq!(actual.fragment.expose_secret(), "a_very_secret_string");
        assert_eq!(actual.state.expose_secret(), "a_less_secret_string");

        let input = "firezone-fd0020211111://handle_client_sign_in_callback?account_name=Firezone&actor_name=Reactor+Scram&fragment=a_very_secret_string&identity_provider_identifier=1234&state=a_less_secret_string";
        let actual = parse_callback_wrapper(input)?;

        assert_eq!(actual.fragment.expose_secret(), "a_very_secret_string");
        assert_eq!(actual.state.expose_secret(), "a_less_secret_string");

        // Negative cases

        // URL host is wrong
        let input = "firezone://not_handle_client_sign_in_callback/?fragment=a_very_secret_string&state=a_less_secret_string&identity_provider_identifier=12345";
        let actual = parse_callback_wrapper(input);
        assert!(actual.is_err());

        // `fragment` is totally missing
        let input =
            "firezone://handle_client_sign_in_callback/?state=&identity_provider_identifier=12345";
        let actual = parse_callback_wrapper(input);
        assert!(actual.is_err());

        // URL is nonsense
        let input = "?????????";
        let actual_result = parse_callback_wrapper(input);
        assert!(actual_result.is_err());

        Ok(())
    }

    fn parse_callback_wrapper(s: &str) -> Result<auth::Response> {
        super::parse_auth_callback(&s.parse()?)
    }
}

//! A module for registering, catching, and parsing deep links that are sent over to the app's already-running instance

// The IPC parts use the same primitives as the IPC service, UDS on Linux
// and named pipes on Windows, so TODO de-dupe the IPC code

use crate::{
    auth,
    gui::{self, ServerMsg},
    ipc::SocketId,
};
use anyhow::{Context as _, Result, bail};
use futures::SinkExt as _;
use secrecy::SecretString;
use tokio_stream::StreamExt as _;
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
    let (mut read, mut write) =
        crate::ipc::connect::<gui::ServerMsg, gui::ClientMsg>(SocketId::Gui).await?;

    write
        .send(&gui::ClientMsg::Deeplink(url))
        .await
        .context("Failed to send deep-link")?;

    let response = read
        .next()
        .await
        .context("No response received")?
        .context("Failed to receive response")?;

    anyhow::ensure!(response == ServerMsg::Ack);

    Ok(())
}

/// Parses a deep-link URL into a struct.
///
/// e.g. `firezone-fd0020211111://handle_client_sign_in_callback/?state=secret&fragment=secret&account_name=Firezone&account_slug=firezone&actor_name=Jane+Doe&identity_provider_identifier=secret`
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

    let mut account_slug = None;
    let mut actor_name = None;
    let mut fragment = None;
    let mut state = None;

    // There's probably a way to get serde to do this
    for (key, value) in url.query_pairs() {
        match key.as_ref() {
            "account_slug" => {
                if account_slug.is_some() {
                    bail!("`account_slug` should appear exactly once");
                }
                account_slug = Some(value.to_string());
            }
            "actor_name" => {
                if actor_name.is_some() {
                    bail!("`actor_name` should appear exactly once");
                }
                actor_name = Some(value.to_string());
            }
            "fragment" => {
                if fragment.is_some() {
                    bail!("`fragment` should appear exactly once");
                }
                fragment = Some(SecretString::new(value.to_string()));
            }
            "state" => {
                if state.is_some() {
                    bail!("`state` should appear exactly once");
                }
                state = Some(SecretString::new(value.to_string()));
            }
            _ => {}
        }
    }

    Ok(auth::Response {
        account_slug: account_slug.context("URL should have `account_slug`")?,
        actor_name: actor_name.context("URL should have `actor_name`")?,
        fragment: fragment.context("URL should have `fragment`")?,
        state: state.context("URL should have `state`")?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::Result;
    use secrecy::ExposeSecret;

    #[test]
    fn parse_auth_callback() -> Result<()> {
        // Positive cases
        let input = "firezone://handle_client_sign_in_callback/?account_slug=firezone&actor_name=Reactor+Scram&fragment=a_very_secret_string&state=a_less_secret_string&identity_provider_identifier=12345";
        let actual = parse_callback_wrapper(input)?;

        assert_eq!(actual.account_slug, "firezone");
        assert_eq!(actual.actor_name, "Reactor Scram");
        assert_eq!(actual.fragment.expose_secret(), "a_very_secret_string");
        assert_eq!(actual.state.expose_secret(), "a_less_secret_string");

        let input = "firezone-fd0020211111://handle_client_sign_in_callback?account_name=Firezone&account_slug=firezone&actor_name=Reactor+Scram&fragment=a_very_secret_string&identity_provider_identifier=1234&state=a_less_secret_string";
        let actual = parse_callback_wrapper(input)?;

        assert_eq!(actual.account_slug, "firezone");
        assert_eq!(actual.actor_name, "Reactor Scram");
        assert_eq!(actual.fragment.expose_secret(), "a_very_secret_string");
        assert_eq!(actual.state.expose_secret(), "a_less_secret_string");

        // Empty string "" `actor_name` is fine
        let input = "firezone://handle_client_sign_in_callback/?account_slug=firezone&actor_name=&fragment=&state=&identity_provider_identifier=12345";
        let actual = parse_callback_wrapper(input)?;

        assert_eq!(actual.account_slug, "firezone");
        assert_eq!(actual.actor_name, "");
        assert_eq!(actual.fragment.expose_secret(), "");
        assert_eq!(actual.state.expose_secret(), "");

        // Negative cases

        // URL host is wrong
        let input = "firezone://not_handle_client_sign_in_callback/?account_slug=firezone&actor_name=Reactor+Scram&fragment=a_very_secret_string&state=a_less_secret_string&identity_provider_identifier=12345";
        let actual = parse_callback_wrapper(input);
        assert!(actual.is_err());

        // `actor_name` is not just blank but totally missing
        let input = "firezone://handle_client_sign_in_callback/?account_slug=firezone&fragment=&state=&identity_provider_identifier=12345";
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

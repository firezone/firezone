//! A module for registering, catching, and parsing deep links that are sent over to the app's already-running instance

// The IPC parts use the same primitives as the IPC service, UDS on Linux
// and named pipes on Windows, so TODO de-dupe the IPC code

use crate::auth;
use anyhow::{bail, Context as _, Result};
use secrecy::{ExposeSecret, SecretString};
use url::Url;

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

#[derive(thiserror::Error, Debug)]
#[error("named pipe server couldn't start listening, we are probably the second instance")]
pub struct CantListen;

pub use imp::{open, register, Server};

/// Parses a deep-link URL into a struct.
///
/// e.g. `firezone-fd0020211111://handle_client_sign_in_callback/?state=secret&fragment=secret&account_name=Firezone&account_slug=firezone&actor_name=Jane+Doe&identity_provider_identifier=secret`
pub(crate) fn parse_auth_callback(url_secret: &SecretString) -> Result<auth::Response> {
    let url = Url::parse(url_secret.expose_secret())?;
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
    use anyhow::{Context, Result};
    use secrecy::{ExposeSecret, SecretString};

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
        super::parse_auth_callback(&SecretString::new(s.to_owned()))
    }

    /// Tests the named pipe or Unix domain socket, doesn't test the URI scheme itself
    ///
    /// Will fail if any other Firezone Client instance is running
    /// Will fail with permission error if Firezone already ran as sudo
    #[tokio::test]
    async fn socket_smoke_test() -> Result<()> {
        let server = super::Server::new()
            .await
            .context("Couldn't start Server")?;
        let server_task = tokio::spawn(async move {
            let bytes = server.accept().await?;
            Ok::<_, anyhow::Error>(bytes)
        });
        let id = uuid::Uuid::new_v4().to_string();
        let expected_url = url::Url::parse(&format!("bogus-test-schema://{id}"))?;
        super::open(&expected_url).await?;

        let bytes = server_task.await??.unwrap();
        let s = std::str::from_utf8(bytes.expose_secret())?;
        let url = url::Url::parse(s)?;
        assert_eq!(url, expected_url);
        Ok(())
    }
}

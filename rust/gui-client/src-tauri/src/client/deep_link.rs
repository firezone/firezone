//! A module for registering, catching, and parsing deep links that are sent over to the app's already-running instance

use crate::client::auth::Response as AuthResponse;
use connlib_shared::control::SecureUrl;
use secrecy::{ExposeSecret, Secret, SecretString};
use std::io;

pub(crate) const FZ_SCHEME: &str = "firezone-fd0020211111";

#[cfg(target_os = "linux")]
#[path = "deep_link/linux.rs"]
mod imp;

#[cfg(target_os = "windows")]
#[path = "deep_link/windows.rs"]
mod imp;

// TODO: Replace this all for `anyhow`.
#[cfg_attr(target_os = "linux", allow(dead_code))]
#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("named pipe server couldn't start listening, we are probably the second instance")]
    CantListen,
    /// Error from client's POV
    #[error(transparent)]
    ClientCommunications(io::Error),
    /// Error while connecting to the server
    #[error(transparent)]
    Connect(io::Error),
    /// Something went wrong finding the path to our own exe
    #[error(transparent)]
    CurrentExe(io::Error),
    /// We got some data but it's not UTF-8
    #[error(transparent)]
    LinkNotUtf8(std::str::Utf8Error),
    #[cfg(target_os = "windows")]
    #[error("Couldn't set up security descriptor for deep link server")]
    SecurityDescriptor,
    /// Error from server's POV
    #[error(transparent)]
    ServerCommunications(io::Error),
    #[error(transparent)]
    UrlParse(#[from] url::ParseError),
    /// Something went wrong setting up the registry
    #[cfg(target_os = "windows")]
    #[error(transparent)]
    WindowsRegistry(io::Error),
}

pub(crate) use imp::{open, register, Server};

pub(crate) fn parse_auth_callback(url: &Secret<SecureUrl>) -> Option<AuthResponse> {
    let url = &url.expose_secret().inner;
    match url.host() {
        Some(url::Host::Domain("handle_client_sign_in_callback")) => {}
        _ => return None,
    }
    if url.path() != "/" {
        return None;
    }

    let mut actor_name = None;
    let mut fragment = None;
    let mut state = None;

    for (key, value) in url.query_pairs() {
        match key.as_ref() {
            "actor_name" => {
                if actor_name.is_some() {
                    // actor_name must appear exactly once
                    return None;
                }
                actor_name = Some(value.to_string());
            }
            "fragment" => {
                if fragment.is_some() {
                    // must appear exactly once
                    return None;
                }
                fragment = Some(SecretString::new(value.to_string()));
            }
            "state" => {
                if state.is_some() {
                    // must appear exactly once
                    return None;
                }
                state = Some(SecretString::new(value.to_string()));
            }
            _ => {}
        }
    }

    Some(AuthResponse {
        actor_name: actor_name?,
        fragment: fragment?,
        state: state?,
    })
}

#[cfg(test)]
mod tests {
    use anyhow::Result;
    use connlib_shared::control::SecureUrl;
    use secrecy::{ExposeSecret, Secret};

    #[test]
    fn parse_auth_callback() -> Result<()> {
        // Positive cases
        let input = "firezone://handle_client_sign_in_callback/?actor_name=Reactor+Scram&fragment=a_very_secret_string&state=a_less_secret_string&identity_provider_identifier=12345";
        let actual = parse_callback_wrapper(input)?.unwrap();

        assert_eq!(actual.actor_name, "Reactor Scram");
        assert_eq!(actual.fragment.expose_secret(), "a_very_secret_string");
        assert_eq!(actual.state.expose_secret(), "a_less_secret_string");

        // Empty string "" `actor_name` is fine
        let input = "firezone://handle_client_sign_in_callback/?actor_name=&fragment=&state=&identity_provider_identifier=12345";
        let actual = parse_callback_wrapper(input)?.unwrap();

        assert_eq!(actual.actor_name, "");
        assert_eq!(actual.fragment.expose_secret(), "");
        assert_eq!(actual.state.expose_secret(), "");

        // Negative cases

        // URL host is wrong
        let input = "firezone://not_handle_client_sign_in_callback/?actor_name=Reactor+Scram&fragment=a_very_secret_string&state=a_less_secret_string&identity_provider_identifier=12345";
        let actual = parse_callback_wrapper(input)?;
        assert!(actual.is_none());

        // `actor_name` is not just blank but totally missing
        let input = "firezone://handle_client_sign_in_callback/?fragment=&state=&identity_provider_identifier=12345";
        let actual = parse_callback_wrapper(input)?;
        assert!(actual.is_none());

        // URL is nonsense
        let input = "?????????";
        let actual_result = parse_callback_wrapper(input);
        assert!(actual_result.is_err());

        Ok(())
    }

    fn parse_callback_wrapper(s: &str) -> Result<Option<super::AuthResponse>> {
        let url = Secret::new(SecureUrl::from_url(url::Url::parse(s)?));
        Ok(super::parse_auth_callback(&url))
    }
}

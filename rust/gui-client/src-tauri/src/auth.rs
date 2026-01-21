//! Fulfills <https://github.com/firezone/firezone/issues/2823>

use anyhow::{Context, Result};
use bin_shared::known_dirs;
use keyring_core::CredentialStore;
use logging::err_with_src;
use rand::{RngCore, thread_rng};
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Arc,
};
use subtle::ConstantTimeEq;
use url::Url;

const NONCE_LENGTH: usize = 32;

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("`known_dirs` failed")]
    CantFindKnownDir,
    #[error("`create_dir_all` failed while writing `actor_name_path`")]
    CreateDirAll(std::io::Error),
    #[error("Couldn't delete session file from disk: {0}")]
    DeleteFile(std::io::Error),
    #[error(transparent)]
    Keyring(#[from] keyring_core::Error),
    #[error("No in-flight request")]
    NoInflightRequest,
    #[error("session file path has no parent, this should be impossible")]
    PathWrong,
    #[error("Couldn't read session file: {0}")]
    ReadFile(std::io::Error),
    #[error("Could not serialize session data")]
    SerializeSession(#[source] serde_json::Error),
    #[error("Could not deserialize session data ({json})")]
    DeserializeSession {
        source: serde_json::Error,
        json: String,
    },
    #[error("State in server response doesn't match state in client request")]
    StatesDontMatch,
    #[error("Couldn't write session file: {0}")]
    WriteFile(std::io::Error),
}

pub struct Auth {
    token_entry: keyring_core::Entry,
    state: State,
    session_dir: PathBuf,
}

enum State {
    SignedOut,
    NeedResponse(Request),
    SignedIn(Session),
}

pub struct Request {
    nonce: SecretString,
    state: SecretString,
}

impl Request {
    pub fn to_url(&self, auth_base_url: &Url, account_slug: Option<&str>) -> SecretString {
        let mut url = auth_base_url.clone();

        if let Some(account_slug) = account_slug {
            url.set_path(account_slug);
        }

        // Avoid further usage of `Url` here so we don't need to zeroize it.
        let base = url.to_string();

        SecretString::from(format!(
            "{base}?as=client&nonce={}&state={}",
            self.nonce.expose_secret(),
            self.state.expose_secret()
        ))
    }
}

pub(crate) struct Response {
    pub(crate) account_slug: String,
    pub(crate) actor_name: String,
    pub(crate) fragment: SecretString,
    pub(crate) state: SecretString,
}

#[derive(Default, Clone, Deserialize, Serialize)]
pub struct Session {
    pub(crate) account_slug: String,
    pub(crate) actor_name: String,
}

struct SessionAndToken {
    session: Session,
    token: SecretString,
}

impl Auth {
    /// Creates a new Auth struct using the "dev.firezone.client/token" keyring key. If the token is stored on disk, the struct is automatically signed in.
    ///
    /// Performs I/O.
    pub fn new() -> Result<Self> {
        #[cfg(target_os = "linux")]
        let store = dbus_secret_service_keyring_store::Store::new()?;

        #[cfg(target_os = "windows")]
        let store =
            windows_native_keyring_store::Store::new_with_configuration(&HashMap::from([(
                // We want to avoid an appended `.` at the end.
                "divider", "",
            )]))?;

        #[cfg(target_os = "macos")]
        let store = keyring_core::mock::Store::new()?;

        Self::new_with_key(
            "dev.firezone.client/token",
            store,
            known_dirs::session().context("Failed to determine `session` directory")?,
        )
    }

    /// Creates a new Auth struct with a custom keyring key for testing.
    ///
    /// `new` also just wraps this.
    fn new_with_key(
        keyring_key: &'static str,
        store: Arc<CredentialStore>,
        session_dir: PathBuf,
    ) -> Result<Self> {
        let mut this = Self {
            token_entry: store.build("", keyring_key, None)?,
            state: State::SignedOut,
            session_dir,
        };

        match this.get_token_from_disk() {
            Err(error) => tracing::error!(
                "Failed to load token from disk. Will start in signed-out state: {}",
                err_with_src(&error)
            ),
            Ok(Some(SessionAndToken { session, token: _ })) => {
                this.state = State::SignedIn(session);
                tracing::debug!("Reloaded token from disk, starting in signed-in state.");
            }
            Ok(None) => tracing::debug!("No token on disk, starting in signed-out state."),
        }

        Ok(this)
    }

    /// Returns the session iff we are signed in.
    pub fn session(&self) -> Option<&Session> {
        match &self.state {
            State::SignedIn(x) => Some(x),
            State::NeedResponse(_) | State::SignedOut => None,
        }
    }

    /// Mark the session as signed out, or cancel an ongoing sign-in flow
    ///
    /// Performs I/O.
    pub fn sign_out(&mut self) -> Result<(), Error> {
        match self.token_entry.delete_credential() {
            Ok(()) | Err(keyring_core::Error::NoEntry) => {}
            Err(error) => {
                tracing::warn!(
                    "Couldn't delete token while signing out: {}",
                    err_with_src(&error)
                );
            }
        }
        delete_if_exists(&actor_name_path(&self.session_dir))?;
        delete_if_exists(&session_data_path(&self.session_dir))?;
        self.state = State::SignedOut;
        Ok(())
    }

    /// Start a new sign-in flow, replacing any ongoing flow
    ///
    /// Returns parameters used to make a URL for the web browser to open
    /// May return Ok(None) if we're already signed in
    pub fn start_sign_in(&mut self) -> Result<&Request, Error> {
        self.sign_out()?;
        self.state = State::NeedResponse(Request {
            nonce: generate_nonce(),
            state: generate_nonce(),
        });
        let State::NeedResponse(request) = &self.state else {
            unreachable!("We just set `self.state`")
        };

        Ok(request)
    }

    /// Complete an ongoing sign-in flow using parameters from a deep link
    ///
    /// Returns a valid token.
    /// Performs I/O.
    ///
    /// Errors if the response is invalid.
    pub(crate) fn handle_response(&mut self, resp: Response) -> Result<SecretString, Error> {
        let req = self.ongoing_request().ok_or(Error::NoInflightRequest)?;

        if !secure_equality(&resp.state, &req.state) {
            self.sign_out()?;
            return Err(Error::StatesDontMatch);
        }

        let token = format!(
            "{}{}",
            req.nonce.expose_secret(),
            resp.fragment.expose_secret()
        );
        let token = SecretString::from(token);

        let session = Session {
            account_slug: resp.account_slug,
            actor_name: resp.actor_name,
        };

        self.save_session(&session, &token)?;
        self.state = State::SignedIn(session);
        Ok(SecretString::from(token))
    }

    fn save_session(&self, session: &Session, token: &SecretString) -> Result<(), Error> {
        // This MUST be the only place the GUI can call `set_password`, since
        // the actor name is also saved here.
        if let Err(e) = self
            .token_entry
            .set_password(token.expose_secret())
            .context("Failed to save token in keyring")
        {
            tracing::info!("{e:#}"); // Log that we couldn't save it and allow the user to continue anyway.
        }
        save_file(
            &actor_name_path(&self.session_dir),
            session.actor_name.as_bytes(),
        )?;
        save_file(
            &session_data_path(&self.session_dir),
            serde_json::to_string(session)
                .map_err(Error::SerializeSession)?
                .as_bytes(),
        )?;
        Ok(())
    }

    /// Returns the token if we are signed in
    ///
    /// This will always make syscalls, but it should be fast enough for normal use.
    pub fn token(&self) -> Result<Option<SecretString>, Error> {
        match self.state {
            State::SignedIn(_) => {}
            State::NeedResponse(_) | State::SignedOut => return Ok(None),
        }

        Ok(self
            .get_token_from_disk()?
            .map(|session_and_token| session_and_token.token))
    }

    /// Retrieves the token from disk regardless of in-memory state
    ///
    /// Performs I/O
    fn get_token_from_disk(&self) -> Result<Option<SessionAndToken>, Error> {
        // Read the actor_name file, then let the session file override it if present.

        let mut session = Session::default();
        match std::fs::read_to_string(actor_name_path(&self.session_dir)) {
            Ok(x) => session.actor_name = x,
            // It can happen with dev systems that actor_name.txt doesn't exist
            // even though the token is in the cred manager.
            // In that case we just say the app is signed out
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(Error::ReadFile(e)),
        };
        match std::fs::read_to_string(session_data_path(&self.session_dir)) {
            Ok(json) => {
                session = serde_json::from_str(&json)
                    .map_err(|source| Error::DeserializeSession { source, json })?;
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(Error::ReadFile(e)),
        }

        // This MUST be the only place the GUI can call `get_password`, since the
        // actor name is also loaded here.
        let Ok(token) = self.token_entry.get_password() else {
            return Ok(None);
        };
        let token = SecretString::from(token);

        Ok(Some(SessionAndToken { session, token }))
    }

    pub fn ongoing_request(&self) -> Option<&Request> {
        match &self.state {
            State::NeedResponse(x) => Some(x),
            State::SignedIn(_) | State::SignedOut => None,
        }
    }
}

fn delete_if_exists(path: &Path) -> Result<(), Error> {
    if let Err(error) = std::fs::remove_file(path) {
        // Ignore NotFound, since the file is gone anyway
        if error.kind() != std::io::ErrorKind::NotFound {
            return Err(Error::DeleteFile(error));
        }
    }
    Ok(())
}

fn save_file(path: &Path, content: &[u8]) -> Result<(), Error> {
    std::fs::create_dir_all(path.parent().ok_or(Error::PathWrong)?).map_err(Error::CreateDirAll)?;
    std::fs::write(path, content).map_err(Error::WriteFile)?;
    Ok(())
}

/// Returns a path to a file where we can save the actor name
///
/// Hopefully we don't need to save anything else, or there will be a migration step
fn actor_name_path(session_dir: &Path) -> PathBuf {
    session_dir.join("actor_name.txt")
}

fn session_data_path(session_dir: &Path) -> PathBuf {
    session_dir.join("session_data.json")
}

/// Generates a random nonce using a CSPRNG, then returns it as hexadecimal
fn generate_nonce() -> SecretString {
    let mut buf = [0u8; NONCE_LENGTH];
    // rand's thread-local RNG is said to be cryptographically secure here: https://docs.rs/rand/latest/rand/rngs/struct.ThreadRng.html
    thread_rng().fill_bytes(&mut buf);

    // Make sure it's not somehow all still zeroes.
    assert_ne!(buf, [0u8; NONCE_LENGTH]);
    hex::encode(buf).into()
}

/// Checks if two byte strings are equal in constant-time.
/// May not be constant-time if the lengths differ:
/// <https://docs.rs/subtle/2.5.0/subtle/trait.ConstantTimeEq.html#impl-ConstantTimeEq-for-%5BT%5D>
fn secure_equality(a: &SecretString, b: &SecretString) -> bool {
    let a = a.expose_secret().as_bytes();
    let b = b.expose_secret().as_bytes();
    a.ct_eq(b).into()
}

pub fn replicate_6791() -> Result<()> {
    tracing::warn!("Debugging issue #6791, pretending to be signed in with a bad token");
    let this = Auth::new()?;
    this.save_session(
        &Session {
            account_slug: "firezone".to_string(),
            actor_name: "Jane Doe".to_string(),
        },
        &SecretString::from("obviously invalid token for testing #6791".to_string()),
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn bogus_secret(x: &str) -> SecretString {
        SecretString::new(x.into())
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn keyring_rs() {
        use keyring_core::api::CredentialStoreApi as _;

        let store = windows_native_keyring_store::Store::new().unwrap();

        // We used this test to find that `service` is not used on Windows - We have to namespace on our own.

        let name_1 = "dev.firezone.client/test_1/token";
        let name_2 = "dev.firezone.client/test_2/token";

        let test_password_1 = "test_password_1";
        let test_password_2 = "test_password_2";

        let entry = store.build("", name_1, None).unwrap();
        entry.set_password("test_password_1").unwrap();

        {
            // In the middle of accessing one token, access another to make sure they don't interfere much
            let entry = store.build("", name_2, None).unwrap();
            entry.set_password(test_password_2).unwrap();

            std::thread::sleep(std::time::Duration::from_secs(1));
            assert_eq!(entry.get_password().unwrap(), test_password_2);
        }

        {
            // Make sure that closing and re-opening the `Entry` on the same thread
            // gives the correct result
            let entry = store.build("", name_2, None).unwrap();
            assert_eq!(entry.get_password().unwrap(), test_password_2);
            entry.delete_credential().unwrap();

            std::thread::sleep(std::time::Duration::from_secs(1));
            assert!(entry.get_password().is_err());
        }

        std::thread::sleep(std::time::Duration::from_secs(1));
        assert_eq!(entry.get_password().unwrap(), test_password_1);
        entry.delete_credential().unwrap();

        std::thread::sleep(std::time::Duration::from_secs(1));
        assert!(entry.get_password().is_err());
    }

    #[test]
    fn secure_eq() {
        // This doesn't test for constant-time properties, it just makes sure the function
        // gives the right result
        let f = |a: &str, b: &str| secure_equality(&bogus_secret(a), &bogus_secret(b));

        assert!(f("1234", "1234"));
        assert!(!f("1234", "123"));
        assert!(!f("1234", "1235"));

        let hex_string = generate_nonce();
        let hex_string = hex_string.expose_secret();
        assert_eq!(hex_string.len(), NONCE_LENGTH * 2);

        let auth_base_url = Url::parse("https://app.firez.one").unwrap();
        let req = Request {
            nonce: bogus_secret("some_nonce"),
            state: bogus_secret("some_state"),
        };
        assert_eq!(
            req.to_url(&auth_base_url, None).expose_secret(),
            "https://app.firez.one/?as=client&nonce=some_nonce&state=some_state"
        );
    }

    #[test]
    fn happy_path() {
        let _guard = logging::test("trace");

        let actor_name = "Jane Doe";
        let store = keyring_core::mock::Store::new().unwrap();
        let session_dir = tempdir().unwrap();

        // Key for credential manager. This is not what we use in production
        let key = "dev.firezone.client/test_DMRCZ67A_happy_path/token";

        {
            // Start the program
            let mut state =
                Auth::new_with_key(key, store.clone(), session_dir.path().to_path_buf()).unwrap();

            // Delete any token on disk from previous test runs
            state.sign_out().unwrap();
            assert!(state.token().unwrap().is_none());

            // User clicks "Sign In", build a fake server response
            let req = state.start_sign_in().unwrap();
            let resp = Response {
                account_slug: "firezone".into(),
                actor_name: actor_name.into(),
                fragment: bogus_secret("fragment"),
                state: req.state.clone(),
            };

            // Handle deep link from the server, now we are signed in and have a token
            assert!(state.token().unwrap().is_none());
            state.handle_response(resp).unwrap();
            assert!(state.token().unwrap().is_some());

            // Make sure we loaded the actor_name
            assert_eq!(state.session().unwrap().actor_name, actor_name);
        }

        // Recreate the state to simulate closing and re-opening the app
        {
            let mut state =
                Auth::new_with_key(key, store, session_dir.path().to_path_buf()).unwrap();

            // Make sure we automatically got the token and actor_name back
            assert!(state.token().unwrap().is_some());
            assert_eq!(state.session().unwrap().actor_name, actor_name);

            // Accidentally sign in again, this can happen if the user holds the systray menu open while a sign in is succeeding.
            // For now, we treat that like signing out and back in immediately, so it wipes the old token.
            // TODO: That sounds wrong.
            assert!(state.start_sign_in().is_ok());
            assert!(state.token().unwrap().is_none());

            // Sign out again, now the token is gone
            state.sign_out().unwrap();
            assert!(state.token().unwrap().is_none());
        }
    }

    #[test]
    fn no_inflight_request() {
        let session_dir = tempdir().unwrap();

        // Start the program
        let mut state = Auth::new_with_key(
            "dev.firezone.client/test_DMRCZ67A_invalid_response/token",
            keyring_core::mock::Store::new().unwrap(),
            session_dir.path().to_path_buf(),
        )
        .unwrap();

        // Delete any token on disk from previous test runs
        state.sign_out().unwrap();
        assert!(state.token().unwrap().is_none());

        // If we get a deep link with no in-flight request, it's invalid
        let r = state.handle_response(Response {
            account_slug: "firezone".into(),
            actor_name: "Jane Doe".into(),
            fragment: bogus_secret("fragment"),
            state: bogus_secret("state"),
        });

        match r {
            Err(Error::NoInflightRequest) => {}
            _ => panic!("Expected NoInflightRequest error"),
        }

        // Clean up the test token
        state.sign_out().unwrap();
    }

    #[test]
    fn states_dont_match() {
        let session_dir = tempdir().unwrap();

        // Start the program
        let mut state = Auth::new_with_key(
            "dev.firezone.client/test_DMRCZ67A_states_dont_match/token",
            keyring_core::mock::Store::new().unwrap(),
            session_dir.path().to_path_buf(),
        )
        .unwrap();

        // Delete any token on disk from previous test runs
        state.sign_out().unwrap();
        assert!(state.token().unwrap().is_none());

        // User clicks "Sign In", build a fake server response
        state.start_sign_in().unwrap();
        let resp = Response {
            account_slug: "firezone".into(),
            actor_name: "Jane Doe".into(),
            fragment: bogus_secret("fragment"),
            state: SecretString::from(
                "bogus state from a replay attack or browser mis-click".to_string(),
            ),
        };
        assert!(state.token().unwrap().is_none());

        // Handle deep link from the server, we should get an error
        let r = state.handle_response(resp);
        match r {
            Err(Error::StatesDontMatch) => {}
            _ => panic!("Expected StatesDontMatch error"),
        }
        assert!(state.token().unwrap().is_none());
    }
}

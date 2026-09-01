//! Fulfills <https://github.com/firezone/firezone/issues/2823>

use anyhow::{Context, Result};
use keyring_core::CredentialStore;
use logging::err_with_src;
use rand::Rng;
use secrecy::{ExposeSecret, SecretString};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};
use subtle::ConstantTimeEq;
use url::Url;

const NONCE_LENGTH: usize = 32;

/// Whether to skip the portal during sign-in.
///
/// When set, [`Auth::new`] uses an in-memory keystore and signs in with a
/// fabricated response instead of contacting the portal, so the real controller
/// / IPC / UI can be exercised against the mock Tunnel service without touching
/// the real keyring or persisted session. Debug builds only.
#[cfg(debug_assertions)]
static SKIP_PORTAL_AUTH: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Set [`SKIP_PORTAL_AUTH`]. Call once at process startup.
#[cfg(debug_assertions)]
pub fn skip_portal_auth() {
    SKIP_PORTAL_AUTH.store(true, std::sync::atomic::Ordering::Relaxed);
}

#[cfg(debug_assertions)]
pub(crate) fn portal_auth_skipped() -> bool {
    SKIP_PORTAL_AUTH.load(std::sync::atomic::Ordering::Relaxed)
}

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("`known_dirs` failed")]
    CantFindKnownDir,
    #[error("Couldn't delete session file from disk: {0}")]
    DeleteFile(std::io::Error),
    #[error(transparent)]
    Keyring(#[from] keyring_core::Error),
    #[error("No in-flight request")]
    NoInflightRequest,
    #[error("State in server response doesn't match state in client request")]
    StatesDontMatch,
}

pub struct Auth {
    token_entry: keyring_core::Entry,
    state: State,
    session_dir: PathBuf,
}

enum State {
    SignedOut,
    NeedResponse(Request),
    SignedIn,
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
            "{base}?as=gui-client&nonce={}&state={}",
            self.nonce.expose_secret(),
            self.state.expose_secret()
        ))
    }
}

pub(crate) struct Response {
    pub(crate) fragment: SecretString,
    pub(crate) state: SecretString,
}

#[cfg(debug_assertions)]
impl Response {
    /// Fabricate the response the portal would send back for `state`.
    ///
    /// The fragment is a placeholder because the mock Tunnel service ignores the
    /// token's value. Debug builds only.
    pub(crate) fn fake(state: SecretString) -> Self {
        Self {
            fragment: SecretString::from("fake-fragment"),
            state,
        }
    }
}

impl Auth {
    /// Creates a new Auth struct using the "dev.firezone.client/token" keyring key. If the token is stored on disk, the struct is automatically signed in.
    ///
    /// Performs I/O except on `cfg(test)`.
    pub fn new() -> Result<Self> {
        #[cfg(debug_assertions)]
        if portal_auth_skipped() {
            return Self::new_fake();
        }

        #[cfg(all(target_os = "linux", not(test)))]
        let store = dbus_secret_service_keyring_store::Store::new()?;

        #[cfg(all(target_os = "windows", not(test)))]
        let store = windows_native_keyring_store::Store::new_with_configuration(
            &std::collections::HashMap::from([(
                // We want to avoid an appended `.` at the end.
                "divider", "",
            )]),
        )?;

        #[cfg(any(target_os = "macos", test))]
        let store = keyring_core::mock::Store::new()?;

        Self::new_with_key(
            "dev.firezone.client/token",
            store,
            known_dirs::session().context("Failed to determine `session` directory")?,
        )
    }

    /// Creates an [`Auth`] backed by an in-memory keystore and a temp session
    /// dir, already signed in with a fabricated response.
    #[cfg(debug_assertions)]
    fn new_fake() -> Result<Self> {
        let mut this = Self::new_with_key(
            "dev.firezone.client/token",
            keyring_core::mock::Store::new()?,
            std::env::temp_dir().join("dev.firezone.client.skip-portal-auth"),
        )?;
        let request = this.start_sign_in()?;
        let response = Response::fake(request.state.clone());
        this.handle_response(response)?;

        Ok(this)
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

        match this.token_from_keyring() {
            Some(_) => {
                this.state = State::SignedIn;
                tracing::debug!("Reloaded token from keyring, starting in signed-in state.");
            }
            None => tracing::debug!("No token in keyring, starting in signed-out state."),
        }

        Ok(this)
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
        // Written by versions that took the actor name from the sign-in callback, so
        // signing out still forgets the name they left on disk.
        // TODO: remove once all clients have migrated.
        delete_if_exists(&self.session_dir.join("actor_name.txt"))?;
        delete_if_exists(&self.session_dir.join("session_data.json"))?;
        self.state = State::SignedOut;
        Ok(())
    }

    /// Adopt the certificate the Tunnel service holds as the session.
    ///
    /// The certificate authenticates every connect anew, so there is nothing to persist and
    /// nothing to read back at startup. The portal names the actor and account once connlib
    /// reaches it, the same as for a browser session.
    pub(crate) fn sign_in_with_certificate(&mut self) {
        self.state = State::SignedIn;
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

        self.save_token(&token);
        self.state = State::SignedIn;
        Ok(token)
    }

    fn save_token(&self, token: &SecretString) {
        // This MUST be the only place the GUI can call `set_password`.
        if let Err(e) = self
            .token_entry
            .set_password(token.expose_secret())
            .context("Failed to save token in keyring")
        {
            tracing::info!("{e:#}"); // Log that we couldn't save it and allow the user to continue anyway.
        }
    }

    /// Returns the token if we are signed in.
    ///
    /// This will always make syscalls, but it should be fast enough for normal use.
    pub fn token(&self) -> Option<SecretString> {
        match self.state {
            State::SignedIn => {}
            State::NeedResponse(_) | State::SignedOut => return None,
        }

        self.token_from_keyring()
    }

    /// Retrieves the token from the keyring regardless of in-memory state.
    ///
    /// Performs I/O
    fn token_from_keyring(&self) -> Option<SecretString> {
        // This MUST be the only place the GUI can call `get_password`.
        let token = self.token_entry.get_password().ok()?;

        Some(SecretString::from(token))
    }

    pub fn ongoing_request(&self) -> Option<&Request> {
        match &self.state {
            State::NeedResponse(x) => Some(x),
            State::SignedIn | State::SignedOut => None,
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

/// Generates a random nonce using a CSPRNG, then returns it as hexadecimal
fn generate_nonce() -> SecretString {
    let mut buf = [0u8; NONCE_LENGTH];
    // rand's thread-local RNG is said to be cryptographically secure here: https://docs.rs/rand/latest/rand/rngs/struct.ThreadRng.html
    rand::rng().fill_bytes(&mut buf);

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
    this.save_token(&SecretString::from(
        "obviously invalid token for testing #6791".to_string(),
    ));
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
            "https://app.firez.one/?as=gui-client&nonce=some_nonce&state=some_state"
        );
    }

    #[test]
    fn happy_path() {
        let _guard = logging::test("trace");

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
            assert!(state.token().is_none());

            // User clicks "Sign In", build a fake server response
            let req = state.start_sign_in().unwrap();
            let resp = Response {
                fragment: bogus_secret("fragment"),
                state: req.state.clone(),
            };

            // Handle deep link from the server, now we are signed in and have a token
            assert!(state.token().is_none());
            state.handle_response(resp).unwrap();
            assert!(state.token().is_some());
        }

        // Recreate the state to simulate closing and re-opening the app
        {
            let mut state =
                Auth::new_with_key(key, store, session_dir.path().to_path_buf()).unwrap();

            // Make sure we automatically got the token back
            assert!(state.token().is_some());

            // Accidentally sign in again, this can happen if the user holds the systray menu open while a sign in is succeeding.
            // For now, we treat that like signing out and back in immediately, so it wipes the old token.
            // TODO: That sounds wrong.
            assert!(state.start_sign_in().is_ok());
            assert!(state.token().is_none());

            // Sign out again, now the token is gone
            state.sign_out().unwrap();
            assert!(state.token().is_none());
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
        assert!(state.token().is_none());

        // If we get a deep link with no in-flight request, it's invalid
        let r = state.handle_response(Response {
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
        assert!(state.token().is_none());

        // User clicks "Sign In", build a fake server response
        state.start_sign_in().unwrap();
        let resp = Response {
            fragment: bogus_secret("fragment"),
            state: SecretString::from(
                "bogus state from a replay attack or browser mis-click".to_string(),
            ),
        };
        assert!(state.token().is_none());

        // Handle deep link from the server, we should get an error
        let r = state.handle_response(resp);
        match r {
            Err(Error::StatesDontMatch) => {}
            _ => panic!("Expected StatesDontMatch error"),
        }
        assert!(state.token().is_none());
    }
}

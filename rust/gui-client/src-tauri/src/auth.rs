//! Fulfills <https://github.com/firezone/firezone/issues/2823>

use crate::settings::SignInSettings;
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
#[cfg(target_os = "windows")]
const SIGN_IN_SETTINGS_ATTRIBUTE: &str = "comment";
#[cfg(not(target_os = "windows"))]
const SIGN_IN_SETTINGS_ATTRIBUTE: &str = "sign-in-settings";

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
    AwaitingPortal,
    SignedIn(Credential),
}

#[derive(Clone)]
pub struct Credential {
    pub token: SecretString,
    pub sign_in_settings: Option<SignInSettings>,
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
    pub(crate) control_plane: Option<crate::settings::ControlPlane>,
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
            control_plane: None,
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
        let token = this.handle_response(response)?;
        this.save_token(&token, None);

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

        match this.credential_from_keyring() {
            Some(credential) => {
                this.state = State::SignedIn(credential);
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
    /// Returns a token to validate with the portal before saving it.
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

        self.state = State::AwaitingPortal;
        Ok(token)
    }

    /// Saves an accepted token and its sign-in settings, replacing any stored credential.
    ///
    /// Performs I/O.
    pub fn sign_in_with_token(&mut self, token: &SecretString, settings: SignInSettings) {
        self.save_token(token, Some(settings));
    }

    /// Attaches missing sign-in settings to an existing token, for compatibility
    /// with credentials saved by older clients.
    pub fn attach_sign_in_settings_to_token(&mut self, settings: SignInSettings) {
        let State::SignedIn(Credential {
            token,
            sign_in_settings: None,
        }) = &self.state
        else {
            return;
        };
        let token = token.clone();
        self.save_token(&token, Some(settings));
    }

    fn save_token(&mut self, token: &SecretString, sign_in_settings: Option<SignInSettings>) {
        let credential = Credential {
            token: token.clone(),
            sign_in_settings,
        };
        let result = (|| -> Result<()> {
            // This MUST be the only place the GUI can call `set_password`.
            self.token_entry
                .set_password(token.expose_secret())
                .context("Failed to save token in keyring")?;
            let settings = credential
                .sign_in_settings
                .as_ref()
                .map(serde_json::to_string)
                .transpose()?
                .unwrap_or_default();
            self.token_entry
                .update_attributes(&std::collections::HashMap::from([(
                    SIGN_IN_SETTINGS_ATTRIBUTE,
                    settings.as_str(),
                )]))
                .context("Failed to save sign-in settings in keyring")?;
            Ok(())
        })();
        if let Err(e) = result {
            tracing::info!("{e:#}"); // Log that we couldn't save it and allow the user to continue anyway.
        }
        self.state = State::SignedIn(credential);
    }

    /// Returns the accepted token and its captured sign-in settings.
    pub fn credential(&self) -> Option<&Credential> {
        match &self.state {
            State::SignedIn(credential) => Some(credential),
            State::NeedResponse(_) => None,
            State::AwaitingPortal => None,
            State::SignedOut => None,
        }
    }

    pub fn is_signed_out(&self) -> bool {
        matches!(self.state, State::SignedOut)
    }

    /// Retrieves the credential from the keyring regardless of in-memory state.
    ///
    /// Performs I/O
    fn credential_from_keyring(&self) -> Option<Credential> {
        // This MUST be the only place the GUI can call `get_password`.
        let token = self.token_entry.get_password().ok()?.into();
        let sign_in_settings = self
            .token_entry
            .get_attributes()
            .ok()
            .and_then(|mut attributes| attributes.remove(SIGN_IN_SETTINGS_ATTRIBUTE))
            .filter(|settings| !settings.is_empty())
            .and_then(|settings| {
                serde_json::from_str(&settings)
                    .inspect_err(|_| tracing::debug!("Couldn't read saved sign-in settings"))
                    .ok()
            });
        Some(Credential {
            token,
            sign_in_settings,
        })
    }

    pub fn ongoing_request(&self) -> Option<&Request> {
        match &self.state {
            State::NeedResponse(x) => Some(x),
            State::SignedIn(_) => None,
            State::AwaitingPortal => None,
            State::SignedOut => None,
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
    let mut this = Auth::new()?;
    this.save_token(
        &SecretString::from("obviously invalid token for testing #6791".to_string()),
        None,
    );
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
            assert!(state.credential().is_none());

            // User clicks "Sign In", build a fake server response
            let req = state.start_sign_in().unwrap();
            let resp = Response {
                fragment: bogus_secret("fragment"),
                state: req.state.clone(),
                control_plane: None,
            };

            let replay = Response {
                fragment: resp.fragment.clone(),
                state: resp.state.clone(),
                control_plane: resp.control_plane,
            };
            let token = state.handle_response(resp).unwrap();
            assert!(matches!(state.state, State::AwaitingPortal));
            assert!(!state.is_signed_out());
            assert!(state.ongoing_request().is_none());
            assert!(state.credential().is_none());
            assert!(state.token_entry.get_password().is_err());
            assert!(matches!(
                state.handle_response(replay),
                Err(Error::NoInflightRequest)
            ));
            assert!(matches!(state.state, State::AwaitingPortal));
            assert!(state.token_entry.get_password().is_err());
            state.sign_in_with_token(&token, sign_in_settings());
            assert_eq!(
                state.credential().unwrap().sign_in_settings,
                Some(sign_in_settings())
            );
            assert_eq!(
                state.credential().unwrap().token.expose_secret(),
                token.expose_secret()
            );
        }

        // Recreate the state to simulate closing and re-opening the app
        {
            let mut state =
                Auth::new_with_key(key, store.clone(), session_dir.path().to_path_buf()).unwrap();

            // Make sure we automatically got the token back
            assert!(state.credential().is_some());
            assert!(state.credential().unwrap().sign_in_settings.is_none());

            // Accidentally sign in again, this can happen if the user holds the systray menu open while a sign in is succeeding.
            // For now, we treat that like signing out and back in immediately, so it wipes the old token.
            // TODO: That sounds wrong.
            let req = state.start_sign_in().unwrap();
            let response = Response {
                fragment: bogus_secret("another-fragment"),
                state: req.state.clone(),
                control_plane: None,
            };
            state.handle_response(response).unwrap();
            assert!(matches!(state.state, State::AwaitingPortal));
            assert!(state.credential().is_none());

            // Sign out again, now the token is gone
            state.sign_out().unwrap();
            assert!(state.credential().is_none());
            assert!(state.is_signed_out());
        }
        let state = Auth::new_with_key(key, store, session_dir.path().to_path_buf()).unwrap();
        assert!(state.credential().is_none());
    }

    fn sign_in_settings() -> SignInSettings {
        SignInSettings {
            account_slug: Some("example".to_owned()),
            auth_url: "https://app.firezone.dev/".parse().unwrap(),
            api_url: "wss://api.firezone.dev/".parse().unwrap(),
        }
    }

    #[test]
    fn attaching_settings_while_signed_out_does_not_create_a_token() {
        let session_dir = tempdir().unwrap();
        let mut auth = Auth::new_with_key(
            "dev.firezone.client/test_attach_signed_out/token",
            keyring_core::mock::Store::new().unwrap(),
            session_dir.path().to_path_buf(),
        )
        .unwrap();

        auth.attach_sign_in_settings_to_token(sign_in_settings());

        assert!(auth.credential().is_none());
        assert!(auth.token_entry.get_password().is_err());
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
        assert!(state.credential().is_none());

        // If we get a deep link with no in-flight request, it's invalid
        let r = state.handle_response(Response {
            fragment: bogus_secret("fragment"),
            state: bogus_secret("state"),
            control_plane: None,
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
        assert!(state.credential().is_none());

        // User clicks "Sign In", build a fake server response
        state.start_sign_in().unwrap();
        let resp = Response {
            fragment: bogus_secret("fragment"),
            state: SecretString::from(
                "bogus state from a replay attack or browser mis-click".to_string(),
            ),
            control_plane: Some(crate::settings::ControlPlane::CloudEu),
        };
        assert!(state.credential().is_none());

        // Handle deep link from the server, we should get an error
        let r = state.handle_response(resp);
        match r {
            Err(Error::StatesDontMatch) => {}
            _ => panic!("Expected StatesDontMatch error"),
        }
        assert!(state.credential().is_none());
        assert!(state.is_signed_out());
    }
}

//! Fulfills <https://github.com/firezone/firezone/issues/2823>

use crate::client::known_dirs;
use connlib_shared::control::SecureUrl;
use rand::{thread_rng, RngCore};
use secrecy::{ExposeSecret, Secret, SecretString};
use std::path::PathBuf;
use subtle::ConstantTimeEq;
use url::Url;

// TODO: Put this behind a "CI tests only" flag so that
// official CI builds, and default local builds won't get the mock
#[cfg(target_os = "linux")]
#[path = "auth/token_storage_mock.rs"]
mod token_storage;

#[cfg(not(target_os = "linux"))]
#[path = "auth/token_storage_keyring.rs"]
mod token_storage;

use token_storage::TokenStorage;

const NONCE_LENGTH: usize = 32;

#[derive(thiserror::Error, Debug)]
pub(crate) enum Error {
    #[error("`actor_name_path` has no parent, this should be impossible")]
    ActorNamePathWrong,
    #[error("`known_dirs` failed")]
    CantFindKnownDir,
    #[error("`create_dir_all` failed while writing `actor_name_path`")]
    CreateDirAll(std::io::Error),
    #[error("Couldn't delete actor_name from disk: {0}")]
    DeleteActorName(std::io::Error),
    #[error(transparent)]
    Keyring(#[from] keyring::Error),
    #[error("No in-flight request")]
    NoInflightRequest,
    #[error("Couldn't read actor_name from disk: {0}")]
    ReadActorName(std::io::Error),
    #[error("State in server response doesn't match state in client request")]
    StatesDontMatch,
    #[error("Couldn't write actor_name to disk: {0}")]
    WriteActorName(std::io::Error),
}

type Result<T> = std::result::Result<T, Error>;

pub(crate) struct Auth {
    /// Implementation details in case we want to disable `keyring-rs`
    token_store: TokenStorage,
    state: State,
}

pub(crate) enum State {
    SignedOut,
    NeedResponse(Request),
    SignedIn(Session),
}

pub(crate) struct Request {
    nonce: SecretString,
    state: SecretString,
}

impl Request {
    pub fn to_url(&self, auth_base_url: &Url) -> Secret<SecureUrl> {
        let mut url = auth_base_url.clone();
        url.query_pairs_mut()
            .append_pair("as", "client")
            .append_pair("nonce", self.nonce.expose_secret())
            .append_pair("state", self.state.expose_secret());
        Secret::from(SecureUrl::from_url(url))
    }
}

pub(crate) struct Response {
    pub actor_name: String,
    pub fragment: SecretString,
    pub state: SecretString,
}

pub(crate) struct Session {
    pub actor_name: String,
}

pub(crate) struct SessionAndToken {
    session: Session,
    token: SecretString,
}

impl Auth {
    /// Creates a new Auth struct using the "dev.firezone.client/token" keyring key. If the token is stored on disk, the struct is automatically signed in.
    ///
    /// Performs I/O.
    pub fn new() -> Result<Self> {
        Self::new_with_key("dev.firezone.client/token")
    }

    /// Creates a new Auth struct with a custom keyring key for testing.
    fn new_with_key(keyring_key: &'static str) -> Result<Self> {
        let token_store = TokenStorage::new(keyring_key);
        let mut this = Self {
            token_store,
            state: State::SignedOut,
        };

        if let Some(SessionAndToken { session, token: _ }) = this.get_token_from_disk()? {
            this.state = State::SignedIn(session);
            tracing::debug!("Reloaded token");
        }

        Ok(this)
    }

    /// Returns the session iff we are signed in.
    pub fn session(&self) -> Option<&Session> {
        match &self.state {
            State::SignedIn(x) => Some(x),
            _ => None,
        }
    }

    /// Mark the session as signed out, or cancel an ongoing sign-in flow
    ///
    /// Performs I/O.
    pub fn sign_out(&mut self) -> Result<()> {
        self.token_store.delete()?;
        if let Err(error) = std::fs::remove_file(actor_name_path()?) {
            // Ignore NotFound, since the file is gone anyway
            if error.kind() != std::io::ErrorKind::NotFound {
                return Err(Error::DeleteActorName(error));
            }
        }
        self.state = State::SignedOut;
        Ok(())
    }

    /// Start a new sign-in flow, replacing any ongoing flow
    ///
    /// Returns parameters used to make a URL for the web browser to open
    /// May return Ok(None) if we're already signed in
    pub fn start_sign_in(&mut self) -> Result<Option<&Request>> {
        self.sign_out()?;
        self.state = State::NeedResponse(Request {
            nonce: generate_nonce(),
            state: generate_nonce(),
        });
        Ok(Some(self.ongoing_request()?))
    }

    /// Complete an ongoing sign-in flow using parameters from a deep link
    ///
    /// Returns a valid token.
    /// Performs I/O.
    ///
    /// Errors if we don't have any ongoing flow, or if the response is invalid
    pub fn handle_response(&mut self, resp: Response) -> Result<SecretString> {
        let req = self.ongoing_request()?;

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

        // This MUST be the only place the GUI can call `set_password`, since
        // the actor name is also saved here.
        self.token_store.set(token.clone())?;
        let path = actor_name_path()?;
        std::fs::create_dir_all(path.parent().ok_or(Error::ActorNamePathWrong)?)
            .map_err(Error::CreateDirAll)?;
        std::fs::write(path, resp.actor_name.as_bytes()).map_err(Error::WriteActorName)?;
        self.state = State::SignedIn(Session {
            actor_name: resp.actor_name,
        });
        Ok(SecretString::from(token))
    }

    /// Returns the token if we are signed in
    ///
    /// This will always make syscalls, but it should be fast enough for normal use.
    pub fn token(&self) -> Result<Option<SecretString>> {
        match self.state {
            State::SignedIn(_) => {}
            _ => return Ok(None),
        }

        Ok(self
            .get_token_from_disk()?
            .map(|session_and_token| session_and_token.token))
    }

    /// Retrieves the token from disk regardless of in-memory state
    ///
    /// Performs I/O
    fn get_token_from_disk(&self) -> Result<Option<SessionAndToken>> {
        let actor_name = match std::fs::read_to_string(actor_name_path()?) {
            Ok(x) => x,
            // It can happen with dev systems that actor_name.txt doesn't exist
            // even though the token is in the cred manager.
            // In that case we just say the app is signed out
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(Error::ReadActorName(e)),
        };

        // This MUST be the only place the GUI can call `get_password`, since the
        // actor name is also loaded here.
        let Some(token) = self.token_store.get()? else {
            return Ok(None);
        };

        Ok(Some(SessionAndToken {
            session: Session { actor_name },
            token,
        }))
    }

    pub fn ongoing_request(&self) -> Result<&Request> {
        match &self.state {
            State::NeedResponse(x) => Ok(x),
            _ => Err(Error::NoInflightRequest),
        }
    }
}

/// Returns a path to a file where we can save the actor name
///
/// Hopefully we don't need to save anything else, or there will be a migration step
fn actor_name_path() -> Result<PathBuf> {
    Ok(known_dirs::session()
        .ok_or(Error::CantFindKnownDir)?
        .join("actor_name.txt"))
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

#[cfg(test)]
mod tests {
    use super::*;

    fn bogus_secret(x: &str) -> SecretString {
        SecretString::new(x.into())
    }

    /// Runs everything in one test so that `cargo test` can't multi-thread it
    /// This should work around a bug we had <https://github.com/firezone/firezone/issues/3256>
    #[test]
    fn everything() -> anyhow::Result<()> {
        // Run `happy_path` first to make sure it reacts okay if our `data` dir is missing
        // TODO: Re-enable happy path tests once `keyring-rs` is working in CI tests
        // happy_path("");
        // happy_path("Jane Doe");
        utils();
        no_inflight_request();
        states_dont_match();
        Ok(())
    }

    fn utils() {
        // This doesn't test for constant-time properties, it just makes sure the function
        // gives the right result
        let f = |a: &str, b: &str| secure_equality(&bogus_secret(a), &bogus_secret(b));

        assert!(f("1234", "1234"));
        assert!(!f("1234", "123"));
        assert!(!f("1234", "1235"));

        let hex_string = generate_nonce();
        let hex_string = hex_string.expose_secret();
        assert_eq!(hex_string.len(), NONCE_LENGTH * 2);
        dbg!(hex_string);

        let auth_base_url = Url::parse("https://app.firez.one").unwrap();
        let req = Request {
            nonce: bogus_secret("some_nonce"),
            state: bogus_secret("some_state"),
        };
        assert_eq!(
            req.to_url(&auth_base_url).expose_secret().inner,
            Url::parse("https://app.firez.one?as=client&nonce=some_nonce&state=some_state")
                .unwrap()
        );
    }

    // TODO: Fix this test
    fn _happy_path(actor_name: &str) {
        // Key for credential manager. This is not what we use in production
        let key = "dev.firezone.client/test_DMRCZ67A_happy_path/token";

        {
            // Start the program
            let mut state = Auth::new_with_key(key).unwrap();

            // Delete any token on disk from previous test runs
            state.sign_out().unwrap();
            assert!(state.token().unwrap().is_none());

            // User clicks "Sign In", build a fake server response
            let req = state.start_sign_in().unwrap().unwrap();
            let resp = Response {
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
            let mut state = Auth::new_with_key(key).unwrap();

            // Make sure we automatically got the token and actor_name back
            assert!(state.token().unwrap().is_some());
            assert_eq!(state.session().unwrap().actor_name, actor_name);

            // Accidentally sign in again, this can happen if the user holds the systray menu open while a sign in is succeeding.
            // For now, we treat that like signing out and back in immediately, so it wipes the old token.
            // TODO: That sounds wrong.
            assert!(state.start_sign_in().unwrap().is_some());
            assert!(state.token().unwrap().is_none());

            // Sign out again, now the token is gone
            state.sign_out().unwrap();
            assert!(state.token().unwrap().is_none());
        }
    }

    fn no_inflight_request() {
        // Start the program
        let mut state =
            Auth::new_with_key("dev.firezone.client/test_DMRCZ67A_invalid_response/token").unwrap();

        // Delete any token on disk from previous test runs
        state.sign_out().unwrap();
        assert!(state.token().unwrap().is_none());

        // If we get a deep link with no in-flight request, it's invalid
        let r = state.handle_response(Response {
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

    fn states_dont_match() {
        // Start the program
        let mut state =
            Auth::new_with_key("dev.firezone.client/test_DMRCZ67A_states_dont_match/token")
                .unwrap();

        // Delete any token on disk from previous test runs
        state.sign_out().unwrap();
        assert!(state.token().unwrap().is_none());

        // User clicks "Sign In", build a fake server response
        state.start_sign_in().unwrap();
        let resp = Response {
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

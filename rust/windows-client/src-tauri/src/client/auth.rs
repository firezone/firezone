//! Fulfills <https://github.com/firezone/firezone/issues/2823>

use connlib_shared::control::SecureUrl;
use rand::{thread_rng, RngCore};
use secrecy::{ExposeSecret, Secret, SecretString};
use subtle::ConstantTimeEq;
use url::Url;

const NONCE_LENGTH: usize = 32;

#[derive(thiserror::Error, Debug)]
pub(crate) enum Error {
    #[error(transparent)]
    Keyring(#[from] keyring::Error),
    #[error("No in-flight request")]
    NoInflightRequest,
    #[error("State in server response doesn't match state in client request")]
    StatesDontMatch,
}

type Result<T> = std::result::Result<T, Error>;

pub(crate) struct Auth {
    /// Key for secure keyrings, e.g. "dev.firezone.client/token" for releases
    /// and something else for automated tests of the auth module.
    keyring_key: &'static str,
    state: State,
}

pub(crate) enum State {
    SignedOut,
    // TODO: Need a way to time out this state if the server never signs us in
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

impl Auth {
    /// Creates a new Auth struct using the "dev.firezone.client/token" keyring key. If the token is stored on disk, the struct is automatically signed in.
    ///
    /// Performs I/O.
    pub fn new() -> Result<Self> {
        Self::new_with_key("dev.firezone.client/token")
    }

    /// Creates a new Auth struct with a custom keyring key for testing.
    fn new_with_key(keyring_key: &'static str) -> Result<Self> {
        let mut this = Self {
            keyring_key,
            state: State::SignedOut,
        };

        if this.get_token_from_disk()?.is_some() {
            this.state = State::SignedIn(Session {
                // TODO: Save and reload actor name to/from disk
                actor_name: "TODO".to_string(),
            });
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
        // TODO: After we store the actor name on disk, clear the actor name here too.
        match self.keyring_entry()?.delete_password() {
            Ok(_) | Err(keyring::Error::NoEntry) => {}
            Err(e) => Err(e)?,
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
        self.keyring_entry()?.set_password(&token)?;
        self.state = State::SignedIn(Session {
            actor_name: resp.actor_name,
        });
        Ok(SecretString::from(token))
    }

    /// Returns the token if we are signed in
    ///
    /// This may always make syscalls, but it should be fast enough for normal use.
    pub fn token(&self) -> Result<Option<SecretString>> {
        match self.state {
            State::SignedIn(_) => {}
            _ => return Ok(None),
        }

        self.get_token_from_disk()
    }

    /// Retrieves the token from disk regardless of in-memory state
    ///
    /// Performs I/O
    fn get_token_from_disk(&self) -> Result<Option<SecretString>> {
        Ok(match self.keyring_entry()?.get_password() {
            Err(keyring::Error::NoEntry) => None,
            Ok(token) => Some(SecretString::from(token)),
            Err(e) => Err(e)?,
        })
    }

    /// Returns an Entry into the OS' credential manager
    ///
    /// Anything you do in there is technically blocking I/O.
    fn keyring_entry(&self) -> Result<keyring::Entry> {
        Ok(keyring::Entry::new_with_target(self.keyring_key, "", "")?)
    }

    pub fn ongoing_request(&self) -> Result<&Request> {
        match &self.state {
            State::NeedResponse(x) => Ok(x),
            _ => Err(Error::NoInflightRequest),
        }
    }
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

    #[test]
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

    #[test]
    fn happy_path() {
        // Start the program
        let mut state =
            Auth::new_with_key("dev.firezone.client/test_DMRCZ67A_happy_path/token").unwrap();

        // Delete any token on disk from previous test runs
        state.sign_out().unwrap();
        assert!(state.token().unwrap().is_none());

        // User clicks "Sign In", build a fake server response
        let req = state.start_sign_in().unwrap().unwrap();

        let resp = Response {
            actor_name: "Jane Doe".into(),
            fragment: bogus_secret("fragment"),
            state: req.state.clone(),
        };
        assert!(state.token().unwrap().is_none());

        // Handle deep link from the server, now we are signed in and have a token
        state.handle_response(resp).unwrap();
        assert!(state.token().unwrap().is_some());

        // Accidentally sign in again, this can happen if the user holds the systray menu open while a sign in is succeeding.
        // For now, we treat that like signing out and back in immediately, so it wipes the old token.
        // TODO: That sounds wrong.
        assert!(state.start_sign_in().unwrap().is_some());
        assert!(state.token().unwrap().is_none());

        // Sign out again, now the token is gone
        state.sign_out().unwrap();
        assert!(state.token().unwrap().is_none());
    }

    #[test]
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

    #[test]
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

    #[test]
    fn test_keyring() -> anyhow::Result<()> {
        // I used this test to find that `service` is not used - We have to namespace on our own.

        let name_1 = "dev.firezone.client/test_1/token";
        let name_2 = "dev.firezone.client/test_2/token";

        keyring::Entry::new_with_target(name_1, "", "")?.set_password("test_password_1")?;

        keyring::Entry::new_with_target(name_2, "", "")?.set_password("test_password_2")?;

        let actual = keyring::Entry::new_with_target(name_1, "", "")?.get_password()?;
        let expected = "test_password_1";

        assert_eq!(actual, expected);

        keyring::Entry::new_with_target(name_1, "", "")?.delete_password()?;
        keyring::Entry::new_with_target(name_2, "", "")?.delete_password()?;

        Ok(())
    }
}

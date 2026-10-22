//! The authentication scheme for the TURN server.
//!
//! TURN specifies two ways of authentication: long-term credentials & short-term credentials.
//! For details on those, please consult the RFC: <https://www.rfc-editor.org/rfc/rfc8489.html#section-9>.
//!
//! This implementation only supports long-term credentials.
//!
//! ## Client authentication
//!
//! On startup, the server generates a 32-byte secret (referred to as `relay_secret`) that is only ever stored in-memory.
//! This secret is shared with the Firezone portal upon connecting with the WebSocket.
//! The portal uses this secret to generate credentials for each TURN client.
//! The credentials take the form of:
//!
//! - account-bound username: `{unix_expiry_timestamp}:{account_hash}:{salt}`
//! - account-bound password: `sha256({username}:{relay_secret})`
//!
//! As such, a TURN client can never create a set of credentials themselves because they are missing the `relay_secret`.
//! In addition, a relay can validate such a username and password combination without having to store any state other than the `relay_secret`.
//!
//! All STUN messages other than `BINDING` requests MUST be authenticated by the client.
//!
//! ## Server authentication
//!
//! In addition to authenticating all messages from the client with the server, a server will authenticate its messages to the client.
//! This also uses the long-term credentials mechanism using the same username and password.
//! In other words, the server will authenticate the messages sent to the client with the client's username and password.
//!
//! ## Security considerations
//!
//! The password is a shared secret and thus ensures message integrity and authenticity to the client.
//! An observer on the network path does not have knowledge of the `relay_secret` and thus cannot fake a relay's identity.
//!
//! Each client will receive a different pair of username and password.
//! Thus, even with valid credentials, an attacker cannot reuse those credentials to fake responses for a different client.

use base64::Engine;
use base64::prelude::BASE64_STANDARD_NO_PAD;
use bytecodec::Encode;
use once_cell::sync::Lazy;
use rand::RngExt;
use secrecy::{ExposeSecret, SecretString};
use sha2::digest::FixedOutput;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::fmt;
use std::time::{Duration, SystemTime};
use stun_codec::Message;
use stun_codec::rfc5389::attributes::{MessageIntegrity, Realm, Username};
use uuid::Uuid;

use crate::{Attribute, ClientSocket};

// TODO: Upstream a const constructor to `stun-codec`.
pub static FIREZONE: Lazy<Realm> =
    Lazy::new(|| Realm::new("firezone".to_owned()).expect("static realm is less than 128 chars"));

pub(crate) trait MessageIntegrityExt {
    fn verify(
        &self,
        relay_secret: &SecretString,
        username: &str,
        now: SystemTime,
    ) -> Result<AccountIdHash, Error>;
}

impl MessageIntegrityExt for MessageIntegrity {
    fn verify(
        &self,
        relay_secret: &SecretString,
        username: &str,
        now: SystemTime,
    ) -> Result<AccountIdHash, Error> {
        let username = parse_username(username)?;
        let expiry = username.expiry();
        let expires_at = systemtime_from_unix(expiry).ok_or(Error::InvalidUsername)?;

        if expires_at < now {
            return Err(Error::Expired);
        }

        let password = generate_password_for_username(relay_secret, &username);

        self.check_long_term_credential(
            &Username::new(username.as_str().to_owned()).map_err(|_| Error::InvalidUsername)?,
            &FIREZONE,
            &password,
        )
        .map_err(|_| Error::InvalidPassword)?;

        Ok(AccountIdHash(username.account().to_owned()))
    }
}

pub(crate) struct AuthenticatedMessage(Message<Attribute>);

impl AuthenticatedMessage {
    /// Creates a new [`AuthenticatedMessage`] that isn't actually authenticated.
    ///
    /// This should only be used in circumstances where we cannot authenticate the message because e.g. the original request wasn't authenticated either.
    pub(crate) fn new_dangerous_unauthenticated(message: Message<Attribute>) -> Self {
        Self(message)
    }

    pub(crate) fn new(
        relay_secret: &SecretString,
        username: &Username,
        mut message: Message<Attribute>,
    ) -> Result<Self, Error> {
        let parsed_username = parse_username(username.name())?;
        let password = generate_password_for_username(relay_secret, &parsed_username);

        let message_integrity =
            MessageIntegrity::new_long_term_credential(&message, username, &FIREZONE, &password)?;

        message.add_attribute(message_integrity);

        Ok(Self(message))
    }

    pub fn class(&self) -> stun_codec::MessageClass {
        self.0.class()
    }

    pub fn method(&self) -> stun_codec::Method {
        self.0.method()
    }

    pub fn get_attribute<T>(&self) -> Option<&T>
    where
        T: stun_codec::Attribute,
        Attribute: stun_codec::convert::TryAsRef<T>,
    {
        self.0.get_attribute()
    }
}

#[derive(Debug, Default)]
pub(crate) struct MessageEncoder(stun_codec::MessageEncoder<Attribute>);

impl Encode for MessageEncoder {
    type Item = AuthenticatedMessage;

    fn encode(&mut self, buf: &mut [u8], eos: bytecodec::Eos) -> bytecodec::Result<usize> {
        self.0.encode(buf, eos)
    }

    fn start_encoding(&mut self, item: Self::Item) -> bytecodec::Result<()> {
        self.0.start_encoding(item.0)
    }

    fn requiring_bytes(&self) -> bytecodec::ByteCount {
        self.0.requiring_bytes()
    }
}

/// Tracks valid nonces for the TURN relay.
///
/// The semantic nature of nonces is an implementation detail of the relay in TURN.
/// This could just as easily also be a time-based logic (i.e. nonces are valid for 10min).
///
/// For simplicity reasons, we use a count-based strategy.
/// Each nonce can be used for a certain number of requests before it is invalid.
///
/// We remember the nonce we last handed out to each client socket and keep
/// reusing it for as long as it is valid, rather than minting a fresh one on
/// every request. This bounds the stored nonces to one per client socket
/// instead of one per request.
#[derive(Default, Debug, Clone)]
pub(crate) struct Nonces {
    inner: HashMap<ClientSocket, Nonce>,
}

#[derive(Debug, Clone, Copy)]
struct Nonce {
    value: Uuid,
    remaining_requests: u64,
}

impl Nonces {
    /// How many requests a client can perform with the same nonce.
    const NUM_REQUESTS: u64 = 10_000;

    /// Returns a valid nonce for the given client.
    ///
    /// If we have already issued a nonce to this client that is still valid, the
    /// same nonce is returned. Otherwise, a fresh one is minted using `rng`.
    pub(crate) fn issue(&mut self, client: ClientSocket, rng: &mut impl RngExt) -> Uuid {
        if let Some(nonce) = self
            .inner
            .get(&client)
            .filter(|nonce| nonce.remaining_requests > 0)
        {
            return nonce.value;
        }

        let value = Uuid::from_u128(rng.random());
        self.add_new(client, value);

        value
    }

    pub(crate) fn add_new(&mut self, client: ClientSocket, value: Uuid) {
        self.inner.insert(
            client,
            Nonce {
                value,
                remaining_requests: Self::NUM_REQUESTS,
            },
        );
    }

    /// Record the usage of a nonce in a request.
    pub(crate) fn handle_nonce_used(
        &mut self,
        client: ClientSocket,
        value: Uuid,
    ) -> Result<(), Error> {
        let mut entry = match self.inner.entry(client) {
            Entry::Vacant(_) => return Err(Error::UnknownNonce),
            Entry::Occupied(entry) => entry,
        };

        let nonce = entry.get_mut();

        if nonce.value != value {
            return Err(Error::UnknownNonce);
        }

        if nonce.remaining_requests == 0 {
            entry.remove();

            return Err(Error::NonceUsedUp);
        }

        nonce.remaining_requests -= 1;

        Ok(())
    }
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum Error {
    #[error("expired")]
    Expired,
    #[error("invalid password")]
    InvalidPassword,
    #[error("invalid username")]
    InvalidUsername,
    #[error("nonce has been used up")]
    NonceUsedUp,
    #[error("unknown nonce")]
    UnknownNonce,
    #[error("cannot authenticate message")]
    CannotAuthenticate(#[from] bytecodec::Error),
}

/// The SHA-256 account ID digest carried in an account-bound TURN credential.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct AccountIdHash(String);

impl fmt::Display for AccountIdHash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

/// An account UUID received from the Portal.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, serde::Deserialize)]
#[serde(transparent)]
pub struct AccountId(Uuid);

impl From<Uuid> for AccountId {
    fn from(value: Uuid) -> Self {
        Self(value)
    }
}

impl fmt::Display for AccountId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

struct ParsedUsername<'a> {
    raw: &'a str,
    expiry: u64,
    account: &'a str,
}

impl<'a> ParsedUsername<'a> {
    fn as_str(&self) -> &'a str {
        self.raw
    }

    fn expiry(&self) -> u64 {
        self.expiry
    }

    fn account(&self) -> &'a str {
        self.account
    }
}

fn parse_username(username: &str) -> Result<ParsedUsername<'_>, Error> {
    let parts = username.split(':').collect::<Vec<&str>>();

    let (expiry, account) = match parts.as_slice() {
        [expiry, account, salt] if !account.is_empty() && !salt.is_empty() => (*expiry, *account),
        _ => return Err(Error::InvalidUsername),
    };

    let expiry = expiry.parse::<u64>().map_err(|_| Error::InvalidUsername)?;

    Ok(ParsedUsername {
        raw: username,
        expiry,
        account,
    })
}

pub fn generate_password(relay_secret: &SecretString, username: &str) -> String {
    let mut hasher = Sha256::default();
    hasher.update(username);
    hasher.update(":");
    hasher.update(relay_secret.expose_secret());

    BASE64_STANDARD_NO_PAD.encode(hasher.finalize_fixed().as_slice())
}

pub fn hash_account_id(account_id: &AccountId) -> AccountIdHash {
    AccountIdHash(BASE64_STANDARD_NO_PAD.encode(Sha256::digest(account_id.to_string()).as_slice()))
}

fn generate_password_for_username(
    relay_secret: &SecretString,
    username: &ParsedUsername<'_>,
) -> String {
    generate_password(relay_secret, username.as_str())
}

/// Converts a UNIX timestamp in seconds to a [`SystemTime`].
///
/// Returns [`None`] if the timestamp is too far in the future to be represented as a [`SystemTime`].
pub(crate) fn systemtime_from_unix(seconds: u64) -> Option<SystemTime> {
    SystemTime::UNIX_EPOCH.checked_add(Duration::from_secs(seconds))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Attribute;
    use rand::{SeedableRng as _, rngs::StdRng};
    use std::net::SocketAddr;
    use stun_codec::rfc5389::methods::BINDING;
    use stun_codec::{Message, MessageClass, TransactionId};

    const RELAY_SECRET_1: &str = "4c98bf59c99b3e467ecd7cf9d6b3e5279645fca59be67bc5bb4af3cf653761ab";
    const RELAY_SECRET_2: &str = "7e35e34801e766a6a29ecb9e22810ea4e3476c2b37bf75882edf94a68b1d9607";
    const SAMPLE_USERNAME: &str = "n23JJ2wKKtt30oXi";

    #[test]
    fn generate_password_test_vector() {
        let expiry = 60 * 60 * 24 * 365 * 60;
        let username = format!("{expiry}:account:{SAMPLE_USERNAME}");

        let password = generate_password(&RELAY_SECRET_1.into(), &username);

        assert_eq!(password, "NQjDRIWM/rciGma9AI95ZGJ+lljzOQLtXs61DOJnT1I")
    }

    #[test]
    fn generate_password_test_vector_elixir() {
        let expiry = 1685984278;
        let account_id = AccountId::from(Uuid::nil());
        let account_hash = hash_account_id(&account_id);
        let username = format!("{expiry}:{account_hash}:uvdgKvS9GXYZ_vmv");
        let password = generate_password(&"1cab293a-4032-46f4-862a-40e5d174b0d2".into(), &username);
        assert_eq!(
            account_hash.to_string(),
            "Erk3fL5+XJTopw2dI5KVI9FK+pVHkxMPijlZx7hJrKg"
        );
        assert_eq!(password, "vNbf+vO+nDVJ2fcJjghxKu6oJVLDJbm9G6kh3XTySFA")
    }

    #[test]
    fn smoke() {
        let account = "account";
        let message_integrity = message_integrity(
            &RELAY_SECRET_1.into(),
            1685200000,
            account,
            "n23JJ2wKKtt30oXi",
        );

        let result = message_integrity.verify(
            &RELAY_SECRET_1.into(),
            "1685200000:account:n23JJ2wKKtt30oXi",
            systemtime_from_unix(1685200000 - 1000).unwrap(),
        );

        assert_eq!(result.unwrap().to_string(), account);
    }

    #[test]
    fn account_bound_credentials_bind_the_account_to_the_password() {
        let expiry = 1685200000;
        let account = "tYfHnH7PcN7e2TU4kl6hZ0w2l7s0mH85ySL0Vzjo0Fg";
        let username = format!("{expiry}:{account}:n23JJ2wKKtt30oXi");
        let parsed = parse_username(&username).unwrap();
        let password = generate_password_for_username(&RELAY_SECRET_1.into(), &parsed);
        let message_integrity = MessageIntegrity::new_long_term_credential(
            &sample_message(),
            &Username::new(username.clone()).unwrap(),
            &FIREZONE,
            &password,
        )
        .unwrap();

        assert_eq!(
            message_integrity
                .verify(
                    &RELAY_SECRET_1.into(),
                    &username,
                    systemtime_from_unix(expiry - 1_000).unwrap(),
                )
                .unwrap()
                .to_string(),
            account
        );

        let different_account = username.replacen(account, "other-account", 1);
        assert!(matches!(
            message_integrity.verify(
                &RELAY_SECRET_1.into(),
                &different_account,
                systemtime_from_unix(expiry - 1_000).unwrap(),
            ),
            Err(Error::InvalidPassword)
        ));
    }

    #[test]
    fn expired_is_not_valid() {
        let message_integrity = message_integrity(
            &RELAY_SECRET_1.into(),
            1685200000 - 1000,
            "account",
            "n23JJ2wKKtt30oXi",
        );

        let result = message_integrity.verify(
            &RELAY_SECRET_1.into(),
            "1685199000:account:n23JJ2wKKtt30oXi",
            systemtime_from_unix(1685200000).unwrap(),
        );

        assert!(matches!(result.unwrap_err(), Error::Expired))
    }

    #[test]
    fn different_relay_secret_makes_password_invalid() {
        let message_integrity = message_integrity(
            &RELAY_SECRET_2.into(),
            1685200000,
            "account",
            "n23JJ2wKKtt30oXi",
        );

        let result = message_integrity.verify(
            &RELAY_SECRET_1.into(),
            "1685200000:account:n23JJ2wKKtt30oXi",
            systemtime_from_unix(168520000 + 1000).unwrap(),
        );

        assert!(matches!(result.unwrap_err(), Error::InvalidPassword))
    }

    #[test]
    fn invalid_username_format_fails() {
        let message_integrity = message_integrity(
            &RELAY_SECRET_2.into(),
            1685200000,
            "account",
            "n23JJ2wKKtt30oXi",
        );

        let result = message_integrity.verify(
            &RELAY_SECRET_1.into(),
            "foobar",
            systemtime_from_unix(168520000 + 1000).unwrap(),
        );

        assert!(matches!(result.unwrap_err(), Error::InvalidUsername))
    }

    #[test]
    fn oversized_unix_expiry_is_invalid_username() {
        let message_integrity =
            message_integrity(&RELAY_SECRET_1.into(), u64::MAX, "account", SAMPLE_USERNAME);

        let result = message_integrity.verify(
            &RELAY_SECRET_1.into(),
            &format!("{}:account:{SAMPLE_USERNAME}", u64::MAX),
            systemtime_from_unix(1685200000).unwrap(),
        );

        assert!(matches!(result.unwrap_err(), Error::InvalidUsername))
    }

    #[test]
    fn nonces_are_valid_for_a_fixed_number_of_requests() {
        let mut nonces = Nonces::default();
        let client = client_socket(1);
        let nonce = Uuid::new_v4();

        nonces.add_new(client, nonce);

        for _ in 0..Nonces::NUM_REQUESTS {
            nonces.handle_nonce_used(client, nonce).unwrap();
        }

        assert!(matches!(
            nonces.handle_nonce_used(client, nonce).unwrap_err(),
            Error::NonceUsedUp
        ));
    }

    #[test]
    fn unknown_nonces_are_invalid() {
        let mut nonces = Nonces::default();
        let client = client_socket(1);
        let nonce = Uuid::new_v4();

        assert!(matches!(
            nonces.handle_nonce_used(client, nonce).unwrap_err(),
            Error::UnknownNonce
        ));
    }

    #[test]
    fn reuses_the_same_nonce_for_repeated_requests_from_one_client() {
        let mut nonces = Nonces::default();
        let client = client_socket(1);
        let mut rng = StdRng::seed_from_u64(0);

        let first = nonces.issue(client, &mut rng);
        let second = nonces.issue(client, &mut rng);

        assert_eq!(first, second);
    }

    #[test]
    fn issues_distinct_nonces_to_distinct_clients() {
        let mut nonces = Nonces::default();
        let mut rng = StdRng::seed_from_u64(0);

        let alice = nonces.issue(client_socket(1), &mut rng);
        let bob = nonces.issue(client_socket(2), &mut rng);

        assert_ne!(alice, bob);
    }

    #[test]
    fn a_nonce_issued_to_one_client_is_invalid_for_another() {
        let mut nonces = Nonces::default();
        let mut rng = StdRng::seed_from_u64(0);

        let nonce = nonces.issue(client_socket(1), &mut rng);

        assert!(matches!(
            nonces
                .handle_nonce_used(client_socket(2), nonce)
                .unwrap_err(),
            Error::UnknownNonce
        ));
    }

    #[test]
    fn issues_a_fresh_nonce_once_the_previous_one_is_used_up() {
        let mut nonces = Nonces::default();
        let client = client_socket(1);
        let mut rng = StdRng::seed_from_u64(0);

        let first = nonces.issue(client, &mut rng);
        for _ in 0..Nonces::NUM_REQUESTS {
            nonces.handle_nonce_used(client, first).unwrap();
        }

        let second = nonces.issue(client, &mut rng);

        assert_ne!(first, second);
    }

    fn message_integrity(
        relay_secret: &SecretString,
        username_expiry: u64,
        account: &str,
        username_salt: &str,
    ) -> MessageIntegrity {
        let username =
            Username::new(format!("{username_expiry}:{account}:{username_salt}")).unwrap();
        let password = generate_password(relay_secret, username.name());

        MessageIntegrity::new_long_term_credential(
            &sample_message(),
            &username,
            &FIREZONE,
            &password,
        )
        .unwrap()
    }

    fn sample_message() -> Message<Attribute> {
        Message::new(
            MessageClass::Request,
            BINDING,
            TransactionId::new([0u8; 12]),
        )
    }

    fn client_socket(id: u8) -> ClientSocket {
        ClientSocket::new(SocketAddr::from(([127, 0, 0, id], 51820)))
    }
}

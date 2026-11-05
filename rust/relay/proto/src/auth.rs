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
//! - account-bound username: `{unix_expiry_timestamp}:{account_hash}:{device_hash}`
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
use hmac::{Hmac, KeyInit as _, Mac as _};
use once_cell::sync::Lazy;
use secrecy::{ExposeSecret, SecretString};
use sha2::digest::FixedOutput;
use sha2::{Digest, Sha256};
use std::fmt;
use std::net::IpAddr;
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
    ) -> Result<AllocationKey, Error>;
}

impl MessageIntegrityExt for MessageIntegrity {
    fn verify(
        &self,
        relay_secret: &SecretString,
        username: &str,
        now: SystemTime,
    ) -> Result<AllocationKey, Error> {
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

        Ok(AllocationKey {
            account: AccountIdHash(username.account().to_owned()),
            device: username.device.to_owned(),
        })
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

/// Issues and checks nonces for the TURN relay.
///
/// Nonces are stateless: each one is an HMAC of the client socket and a time window.
/// This way, the relay does not store anything for a client before it authenticates.
///
/// A nonce is valid in the window it was issued in and in the next one.
#[derive(Clone)]
pub(crate) struct Nonces {
    key: [u8; 32],
}

impl fmt::Debug for Nonces {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Nonces").finish_non_exhaustive()
    }
}

impl Nonces {
    /// How long a single time window is.
    pub(crate) const WINDOW: Duration = Duration::from_secs(10 * 60);

    pub(crate) fn new(key: [u8; 32]) -> Self {
        Self { key }
    }

    /// Returns a valid nonce for the given client.
    pub(crate) fn issue(&self, client: ClientSocket, now: SystemTime) -> String {
        let window = window_at(now);
        let tag = self.mac(client, window).finalize().into_bytes();

        format!("{window}:{}", hex::encode(tag))
    }

    /// Checks that the nonce was issued to this client and has not expired.
    pub(crate) fn verify(
        &self,
        client: ClientSocket,
        nonce: &str,
        now: SystemTime,
    ) -> Result<(), Error> {
        let (window, tag) = nonce.split_once(':').ok_or(Error::UnknownNonce)?;
        let window = window.parse::<u64>().map_err(|_| Error::UnknownNonce)?;
        let tag = hex::decode(tag).map_err(|_| Error::UnknownNonce)?;

        self.mac(client, window)
            .verify_slice(&tag)
            .map_err(|_| Error::UnknownNonce)?;

        let current = window_at(now);

        if window > current || current - window > 1 {
            return Err(Error::StaleNonce);
        }

        Ok(())
    }

    fn mac(&self, client: ClientSocket, window: u64) -> Hmac<Sha256> {
        let socket = client.into_socket();
        let mut mac =
            Hmac::<Sha256>::new_from_slice(&self.key).expect("HMAC accepts keys of any size");

        match socket.ip() {
            IpAddr::V4(ip) => mac.update(&ip.octets()),
            IpAddr::V6(ip) => mac.update(&ip.octets()),
        }
        mac.update(&socket.port().to_be_bytes());
        mac.update(&window.to_be_bytes());

        mac
    }
}

fn window_at(now: SystemTime) -> u64 {
    now.duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        / Nonces::WINDOW.as_secs()
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum Error {
    #[error("expired")]
    Expired,
    #[error("invalid password")]
    InvalidPassword,
    #[error("invalid username")]
    InvalidUsername,
    #[error("nonce has expired")]
    StaleNonce,
    #[error("unknown nonce")]
    UnknownNonce,
    #[error("cannot authenticate message")]
    CannotAuthenticate(#[from] bytecodec::Error),
}

/// The SHA-256 account ID digest carried in an account-bound TURN credential.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct AccountIdHash(String);

/// Identifies the owner of an allocation, independent of the credential's expiry.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub(crate) struct AllocationKey {
    pub(crate) account: AccountIdHash,
    device: String,
}

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
    device: &'a str,
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

    let (expiry, account, device) = match parts.as_slice() {
        [expiry, account, device] if !account.is_empty() && !device.is_empty() => {
            (*expiry, *account, *device)
        }
        _ => return Err(Error::InvalidUsername),
    };

    let expiry = expiry.parse::<u64>().map_err(|_| Error::InvalidUsername)?;

    Ok(ParsedUsername {
        raw: username,
        expiry,
        account,
        device,
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

        assert_eq!(result.unwrap().account.to_string(), account);
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
                .account
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
    fn nonce_is_valid_for_the_client_it_was_issued_to() {
        let nonces = Nonces::new([1; 32]);
        let now = systemtime_from_unix(1685200000).unwrap();

        let nonce = nonces.issue(client_socket(1), now);

        nonces.verify(client_socket(1), &nonce, now).unwrap();
    }

    #[test]
    fn issues_the_same_nonce_within_one_window() {
        let nonces = Nonces::new([1; 32]);
        let now = systemtime_from_unix(1685200000).unwrap();

        let first = nonces.issue(client_socket(1), now);
        let second = nonces.issue(client_socket(1), now + Duration::from_secs(1));

        assert_eq!(first, second);
    }

    #[test]
    fn issues_distinct_nonces_to_distinct_clients() {
        let nonces = Nonces::new([1; 32]);
        let now = systemtime_from_unix(1685200000).unwrap();

        let alice = nonces.issue(client_socket(1), now);
        let bob = nonces.issue(client_socket(2), now);

        assert_ne!(alice, bob);
    }

    #[test]
    fn a_nonce_issued_to_one_client_is_invalid_for_another() {
        let nonces = Nonces::new([1; 32]);
        let now = systemtime_from_unix(1685200000).unwrap();

        let nonce = nonces.issue(client_socket(1), now);

        assert!(matches!(
            nonces.verify(client_socket(2), &nonce, now).unwrap_err(),
            Error::UnknownNonce
        ));
    }

    #[test]
    fn a_nonce_issued_with_another_key_is_invalid() {
        let now = systemtime_from_unix(1685200000).unwrap();

        let nonce = Nonces::new([1; 32]).issue(client_socket(1), now);

        assert!(matches!(
            Nonces::new([2; 32])
                .verify(client_socket(1), &nonce, now)
                .unwrap_err(),
            Error::UnknownNonce
        ));
    }

    #[test]
    fn malformed_nonces_are_invalid() {
        let nonces = Nonces::new([1; 32]);
        let now = systemtime_from_unix(1685200000).unwrap();

        for nonce in ["", "foo", "1:", ":00", "x:00", "2808666:zz"] {
            assert!(matches!(
                nonces.verify(client_socket(1), nonce, now).unwrap_err(),
                Error::UnknownNonce
            ));
        }
    }

    #[test]
    fn a_nonce_stays_valid_in_the_next_window() {
        let nonces = Nonces::new([1; 32]);
        let now = systemtime_from_unix(1685200000).unwrap();

        let nonce = nonces.issue(client_socket(1), now);

        nonces
            .verify(client_socket(1), &nonce, now + Nonces::WINDOW)
            .unwrap();
    }

    #[test]
    fn a_nonce_expires_after_two_windows() {
        let nonces = Nonces::new([1; 32]);
        let now = systemtime_from_unix(1685200000).unwrap();

        let nonce = nonces.issue(client_socket(1), now);

        assert!(matches!(
            nonces
                .verify(client_socket(1), &nonce, now + Nonces::WINDOW * 2)
                .unwrap_err(),
            Error::StaleNonce
        ));
    }

    #[test]
    fn a_nonce_from_a_future_window_is_stale() {
        let nonces = Nonces::new([1; 32]);
        let now = systemtime_from_unix(1685200000).unwrap();

        let nonce = nonces.issue(client_socket(1), now + Nonces::WINDOW);

        assert!(matches!(
            nonces.verify(client_socket(1), &nonce, now).unwrap_err(),
            Error::StaleNonce
        ));
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

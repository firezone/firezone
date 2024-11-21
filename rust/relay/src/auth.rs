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
//! - username: `{unix_expiry_timestamp}:{salt}`
//! - password: `sha256({unix_expiry_timestamp}:{relay_secret}:{salt})`
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

use base64::prelude::BASE64_STANDARD_NO_PAD;
use base64::Engine;
use bytecodec::Encode;
use once_cell::sync::Lazy;
use secrecy::{ExposeSecret, SecretString};
use sha2::digest::FixedOutput;
use sha2::Sha256;
use std::collections::hash_map::Entry;
use std::collections::HashMap;
use std::time::{Duration, SystemTime};
use stun_codec::rfc5389::attributes::{MessageIntegrity, Realm, Username};
use stun_codec::Message;
use uuid::Uuid;

use crate::Attribute;

// TODO: Upstream a const constructor to `stun-codec`.
pub static FIREZONE: Lazy<Realm> =
    Lazy::new(|| Realm::new("firezone".to_owned()).expect("static realm is less than 128 chars"));

pub(crate) trait MessageIntegrityExt {
    fn verify(
        &self,
        relay_secret: &SecretString,
        username: &str,
        now: SystemTime,
    ) -> Result<(), Error>;
}

impl MessageIntegrityExt for MessageIntegrity {
    fn verify(
        &self,
        relay_secret: &SecretString,
        username: &str,
        now: SystemTime,
    ) -> Result<(), Error> {
        let (expiry_unix_timestamp, salt) = split_username(username)?;
        let expired = systemtime_from_unix(expiry_unix_timestamp);

        if expired < now {
            return Err(Error::Expired);
        }

        let password = generate_password(relay_secret, expired, salt);

        self.check_long_term_credential(
            &Username::new(format!("{}:{}", expiry_unix_timestamp, salt))
                .map_err(|_| Error::InvalidUsername)?,
            &FIREZONE,
            &password,
        )
        .map_err(|_| Error::InvalidPassword)?;

        Ok(())
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
        username: &str,
        mut message: Message<Attribute>,
    ) -> Result<Self, Error> {
        let (expiry_unix_timestamp, salt) = split_username(username)?;
        let expired = systemtime_from_unix(expiry_unix_timestamp);

        let username = Username::new(format!("{}:{}", expiry_unix_timestamp, salt))
            .map_err(|_| Error::InvalidUsername)?;
        let password = generate_password(relay_secret, expired, salt);

        let message_integrity =
            MessageIntegrity::new_long_term_credential(&message, &username, &FIREZONE, &password)?;

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
#[derive(Default, Debug, Clone)]
pub(crate) struct Nonces {
    inner: HashMap<Uuid, u64>,
}

impl Nonces {
    /// How many requests a client can perform with the same nonce.
    const NUM_REQUESTS: u64 = 100;

    pub(crate) fn add_new(&mut self, nonce: Uuid) {
        self.inner.insert(nonce, Self::NUM_REQUESTS);
    }

    /// Record the usage of a nonce in a request.
    pub(crate) fn handle_nonce_used(&mut self, nonce: Uuid) -> Result<(), Error> {
        let mut entry = match self.inner.entry(nonce) {
            Entry::Vacant(_) => return Err(Error::InvalidNonce),
            Entry::Occupied(entry) => entry,
        };

        let remaining_requests = entry.get_mut();

        if *remaining_requests == 0 {
            entry.remove();

            return Err(Error::InvalidNonce);
        }

        *remaining_requests -= 1;

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
    #[error("invalid nonce")]
    InvalidNonce,
    #[error("cannot authenticate message")]
    CannotAuthenticate(#[from] bytecodec::Error),
}

pub(crate) fn split_username(username: &str) -> Result<(u64, &str), Error> {
    let [expiry, username_salt]: [&str; 2] = username
        .split(':')
        .collect::<Vec<&str>>()
        .try_into()
        .map_err(|_| Error::InvalidUsername)?;

    let expiry_unix_timestamp = expiry.parse::<u64>().map_err(|_| Error::InvalidUsername)?;

    Ok((expiry_unix_timestamp, username_salt))
}

pub fn generate_password(
    relay_secret: &SecretString,
    expiry: SystemTime,
    username_salt: &str,
) -> String {
    use sha2::Digest as _;

    let mut hasher = Sha256::default();

    let expiry_secs = expiry
        .duration_since(SystemTime::UNIX_EPOCH)
        .expect("expiry must be later than UNIX_EPOCH")
        .as_secs();

    hasher.update(format!("{expiry_secs}"));
    hasher.update(":");
    hasher.update(relay_secret.expose_secret().as_str());
    hasher.update(":");
    hasher.update(username_salt);

    let array = hasher.finalize_fixed();

    BASE64_STANDARD_NO_PAD.encode(array.as_slice())
}

pub(crate) fn systemtime_from_unix(seconds: u64) -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_secs(seconds)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Attribute;
    use stun_codec::rfc5389::methods::BINDING;
    use stun_codec::{Message, MessageClass, TransactionId};

    const RELAY_SECRET_1: &str = "4c98bf59c99b3e467ecd7cf9d6b3e5279645fca59be67bc5bb4af3cf653761ab";
    const RELAY_SECRET_2: &str = "7e35e34801e766a6a29ecb9e22810ea4e3476c2b37bf75882edf94a68b1d9607";
    const SAMPLE_USERNAME: &str = "n23JJ2wKKtt30oXi";

    #[test]
    fn generate_password_test_vector() {
        let expiry = systemtime_from_unix(60 * 60 * 24 * 365 * 60);

        let password = generate_password(&RELAY_SECRET_1.parse().unwrap(), expiry, SAMPLE_USERNAME);

        assert_eq!(password, "00hqldgk5xLeKKOB+xls9mHMVtgqzie9DulfgQwMv68")
    }

    #[test]
    fn generate_password_test_vector_elixir() {
        let expiry = systemtime_from_unix(1685984278);
        let password = generate_password(
            &"1cab293a-4032-46f4-862a-40e5d174b0d2".parse().unwrap(),
            expiry,
            "uvdgKvS9GXYZ_vmv",
        );
        assert_eq!(password, "6xUIoZ+QvxKhRasLifwfRkMXl+ETLJUsFkHlXjlHAkg")
    }

    #[test]
    fn smoke() {
        let message_integrity = message_integrity(
            &RELAY_SECRET_1.parse().unwrap(),
            1685200000,
            "n23JJ2wKKtt30oXi",
        );

        let result = message_integrity.verify(
            &RELAY_SECRET_1.parse().unwrap(),
            "1685200000:n23JJ2wKKtt30oXi",
            systemtime_from_unix(1685200000 - 1000),
        );

        result.expect("credentials to be valid");
    }

    #[test]
    fn expired_is_not_valid() {
        let message_integrity = message_integrity(
            &RELAY_SECRET_1.parse().unwrap(),
            1685200000 - 1000,
            "n23JJ2wKKtt30oXi",
        );

        let result = message_integrity.verify(
            &RELAY_SECRET_1.parse().unwrap(),
            "1685199000:n23JJ2wKKtt30oXi",
            systemtime_from_unix(1685200000),
        );

        assert!(matches!(result.unwrap_err(), Error::Expired))
    }

    #[test]
    fn different_relay_secret_makes_password_invalid() {
        let message_integrity = message_integrity(
            &RELAY_SECRET_2.parse().unwrap(),
            1685200000,
            "n23JJ2wKKtt30oXi",
        );

        let result = message_integrity.verify(
            &RELAY_SECRET_1.parse().unwrap(),
            "1685200000:n23JJ2wKKtt30oXi",
            systemtime_from_unix(168520000 + 1000),
        );

        assert!(matches!(result.unwrap_err(), Error::InvalidPassword))
    }

    #[test]
    fn invalid_username_format_fails() {
        let message_integrity = message_integrity(
            &RELAY_SECRET_2.parse().unwrap(),
            1685200000,
            "n23JJ2wKKtt30oXi",
        );

        let result = message_integrity.verify(
            &RELAY_SECRET_1.parse().unwrap(),
            "foobar",
            systemtime_from_unix(168520000 + 1000),
        );

        assert!(matches!(result.unwrap_err(), Error::InvalidUsername))
    }

    #[test]
    fn nonces_are_valid_for_100_requests() {
        let mut nonces = Nonces::default();
        let nonce = Uuid::new_v4();

        nonces.add_new(nonce);

        for _ in 0..100 {
            nonces.handle_nonce_used(nonce).unwrap();
        }

        assert!(matches!(
            nonces.handle_nonce_used(nonce).unwrap_err(),
            Error::InvalidNonce
        ));
    }

    #[test]
    fn unknown_nonces_are_invalid() {
        let mut nonces = Nonces::default();
        let nonce = Uuid::new_v4();

        assert!(matches!(
            nonces.handle_nonce_used(nonce).unwrap_err(),
            Error::InvalidNonce
        ));
    }

    fn message_integrity(
        relay_secret: &SecretString,
        username_expiry: u64,
        username_salt: &str,
    ) -> MessageIntegrity {
        let username = Username::new(format!("{username_expiry}:{username_salt}")).unwrap();
        let password = generate_password(
            relay_secret,
            systemtime_from_unix(username_expiry),
            username_salt,
        );

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
}

use base64::prelude::BASE64_STANDARD_NO_PAD;
use base64::Engine;
use once_cell::sync::Lazy;
use sha2::digest::FixedOutput;
use sha2::Sha256;
use std::borrow::ToOwned;
use std::time::{Duration, SystemTime};
use stun_codec::rfc5389::attributes::{MessageIntegrity, Realm, Username};

// TODO: Upstream a const constructor to `stun-codec`.
pub static FIREZONE: Lazy<Realm> = Lazy::new(|| Realm::new("firezone".to_owned()).unwrap());

pub trait MessageIntegrityExt {
    fn verify(&self, relay_secret: &[u8], username: &str, now: SystemTime) -> Result<(), Error>;
}

impl MessageIntegrityExt for MessageIntegrity {
    fn verify(&self, relay_secret: &[u8], username: &str, now: SystemTime) -> Result<(), Error> {
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

#[derive(Debug, PartialEq)]
pub enum Error {
    Expired,
    InvalidPassword,
    InvalidUsername,
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

pub(crate) fn generate_password(
    relay_secret: &[u8],
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
    hasher.update(relay_secret);
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
    use hex_literal::hex;
    use stun_codec::rfc5389::attributes::Username;
    use stun_codec::rfc5389::methods::BINDING;
    use stun_codec::{Message, MessageClass, TransactionId};
    use uuid::Uuid;

    const RELAY_SECRET_1: [u8; 32] =
        hex!("4c98bf59c99b3e467ecd7cf9d6b3e5279645fca59be67bc5bb4af3cf653761ab");
    const RELAY_SECRET_2: [u8; 32] =
        hex!("7e35e34801e766a6a29ecb9e22810ea4e3476c2b37bf75882edf94a68b1d9607");
    const SAMPLE_USERNAME: &'static str = "n23JJ2wKKtt30oXi";

    #[test]
    fn generate_password_test_vector() {
        let expiry = systemtime_from_unix(60 * 60 * 24 * 365 * 60);

        let password = generate_password(&RELAY_SECRET_1, expiry, SAMPLE_USERNAME);

        assert_eq!(password, "XnR4dOjSrxVx+3PR5/XIFKA80NckB04N7ndZMM6aoQg")
    }

    #[test]
    fn generate_password_test_vector_elixir() {
        let expiry = systemtime_from_unix(1685984278);

        let password = generate_password(
            "1cab293a-4032-46f4-862a-40e5d174b0d2".as_bytes(),
            expiry,
            "uvdgKvS9GXYZ_vmv",
        );

        assert_eq!(password, "6xUIoZ+QvxKhRasLifwfRkMXl+ETLJUsFkHlXjlHAkg")
    }

    #[test]
    fn smoke() {
        let message_integrity = message_integrity(&RELAY_SECRET_1, 1685200000, "n23JJ2wKKtt30oXi");

        let result = message_integrity.verify(
            &RELAY_SECRET_1,
            &format!("1685200000:n23JJ2wKKtt30oXi"),
            systemtime_from_unix(1685200000 - 1000),
        );

        result.expect("credentials to be valid");
    }

    #[test]
    fn expired_is_not_valid() {
        let message_integrity =
            message_integrity(&RELAY_SECRET_1, 1685200000 - 1000, "n23JJ2wKKtt30oXi");

        let result = message_integrity.verify(
            &RELAY_SECRET_1,
            &format!("1685199000:n23JJ2wKKtt30oXi"),
            systemtime_from_unix(1685200000),
        );

        assert_eq!(result.unwrap_err(), Error::Expired)
    }

    #[test]
    fn different_relay_secret_makes_password_invalid() {
        let message_integrity = message_integrity(&RELAY_SECRET_2, 1685200000, "n23JJ2wKKtt30oXi");

        let result = message_integrity.verify(
            &RELAY_SECRET_1,
            &format!("1685200000:n23JJ2wKKtt30oXi"),
            systemtime_from_unix(168520000 + 1000),
        );

        assert_eq!(result.unwrap_err(), Error::InvalidPassword)
    }

    #[test]
    fn invalid_username_format_fails() {
        let message_integrity = message_integrity(&RELAY_SECRET_2, 1685200000, "n23JJ2wKKtt30oXi");

        let result = message_integrity.verify(
            &RELAY_SECRET_1,
            &format!("foobar"),
            systemtime_from_unix(168520000 + 1000),
        );

        assert_eq!(result.unwrap_err(), Error::InvalidUsername)
    }

    fn message_integrity(
        relay_secret: &[u8],
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

use base64::{Engine, display::Base64Display, engine::general_purpose::STANDARD};
use boringtun::x25519::PublicKey;
use secrecy::{CloneableSecret, SecretBox, SerializableSecret, zeroize::Zeroize};
use serde::{Deserialize, Deserializer, Serialize, Serializer, de};

use std::{fmt, str::FromStr};

// Note: the wireguard key and the ICE session key are the same length by mere coincidence
// it'd be correct to define key with a const generic parameter for the size and have a different type
// that depends on the length.
// However, that's some unnecessary complexity due to the coincide mentioned above.
const KEY_SIZE: usize = 32;

/// A `Key` struct to hold interface or peer keys as bytes. This type is
/// deserialized from a base64 encoded string. It can also be serialized back
/// into an encoded string.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Key(pub [u8; KEY_SIZE]);

impl FromStr for Key {
    type Err = base64::DecodeError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let mut key_bytes = [0u8; KEY_SIZE];
        // decode_slice tries to estimate the size the decoded string before decoding
        // if the passed buffer is smaller, it return an error.
        // the problem is... the estimator is very bad! Meaning, decode_slice doesn't work
        // we could use `decode_slice_unchecked`... or we could if we could trust the input, of course we can't
        // (unless the portal sanitized the key beforehand which it doesn't) since someone could abuse this somehow
        // to DoS a gateway by provinding a wrongly size public_key.
        //:(
        // so... we decode into a vec, check the length and convert to an array :)
        // TODO: https://github.com/marshallpierce/rust-base64/issues/210
        let bytes_decoded = STANDARD.decode(s)?;
        if bytes_decoded.len() != KEY_SIZE {
            Err(base64::DecodeError::InvalidLength(bytes_decoded.len()))
        } else {
            key_bytes.copy_from_slice(&bytes_decoded);
            Ok(Key(key_bytes))
        }
    }
}

impl Zeroize for Key {
    fn zeroize(&mut self) {
        self.0.zeroize();
    }
}

impl From<PublicKey> for Key {
    fn from(value: PublicKey) -> Self {
        Self(value.to_bytes())
    }
}

impl From<Key> for PublicKey {
    fn from(value: Key) -> Self {
        value.0.into()
    }
}

impl fmt::Display for Key {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", Base64Display::new(&self.0, &STANDARD))
    }
}

impl<'de> Deserialize<'de> for Key {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        s.parse().map_err(de::Error::custom)
    }
}

impl Serialize for Key {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.collect_str(&self)
    }
}

impl CloneableSecret for Key {}
impl SerializableSecret for Key {}

pub type SecretKey = SecretBox<Key>;

#[cfg(test)]
mod test {
    use boringtun::x25519::{PublicKey, StaticSecret};
    use rand::rngs::OsRng;

    use super::Key;

    #[test]
    fn can_deserialize_public_key() {
        let public_key_string = r#""S6REkbStSNMfn8hpLkVxibjR+zz3RO/Gq40TprHJE2U=""#;
        let actual_key: Key = serde_json::from_str(public_key_string).unwrap();
        assert_eq!(actual_key.to_string(), public_key_string.trim_matches('"'));
    }

    #[test]
    fn can_serialize_from_private_key_and_back() {
        let private_key = StaticSecret::random_from_rng(OsRng);
        let expected_public_key = PublicKey::from(private_key.to_bytes());
        let public_key = Key(expected_public_key.to_bytes());
        let public_key_string = serde_json::to_string(&public_key).unwrap();
        let actual_key: Key = serde_json::from_str(&public_key_string).unwrap();
        let actual_public_key = PublicKey::from(actual_key.0);
        assert_eq!(actual_public_key, expected_public_key);
    }
}

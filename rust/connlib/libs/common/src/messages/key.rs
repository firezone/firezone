use base64::{display::Base64Display, engine::general_purpose::STANDARD, Engine};
use serde::{de, Deserialize, Deserializer, Serialize, Serializer};

use std::{fmt, str::FromStr};

use crate::Error;

const KEY_SIZE: usize = 32;

/// A `Key` struct to hold interface or peer keys as bytes. This type is
/// deserialized from a base64 encoded string. It can also be serialized back
/// into an encoded string.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Key(pub [u8; KEY_SIZE]);

impl FromStr for Key {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let mut key_bytes = [0u8; KEY_SIZE];
        let bytes_decoded = STANDARD.decode_slice(s, &mut key_bytes)?;

        if bytes_decoded != KEY_SIZE {
            Err(base64::DecodeError::InvalidLength)?;
        }

        Ok(Self(key_bytes))
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

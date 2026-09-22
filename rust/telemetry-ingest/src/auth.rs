//! Verification of the metrics tokens the portal mints for gateways.

use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context as _, Result, bail};
use base64::Engine as _;
use opentelemetry_proto::tonic::common::v1::{AnyValue, KeyValue, any_value};
use opentelemetry_proto::tonic::resource::v1::Resource;
use ring::signature::{ED25519, UnparsedPublicKey};
use serde::Deserialize;

const BASE64_URL: base64::engine::general_purpose::GeneralPurpose =
    base64::engine::general_purpose::URL_SAFE_NO_PAD;

/// The Ed25519 public keys a metrics token may be signed with, by key id.
///
/// More than one key is valid at a time so the portal's signing key can be
/// rotated with a period where both the old and the new key are accepted.
#[derive(Debug)]
pub struct PublicKeys(HashMap<String, Vec<u8>>);

impl PublicKeys {
    /// Parses `kid:base64-ed25519-public-key` pairs, separated by commas.
    pub fn parse(raw: &str) -> Result<Self> {
        let keys = raw
            .split(',')
            .map(str::trim)
            .filter(|entry| !entry.is_empty())
            .map(|entry| {
                let (kid, key) = entry
                    .split_once(':')
                    .with_context(|| format!("Expected `kid:key`, got `{entry}`"))?;
                let key = base64::engine::general_purpose::STANDARD
                    .decode(key)
                    .with_context(|| format!("Key `{kid}` is not valid base64"))?;

                anyhow::ensure!(
                    key.len() == 32,
                    "Key `{kid}` is {} bytes, not a 32-byte Ed25519 public key",
                    key.len()
                );

                Ok((kid.to_owned(), key))
            })
            .collect::<Result<HashMap<_, _>>>()?;

        if keys.is_empty() {
            bail!("No public keys configured");
        }

        Ok(Self(keys))
    }
}

#[derive(Debug, Deserialize)]
struct Header {
    alg: String,
    kid: String,
}

/// The attribution the portal signed into the token.
///
/// It is the only source of identity for a report: gateways do not know who
/// they are, and the ingest service has no database to look them up in.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Claims {
    pub account_id: String,
    pub account_slug: String,
    pub gateway_id: String,
    pub site_id: String,
    pub site_name: String,
    pub exp: u64,
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Rejected {
    Malformed,
    UnsupportedAlgorithm,
    UnknownKey,
    BadSignature,
    Expired,
}

impl std::fmt::Display for Rejected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let reason = match self {
            Self::Malformed => "malformed",
            Self::UnsupportedAlgorithm => "unsupported algorithm",
            Self::UnknownKey => "unknown key id",
            Self::BadSignature => "bad signature",
            Self::Expired => "expired",
        };

        f.write_str(reason)
    }
}

/// Verifies `token` and returns what it attributes a report to.
///
/// Only `EdDSA` is accepted and the key is picked by the token's `kid`, so a
/// token cannot nominate a different algorithm to have its signature checked
/// with. The claims are parsed only once the signature holds.
pub fn verify(token: &str, keys: &PublicKeys, now: SystemTime) -> Result<Claims, Rejected> {
    let mut parts = token.split('.');

    let (header, payload, signature) =
        match (parts.next(), parts.next(), parts.next(), parts.next()) {
            (Some(header), Some(payload), Some(signature), None) => (header, payload, signature),
            _ => return Err(Rejected::Malformed),
        };

    let Header { alg, kid } = decode_json(header)?;

    if alg != "EdDSA" {
        return Err(Rejected::UnsupportedAlgorithm);
    }

    let key = keys.0.get(&kid).ok_or(Rejected::UnknownKey)?;
    let signature = BASE64_URL
        .decode(signature)
        .map_err(|_| Rejected::Malformed)?;
    let signed = &token[..header.len() + 1 + payload.len()];

    UnparsedPublicKey::new(&ED25519, key)
        .verify(signed.as_bytes(), &signature)
        .map_err(|_| Rejected::BadSignature)?;

    let claims: Claims = decode_json(payload)?;

    if claims.exp <= unix_seconds(now) {
        return Err(Rejected::Expired);
    }

    Ok(claims)
}

impl Claims {
    /// The resource every data point in the report is attributed to.
    pub fn resource(&self) -> Resource {
        Resource {
            attributes: vec![
                attribute("firezone.account.id", &self.account_id),
                attribute("firezone.account.slug", &self.account_slug),
                attribute("firezone.gateway.id", &self.gateway_id),
                attribute("firezone.site.id", &self.site_id),
                attribute("firezone.site.name", &self.site_name),
            ],
            ..Default::default()
        }
    }
}

fn attribute(key: &str, value: &str) -> KeyValue {
    KeyValue {
        key: key.to_owned(),
        value: Some(AnyValue {
            value: Some(any_value::Value::StringValue(value.to_owned())),
        }),
        ..Default::default()
    }
}

fn decode_json<T: serde::de::DeserializeOwned>(part: &str) -> Result<T, Rejected> {
    let json = BASE64_URL.decode(part).map_err(|_| Rejected::Malformed)?;

    serde_json::from_slice(&json).map_err(|_| Rejected::Malformed)
}

fn unix_seconds(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .map(|since_epoch| since_epoch.as_secs())
        .unwrap_or_default()
}

#[cfg(test)]
pub mod tests {
    use std::time::Duration;

    use ring::signature::{Ed25519KeyPair, KeyPair as _};

    use super::*;

    const KID: &str = "test-key";

    #[test]
    fn accepts_a_token_signed_by_a_configured_key() {
        let signer = Signer::generate(KID);

        let claims = verify(&signer.token(claims()), &keys(&signer), SystemTime::now()).unwrap();

        assert_eq!(
            claims,
            Claims {
                account_id: "account".to_owned(),
                account_slug: "acme".to_owned(),
                gateway_id: "gateway".to_owned(),
                site_id: "site".to_owned(),
                site_name: "Production".to_owned(),
                exp: claims.exp,
            }
        );
    }

    #[test]
    fn rejects_a_token_signed_by_another_key() {
        let configured = Signer::generate(KID);
        let impostor = Signer::generate(KID);

        let rejection = verify(
            &impostor.token(claims()),
            &keys(&configured),
            SystemTime::now(),
        )
        .unwrap_err();

        assert_eq!(rejection, Rejected::BadSignature);
    }

    #[test]
    fn rejects_a_token_whose_payload_was_tampered_with() {
        let signer = Signer::generate(KID);
        let token = signer.token(claims());

        let (signed, signature) = token.rsplit_once('.').unwrap();
        let (header, _) = signed.split_once('.').unwrap();
        let forged_payload = BASE64_URL.encode(
            serde_json::json!({
                "account_id": "somebody-else",
                "account_slug": "acme",
                "gateway_id": "gateway",
                "site_id": "site",
                "site_name": "Production",
                "exp": exp(),
            })
            .to_string(),
        );

        let forged = format!("{header}.{forged_payload}.{signature}");

        assert_eq!(
            verify(&forged, &keys(&signer), SystemTime::now()).unwrap_err(),
            Rejected::BadSignature
        );
    }

    /// A token nominating a symmetric algorithm must not get its signature
    /// checked with the public key as the shared secret.
    #[test]
    fn rejects_a_token_nominating_another_algorithm() {
        let signer = Signer::generate(KID);

        for alg in ["HS256", "none", "RS256", "eddsa"] {
            let token = signer.sign(
                serde_json::json!({ "alg": alg, "typ": "JWT", "kid": KID }),
                claims(),
            );

            assert_eq!(
                verify(&token, &keys(&signer), SystemTime::now()).unwrap_err(),
                Rejected::UnsupportedAlgorithm,
                "`{alg}` must be rejected"
            );
        }
    }

    #[test]
    fn rejects_a_token_naming_an_unknown_key() {
        let signer = Signer::generate("rotated-out");

        assert_eq!(
            verify(
                &signer.token(claims()),
                &keys(&Signer::generate(KID)),
                SystemTime::now()
            )
            .unwrap_err(),
            Rejected::UnknownKey
        );
    }

    #[test]
    fn rejects_an_expired_token() {
        let signer = Signer::generate(KID);
        let token = signer.token(claims());
        let long_after = SystemTime::now() + Duration::from_secs(86_400);

        assert_eq!(
            verify(&token, &keys(&signer), long_after).unwrap_err(),
            Rejected::Expired
        );
    }

    #[test]
    fn rejects_malformed_tokens() {
        let signer = Signer::generate(KID);

        for token in ["", "not-a-jwt", "a.b", "a.b.c.d", "a.b.c"] {
            assert_eq!(
                verify(token, &keys(&signer), SystemTime::now()).unwrap_err(),
                Rejected::Malformed,
                "`{token}` must be rejected"
            );
        }
    }

    #[test]
    fn accepts_more_than_one_key_for_rotation() {
        let old = Signer::generate("old");
        let new = Signer::generate("new");

        let keys = PublicKeys::parse(&format!(
            "{}, {}",
            old.configured_public_key(),
            new.configured_public_key()
        ))
        .unwrap();

        for signer in [&old, &new] {
            verify(&signer.token(claims()), &keys, SystemTime::now()).unwrap();
        }
    }

    #[test]
    fn rejects_public_keys_that_are_not_ed25519() {
        for raw in ["", "no-colon", "kid:not-base64!", "kid:c2hvcnQ="] {
            PublicKeys::parse(raw).unwrap_err();
        }
    }

    fn keys(signer: &Signer) -> PublicKeys {
        PublicKeys::parse(&signer.configured_public_key()).unwrap()
    }

    fn claims() -> serde_json::Value {
        serde_json::json!({
            "account_id": "account",
            "account_slug": "acme",
            "gateway_id": "gateway",
            "site_id": "site",
            "site_name": "Production",
            "iat": unix_seconds(SystemTime::now()),
            "exp": exp(),
        })
    }

    fn exp() -> u64 {
        unix_seconds(SystemTime::now() + Duration::from_secs(600))
    }

    /// Mints tokens the way the portal does.
    pub struct Signer {
        kid: String,
        key_pair: Ed25519KeyPair,
    }

    impl Signer {
        pub fn generate(kid: &str) -> Self {
            let pkcs8 = Ed25519KeyPair::generate_pkcs8(&ring::rand::SystemRandom::new()).unwrap();

            Self {
                kid: kid.to_owned(),
                key_pair: Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap(),
            }
        }

        /// The key as `TELEMETRY_INGEST_JWT_PUBLIC_KEYS` spells it.
        pub fn configured_public_key(&self) -> String {
            format!(
                "{}:{}",
                self.kid,
                base64::engine::general_purpose::STANDARD.encode(self.key_pair.public_key())
            )
        }

        pub fn token(&self, claims: serde_json::Value) -> String {
            self.sign(
                serde_json::json!({ "alg": "EdDSA", "typ": "JWT", "kid": self.kid }),
                claims,
            )
        }

        pub fn sign(&self, header: serde_json::Value, claims: serde_json::Value) -> String {
            let signed = format!(
                "{}.{}",
                BASE64_URL.encode(header.to_string()),
                BASE64_URL.encode(claims.to_string())
            );
            let signature = self.key_pair.sign(signed.as_bytes());

            format!("{signed}.{}", BASE64_URL.encode(signature.as_ref()))
        }
    }
}

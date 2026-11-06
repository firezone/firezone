use anyhow::{Context as _, Result};
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use serde::Deserialize;

/// The claims of a token the portal issues to a device for exporting metrics.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Claims {
    pub account_id: String,
    pub account_slug: String,
    pub device_id: String,
    pub device_type: DeviceType,
    pub device_version: Option<String>,
    /// The patterns of the metric names the device may export.
    pub metrics: Vec<String>,
    pub iat: u64,
    pub exp: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DeviceType {
    Client,
    Gateway,
}

impl DeviceType {
    pub fn as_str(&self) -> &'static str {
        match self {
            DeviceType::Client => "client",
            DeviceType::Gateway => "gateway",
        }
    }
}

pub struct Verifier {
    key: DecodingKey,
    validation: Validation,
}

impl Verifier {
    pub fn from_ed_pem(pem: &[u8]) -> Result<Self> {
        let key = DecodingKey::from_ed_pem(pem).context("Invalid Ed25519 public key")?;
        let validation = Validation::new(Algorithm::EdDSA);

        Ok(Self { key, validation })
    }

    /// Verifies the signature and expiry of `token` and returns its claims.
    pub fn verify(&self, token: &str) -> Result<Claims, jsonwebtoken::errors::Error> {
        let data = jsonwebtoken::decode::<Claims>(token, &self.key, &self.validation)?;

        Ok(data.claims)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use jsonwebtoken::errors::ErrorKind;
    use jsonwebtoken::{EncodingKey, Header};

    const PRIVATE_KEY: &[u8] = include_bytes!("../tests/fixtures/private.pem");
    pub(crate) const PUBLIC_KEY: &[u8] = include_bytes!("../tests/fixtures/public.pem");
    const GOLDEN_TOKEN: &str = include_str!("../tests/fixtures/golden.jwt");
    const OTHER_PUBLIC_KEY: &[u8] = b"-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAlmzDG2H7LGI0Y6lY0p2SXotdYqWt8Ahi1vBVRnKSFn0=
-----END PUBLIC KEY-----
";

    #[test]
    fn golden_token_is_valid() {
        let verifier = Verifier::from_ed_pem(PUBLIC_KEY).unwrap();

        let claims = verifier.verify(GOLDEN_TOKEN.trim()).unwrap();

        assert_eq!(
            claims,
            Claims {
                account_id: "00000000-0000-0000-0000-000000000001".to_owned(),
                account_slug: "golden".to_owned(),
                device_id: "00000000-0000-0000-0000-000000000002".to_owned(),
                device_type: DeviceType::Client,
                device_version: Some("1.5.0".to_owned()),
                metrics: vec!["connlib.*".to_owned()],
                iat: 1_700_000_000,
                exp: 4_102_444_800,
            }
        );
    }

    #[test]
    fn rejects_expired_token() {
        let verifier = Verifier::from_ed_pem(PUBLIC_KEY).unwrap();
        let token = sign(&claims_json(1_700_000_100));

        let error = verifier.verify(&token).unwrap_err();

        assert_eq!(error.kind(), &ErrorKind::ExpiredSignature);
    }

    #[test]
    fn rejects_token_without_expiry() {
        let verifier = Verifier::from_ed_pem(PUBLIC_KEY).unwrap();
        let mut claims = claims_json(4_102_444_800);
        claims.as_object_mut().unwrap().remove("exp");

        let result = verifier.verify(&sign(&claims));

        assert!(result.is_err());
    }

    #[test]
    fn rejects_token_signed_with_other_key() {
        let verifier = Verifier::from_ed_pem(OTHER_PUBLIC_KEY).unwrap();

        let error = verifier.verify(GOLDEN_TOKEN.trim()).unwrap_err();

        assert_eq!(error.kind(), &ErrorKind::InvalidSignature);
    }

    #[test]
    fn rejects_non_eddsa_token() {
        let verifier = Verifier::from_ed_pem(PUBLIC_KEY).unwrap();
        let token = jsonwebtoken::encode(
            &Header::new(Algorithm::HS256),
            &claims_json(4_102_444_800),
            &EncodingKey::from_secret(PUBLIC_KEY),
        )
        .unwrap();

        let error = verifier.verify(&token).unwrap_err();

        assert_eq!(error.kind(), &ErrorKind::InvalidAlgorithm);
    }

    #[test]
    fn rejects_malformed_token() {
        let verifier = Verifier::from_ed_pem(PUBLIC_KEY).unwrap();

        let result = verifier.verify("not.a.token");

        assert!(result.is_err());
    }

    pub(crate) fn token(metrics: &[&str]) -> String {
        let mut claims = claims_json(4_102_444_800);
        claims["metrics"] = serde_json::json!(metrics);

        sign(&claims)
    }

    fn sign(claims: &serde_json::Value) -> String {
        jsonwebtoken::encode(
            &Header::new(Algorithm::EdDSA),
            claims,
            &EncodingKey::from_ed_pem(PRIVATE_KEY).unwrap(),
        )
        .unwrap()
    }

    fn claims_json(exp: u64) -> serde_json::Value {
        serde_json::json!({
            "account_id": "00000000-0000-0000-0000-000000000001",
            "account_slug": "golden",
            "device_id": "00000000-0000-0000-0000-000000000002",
            "device_type": "client",
            "device_version": "1.5.0",
            "metrics": ["connlib.*"],
            "iat": 1_700_000_000,
            "exp": exp,
        })
    }
}

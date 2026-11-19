use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context as _, Result, bail, ensure};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ring::signature::{ED25519, UnparsedPublicKey};
use rustls_pki_types::SubjectPublicKeyInfoDer;
use rustls_pki_types::pem::PemObject as _;
use serde::Deserialize;

/// DER encoding of an Ed25519 `SubjectPublicKeyInfo` up to the 32-byte key.
const ED25519_SPKI_PREFIX: &[u8] = &[
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
];

/// How far past `exp` a token is still accepted, to tolerate clock skew.
const EXPIRY_LEEWAY_SECS: u64 = 60;

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

#[derive(Deserialize)]
struct Header {
    alg: String,
}

/// Verifies the EdDSA JWTs the portal signs with its Ed25519 key.
pub struct Verifier {
    key: UnparsedPublicKey<Vec<u8>>,
}

impl Verifier {
    pub fn from_ed_pem(pem: &[u8]) -> Result<Self> {
        let spki =
            SubjectPublicKeyInfoDer::from_pem_slice(pem).context("Invalid PEM public key")?;
        let key = spki
            .strip_prefix(ED25519_SPKI_PREFIX)
            .filter(|key| key.len() == 32)
            .context("Not an Ed25519 public key")?;

        Ok(Self {
            key: UnparsedPublicKey::new(&ED25519, key.to_vec()),
        })
    }

    /// Verifies the signature and expiry of `token` and returns its claims.
    pub fn verify(&self, token: &str) -> Result<Claims> {
        let mut parts = token.split('.');
        let (Some(header), Some(payload), Some(signature), None) =
            (parts.next(), parts.next(), parts.next(), parts.next())
        else {
            bail!("Not a JWT");
        };

        let header = serde_json::from_slice::<Header>(&URL_SAFE_NO_PAD.decode(header)?)?;
        ensure!(
            header.alg == "EdDSA",
            "Unsupported algorithm {}",
            header.alg
        );

        let signed = &token[..token.len() - signature.len() - 1];
        self.key
            .verify(signed.as_bytes(), &URL_SAFE_NO_PAD.decode(signature)?)
            .map_err(|_| anyhow::anyhow!("Invalid signature"))?;

        let claims = serde_json::from_slice::<Claims>(&URL_SAFE_NO_PAD.decode(payload)?)?;
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        ensure!(now <= claims.exp + EXPIRY_LEEWAY_SECS, "Token expired");

        Ok(claims)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use ring::signature::Ed25519KeyPair;
    use rustls_pki_types::PrivatePkcs8KeyDer;

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

        assert_eq!(error.to_string(), "Token expired");
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

        assert_eq!(error.to_string(), "Invalid signature");
    }

    #[test]
    fn rejects_non_eddsa_token() {
        let verifier = Verifier::from_ed_pem(PUBLIC_KEY).unwrap();
        let token = sign_with_header(
            r#"{"alg":"HS256","typ":"JWT"}"#,
            &claims_json(4_102_444_800),
        );

        let error = verifier.verify(&token).unwrap_err();

        assert_eq!(error.to_string(), "Unsupported algorithm HS256");
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
        sign_with_header(r#"{"alg":"EdDSA","typ":"JWT"}"#, claims)
    }

    fn sign_with_header(header: &str, claims: &serde_json::Value) -> String {
        let pkcs8 = PrivatePkcs8KeyDer::from_pem_slice(PRIVATE_KEY).unwrap();
        let key = Ed25519KeyPair::from_pkcs8_maybe_unchecked(pkcs8.secret_pkcs8_der()).unwrap();
        let signed = format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(header),
            URL_SAFE_NO_PAD.encode(claims.to_string())
        );
        let signature = URL_SAFE_NO_PAD.encode(key.sign(signed.as_bytes()));

        format!("{signed}.{signature}")
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

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

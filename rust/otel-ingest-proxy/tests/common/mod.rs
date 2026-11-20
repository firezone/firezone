use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ring::signature::Ed25519KeyPair;
use rustls_pki_types::PrivatePkcs8KeyDer;
use rustls_pki_types::pem::PemObject as _;

pub const PUBLIC_KEY: &[u8] = include_bytes!("../fixtures/public.pem");
pub const EDDSA_HEADER: &str = r#"{"alg":"EdDSA","typ":"JWT"}"#;

const PRIVATE_KEY: &[u8] = include_bytes!("../fixtures/private.pem");

/// Returns the claims of the golden token.
pub fn claims() -> serde_json::Value {
    serde_json::json!({
        "account_id": "00000000-0000-0000-0000-000000000001",
        "account_slug": "golden",
        "device_id": "00000000-0000-0000-0000-000000000002",
        "device_type": "client",
        "device_version": "1.5.0",
        "metrics": ["connlib.*"],
        "iat": 1_700_000_000,
        "exp": 4_102_444_800_u64,
    })
}

/// Signs `claims` with the private key of [`PUBLIC_KEY`].
pub fn sign(header: &str, claims: &serde_json::Value) -> String {
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

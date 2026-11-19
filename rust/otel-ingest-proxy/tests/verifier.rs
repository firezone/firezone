#![allow(clippy::unwrap_used)]

mod common;

use common::{EDDSA_HEADER, PUBLIC_KEY, claims, sign};
use firezone_otel_ingest_proxy::{Claims, DeviceType, Verifier};

const GOLDEN_TOKEN: &str = include_str!("fixtures/golden.jwt");
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
    let mut claims = claims();
    claims["exp"] = serde_json::json!(1_700_000_100);

    let error = verifier.verify(&sign(EDDSA_HEADER, &claims)).unwrap_err();

    assert_eq!(error.to_string(), "Token expired");
}

#[test]
fn rejects_token_without_expiry() {
    let verifier = Verifier::from_ed_pem(PUBLIC_KEY).unwrap();
    let mut claims = claims();
    claims.as_object_mut().unwrap().remove("exp");

    let result = verifier.verify(&sign(EDDSA_HEADER, &claims));

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
    let token = sign(r#"{"alg":"HS256","typ":"JWT"}"#, &claims());

    let error = verifier.verify(&token).unwrap_err();

    assert_eq!(error.to_string(), "Unsupported algorithm HS256");
}

#[test]
fn rejects_malformed_token() {
    let verifier = Verifier::from_ed_pem(PUBLIC_KEY).unwrap();

    let result = verifier.verify("not.a.token");

    assert!(result.is_err());
}

use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    time::{Duration, SystemTime},
};

use rcgen::{
    CertificateParams, DnType, ExtendedKeyUsagePurpose, KeyPair, KeyUsagePurpose, SanType,
    string::Ia5String,
};
use x509_identity::{SigningAlgorithm, UserIdentity, parse_certificate};

const RSA_LEAF: &[u8] =
    include_bytes!("../../../../elixir/test/support/fixtures/trust_anchors/leaf_cert.der");
const P384_LEAF: &[u8] =
    include_bytes!("../../../../elixir/test/support/fixtures/trust_anchors/p384_leaf.der");

const SUBJECT_CN: &str = "dev.firezone.device-trust";

#[test]
fn recognizes_rsa_client_identity() {
    let metadata =
        parse_certificate(RSA_LEAF, now()).expect("fixture should be a valid RSA certificate");

    assert_eq!(metadata.subject_cn.as_deref(), Some(SUBJECT_CN));
    assert!(metadata.has_client_auth_eku);
    assert!(metadata.digital_signature_allowed);
    assert!(metadata.is_currently_valid);
    assert_eq!(
        metadata.signing_algorithm,
        Some(SigningAlgorithm::RsaSha256)
    );
    assert!(metadata.is_usable(SUBJECT_CN));
}

#[test]
fn rejects_bytes_that_are_not_a_certificate() {
    assert!(parse_certificate(&[], now()).is_none());
    assert!(parse_certificate(&[0xde, 0xad, 0xbe, 0xef], now()).is_none());
}

#[test]
fn recognizes_p384_digest() {
    let metadata =
        parse_certificate(P384_LEAF, now()).expect("fixture should be a valid P-384 certificate");

    assert_eq!(
        metadata.signing_algorithm,
        Some(SigningAlgorithm::EcdsaSha384)
    );
    assert_eq!(
        metadata.subject_alternative_names,
        [
            "URI: firezone://serial/C02XK1ZGJGH5",
            "URI: firezone://udid/7a461ff9-0be2-64a9-a418-539d9a21827b",
            "DNS: UDID=7A461FF9",
            "DNS: host.test.invalid",
        ]
    );
}

#[test]
fn formats_ip_address_sans() {
    let der = certificate_with_sans(vec![
        SanType::IpAddress(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1))),
        SanType::IpAddress(IpAddr::V6(Ipv6Addr::new(0x2001, 0x0db8, 0, 0, 0, 0, 0, 1))),
    ]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");

    assert_eq!(
        metadata.subject_alternative_names,
        ["IP address: 10.0.0.1", "IP address: 2001:db8::1"]
    );
}

#[test]
fn extracts_typed_mdm_device_id_like_the_portal() {
    let der = certificate_with_uri_sans(&[
        "firezone://serial/C02XK1ZGJGH5",
        "firezone://intune-id/5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3",
    ]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");

    assert_eq!(
        metadata.mdm_device_id.as_deref(),
        Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3")
    );
    assert_eq!(metadata.device_serial.as_deref(), Some("C02XK1ZGJGH5"));
}

#[test]
fn extracts_mdm_device_id_from_intune_comma_joined_uri() {
    let der = certificate_with_uri_sans(&[
        "tag:microsoft.com,2022-09-14:sid:S-1-12-1-1, firezone://serial/C02XK1ZGJGH5, firezone://intune-id/5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3",
    ]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");

    assert_eq!(
        metadata.mdm_device_id.as_deref(),
        Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3")
    );
    assert_eq!(metadata.device_serial.as_deref(), Some("C02XK1ZGJGH5"));
}

#[test]
fn extracts_user_identity_from_intune_comma_joined_uri() {
    let der = certificate_with_uri_sans(&[
        "tag:microsoft.com,2022-09-14:sid:S-1-12-1-1, firezone://email/Alice%40Example.COM, firezone://account-id/5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3, firezone://serial/C02XK1ZGJGH5",
    ]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");

    assert_eq!(
        metadata.user_identity(),
        Some(UserIdentity {
            email: "alice@example.com".to_owned(),
            account_id: "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3".to_owned(),
        })
    );
    assert_eq!(metadata.device_serial.as_deref(), Some("C02XK1ZGJGH5"));
}

#[test]
fn user_identity_requires_unambiguous_valid_attributes() {
    let conflicting_emails = certificate_with_uri_sans(&[
        "firezone://email/alice@example.com",
        "firezone://email/bob@example.com",
        "firezone://account-id/5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3",
    ]);
    let malformed_account_id = certificate_with_uri_sans(&[
        "firezone://email/alice@example.com",
        "firezone://account-id/not-a-uuid",
    ]);
    let equivalent_duplicates = certificate_with_uri_sans(&[
        "firezone://email/Alice@Example.COM",
        "firezone://email/alice@example.com",
        "firezone://account-id/5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3",
        "firezone://account-id/5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3",
    ]);

    let conflicting_emails =
        parse_certificate(&conflicting_emails, now()).expect("generated certificate should parse");
    let malformed_account_id = parse_certificate(&malformed_account_id, now())
        .expect("generated certificate should parse");
    let equivalent_duplicates = parse_certificate(&equivalent_duplicates, now())
        .expect("generated certificate should parse");

    assert_eq!(conflicting_emails.actor_email, None);
    assert_eq!(conflicting_emails.user_identity(), None);
    assert_eq!(malformed_account_id.account_id, None);
    assert_eq!(malformed_account_id.user_identity(), None);
    assert_eq!(
        equivalent_duplicates.user_identity(),
        Some(UserIdentity {
            email: "alice@example.com".to_owned(),
            account_id: "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3".to_owned(),
        })
    );
}

#[test]
fn extracts_bare_guid_only_when_no_typed_identifier_exists() {
    let bare_guid = certificate_with_uri_sans(&["5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3"]);
    let guid_beside_serial = certificate_with_uri_sans(&[
        "firezone://serial/C02XK1ZGJGH5",
        "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3",
    ]);

    let bare_guid =
        parse_certificate(&bare_guid, now()).expect("generated certificate should parse");
    let guid_beside_serial =
        parse_certificate(&guid_beside_serial, now()).expect("generated certificate should parse");

    assert_eq!(
        bare_guid.mdm_device_id.as_deref(),
        Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3")
    );
    assert_eq!(guid_beside_serial.mdm_device_id, None);
}

#[test]
fn diagnostics_show_derived_firezone_attributes() {
    let mut metadata = parse_certificate(RSA_LEAF, now()).expect("test certificate should parse");
    metadata.actor_email = Some("alice@example.com".to_owned());
    metadata.account_id = Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3".to_owned());
    metadata.mdm_device_id = Some("intune-device-123".to_owned());
    metadata.device_serial = Some("C02XK1ZGJGH5".to_owned());

    let fields = metadata.detail_fields();

    for (label, value) in [
        ("Actor Email", "alice@example.com"),
        ("Account ID", "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"),
        ("MDM Device ID", "intune-device-123"),
        ("Device Serial", "C02XK1ZGJGH5"),
    ] {
        assert!(
            fields
                .iter()
                .any(|field| field.label == label && field.value == value),
            "diagnostics should show {label}"
        );
    }
    assert_eq!(
        metadata.user_identity(),
        Some(UserIdentity {
            email: "alice@example.com".to_owned(),
            account_id: "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3".to_owned(),
        })
    );
}

fn certificate_with_uri_sans(uris: &[&str]) -> Vec<u8> {
    let subject_alt_names = uris
        .iter()
        .map(|uri| {
            SanType::URI(Ia5String::try_from(*uri).expect("SAN URI should be an IA5 string"))
        })
        .collect();

    certificate_with_sans(subject_alt_names)
}

fn certificate_with_sans(subject_alt_names: Vec<SanType>) -> Vec<u8> {
    let key = KeyPair::generate().expect("should generate a key pair");

    let mut params = CertificateParams::default();
    params.subject_alt_names = subject_alt_names;
    params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
    params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ClientAuth];
    params
        .distinguished_name
        .push(DnType::CommonName, SUBJECT_CN);

    let certificate = params
        .self_signed(&key)
        .expect("should self-sign the certificate");

    certificate.der().to_vec()
}

fn now() -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_secs(1_798_761_600)
}

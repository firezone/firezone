use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    time::{Duration, SystemTime},
};

use rcgen::{
    CertificateParams, DnType, ExtendedKeyUsagePurpose, KeyPair, KeyUsagePurpose, SanType,
    SerialNumber, date_time_ymd, string::Ia5String,
};
use x509_claims::{
    Claim, DetailField, Identity, ParsedCertificate, SigningAlgorithm, ValidationError,
    parse_certificate,
};

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
    assert!(metadata.is_currently_valid());
    assert_eq!(
        metadata.signing_algorithm,
        Some(SigningAlgorithm::RsaSha256)
    );
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
        metadata.mdm_device_id.valid(),
        Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3")
    );
    assert_eq!(metadata.device_serial.valid(), Some("C02XK1ZGJGH5"));
}

#[test]
fn percent_decodes_typed_mdm_identifiers() {
    // The portal runs every typed claim through `URI.decode`, so a client that reported the
    // escape sequence verbatim would name a device the portal has never heard of.
    let der = certificate_with_uri_sans(&[
        "firezone://intune-id/5F2E7B7A%2D9D54%2D4BD2%2D9D4F%2D8F6C2A01F9D3",
        "firezone://serial/C02XK1%5AGJGH5",
    ]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");

    assert_eq!(
        metadata.mdm_device_id.valid(),
        Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3")
    );
    assert_eq!(metadata.device_serial.valid(), Some("C02XK1ZGJGH5"));
}

#[test]
fn extracts_mdm_device_id_from_intune_comma_joined_uri() {
    let der = certificate_with_uri_sans(&[
        "tag:microsoft.com,2022-09-14:sid:S-1-12-1-1, firezone://serial/C02XK1ZGJGH5, firezone://intune-id/5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3",
    ]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");

    assert_eq!(
        metadata.mdm_device_id.valid(),
        Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3")
    );
    assert_eq!(metadata.device_serial.valid(), Some("C02XK1ZGJGH5"));
}

#[test]
fn extracts_claims_from_intune_comma_joined_uri() {
    let der = certificate_with_uri_sans(&[
        "tag:microsoft.com,2022-09-14:sid:S-1-12-1-1, firezone://email/Alice%40Example.COM, firezone://account-id/5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3, firezone://serial/C02XK1ZGJGH5",
    ]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");

    assert_eq!(metadata.actor_email.valid(), Some("alice@example.com"));
    assert_eq!(
        metadata.account_id.valid(),
        Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3")
    );
    assert_eq!(metadata.device_serial.valid(), Some("C02XK1ZGJGH5"));
}

#[test]
fn accepts_a_claim_only_when_it_is_unambiguous_and_valid() {
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

    assert_eq!(
        conflicting_emails.actor_email,
        invalid(
            "alice@example.com, bob@example.com",
            ValidationError::Ambiguous
        )
    );
    assert_eq!(
        malformed_account_id.account_id,
        invalid("not-a-uuid", ValidationError::NotAUuid)
    );
    assert_eq!(
        equivalent_duplicates.actor_email.valid(),
        Some("alice@example.com"),
        "the same value written twice is one value"
    );
    assert_eq!(
        equivalent_duplicates.account_id.valid(),
        Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3")
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
        bare_guid.mdm_device_id.valid(),
        Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3")
    );
    assert_eq!(guid_beside_serial.mdm_device_id, absent());
}

#[test]
fn diagnostics_show_derived_firezone_attributes() {
    let mut metadata = parse_certificate(RSA_LEAF, now()).expect("test certificate should parse");
    metadata.actor_email = valid("alice@example.com");
    metadata.account_id = valid("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3");
    metadata.mdm_device_id = valid("intune-device-123");
    metadata.device_serial = valid("C02XK1ZGJGH5");

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
                .any(|field| field.label == label && field.value.as_deref() == Some(value)),
            "diagnostics should show {label}"
        );
    }
}

#[test]
fn diagnostics_show_what_a_certificate_lacks_without_judging_it() {
    let der = certificate_without_client_identity_extensions();

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");

    assert_eq!(
        detail_value(&metadata, "TLS Client Authentication EKU").as_deref(),
        Some("No")
    );
    assert_eq!(
        detail_value(&metadata, "Digital Signature Key Usage").as_deref(),
        Some("Not allowed")
    );
    assert_eq!(
        detail_value(&metadata, "Signing Algorithm").as_deref(),
        Some("1.3.101.112"),
        "an algorithm the parser has no name for should still be shown"
    );
    assert!(
        metadata
            .detail_fields()
            .iter()
            .all(|field| field.problem.is_none()),
        "what the portal makes of these rows is not a problem with them"
    );
}

#[test]
fn elides_a_serial_number_no_issuer_would_have_produced() {
    // A high bit in the leading octet makes DER pad the serial number to keep it positive, so
    // the largest RFC 5280 permits reaches the parser as 21 octets rather than 20.
    let compliant = certificate_with_serial(&[0xab; 20]);
    let oversized = certificate_with_serial(&[0xab; 4096]);

    let compliant =
        parse_certificate(&compliant, now()).expect("generated certificate should parse");
    let oversized =
        parse_certificate(&oversized, now()).expect("generated certificate should parse");

    assert_eq!(
        compliant.serial,
        format!("00:{}", ["ab"; 20].join(":")),
        "the longest compliant serial number should still be shown in full"
    );
    assert_eq!(
        oversized.serial,
        format!("00:{} (+4076 octets)", ["ab"; 20].join(":"))
    );
}

#[test]
fn reports_every_firezone_claim_it_cannot_use() {
    let der = certificate_with_uri_sans(&[
        "firezone://email/not-an-address",
        "firezone://account-id/not-a-uuid",
        "firezone://intune-id/00000000-0000-0000-0000-000000000000",
        "firezone://not-a-real-attribute/x",
    ]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");

    assert_eq!(
        metadata.actor_email,
        invalid("not-an-address", ValidationError::NotAnEmailAddress)
    );
    assert_eq!(
        metadata.account_id,
        invalid("not-a-uuid", ValidationError::NotAUuid)
    );
    assert_eq!(
        metadata.mdm_device_id,
        invalid(
            "00000000-0000-0000-0000-000000000000",
            ValidationError::PlaceholderIdentifier
        )
    );
    assert_eq!(metadata.device_serial, absent());
    assert_eq!(
        metadata.unrecognised_claims,
        ["firezone://not-a-real-attribute/x"]
    );
}

#[test]
fn reports_conflicting_claims_rather_than_picking_one() {
    let der = certificate_with_uri_sans(&[
        "firezone://email/alice@example.com",
        "firezone://email/bob@example.com",
        "firezone://account-id/5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3",
    ]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");

    assert_eq!(
        metadata.actor_email,
        invalid(
            "alice@example.com, bob@example.com",
            ValidationError::Ambiguous
        ),
        "a certificate naming two actors should authenticate as neither"
    );
}

#[test]
fn keeps_a_valid_claim_beside_an_invalid_one() {
    let der = certificate_with_uri_sans(&[
        "firezone://email/alice@example.com",
        "firezone://email/not-an-address",
    ]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");

    assert_eq!(
        metadata.actor_email,
        valid("alice@example.com"),
        "a value the parser cannot use should not sink the one beside it"
    );
}

#[test]
fn elides_an_unrecognised_claim_too_long_to_display() {
    let der = certificate_with_uri_sans(&[&format!(
        "firezone://not-a-real-attribute/{}",
        "a".repeat(300)
    )]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");

    assert_eq!(
        metadata.unrecognised_claims,
        [format!(
            "firezone://not-a-real-attribute/{} (+268 characters)",
            "a".repeat(32)
        )]
    );
}

#[test]
fn diagnostics_show_why_a_claim_is_not_usable() {
    let der = certificate_with_uri_sans(&[
        "firezone://email/not-an-address",
        "firezone://not-a-real-attribute/x",
    ]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");
    let fields = metadata.detail_fields();

    assert_eq!(
        detail_value(&metadata, "Actor Email").as_deref(),
        Some("not-an-address"),
        "a value the parser cannot use should still be shown"
    );
    assert_eq!(
        detail_problem(&metadata, "Actor Email"),
        Some(ValidationError::NotAnEmailAddress)
    );
    assert_eq!(
        detail_value(&metadata, "firezone://not-a-real-attribute").as_deref(),
        Some("x")
    );
    assert_eq!(
        detail_problem(&metadata, "firezone://not-a-real-attribute"),
        Some(ValidationError::UnknownAttribute)
    );
    assert!(
        position(&fields, "firezone://not-a-real-attribute")
            < position(&fields, "Subject Alternative Names"),
        "an unrecognised claim should sit with the other Firezone claims"
    );
    assert_eq!(
        detail_value(&metadata, "Subject Alternative Names").as_deref(),
        Some("URI: firezone://email/not-an-address"),
        "a value no claim row shows should stay visible"
    );
}

#[test]
fn lists_only_the_alternative_names_no_claim_row_shows() {
    let metadata =
        parse_certificate(P384_LEAF, now()).expect("fixture should be a valid P-384 certificate");

    assert_eq!(metadata.device_serial.valid(), Some("C02XK1ZGJGH5"));
    assert_eq!(
        detail_value(&metadata, "Subject Alternative Names").as_deref(),
        Some(
            "URI: firezone://udid/7a461ff9-0be2-64a9-a418-539d9a21827b\nDNS: UDID=7A461FF9\nDNS: host.test.invalid"
        ),
        "the serial the Device Serial row shows should not be repeated"
    );
}

#[test]
fn omits_the_alternative_names_row_when_the_claim_rows_show_them_all() {
    let every_name_is_a_claim = certificate_with_uri_sans(&[
        "firezone://email/alice@example.com",
        "firezone://serial/C02XK1ZGJGH5",
    ]);
    let bare_guid = certificate_with_uri_sans(&["5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3"]);

    let every_name_is_a_claim = parse_certificate(&every_name_is_a_claim, now())
        .expect("generated certificate should parse");
    let bare_guid =
        parse_certificate(&bare_guid, now()).expect("generated certificate should parse");

    assert!(
        !every_name_is_a_claim
            .detail_fields()
            .iter()
            .any(|field| field.label == "Subject Alternative Names")
    );
    assert_eq!(
        bare_guid.mdm_device_id.valid(),
        Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3")
    );
    assert!(
        !bare_guid
            .detail_fields()
            .iter()
            .any(|field| field.label == "Subject Alternative Names"),
        "a bare device ID the MDM Device ID row shows should not be repeated"
    );
}

#[test]
fn diagnostics_distinguish_an_invalid_claim_from_a_valid_one() {
    let der = certificate_with_uri_sans(&[
        "firezone://email/alice@example.com",
        "firezone://account-id/not-a-uuid",
    ]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");

    assert_eq!(
        detail_value(&metadata, "Actor Email").as_deref(),
        Some("alice@example.com")
    );
    assert_eq!(detail_problem(&metadata, "Actor Email"), None);
    assert_eq!(
        detail_value(&metadata, "Account ID").as_deref(),
        Some("not-a-uuid")
    );
    assert_eq!(
        detail_problem(&metadata, "Account ID"),
        Some(ValidationError::NotAUuid)
    );
}

#[test]
fn diagnostics_show_a_row_for_a_claim_the_certificate_does_not_carry() {
    let der = certificate_with_uri_sans(&["firezone://email/alice@example.com"]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");

    assert_eq!(metadata.account_id, absent());
    assert_eq!(detail_value(&metadata, "Account ID"), None);
    assert_eq!(detail_value(&metadata, "MDM Device ID"), None);
    assert_eq!(detail_value(&metadata, "Device Serial"), None);
}

#[test]
fn diagnostics_omit_unrecognised_claims_when_there_are_none() {
    let der = certificate_with_uri_sans(&[
        "firezone://email/alice@example.com",
        "firezone://account-id/5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3",
        "firezone://serial/C02XK1ZGJGH5",
    ]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");

    assert!(metadata.unrecognised_claims.is_empty());
    assert!(
        !metadata
            .detail_fields()
            .iter()
            .any(|field| field.problem == Some(ValidationError::UnknownAttribute))
    );
}

#[test]
fn diagnostics_read_from_the_identity_down_to_the_encoding() {
    let mut names = [
        "firezone://email/alice@example.com",
        "firezone://account-id/5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3",
        "firezone://intune-id/0d5a1c9e-3b72-4f60-8a4d-2e9b7c1f5a38",
        "firezone://serial/C02XK1ZGJGH5",
        "firezone://not-a-real-attribute/x",
    ]
    .map(|uri| SanType::URI(Ia5String::try_from(uri).expect("SAN URI should be an IA5 string")))
    .to_vec();
    names.push(SanType::DnsName(
        Ia5String::try_from("host.test.invalid").expect("SAN should be an IA5 string"),
    ));
    let der = certificate_with_sans(names);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");
    for claim in [
        &metadata.actor_email,
        &metadata.account_id,
        &metadata.mdm_device_id,
        &metadata.device_serial,
    ] {
        assert!(
            claim.valid().is_some(),
            "this certificate should carry every claim"
        );
    }

    let labels = metadata
        .detail_fields()
        .into_iter()
        .map(|field| field.label)
        .collect::<Vec<_>>();

    assert_eq!(
        labels,
        [
            // The one row with something wrong with it leads, and the rest read in the order
            // the diagnostics build them in.
            "firezone://not-a-real-attribute",
            "Common Name",
            "Subject",
            "Issuer",
            "Actor Email",
            "Account ID",
            "Actor ID",
            "MDM Device ID",
            "Device Serial",
            "Subject Alternative Names",
            "Serial Number",
            "Not Before",
            "Not After",
            "TLS Client Authentication EKU",
            "Digital Signature Key Usage",
            "Signing Algorithm",
            "SHA-256 Fingerprint",
        ],
    );
}

#[test]
fn the_rows_with_a_problem_read_first() {
    let der = certificate_with_uri_sans(&[
        "firezone://email/not-an-address",
        "firezone://not-a-real-attribute/x",
    ]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");
    let fields = metadata.detail_fields();
    let (with_a_problem, remainder): (Vec<_>, Vec<_>) =
        fields.iter().partition(|field| field.problem.is_some());

    assert_eq!(
        labels(&with_a_problem),
        ["Actor Email", "firezone://not-a-real-attribute"],
        "the rows that carry a problem keep the order they were built in"
    );
    assert_eq!(
        labels(&fields.iter().take(with_a_problem.len()).collect::<Vec<_>>()),
        labels(&with_a_problem),
        "a row with a problem should not read after one without"
    );
    assert!(
        labels(&remainder).starts_with(&[
            "Common Name",
            "Subject",
            "Issuer",
            "Account ID",
            "Actor ID",
            "MDM Device ID",
            "Device Serial",
        ]),
        "the rows with nothing wrong keep the order they were built in"
    );
    assert!(labels(&remainder).ends_with(&["Signing Algorithm", "SHA-256 Fingerprint"]));
}

#[test]
fn a_certificate_outside_its_validity_window_says_which_date_is_wrong() {
    let expired = certificate_valid_between(2018, 2020);
    let not_yet_valid = certificate_valid_between(2030, 2032);

    let expired = parse_certificate(&expired, now()).expect("generated certificate should parse");
    let not_yet_valid =
        parse_certificate(&not_yet_valid, now()).expect("generated certificate should parse");

    assert_eq!(
        detail_problem(&expired, "Not After"),
        Some(ValidationError::Expired)
    );
    assert_eq!(detail_problem(&expired, "Not Before"), None);
    assert_eq!(
        detail_problem(&not_yet_valid, "Not Before"),
        Some(ValidationError::NotYetValid)
    );
    assert_eq!(detail_problem(&not_yet_valid, "Not After"), None);
    assert_eq!(
        position(&expired.detail_fields(), "Not After"),
        0,
        "the date that expired the certificate is what the reader came for"
    );
}

#[test]
fn an_unreadable_clock_leaves_both_validity_dates_unjudged() {
    let der = certificate_valid_between(2018, 2020);

    let metadata = parse_certificate(&der, a_clock_that_cannot_be_read())
        .expect("generated certificate should parse");

    assert!(!metadata.is_currently_valid());
    assert_eq!(detail_problem(&metadata, "Not Before"), None);
    assert_eq!(detail_problem(&metadata, "Not After"), None);
}

#[test]
fn sparse_diagnostics_keep_the_order_without_leaving_gaps() {
    let der = certificate_with_uri_sans(&["firezone://email/alice@example.com"]);

    let metadata = parse_certificate(&der, now()).expect("generated certificate should parse");
    assert_eq!(metadata.actor_email.valid(), Some("alice@example.com"));

    let labels = metadata
        .detail_fields()
        .into_iter()
        .map(|field| field.label)
        .collect::<Vec<_>>();

    assert_eq!(
        labels,
        [
            "Common Name",
            "Subject",
            "Issuer",
            "Actor Email",
            "Account ID",
            "Actor ID",
            "MDM Device ID",
            "Device Serial",
            "Serial Number",
            "Not Before",
            "Not After",
            "TLS Client Authentication EKU",
            "Digital Signature Key Usage",
            "Signing Algorithm",
            "SHA-256 Fingerprint",
        ],
        "a claim without a value keeps its row, a row with nothing to say leaves no gap"
    );
}

#[test]
fn the_issuer_reads_directly_after_the_subject() {
    let metadata = parse_certificate(RSA_LEAF, now()).expect("fixture should parse");

    let fields = metadata.detail_fields();

    assert_eq!(
        position(&fields, "Issuer"),
        position(&fields, "Subject") + 1,
        "who issued the certificate belongs beside whom it names"
    );
}

#[test]
fn the_alternative_names_remainder_reads_after_the_claims() {
    let metadata =
        parse_certificate(P384_LEAF, now()).expect("fixture should be a valid P-384 certificate");

    let fields = metadata.detail_fields();

    assert!(
        position(&fields, "Device Serial") < position(&fields, "Subject Alternative Names"),
        "the remainder should follow the claim rows it was filtered against"
    );
    assert!(
        position(&fields, "Subject Alternative Names") < position(&fields, "Serial Number"),
        "the remainder belongs to the identity, not to the certificate facts below"
    );
}

fn labels<'a>(fields: &[&'a DetailField]) -> Vec<&'a str> {
    fields.iter().map(|field| field.label.as_str()).collect()
}

fn position(fields: &[DetailField], label: &str) -> usize {
    fields
        .iter()
        .position(|field| field.label == label)
        .unwrap_or_else(|| panic!("diagnostics should show {label}"))
}

fn detail_value(metadata: &ParsedCertificate, label: &str) -> Option<String> {
    metadata
        .detail_fields()
        .into_iter()
        .find(|field| field.label == label)
        .unwrap_or_else(|| panic!("diagnostics should show {label}"))
        .value
}

fn absent() -> Claim {
    Claim {
        value: None,
        error: None,
    }
}

fn valid(value: &str) -> Claim {
    Claim {
        value: Some(value.to_owned()),
        error: None,
    }
}

fn invalid(value: &str, error: ValidationError) -> Claim {
    Claim {
        value: Some(value.to_owned()),
        error: Some(error),
    }
}

/// What a row says is wrong with it, [`None`] when nothing is.
fn detail_problem(metadata: &ParsedCertificate, label: &str) -> Option<ValidationError> {
    metadata
        .detail_fields()
        .into_iter()
        .find(|field| field.label == label)
        .unwrap_or_else(|| panic!("diagnostics should show {label}"))
        .problem
}

/// An Ed25519 certificate carrying neither the client authentication EKU nor a key usage
/// allowing digital signatures.
fn certificate_without_client_identity_extensions() -> Vec<u8> {
    let key = KeyPair::generate_for(&rcgen::PKCS_ED25519).expect("should generate a key pair");

    let mut params = CertificateParams::default();
    // `rcgen` writes the extension block only for a certificate that carries a subject
    // alternative name, so the DNS name is what gets the key usage onto the wire at all.
    params.subject_alt_names = vec![SanType::DnsName(
        Ia5String::try_from("host.test.invalid").expect("SAN should be an IA5 string"),
    )];
    params.key_usages = vec![KeyUsagePurpose::KeyEncipherment];
    params
        .distinguished_name
        .push(DnType::CommonName, SUBJECT_CN);

    let certificate = params
        .self_signed(&key)
        .expect("should self-sign the certificate");

    certificate.der().to_vec()
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

fn certificate_with_serial(serial: &[u8]) -> Vec<u8> {
    let key = KeyPair::generate().expect("should generate a key pair");

    let mut params = CertificateParams::default();
    params.serial_number = Some(SerialNumber::from_slice(serial));
    params
        .distinguished_name
        .push(DnType::CommonName, SUBJECT_CN);

    let certificate = params
        .self_signed(&key)
        .expect("should self-sign the certificate");

    certificate.der().to_vec()
}

/// A certificate whose validity window opens and closes on the first of January.
fn certificate_valid_between(first_year: i32, last_year: i32) -> Vec<u8> {
    let key = KeyPair::generate().expect("should generate a key pair");

    let mut params = CertificateParams::default();
    params.not_before = date_time_ymd(first_year, 1, 1);
    params.not_after = date_time_ymd(last_year, 1, 1);
    params
        .distinguished_name
        .push(DnType::CommonName, SUBJECT_CN);

    let certificate = params
        .self_signed(&key)
        .expect("should self-sign the certificate");

    certificate.der().to_vec()
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

/// An instant with no Unix timestamp, the way a clock the platform cannot read reaches the parser.
fn a_clock_that_cannot_be_read() -> SystemTime {
    SystemTime::UNIX_EPOCH - Duration::from_secs(1)
}

/// Claiming an identity at all is what suppresses signing in with a token, so the client has to
/// tell "claims nobody" from "claims somebody it cannot name".
#[test]
fn an_identity_is_absent_or_claimed() {
    let identity_of = |uris: &[&str]| {
        let der = certificate_with_uri_sans(uris);

        parse_certificate(&der, now())
            .expect("generated certificate should parse")
            .identity()
    };

    assert_eq!(identity_of(&[]), Identity::Absent);
    assert_eq!(
        identity_of(&["firezone://serial/C02XK1ZGJGH5"]),
        Identity::Absent,
        "naming the device claims nobody"
    );

    for uris in [
        vec!["firezone://email/jane.doe@example.com"],
        vec![
            "firezone://email/jane.doe@example.com",
            "firezone://account-id/5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3",
        ],
        vec![
            "firezone://email/jane.doe@example.com",
            "firezone://account-id/not-a-uuid",
            "firezone://actor-id/not-a-uuid",
        ],
    ] {
        assert_eq!(
            identity_of(&uris),
            Identity::Claimed {
                email: Some("jane.doe@example.com".to_owned())
            },
            "{uris:?}"
        );
    }

    for uris in [
        vec!["firezone://account-id/5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"],
        vec!["firezone://actor-id/9b4d1c07-6e2a-4f83-8c15-7ad0e39b2c64"],
        // An address no user could have is a claim on nobody the client can name.
        vec!["firezone://email/jane.doe"],
        vec![
            "firezone://email/jane.doe@example.com",
            "firezone://email/john.doe@example.com",
        ],
        // An attribute written with no value at all still claims the certificate is somebody's.
        vec!["firezone://email/"],
        vec!["firezone://email"],
    ] {
        assert_eq!(
            identity_of(&uris),
            Identity::Claimed { email: None },
            "{uris:?}"
        );
    }
}

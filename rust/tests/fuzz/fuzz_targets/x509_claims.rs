#![no_main]

//! Exercises the X.509 client identity parser with arbitrary DER.
//!
//! Every claim the clients and the portal act on is asserted against the certificate it
//! was read from, so a parse that succeeds also has to be internally consistent.

use std::{
    collections::HashSet,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use arbitrary::Arbitrary;
use libfuzzer_sys::fuzz_target;
use sha2::{Digest as _, Sha256};
use x509_claims::{
    ClaimValue, ParsedCertificate, RejectionReason, UnusableReason, parse_certificate,
};

fuzz_target!(|input: Input| {
    let Some(certificate) = parse_certificate(input.der, instant(input.seconds_since_epoch)) else {
        return;
    };

    assert_validity_window(&certificate, input.seconds_since_epoch);
    assert_validity_is_contiguous(
        input.der,
        input.seconds_since_epoch,
        input.other_seconds_since_epoch,
    );
    assert_usable_is_the_conjunction(&certificate);
    assert_unusable_reasons_mirror_the_rules(&certificate);
    // An arbitrary common name almost never matches, so it covers the rejection while the
    // certificate's own one covers the match.
    assert_usable_requires_an_exact_common_name(&certificate, input.expected_subject_cn);
    assert_usable_requires_an_exact_common_name(
        &certificate,
        certificate.subject_cn.as_deref().unwrap_or_default(),
    );
    assert_user_identity_agrees_with_its_fields(&certificate);
    assert_account_id_is_a_uuid(&certificate);
    assert_actor_email_is_addressable(&certificate);
    assert_mdm_device_id_is_normalised(&certificate);
    assert_device_serial_is_printable(&certificate);
    assert_claims_are_rendered_as_they_were_read(&certificate);
    assert_unrecognised_claims_are_shown(&certificate);
    assert_every_rejection_reason_reads();
    assert_fingerprint_covers_the_input(&certificate, input.der);
    assert_serial_is_bounded(&certificate);
    assert_detail_fields_are_labelled(&certificate);
    assert_parsing_is_deterministic(&certificate, input.der, input.seconds_since_epoch);
});

/// The certificate comes last so that it takes the rest of the input: libFuzzer's
/// mutations then apply to the DER instead of to the parameters in front of it.
#[derive(Arbitrary, Debug)]
struct Input<'a> {
    /// Instants are `u32` seconds so that offsetting the epoch by one can neither overflow
    /// [`SystemTime`] nor exceed the `i64` timestamp the parser compares it against.
    seconds_since_epoch: u32,
    other_seconds_since_epoch: u32,
    expected_subject_cn: &'a str,
    der: &'a [u8],
}

/// Asserts that a certificate is current exactly between its two validity timestamps.
fn assert_validity_window(certificate: &ParsedCertificate, seconds_since_epoch: u32) {
    let window = certificate.not_before_timestamp..=certificate.not_after_timestamp;

    assert_eq!(
        certificate.is_currently_valid,
        window.contains(&i64::from(seconds_since_epoch))
    );
}

/// Asserts that validity is a contiguous interval: an instant between two valid ones is valid too.
fn assert_validity_is_contiguous(der: &[u8], first: u32, second: u32) {
    let earlier = first.min(second);
    let later = first.max(second);
    let ends_are_valid = is_valid_at(der, earlier) && is_valid_at(der, later);

    if !ends_are_valid {
        return;
    }

    assert!(is_valid_at(der, earlier + (later - earlier) / 2));
}

/// Asserts that `is_usable` is the conjunction of the checks that make up a usable certificate.
fn assert_usable_is_the_conjunction(certificate: &ParsedCertificate) {
    let subject_cn = certificate.subject_cn.as_deref().unwrap_or_default();

    assert_eq!(
        certificate.is_usable(subject_cn),
        certificate.subject_cn.as_deref() == Some(subject_cn)
            && certificate.has_client_auth_eku
            && certificate.digital_signature_allowed
            && certificate.is_currently_valid
            && certificate.signing_algorithm.is_some()
    );
    assert_eq!(
        certificate.is_usable(subject_cn),
        certificate.subject_cn.as_deref() == Some(subject_cn)
            && certificate.unusable_reasons().is_empty()
    );
}

/// Asserts that every rule reports itself exactly when the field it is derived from fails.
///
/// The clients show these to an administrator, so a reason that is missing or spurious sends
/// them after the wrong part of their certificate template.
fn assert_unusable_reasons_mirror_the_rules(certificate: &ParsedCertificate) {
    let reasons = certificate.unusable_reasons();
    let rules = [
        (
            UnusableReason::NoClientAuthEku,
            !certificate.has_client_auth_eku,
        ),
        (
            UnusableReason::NoDigitalSignatureKeyUsage,
            !certificate.digital_signature_allowed,
        ),
        (
            UnusableReason::OutsideValidityPeriod,
            !certificate.is_currently_valid,
        ),
        (
            UnusableReason::UnsupportedKeyAlgorithm,
            certificate.signing_algorithm.is_none(),
        ),
    ];

    for (reason, failed) in rules {
        assert!(!reason.label().is_empty());
        assert_eq!(reasons.contains(&reason), failed);
    }

    let summary = certificate.unusable_summary();

    assert_eq!(summary.is_some(), !reasons.is_empty());

    let Some(summary) = summary else {
        return;
    };

    for reason in reasons {
        assert!(summary.contains(reason.label()));
    }
}

/// Asserts that `is_usable` accepts a common name only on an exact match.
fn assert_usable_requires_an_exact_common_name(certificate: &ParsedCertificate, candidate: &str) {
    if certificate.subject_cn.as_deref() == Some(candidate) {
        return;
    }

    assert!(!certificate.is_usable(candidate));
}

/// Asserts that a portal identity is present exactly when both of the claims it is made of are.
fn assert_user_identity_agrees_with_its_fields(certificate: &ParsedCertificate) {
    let user_identity = certificate.user_identity();

    assert_eq!(
        user_identity.is_some(),
        certificate.actor_email.attested().is_some() && certificate.account_id.attested().is_some()
    );

    let Some(user_identity) = user_identity else {
        return;
    };

    assert_eq!(
        certificate.actor_email.attested(),
        Some(user_identity.email.as_str())
    );
    assert_eq!(
        certificate.account_id.attested(),
        Some(user_identity.account_id.as_str())
    );
}

/// Asserts that an account ID reaches the portal as a hyphenated, lower-case UUID.
fn assert_account_id_is_a_uuid(certificate: &ParsedCertificate) {
    let Some(account_id) = certificate.account_id.attested() else {
        return;
    };

    assert!(uuid::Uuid::parse_str(account_id).is_ok());
    assert_eq!(account_id, account_id.to_lowercase());
    assert_eq!(account_id.len(), 36);
}

/// Asserts that an actor email is a lower-case address the portal can look an actor up by.
fn assert_actor_email_is_addressable(certificate: &ParsedCertificate) {
    let Some(actor_email) = certificate.actor_email.attested() else {
        return;
    };
    let (local, domain) = actor_email.split_once('@').expect("an email has a domain");

    assert_eq!(actor_email, actor_email.to_lowercase());
    assert!(!actor_email.chars().any(char::is_whitespace));
    assert!(!local.is_empty());
    assert!(!domain.is_empty());
    assert!(!domain.contains('@'));
    assert!(actor_email.len() <= 255);
}

/// Asserts that an MDM device ID is already in the form devices are matched by.
fn assert_mdm_device_id_is_normalised(certificate: &ParsedCertificate) {
    let Some(mdm_device_id) = certificate.mdm_device_id.attested() else {
        return;
    };

    assert_eq!(mdm_device_id, mdm_device_id.trim().to_ascii_lowercase());
    assert!(mdm_device_id.len() <= 255);
}

/// Asserts that a device serial carries something to show.
fn assert_device_serial_is_printable(certificate: &ParsedCertificate) {
    let Some(device_serial) = certificate.device_serial.attested() else {
        return;
    };

    assert!(!device_serial.trim().is_empty());
    assert!(device_serial.len() <= 255);
}

/// Asserts that every claim reaches the diagnostics screen as the state it was read in.
///
/// The clients call out the invalid ones, so a row that disagrees with the claim it was built
/// from sends an administrator after the wrong part of their certificate template.
fn assert_claims_are_rendered_as_they_were_read(certificate: &ParsedCertificate) {
    let fields = certificate.detail_fields();
    let claims = [
        ("Actor Email", &certificate.actor_email),
        ("Account ID", &certificate.account_id),
        ("MDM Device ID", &certificate.mdm_device_id),
        ("Device Serial", &certificate.device_serial),
    ];

    for (label, claim) in claims {
        let field = fields
            .iter()
            .find(|field| field.label == label)
            .unwrap_or_else(|| panic!("diagnostics should show {label}"));

        assert_eq!(field.value, *claim);
    }
}

/// Asserts that a `firezone://` name the parser does not read gets a bounded row of its own.
///
/// The name is copied out of the certificate, so one that spends its whole size on a single
/// name would otherwise take longer to display than to parse.
fn assert_unrecognised_claims_are_shown(certificate: &ParsedCertificate) {
    let unrecognised = certificate
        .detail_fields()
        .into_iter()
        .filter(|field| field.value == ClaimValue::Invalid(RejectionReason::UnknownAttribute))
        .map(|field| field.label)
        .collect::<HashSet<_>>();

    for claim in &certificate.unrecognised_claims {
        assert!(claim.chars().count() <= 96, "{claim}");
        assert!(unrecognised.contains(claim), "{claim} has no row");
    }
}

/// Asserts that every refusal a claim can carry renders a phrase of its own.
///
/// The clients show these to an administrator, so a blank phrase says nothing and two reasons
/// sharing one phrase sends them after the wrong part of their certificate template.
fn assert_every_rejection_reason_reads() {
    let labels = [
        RejectionReason::Empty,
        RejectionReason::TooLong,
        RejectionReason::NotAnEmailAddress,
        RejectionReason::NotAUuid,
        RejectionReason::Ambiguous,
        RejectionReason::PlaceholderIdentifier,
        RejectionReason::UnknownAttribute,
    ]
    .map(RejectionReason::label);

    for label in labels {
        assert!(!label.is_empty());
    }

    assert_eq!(labels.iter().collect::<HashSet<_>>().len(), labels.len());
}

/// Asserts that the fingerprint identifies the very bytes that were parsed.
fn assert_fingerprint_covers_the_input(certificate: &ParsedCertificate, der: &[u8]) {
    let digest = Sha256::digest(der)
        .iter()
        .map(|byte| format!("{byte:02X}"))
        .collect::<Vec<_>>()
        .join(":");

    assert_eq!(certificate.fingerprint, digest);
    assert_eq!(certificate.der_bytes, der.len());
}

/// Asserts that the serial number row stays a row however long the serial number is.
///
/// Rendering costs three characters per octet, so a certificate that spends its whole size on
/// a serial number would otherwise take longer to display than to parse.
fn assert_serial_is_bounded(certificate: &ParsedCertificate) {
    assert!(certificate.serial.len() <= 96, "{}", certificate.serial);
}

/// Asserts that every diagnostics row carries a label to render it under.
///
/// A certificate may carry an empty subject, issuer or common name, and a claim it leaves out
/// has no value at all, so only the label is guaranteed to hold text.
fn assert_detail_fields_are_labelled(certificate: &ParsedCertificate) {
    for field in certificate.detail_fields() {
        assert!(!field.label.is_empty());
    }
}

/// Asserts that parsing is a function of the DER and the instant alone.
fn assert_parsing_is_deterministic(
    certificate: &ParsedCertificate,
    der: &[u8],
    seconds_since_epoch: u32,
) {
    let reparsed = parse_certificate(der, instant(seconds_since_epoch))
        .expect("DER that parses once parses again");

    // Comparing the `Debug` output keeps `PartialEq` out of the crate's public API, which
    // nothing outside this target has a use for.
    assert_eq!(format!("{certificate:?}"), format!("{reparsed:?}"));
}

fn is_valid_at(der: &[u8], seconds_since_epoch: u32) -> bool {
    parse_certificate(der, instant(seconds_since_epoch))
        .expect("DER that parses once parses at any instant")
        .is_currently_valid
}

fn instant(seconds_since_epoch: u32) -> SystemTime {
    UNIX_EPOCH + Duration::from_secs(u64::from(seconds_since_epoch))
}

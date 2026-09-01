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
use x509_claims::{Claim, ParsedCertificate, ValidationError, parse_certificate};

fuzz_target!(|input: Input| {
    let Some(certificate) = parse_certificate(input.der, instant(input.seconds_since_epoch)) else {
        return;
    };

    assert_validity_window(&certificate, input.seconds_since_epoch);
    assert_the_validity_date_at_fault_says_so(&certificate, input.seconds_since_epoch);
    assert_validity_is_contiguous(
        input.der,
        input.seconds_since_epoch,
        input.other_seconds_since_epoch,
    );
    assert_mdm_device_id_is_normalised(&certificate);
    assert_device_serial_is_printable(&certificate);
    assert_claims_are_rendered_as_they_were_read(&certificate);
    assert_unrecognised_claims_are_shown(&certificate);
    assert_every_validation_error_reads();
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
    der: &'a [u8],
}

/// Asserts that a certificate is current exactly between its two validity timestamps.
fn assert_validity_window(certificate: &ParsedCertificate, seconds_since_epoch: u32) {
    let window = certificate.not_before_timestamp..=certificate.not_after_timestamp;

    assert_eq!(
        certificate.is_currently_valid(),
        window.contains(&i64::from(seconds_since_epoch))
    );
}

/// Asserts that an instant outside the validity window is blamed on the date it falls outside of.
///
/// The clients sort the rows carrying a problem to the top, so a window blamed on the wrong end
/// sends an administrator after a date that is fine.
fn assert_the_validity_date_at_fault_says_so(
    certificate: &ParsedCertificate,
    seconds_since_epoch: u32,
) {
    let checked_at = i64::from(seconds_since_epoch);
    let fields = certificate.detail_fields();
    let problem_of = |label: &str| {
        fields
            .iter()
            .find(|field| field.label == label)
            .unwrap_or_else(|| panic!("diagnostics should show {label}"))
            .problem
    };

    assert_eq!(
        problem_of("Not Before"),
        (checked_at < certificate.not_before_timestamp).then_some(ValidationError::NotYetValid)
    );
    assert_eq!(
        problem_of("Not After"),
        (checked_at > certificate.not_after_timestamp).then_some(ValidationError::Expired)
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

/// Asserts that an MDM device ID is already in the form devices are matched by.
fn assert_mdm_device_id_is_normalised(certificate: &ParsedCertificate) {
    let Some(mdm_device_id) = certificate.mdm_device_id.valid() else {
        return;
    };

    assert_eq!(mdm_device_id, mdm_device_id.trim().to_ascii_lowercase());
    assert!(mdm_device_id.len() <= 255);
}

/// Asserts that a device serial carries something to show.
fn assert_device_serial_is_printable(certificate: &ParsedCertificate) {
    let Some(device_serial) = certificate.device_serial.valid() else {
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
    let claims: [(&str, &Claim); 2] = [
        ("MDM Device ID", &certificate.mdm_device_id),
        ("Device Serial", &certificate.device_serial),
    ];

    for (label, claim) in claims {
        let field = fields
            .iter()
            .find(|field| field.label == label)
            .unwrap_or_else(|| panic!("diagnostics should show {label}"));

        assert_eq!(field.value, claim.value);
        assert_eq!(field.problem, claim.error);
    }
}

/// Asserts that an unrecognised `firezone://` name gets a bounded row of its own.
///
/// The name is copied out of the certificate, so one that spends its whole size on a single
/// name would otherwise take longer to display than to parse.
fn assert_unrecognised_claims_are_shown(certificate: &ParsedCertificate) {
    let unrecognised = certificate
        .detail_fields()
        .into_iter()
        .filter(|field| field.problem == Some(ValidationError::UnknownAttribute))
        .map(|field| field.label)
        .collect::<Vec<_>>();

    assert_eq!(unrecognised.len(), certificate.unrecognised_claims.len());

    for claim in &certificate.unrecognised_claims {
        assert!(claim.chars().count() <= 96, "{claim}");
        assert!(
            unrecognised.iter().any(|label| claim.starts_with(label)),
            "{claim} has no row"
        );
    }
}

/// Asserts that every error a claim can carry renders a phrase of its own.
///
/// The clients show these to an administrator, so a blank phrase says nothing and two errors
/// sharing one phrase sends them after the wrong part of their certificate template.
fn assert_every_validation_error_reads() {
    let labels = [
        ValidationError::Empty,
        ValidationError::TooLong,
        ValidationError::Ambiguous,
        ValidationError::PlaceholderIdentifier,
        ValidationError::UnknownAttribute,
        ValidationError::NotYetValid,
        ValidationError::Expired,
        ValidationError::MissingClientAuthEku,
        ValidationError::DigitalSignatureNotAllowed,
    ]
    .map(ValidationError::label);

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
        .is_currently_valid()
}

fn instant(seconds_since_epoch: u32) -> SystemTime {
    UNIX_EPOCH + Duration::from_secs(u64::from(seconds_since_epoch))
}

//! UniFFI bindings for the [`x509_claims`] certificate parser.
//!
//! Only the mobile and Apple clients go through here. The parsing itself lives in
//! `x509-claims`, which stays free of `uniffi` so the GUI and headless clients can
//! depend on it directly.

use std::time::SystemTime;

uniffi::setup_scaffolding!();

/// A row for certificate diagnostics screens, mirroring [`x509_claims::DetailField`].
///
/// The value reads on top and the problem, if there is one, underneath it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DetailField {
    pub label: String,
    pub value: Option<String>,
    /// Why the value above is not usable, `None` when it is.
    pub problem: Option<ValidationError>,
}

/// What a certificate says about one of the claims the clients read, mirroring
/// [`x509_claims::Claim`].
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Claim {
    /// What the certificate carries, `None` when it carries nothing.
    pub value: Option<String>,
    /// Why the value is not usable as this claim, `None` when it is.
    pub error: Option<ValidationError>,
}

/// Why a diagnostics row is not usable as what it names, mirroring
/// [`x509_claims::ValidationError`].
///
/// The clients word these from their own string resources, so the error crosses the binding
/// as itself rather than as a sentence.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ValidationError {
    Empty,
    TooLong,
    Ambiguous,
    PlaceholderIdentifier,
    UnknownAttribute,
    NotYetValid,
    Expired,
    MissingClientAuthEku,
    DigitalSignatureNotAllowed,
}

/// Metadata parsed from a client certificate, mirroring [`x509_claims::ParsedCertificate`].
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ParsedCertificate {
    pub subject_cn: Option<String>,
    pub subject: String,
    /// Human-readable renderings of all subject alternative names.
    pub subject_alternative_names: Vec<String>,
    pub mdm_device_id: Claim,
    pub device_serial: Claim,
    /// `firezone://` names whose attribute the parser does not recognise, e.g. a template typo.
    pub unrecognised_claims: Vec<String>,
    pub issuer: String,
    pub serial: String,
    pub has_client_auth_eku: bool,
    pub digital_signature_allowed: bool,
    pub is_currently_valid: bool,
    pub not_before: String,
    pub not_before_timestamp: i64,
    pub not_after: String,
    /// Label of the supported signing algorithm, e.g. `SHA256withRSA`.
    pub signing_algorithm: Option<String>,
    /// Colon-separated uppercase hex SHA-256 fingerprint of the DER bytes.
    pub fingerprint: String,
    pub der_bytes: u64,
    /// Ready-to-display diagnostics rows derived from the fields above.
    pub detail_fields: Vec<DetailField>,
}

/// Parses a DER-encoded client certificate into its display metadata.
///
/// Returns [`None`] if the bytes are not a valid X.509 certificate.
#[uniffi::export]
pub fn parse_client_certificate(der: Vec<u8>) -> Option<ParsedCertificate> {
    let parsed = x509_claims::parse_certificate(&der, SystemTime::now())?;

    Some(ParsedCertificate::from(parsed))
}

impl From<x509_claims::ParsedCertificate> for ParsedCertificate {
    fn from(parsed: x509_claims::ParsedCertificate) -> Self {
        let is_currently_valid = parsed.is_currently_valid();
        let detail_fields = parsed
            .detail_fields()
            .into_iter()
            .map(DetailField::from)
            .collect();

        Self {
            subject_cn: parsed.subject_cn,
            subject: parsed.subject,
            subject_alternative_names: parsed.subject_alternative_names,
            mdm_device_id: Claim::from(parsed.mdm_device_id),
            device_serial: Claim::from(parsed.device_serial),
            unrecognised_claims: parsed.unrecognised_claims,
            issuer: parsed.issuer,
            serial: parsed.serial,
            has_client_auth_eku: parsed.has_client_auth_eku,
            digital_signature_allowed: parsed.digital_signature_allowed,
            is_currently_valid,
            not_before: parsed.not_before,
            not_before_timestamp: parsed.not_before_timestamp,
            not_after: parsed.not_after,
            signing_algorithm: parsed
                .signing_algorithm
                .map(|algorithm| algorithm.label().to_owned()),
            fingerprint: parsed.fingerprint,
            der_bytes: parsed.der_bytes as u64,
            detail_fields,
        }
    }
}

impl From<x509_claims::DetailField> for DetailField {
    fn from(field: x509_claims::DetailField) -> Self {
        Self {
            label: field.label,
            value: field.value,
            problem: field.problem.map(ValidationError::from),
        }
    }
}

impl From<x509_claims::Claim> for Claim {
    fn from(claim: x509_claims::Claim) -> Self {
        Self {
            value: claim.value,
            error: claim.error.map(ValidationError::from),
        }
    }
}

impl From<x509_claims::ValidationError> for ValidationError {
    fn from(error: x509_claims::ValidationError) -> Self {
        match error {
            x509_claims::ValidationError::Empty => Self::Empty,
            x509_claims::ValidationError::TooLong => Self::TooLong,
            x509_claims::ValidationError::Ambiguous => Self::Ambiguous,
            x509_claims::ValidationError::PlaceholderIdentifier => Self::PlaceholderIdentifier,
            x509_claims::ValidationError::UnknownAttribute => Self::UnknownAttribute,
            x509_claims::ValidationError::NotYetValid => Self::NotYetValid,
            x509_claims::ValidationError::Expired => Self::Expired,
            x509_claims::ValidationError::MissingClientAuthEku => Self::MissingClientAuthEku,
            x509_claims::ValidationError::DigitalSignatureNotAllowed => {
                Self::DigitalSignatureNotAllowed
            }
        }
    }
}

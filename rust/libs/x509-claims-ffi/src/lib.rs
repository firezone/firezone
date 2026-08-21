//! UniFFI bindings for the [`x509_claims`] certificate parser.
//!
//! Only the mobile and Apple clients go through here. The parsing itself lives in
//! `x509-claims`, which stays free of `uniffi` so the GUI and headless clients can
//! depend on it directly.

use std::time::SystemTime;

uniffi::setup_scaffolding!();

/// A portal user identity encoded in a managed certificate's URI SANs.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UserIdentity {
    pub email: String,
    pub account_id: String,
}

/// A label-value pair for certificate diagnostics screens.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DetailField {
    pub label: String,
    pub value: String,
}

/// A `firezone://` claim found in a subject alternative name that the parser will not attest.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RejectedClaim {
    /// The attribute as it appeared in the URI, lower-cased, e.g. `email`.
    pub attribute: String,
    /// The value as it appeared, percent-decoded and trimmed, truncated for display.
    pub value: String,
    pub reason: RejectionReason,
}

/// Why a `firezone://` claim was not attested, mirroring [`x509_claims::RejectionReason`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RejectionReason {
    Empty,
    TooLong,
    NotAnEmailAddress,
    NotAUuid,
    Ambiguous,
    PlaceholderIdentifier,
    UnknownAttribute,
}

/// Metadata parsed from a client certificate, mirroring [`x509_claims::ParsedCertificate`].
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ParsedCertificate {
    pub subject_cn: Option<String>,
    pub subject: String,
    /// Human-readable renderings of all subject alternative names.
    pub subject_alternative_names: Vec<String>,
    pub actor_email: Option<String>,
    pub account_id: Option<String>,
    pub mdm_device_id: Option<String>,
    pub device_serial: Option<String>,
    pub rejected_claims: Vec<RejectedClaim>,
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
    /// Why this certificate cannot be presented for mutual TLS, `None` if it can.
    pub unusable_summary: Option<String>,
    pub user_identity: Option<UserIdentity>,
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
        let unusable_summary = parsed.unusable_summary();
        let user_identity = parsed.user_identity().map(UserIdentity::from);
        let detail_fields = parsed
            .detail_fields()
            .into_iter()
            .map(DetailField::from)
            .collect();
        let rejected_claims = parsed
            .rejected_claims
            .into_iter()
            .map(RejectedClaim::from)
            .collect();

        Self {
            subject_cn: parsed.subject_cn,
            subject: parsed.subject,
            subject_alternative_names: parsed.subject_alternative_names,
            actor_email: parsed.actor_email,
            account_id: parsed.account_id,
            mdm_device_id: parsed.mdm_device_id,
            device_serial: parsed.device_serial,
            rejected_claims,
            issuer: parsed.issuer,
            serial: parsed.serial,
            has_client_auth_eku: parsed.has_client_auth_eku,
            digital_signature_allowed: parsed.digital_signature_allowed,
            is_currently_valid: parsed.is_currently_valid,
            not_before: parsed.not_before,
            not_before_timestamp: parsed.not_before_timestamp,
            not_after: parsed.not_after,
            signing_algorithm: parsed
                .signing_algorithm
                .map(|algorithm| algorithm.label().to_owned()),
            fingerprint: parsed.fingerprint,
            der_bytes: parsed.der_bytes as u64,
            unusable_summary,
            user_identity,
            detail_fields,
        }
    }
}

impl From<x509_claims::UserIdentity> for UserIdentity {
    fn from(identity: x509_claims::UserIdentity) -> Self {
        Self {
            email: identity.email,
            account_id: identity.account_id,
        }
    }
}

impl From<x509_claims::DetailField> for DetailField {
    fn from(field: x509_claims::DetailField) -> Self {
        Self {
            label: field.label,
            value: field.value,
        }
    }
}

impl From<x509_claims::RejectedClaim> for RejectedClaim {
    fn from(claim: x509_claims::RejectedClaim) -> Self {
        Self {
            attribute: claim.attribute,
            value: claim.value,
            reason: RejectionReason::from(claim.reason),
        }
    }
}

impl From<x509_claims::RejectionReason> for RejectionReason {
    fn from(reason: x509_claims::RejectionReason) -> Self {
        match reason {
            x509_claims::RejectionReason::Empty => Self::Empty,
            x509_claims::RejectionReason::TooLong => Self::TooLong,
            x509_claims::RejectionReason::NotAnEmailAddress => Self::NotAnEmailAddress,
            x509_claims::RejectionReason::NotAUuid => Self::NotAUuid,
            x509_claims::RejectionReason::Ambiguous => Self::Ambiguous,
            x509_claims::RejectionReason::PlaceholderIdentifier => Self::PlaceholderIdentifier,
            x509_claims::RejectionReason::UnknownAttribute => Self::UnknownAttribute,
        }
    }
}

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

/// A row for certificate diagnostics screens, mirroring [`x509_claims::DetailField`].
///
/// The value reads on top and the problem, if there is one, underneath it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DetailField {
    pub label: String,
    pub value: ClaimValue,
    /// What is wrong with the value above, `None` when nothing is.
    pub problem: Option<FieldProblem>,
}

/// The text a diagnostics row shows, mirroring [`x509_claims::ClaimValue`].
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ClaimValue {
    /// What the certificate carries, whether or not the clients will attest it.
    Present { value: String },
    /// The certificate carries nothing for this row.
    Absent,
}

/// What a certificate says about one of the claims the clients read, mirroring
/// [`x509_claims::Claim`].
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Claim {
    pub value: ClaimValue,
    /// Why the clients will not attest the value, `None` when they will.
    pub rejection: Option<RejectionReason>,
}

/// What is wrong with one diagnostics row, mirroring [`x509_claims::FieldProblem`].
///
/// The clients word these from their own string resources, so the reason crosses the binding
/// as itself rather than as a sentence.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FieldProblem {
    /// The certificate carries this claim and the clients will not attest what it says.
    Rejected { reason: RejectionReason },
    /// The certificate cannot be presented for mutual TLS because of this attribute.
    Unusable { reason: UnusableReason },
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

/// A rule the certificate has to satisfy, mirroring [`x509_claims::UnusableReason`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum UnusableReason {
    NoClientAuthEku,
    NoDigitalSignatureKeyUsage,
    NotYetValid,
    Expired,
    UnsupportedKeyAlgorithm,
}

/// Metadata parsed from a client certificate, mirroring [`x509_claims::ParsedCertificate`].
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ParsedCertificate {
    pub subject_cn: Option<String>,
    pub subject: String,
    /// Human-readable renderings of all subject alternative names.
    pub subject_alternative_names: Vec<String>,
    pub actor_email: Claim,
    pub account_id: Claim,
    pub mdm_device_id: Claim,
    pub device_serial: Claim,
    /// `firezone://` names whose attribute the parser does not read, e.g. a typo in a template.
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
    /// Whether the certificate's own rules allow presenting it for mutual TLS.
    pub is_usable: bool,
    /// The rules it fails that no detail row carries, which the clients state with the verdict.
    pub certificate_problems: Vec<UnusableReason>,
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
        let is_usable = parsed.passes_its_own_rules();
        let certificate_problems = parsed
            .unusable_reasons_without_a_field()
            .into_iter()
            .map(UnusableReason::from)
            .collect();
        let user_identity = parsed.user_identity().map(UserIdentity::from);
        let detail_fields = parsed
            .detail_fields()
            .into_iter()
            .map(DetailField::from)
            .collect();

        Self {
            subject_cn: parsed.subject_cn,
            subject: parsed.subject,
            subject_alternative_names: parsed.subject_alternative_names,
            actor_email: Claim::from(parsed.actor_email),
            account_id: Claim::from(parsed.account_id),
            mdm_device_id: Claim::from(parsed.mdm_device_id),
            device_serial: Claim::from(parsed.device_serial),
            unrecognised_claims: parsed.unrecognised_claims,
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
            is_usable,
            certificate_problems,
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
            value: ClaimValue::from(field.value),
            problem: field.problem.map(FieldProblem::from),
        }
    }
}

impl From<x509_claims::ClaimValue> for ClaimValue {
    fn from(value: x509_claims::ClaimValue) -> Self {
        match value {
            x509_claims::ClaimValue::Present { value } => Self::Present { value },
            x509_claims::ClaimValue::Absent => Self::Absent,
        }
    }
}

impl From<x509_claims::Claim> for Claim {
    fn from(claim: x509_claims::Claim) -> Self {
        Self {
            value: ClaimValue::from(claim.value),
            rejection: claim.rejection.map(RejectionReason::from),
        }
    }
}

impl From<x509_claims::FieldProblem> for FieldProblem {
    fn from(problem: x509_claims::FieldProblem) -> Self {
        match problem {
            x509_claims::FieldProblem::Rejected { reason } => Self::Rejected {
                reason: RejectionReason::from(reason),
            },
            x509_claims::FieldProblem::Unusable { reason } => Self::Unusable {
                reason: UnusableReason::from(reason),
            },
        }
    }
}

impl From<x509_claims::UnusableReason> for UnusableReason {
    fn from(reason: x509_claims::UnusableReason) -> Self {
        match reason {
            x509_claims::UnusableReason::NoClientAuthEku => Self::NoClientAuthEku,
            x509_claims::UnusableReason::NoDigitalSignatureKeyUsage => {
                Self::NoDigitalSignatureKeyUsage
            }
            x509_claims::UnusableReason::NotYetValid => Self::NotYetValid,
            x509_claims::UnusableReason::Expired => Self::Expired,
            x509_claims::UnusableReason::UnsupportedKeyAlgorithm => Self::UnsupportedKeyAlgorithm,
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

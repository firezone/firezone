//! UniFFI bindings for the [`device_trust`] certificate parser.
//!
//! Only the mobile and Apple clients go through here. The parsing itself lives in
//! `device-trust`, which stays free of `uniffi` so the GUI and headless clients can
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

/// Metadata parsed from a client certificate, mirroring [`device_trust::CertificateMetadata`].
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CertificateInfo {
    pub subject_cn: Option<String>,
    pub subject: String,
    /// Human-readable renderings of all subject alternative names.
    pub subject_alternative_names: Vec<String>,
    pub actor_email: Option<String>,
    pub account_id: Option<String>,
    pub mdm_device_id: Option<String>,
    pub device_serial: Option<String>,
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
    pub user_identity: Option<UserIdentity>,
    /// Ready-to-display diagnostics rows derived from the fields above.
    pub detail_fields: Vec<DetailField>,
}

/// Parses a DER-encoded client certificate into its display metadata.
///
/// Returns [`None`] if the bytes are not a valid X.509 certificate.
#[uniffi::export]
pub fn parse_client_certificate(der: Vec<u8>) -> Option<CertificateInfo> {
    let metadata = device_trust::parse_certificate(&der, SystemTime::now())?;

    Some(CertificateInfo::from(metadata))
}

impl From<device_trust::CertificateMetadata> for CertificateInfo {
    fn from(metadata: device_trust::CertificateMetadata) -> Self {
        let user_identity = metadata.user_identity().map(UserIdentity::from);
        let detail_fields = metadata
            .detail_fields()
            .into_iter()
            .map(DetailField::from)
            .collect();

        Self {
            subject_cn: metadata.subject_cn,
            subject: metadata.subject,
            subject_alternative_names: metadata.subject_alternative_names,
            actor_email: metadata.actor_email,
            account_id: metadata.account_id,
            mdm_device_id: metadata.mdm_device_id,
            device_serial: metadata.device_serial,
            issuer: metadata.issuer,
            serial: metadata.serial,
            has_client_auth_eku: metadata.has_client_auth_eku,
            digital_signature_allowed: metadata.digital_signature_allowed,
            is_currently_valid: metadata.is_currently_valid,
            not_before: metadata.not_before,
            not_before_timestamp: metadata.not_before_timestamp,
            not_after: metadata.not_after,
            signing_algorithm: metadata
                .signing_algorithm
                .map(|algorithm| algorithm.label().to_owned()),
            fingerprint: metadata.fingerprint,
            der_bytes: metadata.der_bytes as u64,
            user_identity,
            detail_fields,
        }
    }
}

impl From<device_trust::UserIdentity> for UserIdentity {
    fn from(identity: device_trust::UserIdentity) -> Self {
        Self {
            email: identity.email,
            account_id: identity.account_id,
        }
    }
}

impl From<device_trust::DetailField> for DetailField {
    fn from(field: device_trust::DetailField) -> Self {
        Self {
            label: field.label,
            value: field.value,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RSA_LEAF: &[u8] =
        include_bytes!("../../../../elixir/test/support/fixtures/trust_anchors/leaf_cert.der");

    #[test]
    fn parses_der_certificate() {
        let info = parse_client_certificate(RSA_LEAF.to_vec()).expect("fixture should parse");

        assert_eq!(
            info.subject_cn.as_deref(),
            Some("dev.firezone.device-trust")
        );
        assert_eq!(info.der_bytes, RSA_LEAF.len() as u64);
        assert!(!info.detail_fields.is_empty());
    }

    #[test]
    fn rejects_garbage() {
        assert_eq!(parse_client_certificate(Vec::new()), None);
        assert_eq!(parse_client_certificate(vec![0xde, 0xad, 0xbe, 0xef]), None);
    }
}

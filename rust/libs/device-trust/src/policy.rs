//! Shared X.509 candidate-filtering policy used by all platforms.
//!
//! Mirrors the Apple/Android signers: subject CN match, presence of the clientAuth EKU, and a
//! current timestamp inside the certificate's validity window. The platform layer parses the DER
//! bytes once and then filters candidates here before attempting an expensive signing call.

use std::time::SystemTime;
use x509_parser::extensions::ParsedExtension;
use x509_parser::oid_registry::{OID_KEY_TYPE_EC_PUBLIC_KEY, OID_PKCS1_RSAENCRYPTION};
use x509_parser::prelude::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PublicKeyKind {
    Rsa,
    Ecdsa,
}

#[derive(Debug, Clone)]
pub(crate) struct CertMetadata {
    pub subject_cn: Option<String>,
    pub has_client_auth_eku: bool,
    pub not_before: Option<SystemTime>,
    pub not_after: Option<SystemTime>,
    pub public_key_kind: Option<PublicKeyKind>,
}

pub(crate) fn parse_metadata(der: &[u8]) -> Option<CertMetadata> {
    let (_, cert) = X509Certificate::from_der(der).ok()?;

    let subject_cn = cert
        .subject()
        .iter_common_name()
        .next()
        .and_then(|cn| cn.as_str().ok().map(str::to_owned));

    let has_client_auth_eku = cert.extensions().iter().any(|ext| {
        matches!(
            ext.parsed_extension(),
            ParsedExtension::ExtendedKeyUsage(eku) if eku.client_auth
        )
    });

    let not_before = SystemTime::UNIX_EPOCH.checked_add(std::time::Duration::from_secs(
        cert.validity().not_before.timestamp().max(0) as u64,
    ));
    let not_after = SystemTime::UNIX_EPOCH.checked_add(std::time::Duration::from_secs(
        cert.validity().not_after.timestamp().max(0) as u64,
    ));

    let public_key_kind = {
        let oid = &cert.subject_pki.algorithm.algorithm;
        if oid == &OID_PKCS1_RSAENCRYPTION {
            Some(PublicKeyKind::Rsa)
        } else if oid == &OID_KEY_TYPE_EC_PUBLIC_KEY {
            Some(PublicKeyKind::Ecdsa)
        } else {
            None
        }
    };

    Some(CertMetadata {
        subject_cn,
        has_client_auth_eku,
        not_before,
        not_after,
        public_key_kind,
    })
}

pub(crate) fn matches_client_auth_identity(
    metadata: &CertMetadata,
    expected_subject_cn: &str,
    now: SystemTime,
) -> bool {
    if metadata.subject_cn.as_deref() != Some(expected_subject_cn) {
        return false;
    }

    if !metadata.has_client_auth_eku {
        return false;
    }

    if metadata.not_before.is_some_and(|nb| now < nb) {
        return false;
    }

    if metadata.not_after.is_some_and(|na| now > na) {
        return false;
    }

    true
}

#![cfg_attr(not(any(target_os = "linux", target_os = "windows")), allow(dead_code))]

use std::{
    net::{Ipv4Addr, Ipv6Addr},
    time::SystemTime,
};

use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64_STANDARD};
use sha2::{Digest as _, Sha256};
use x509_parser::{
    extensions::{GeneralName, ParsedExtension},
    oid_registry::{OID_KEY_TYPE_EC_PUBLIC_KEY, OID_PKCS1_RSAENCRYPTION},
    prelude::{FromDer as _, X509Certificate},
};

use crate::DetailField;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SigningAlgorithm {
    RsaSha256,
    EcdsaSha256,
    EcdsaSha384,
    EcdsaSha512,
}

impl SigningAlgorithm {
    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::RsaSha256 => "SHA256withRSA",
            Self::EcdsaSha256 => "SHA256withECDSA",
            Self::EcdsaSha384 => "SHA384withECDSA",
            Self::EcdsaSha512 => "SHA512withECDSA",
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct CertificateMetadata {
    pub subject_cn: Option<String>,
    pub subject: String,
    pub subject_alternative_names: Vec<String>,
    pub mdm_device_id: Option<String>,
    pub issuer: String,
    pub serial: String,
    pub has_client_auth_eku: bool,
    pub digital_signature_allowed: bool,
    pub is_currently_valid: bool,
    pub not_before: String,
    pub not_before_timestamp: i64,
    pub not_after: String,
    pub signing_algorithm: Option<SigningAlgorithm>,
    pub fingerprint: String,
    pub der_bytes: usize,
}

impl CertificateMetadata {
    pub(crate) fn matches_subject(&self, expected_subject_cn: &str) -> bool {
        self.subject_cn.as_deref() == Some(expected_subject_cn)
    }

    pub(crate) fn is_usable(&self, expected_subject_cn: &str) -> bool {
        self.matches_subject(expected_subject_cn)
            && self.has_client_auth_eku
            && self.digital_signature_allowed
            && self.is_currently_valid
            && self.signing_algorithm.is_some()
    }

    pub(crate) fn detail_fields(&self) -> Vec<DetailField> {
        vec![
            field(
                "Common Name",
                self.subject_cn.as_deref().unwrap_or("Unavailable"),
            ),
            field("Subject", &self.subject),
            field(
                "Subject Alternative Names",
                if self.subject_alternative_names.is_empty() {
                    "None".to_owned()
                } else {
                    self.subject_alternative_names.join("\n")
                },
            ),
            field("Issuer", &self.issuer),
            field("Serial Number", &self.serial),
            field("Not Before", &self.not_before),
            field("Not After", &self.not_after),
            field(
                "Currently Valid",
                if self.is_currently_valid { "Yes" } else { "No" },
            ),
            field(
                "TLS Client Authentication EKU",
                if self.has_client_auth_eku {
                    "Yes"
                } else {
                    "No"
                },
            ),
            field(
                "Digital Signature Key Usage",
                if self.digital_signature_allowed {
                    "Allowed"
                } else {
                    "Not allowed"
                },
            ),
            field(
                "Signing Algorithm",
                self.signing_algorithm
                    .map(SigningAlgorithm::label)
                    .unwrap_or("Unsupported"),
            ),
            field("SHA-256 Fingerprint", &self.fingerprint),
            field("DER Byte Count", self.der_bytes.to_string()),
        ]
    }
}

pub(crate) fn parse_certificate(der: &[u8], now: SystemTime) -> Option<CertificateMetadata> {
    let (_, certificate) = X509Certificate::from_der(der).ok()?;

    let subject_cn = certificate
        .subject()
        .iter_common_name()
        .next()
        .and_then(|cn| cn.as_str().ok().map(str::to_owned));
    let has_client_auth_eku = certificate.extensions().iter().any(|extension| {
        matches!(
            extension.parsed_extension(),
            ParsedExtension::ExtendedKeyUsage(eku) if eku.client_auth
        )
    });
    let general_names = certificate
        .extensions()
        .iter()
        .filter_map(|extension| {
            if let ParsedExtension::SubjectAlternativeName(names) = extension.parsed_extension() {
                Some(names.general_names.iter())
            } else {
                None
            }
        })
        .flatten()
        .collect::<Vec<_>>();
    let subject_alternative_names = general_names
        .iter()
        .map(|name| format_subject_alternative_name(name))
        .collect();
    let mdm_device_id = extract_mdm_device_id(general_names.iter().filter_map(|name| {
        if let GeneralName::URI(value) = name {
            Some(*value)
        } else {
            None
        }
    }));
    // RFC 5280 permits Key Usage to be omitted. When present, it must allow
    // digitalSignature, matching the portal's verification policy.
    let digital_signature_allowed = certificate
        .extensions()
        .iter()
        .find_map(|extension| {
            if let ParsedExtension::KeyUsage(key_usage) = extension.parsed_extension() {
                Some(key_usage.digital_signature())
            } else {
                None
            }
        })
        .unwrap_or(true);

    let not_before_timestamp = certificate.validity().not_before.timestamp();
    let not_after_timestamp = certificate.validity().not_after.timestamp();
    let now_timestamp = now
        .duration_since(SystemTime::UNIX_EPOCH)
        .ok()
        .and_then(|duration| i64::try_from(duration.as_secs()).ok());
    let is_currently_valid = now_timestamp.is_some_and(|timestamp| {
        timestamp >= not_before_timestamp && timestamp <= not_after_timestamp
    });

    let signing_algorithm = {
        let algorithm = &certificate.subject_pki.algorithm;
        if algorithm.algorithm == OID_PKCS1_RSAENCRYPTION {
            Some(SigningAlgorithm::RsaSha256)
        } else if algorithm.algorithm == OID_KEY_TYPE_EC_PUBLIC_KEY {
            let curve = algorithm
                .parameters
                .as_ref()
                .and_then(|parameters| parameters.as_oid().ok())
                .map(|oid| oid.to_id_string());
            match curve.as_deref() {
                Some("1.3.132.0.34") => Some(SigningAlgorithm::EcdsaSha384),
                Some("1.3.132.0.35") => Some(SigningAlgorithm::EcdsaSha512),
                Some("1.2.840.10045.3.1.7") => Some(SigningAlgorithm::EcdsaSha256),
                Some(_) | None => None,
            }
        } else {
            None
        }
    };

    let fingerprint = Sha256::digest(der)
        .iter()
        .map(|byte| format!("{byte:02X}"))
        .collect::<Vec<_>>()
        .join(":");

    Some(CertificateMetadata {
        subject_cn,
        subject: certificate.subject().to_string(),
        subject_alternative_names,
        mdm_device_id,
        issuer: certificate.issuer().to_string(),
        serial: certificate.raw_serial_as_string(),
        has_client_auth_eku,
        digital_signature_allowed,
        is_currently_valid,
        not_before: certificate.validity().not_before.to_string(),
        not_before_timestamp,
        not_after: certificate.validity().not_after.to_string(),
        signing_algorithm,
        fingerprint,
        der_bytes: der.len(),
    })
}

fn extract_mdm_device_id<'a>(uris: impl IntoIterator<Item = &'a str>) -> Option<String> {
    let uris = uris
        .into_iter()
        .flat_map(split_comma_joined_uris)
        .filter(|uri| {
            !uri.to_ascii_lowercase()
                .starts_with("tag:microsoft.com,2022-09-14:sid:")
        })
        .collect::<Vec<_>>();
    let mut saw_typed_identifier = false;
    let mut typed_mdm_device_id = None;

    for uri in &uris {
        let Some((scheme, remainder)) = uri.split_once("://") else {
            continue;
        };
        if !scheme.eq_ignore_ascii_case("firezone") {
            continue;
        }
        let Some((id_type, value)) = remainder.split_once('/') else {
            continue;
        };
        let id_type = id_type.to_ascii_lowercase();
        if !matches!(
            id_type.as_str(),
            "serial"
                | "apple-serial"
                | "udid"
                | "apple-udid"
                | "smbios-uuid"
                | "intune-id"
                | "entra-id"
                | "ws1-uuid"
                | "jamf-id"
                | "kandji-id"
        ) || !valid_identifier(value)
        {
            continue;
        }

        saw_typed_identifier = true;
        if matches!(
            id_type.as_str(),
            "intune-id" | "entra-id" | "ws1-uuid" | "jamf-id" | "kandji-id"
        ) && typed_mdm_device_id.is_none()
        {
            typed_mdm_device_id = normalize_mdm_device_id(value);
        }
    }

    if saw_typed_identifier {
        return typed_mdm_device_id;
    }

    uris.into_iter().find_map(|uri| {
        let value = uri.trim();
        (value.len() == 36 && uuid::Uuid::parse_str(value).is_ok())
            .then(|| normalize_mdm_device_id(value))
            .flatten()
    })
}

/// Intune encodes all configured SAN URI rows into one comma-joined value.
/// Only split where the text following a comma begins with another URI scheme,
/// preserving the comma in Microsoft's SID URI.
fn split_comma_joined_uris(value: &str) -> Vec<&str> {
    let mut values = Vec::new();
    let mut start = 0;

    for (comma, _) in value.match_indices(',') {
        let remainder = &value[comma + 1..];
        let next = remainder.trim_start();
        if !starts_with_uri_scheme(next) {
            continue;
        }

        values.push(&value[start..comma]);
        start = comma + 1 + (remainder.len() - next.len());
    }
    values.push(&value[start..]);

    values
}

fn starts_with_uri_scheme(value: &str) -> bool {
    let mut bytes = value.bytes();
    let Some(first) = bytes.next() else {
        return false;
    };
    if !first.is_ascii_alphabetic() {
        return false;
    }

    bytes
        .take_while(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'.' | b'-' | b':')
        })
        .any(|byte| byte == b':')
}

fn valid_identifier(value: &str) -> bool {
    let value = value.trim();
    !value.is_empty()
        && value.len() <= 255
        && value.bytes().all(|byte| (0x20..=0x7e).contains(&byte))
}

fn normalize_mdm_device_id(value: &str) -> Option<String> {
    let normalized = value.trim().to_ascii_lowercase();
    if !valid_identifier(&normalized)
        || matches!(
            normalized.as_str(),
            "0" | "00000000-0000-0000-0000-000000000000"
                | "ffffffff-ffff-ffff-ffff-ffffffffffff"
                | "03000200-0400-0500-0006-000700080009"
                | "idnotpresentbutsettable"
        )
    {
        return None;
    }

    Some(normalized)
}

fn format_subject_alternative_name(name: &GeneralName<'_>) -> String {
    match name {
        GeneralName::OtherName(oid, value) => format!(
            "Other name ({oid}): DER/Base64 {}",
            BASE64_STANDARD.encode(value)
        ),
        GeneralName::RFC822Name(value) => format!("Email: {value}"),
        GeneralName::DNSName(value) => format!("DNS: {value}"),
        GeneralName::X400Address(value) => format!(
            "X.400 address: DER/Base64 {}",
            BASE64_STANDARD.encode(value.data)
        ),
        GeneralName::DirectoryName(value) => format!("Directory name: {value}"),
        GeneralName::EDIPartyName(value) => format!(
            "EDI party name: DER/Base64 {}",
            BASE64_STANDARD.encode(value.data)
        ),
        GeneralName::URI(value) => format!("URI: {value}"),
        GeneralName::IPAddress(value) => format!("IP address: {}", format_ip_address(value)),
        GeneralName::RegisteredID(value) => format!("Registered ID: {value}"),
        GeneralName::Invalid(tag, value) => format!(
            "Invalid SAN (tag {tag}): DER/Base64 {}",
            BASE64_STANDARD.encode(value)
        ),
    }
}

fn format_ip_address(value: &[u8]) -> String {
    match value {
        [a, b, c, d] => Ipv4Addr::new(*a, *b, *c, *d).to_string(),
        value if value.len() == 16 => {
            let octets = <[u8; 16]>::try_from(value).expect("length was checked");
            Ipv6Addr::from(octets).to_string()
        }
        value => format!("DER/Base64 {}", BASE64_STANDARD.encode(value)),
    }
}

pub(crate) fn field(label: impl Into<String>, value: impl Into<String>) -> DetailField {
    DetailField {
        label: label.into(),
        value: value.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    const RSA_LEAF: &[u8] =
        include_bytes!("../../../../elixir/test/support/fixtures/trust_anchors/leaf_cert.der");
    const P384_LEAF: &[u8] =
        include_bytes!("../../../../elixir/test/support/fixtures/trust_anchors/p384_leaf.der");

    #[test]
    fn recognizes_rsa_client_identity() {
        let metadata = parse_certificate(
            RSA_LEAF,
            SystemTime::UNIX_EPOCH + Duration::from_secs(1_798_761_600),
        )
        .expect("fixture should be a valid RSA certificate");
        assert_eq!(
            metadata.subject_cn.as_deref(),
            Some("dev.firezone.device-trust")
        );
        assert!(metadata.has_client_auth_eku);
        assert!(metadata.digital_signature_allowed);
        assert!(metadata.is_currently_valid);
        assert_eq!(
            metadata.signing_algorithm,
            Some(SigningAlgorithm::RsaSha256)
        );
        assert!(metadata.is_usable("dev.firezone.device-trust"));
    }

    #[test]
    fn recognizes_p384_digest() {
        let metadata = parse_certificate(
            P384_LEAF,
            SystemTime::UNIX_EPOCH + Duration::from_secs(1_798_761_600),
        )
        .expect("fixture should be a valid P-384 certificate");
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
    fn formats_ip_addresses() {
        assert_eq!(format_ip_address(&[10, 0, 0, 1]), "10.0.0.1");
        assert_eq!(
            format_ip_address(&[0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]),
            "2001:db8::1"
        );
    }

    #[test]
    fn extracts_typed_mdm_device_id_like_the_portal() {
        assert_eq!(
            extract_mdm_device_id([
                "firezone://serial/C02XK1ZGJGH5",
                "firezone://intune-id/5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3",
            ]),
            Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3".to_owned())
        );
    }

    #[test]
    fn extracts_mdm_device_id_from_intune_comma_joined_uri() {
        assert_eq!(
            extract_mdm_device_id([
                "tag:microsoft.com,2022-09-14:sid:S-1-12-1-1, firezone://serial/C02XK1ZGJGH5, firezone://intune-id/5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3",
            ]),
            Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3".to_owned())
        );
    }

    #[test]
    fn extracts_bare_guid_only_when_no_typed_identifier_exists() {
        assert_eq!(
            extract_mdm_device_id(["5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3"]),
            Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3".to_owned())
        );
        assert_eq!(
            extract_mdm_device_id([
                "firezone://serial/C02XK1ZGJGH5",
                "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3",
            ]),
            None
        );
    }
}

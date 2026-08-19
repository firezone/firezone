//! X.509 client identity certificates for the Firezone clients.
//!
//! This crate reads certificates and evaluates Firezone's rules for them: [`parse_certificate`]
//! turns DER bytes into a [`ParsedCertificate`] plus the label-value rows the clients render on
//! their diagnostics screens. Discovering certificates in a platform keystore and signing with
//! them happens elsewhere.
//!
//! Nothing here depends on `uniffi`, so the GUI and headless clients can link it
//! directly. `x509-identity-ffi` wraps this crate for the mobile and Apple clients and is
//! the only place the binding types live.

use std::{
    collections::HashSet,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SigningAlgorithm {
    RsaSha256,
    EcdsaSha256,
    EcdsaSha384,
    EcdsaSha512,
}

impl SigningAlgorithm {
    pub fn label(self) -> &'static str {
        match self {
            Self::RsaSha256 => "SHA256withRSA",
            Self::EcdsaSha256 => "SHA256withECDSA",
            Self::EcdsaSha384 => "SHA384withECDSA",
            Self::EcdsaSha512 => "SHA512withECDSA",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ParsedCertificate {
    pub subject_cn: Option<String>,
    pub subject: String,
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
    pub signing_algorithm: Option<SigningAlgorithm>,
    pub fingerprint: String,
    pub der_bytes: usize,
}

impl ParsedCertificate {
    fn matches_subject(&self, expected_subject_cn: &str) -> bool {
        self.subject_cn.as_deref() == Some(expected_subject_cn)
    }

    pub fn is_usable(&self, expected_subject_cn: &str) -> bool {
        self.matches_subject(expected_subject_cn)
            && self.has_client_auth_eku
            && self.digital_signature_allowed
            && self.is_currently_valid
            && self.signing_algorithm.is_some()
    }

    pub fn detail_fields(&self) -> Vec<DetailField> {
        let mut fields = vec![
            field(
                "Common Name",
                self.subject_cn.as_deref().unwrap_or("Unavailable"),
            ),
            field("Subject", &self.subject),
        ];
        if let Some(actor_email) = &self.actor_email {
            fields.push(field("Actor Email", actor_email));
        }
        if let Some(account_id) = &self.account_id {
            fields.push(field("Account ID", account_id));
        }
        if let Some(mdm_device_id) = &self.mdm_device_id {
            fields.push(field("MDM Device ID", mdm_device_id));
        }
        if let Some(device_serial) = &self.device_serial {
            fields.push(field("Device Serial", device_serial));
        }
        fields.extend([
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
        ]);
        fields
    }

    pub fn user_identity(&self) -> Option<UserIdentity> {
        Some(UserIdentity {
            email: self.actor_email.clone()?,
            account_id: self.account_id.clone()?,
        })
    }
}

/// A portal user identity encoded in a managed certificate's URI SANs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserIdentity {
    pub email: String,
    pub account_id: String,
}

/// A label-value pair for the clients' certificate diagnostics screens.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DetailField {
    pub label: String,
    pub value: String,
}

pub fn parse_certificate(der: &[u8], now: SystemTime) -> Option<ParsedCertificate> {
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
        .flat_map(|name| format_subject_alternative_name(name))
        .collect();
    let uri_subject_alternative_names = general_names
        .iter()
        .filter_map(|name| {
            if let GeneralName::URI(value) = name {
                Some(*value)
            } else {
                None
            }
        })
        .flat_map(split_comma_joined_uris)
        .collect::<Vec<_>>();
    let actor_email = extract_actor_email(&uri_subject_alternative_names);
    let account_id = extract_account_id(&uri_subject_alternative_names);
    let mdm_device_id = extract_mdm_device_id(uri_subject_alternative_names.iter().copied());
    let device_serial = extract_device_serial(&uri_subject_alternative_names);
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

    Some(ParsedCertificate {
        subject_cn,
        subject: certificate.subject().to_string(),
        subject_alternative_names,
        actor_email,
        account_id,
        mdm_device_id,
        device_serial,
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

fn extract_actor_email(uris: &[&str]) -> Option<String> {
    let emails = firezone_attribute_values(uris, "email")
        .into_iter()
        .filter(|value| valid_email(value))
        .map(|value| value.to_lowercase())
        .collect::<HashSet<_>>();

    (emails.len() == 1)
        .then(|| emails.into_iter().next())
        .flatten()
}

fn extract_account_id(uris: &[&str]) -> Option<String> {
    let account_ids = firezone_attribute_values(uris, "account-id")
        .into_iter()
        .filter_map(|value| uuid::Uuid::parse_str(&value).ok())
        .map(|value| value.hyphenated().to_string().to_lowercase())
        .collect::<HashSet<_>>();

    (account_ids.len() == 1)
        .then(|| account_ids.into_iter().next())
        .flatten()
}

fn extract_device_serial(uris: &[&str]) -> Option<String> {
    let serials = firezone_attribute_values(uris, "serial")
        .into_iter()
        .chain(firezone_attribute_values(uris, "apple-serial"))
        .collect::<Vec<_>>();
    let normalized = serials
        .iter()
        .map(|value| value.to_lowercase())
        .collect::<HashSet<_>>();

    (normalized.len() == 1)
        .then(|| serials.into_iter().next())
        .flatten()
}

fn firezone_attribute_values(uris: &[&str], expected_attribute: &str) -> Vec<String> {
    uris.iter()
        .filter_map(|uri| {
            let (scheme, remainder) = uri.split_once("://")?;
            if !scheme.eq_ignore_ascii_case("firezone") {
                return None;
            }
            let (attribute, raw_value) = remainder.split_once('/')?;
            if !attribute.eq_ignore_ascii_case(expected_attribute) {
                return None;
            }

            let decoded = percent_decode(raw_value).unwrap_or_else(|| raw_value.to_owned());
            let value = decoded.trim();
            valid_identifier(value).then(|| value.to_owned())
        })
        .collect()
}

fn valid_email(value: &str) -> bool {
    if !valid_identifier(value) || value.chars().any(char::is_whitespace) {
        return false;
    }
    let mut parts = value.split('@');
    matches!((parts.next(), parts.next(), parts.next()), (Some(local), Some(domain), None) if !local.is_empty() && !domain.is_empty())
}

fn percent_decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'%' {
            decoded.push(bytes[index]);
            index += 1;
            continue;
        }
        let high = *bytes.get(index + 1)?;
        let low = *bytes.get(index + 2)?;
        decoded.push(hex_value(high)? << 4 | hex_value(low)?);
        index += 3;
    }
    String::from_utf8(decoded).ok()
}

fn hex_value(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
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

        values.push(value[start..comma].trim());
        start = comma + 1 + (remainder.len() - next.len());
    }
    values.push(value[start..].trim());

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
    !value.is_empty() && value.len() <= 255
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

fn format_subject_alternative_name(name: &GeneralName<'_>) -> Vec<String> {
    let value = match name {
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
        GeneralName::URI(value) => {
            return split_comma_joined_uris(value)
                .into_iter()
                .map(|value| format!("URI: {value}"))
                .collect();
        }
        GeneralName::IPAddress(value) => format!("IP address: {}", format_ip_address(value)),
        GeneralName::RegisteredID(value) => format!("Registered ID: {value}"),
        GeneralName::Invalid(tag, value) => format!(
            "Invalid SAN (tag {tag}): DER/Base64 {}",
            BASE64_STANDARD.encode(value)
        ),
    };
    vec![value]
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

fn field(label: impl Into<String>, value: impl Into<String>) -> DetailField {
    DetailField {
        label: label.into(),
        value: value.into(),
    }
}

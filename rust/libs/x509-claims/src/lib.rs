//! X.509 client identity certificates for the Firezone clients.
//!
//! [`parse_certificate`] turns DER bytes into a [`ParsedCertificate`] plus the label-value rows
//! the clients render on their diagnostics screens. Whether a certificate is accepted is the
//! portal's answer, not this crate's. Discovering certificates in a platform keystore and
//! signing with them happens elsewhere.
//!
//! Nothing here depends on `uniffi`, so the GUI and headless clients can link it
//! directly. `x509-claims-ffi` wraps this crate for the mobile and Apple clients and is
//! the only place the binding types live.

use std::{
    collections::HashSet,
    net::{Ipv4Addr, Ipv6Addr},
    time::SystemTime,
};

use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64_STANDARD};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use x509_parser::{
    extensions::{GeneralName, ParsedExtension},
    oid_registry::{OID_KEY_TYPE_EC_PUBLIC_KEY, OID_PKCS1_RSAENCRYPTION},
    prelude::AlgorithmIdentifier,
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

/// What a certificate says about one of the claims the clients read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Claim {
    /// What the certificate carries, [`None`] when it carries nothing.
    pub value: Option<String>,
    /// Why the value is not usable as this claim, [`None`] when it is.
    pub error: Option<ValidationError>,
}

impl Claim {
    /// The value usable as this claim, [`None`] when there is none.
    pub fn valid(&self) -> Option<&str> {
        self.value.as_deref().filter(|_| self.error.is_none())
    }

    /// Whether the certificate wrote this attribute at all, whatever it wrote in it.
    ///
    /// An attribute written with an empty value has no value to show, so the error is the
    /// only trace it leaves.
    fn is_carried(&self) -> bool {
        self.value.is_some() || self.error.is_some()
    }

    fn present(value: String) -> Self {
        Self {
            value: Some(value),
            error: None,
        }
    }

    fn absent() -> Self {
        Self {
            value: None,
            error: None,
        }
    }

    /// A claim whose value is not usable as it.
    ///
    /// The value is shown the way the certificate spelled it, bounded the way every other
    /// claim value is: an administrator fixing a template needs to see what it wrote.
    fn invalid(value: &str, error: ValidationError) -> Self {
        let value = format_claim_value(value);

        Self {
            value: match value.trim().is_empty() {
                true => None,
                false => Some(value),
            },
            error: Some(error),
        }
    }
}

/// Why the text a certificate gave a claim is not usable as it, read underneath that text.
///
/// The clients word these themselves, so an error crosses to them as the error it is rather
/// than as a sentence: the mobile and Apple clients render them from their own string resources.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq, Hash)]
pub enum ValidationError {
    Empty,
    TooLong,
    NotAnEmailAddress,
    NotAUuid,
    Ambiguous,
    PlaceholderIdentifier,
    UnknownAttribute,
}

impl ValidationError {
    /// A phrase that reads on its own and after the claim it explains.
    pub fn label(self) -> &'static str {
        match self {
            Self::Empty => "empty",
            Self::TooLong => "longer than 255 characters",
            Self::NotAnEmailAddress => "not a valid email address",
            Self::NotAUuid => "not a UUID",
            Self::Ambiguous => "more than one value was given",
            Self::PlaceholderIdentifier => "a placeholder identifier",
            Self::UnknownAttribute => "not an attribute we understand",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ParsedCertificate {
    pub subject_cn: Option<String>,
    pub subject: String,
    pub subject_alternative_names: Vec<String>,
    pub actor_email: Claim,
    pub account_id: Claim,
    pub actor_id: Claim,
    pub mdm_device_id: Claim,
    pub device_serial: Claim,
    /// `firezone://` names whose attribute this parser does not read, e.g. a typo in a template.
    pub unrecognised_claims: Vec<String>,
    pub issuer: String,
    pub serial: String,
    pub has_client_auth_eku: bool,
    pub digital_signature_allowed: bool,
    pub is_currently_valid: bool,
    /// The instant the validity window was compared against, in seconds since the Unix epoch.
    pub checked_at_timestamp: i64,
    pub not_before: String,
    pub not_before_timestamp: i64,
    pub not_after: String,
    pub not_after_timestamp: i64,
    pub signing_algorithm: Option<SigningAlgorithm>,
    /// The public key's algorithm as the certificate spells it, for one Firezone cannot sign with.
    ///
    /// Object identifiers rather than a name: an algorithm this parser has no name for is
    /// exactly the one an administrator needs to read off the row.
    pub key_algorithm_oid: String,
    pub fingerprint: String,
    pub der_bytes: usize,
}

impl ParsedCertificate {
    pub fn detail_fields(&self) -> Vec<DetailField> {
        let mut fields = vec![
            optional_field("Common Name", self.subject_cn.clone()),
            field("Subject", &self.subject),
            field("Issuer", &self.issuer),
            claim_field("Actor Email", self.actor_email.clone()),
            claim_field("Account ID", self.account_id.clone()),
            claim_field("Actor ID", self.actor_id.clone()),
            claim_field("MDM Device ID", self.mdm_device_id.clone()),
            claim_field("Device Serial", self.device_serial.clone()),
        ];
        fields.extend(
            self.unrecognised_claims
                .iter()
                .map(|claim| unrecognised_claim_field(claim)),
        );
        let remaining = self.remaining_subject_alternative_names();
        if !remaining.is_empty() {
            fields.push(field("Subject Alternative Names", remaining.join("\n")));
        }
        fields.extend([
            field("Serial Number", &self.serial),
            field("Not Before", &self.not_before),
            field("Not After", &self.not_after),
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
                    .map(str::to_owned)
                    .unwrap_or_else(|| self.key_algorithm_oid.clone()),
            ),
            field("SHA-256 Fingerprint", &self.fingerprint),
        ]);

        // What is wrong with a certificate is what the reader came for, so it reads before the
        // rows that are merely true. The sort is stable, which is what keeps a row from moving
        // between two renderings of the same certificate.
        fields.sort_by_key(|field| field.problem.is_none());

        fields
    }

    /// Who the certificate claims is connecting.
    ///
    /// Carrying an account, actor or email claim at all commits the session to mutual TLS,
    /// whatever the claim says: what the portal makes of it is the portal's answer.
    pub fn identity(&self) -> Identity {
        let claims_somebody = [&self.account_id, &self.actor_id, &self.actor_email]
            .into_iter()
            .any(Claim::is_carried);

        if !claims_somebody {
            return Identity::Absent;
        }

        Identity::Claimed {
            email: self.actor_email.valid().map(str::to_owned),
        }
    }

    /// The subject alternative names that no claim row shows.
    ///
    /// The claim rows are parsed out of the URI names, so a name one of them displays would
    /// only be repeated here.
    fn remaining_subject_alternative_names(&self) -> Vec<&str> {
        self.subject_alternative_names
            .iter()
            .map(String::as_str)
            .filter(|name| !self.shown_in_a_claim_row(name))
            .collect()
    }

    /// Whether one of the claim rows displays this formatted subject alternative name.
    fn shown_in_a_claim_row(&self, name: &str) -> bool {
        let Some(uri) = name.strip_prefix(URI_PREFIX) else {
            return false;
        };
        let Some((attribute, value)) = firezone_claim(uri) else {
            // A bare device ID has no attribute and is matched by the URI as a whole.
            return self.matches_a_valid_claim(uri);
        };
        if !known_attribute(&attribute) {
            // An unrecognised claim gets a row of its own.
            return true;
        }
        let value = percent_decode(value).unwrap_or_else(|| value.to_owned());

        self.matches_a_valid_claim(value.trim())
    }

    /// Whether one of the claim rows holds `value`, compared the way the claims are matched.
    fn matches_a_valid_claim(&self, value: &str) -> bool {
        [
            &self.actor_email,
            &self.account_id,
            &self.mdm_device_id,
            &self.device_serial,
        ]
        .into_iter()
        .filter_map(|claim| claim.valid())
        .any(|valid| valid.to_lowercase() == value.to_lowercase())
    }
}

/// Who the certificate claims is connecting.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Identity {
    /// The certificate claims nobody, so the session signs in with a token.
    Absent,
    /// The certificate claims somebody, named by `email` where one could be read.
    Claimed { email: Option<String> },
}

/// A row for the clients' certificate diagnostics screens.
///
/// The value reads on top and the problem, if there is one, underneath it: a certificate is
/// wrong in an attribute, and that is where a reader has to look to fix it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DetailField {
    pub label: String,
    pub value: Option<String>,
    /// Why the value above is not usable, [`None`] when it is.
    pub problem: Option<ValidationError>,
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
    let actor_id = extract_actor_id(&uri_subject_alternative_names);
    let mdm_device_id = extract_mdm_device_id(&uri_subject_alternative_names);
    let device_serial = extract_device_serial(&uri_subject_alternative_names);
    let unrecognised_claims = extract_unrecognised_claims(&uri_subject_alternative_names);
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

    let key_algorithm_oid = format_key_algorithm(&certificate.subject_pki.algorithm);

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
        actor_id,
        mdm_device_id,
        device_serial,
        unrecognised_claims,
        issuer: certificate.issuer().to_string(),
        serial: format_serial(certificate.raw_serial()),
        has_client_auth_eku,
        digital_signature_allowed,
        is_currently_valid,
        checked_at_timestamp: now_timestamp.unwrap_or_default(),
        not_before: certificate.validity().not_before.to_string(),
        not_before_timestamp,
        not_after: certificate.validity().not_after.to_string(),
        not_after_timestamp,
        signing_algorithm,
        key_algorithm_oid,
        fingerprint,
        der_bytes: der.len(),
    })
}

/// The public key algorithm's object identifier, with the curve's where one is named.
fn format_key_algorithm(algorithm: &AlgorithmIdentifier<'_>) -> String {
    let oid = algorithm.algorithm.to_id_string();
    let Some(parameters) = algorithm
        .parameters
        .as_ref()
        .and_then(|parameters| parameters.as_oid().ok())
    else {
        return oid;
    };

    format!("{oid} ({})", parameters.to_id_string())
}

fn extract_actor_email(uris: &[&str]) -> Claim {
    let emails = firezone_attribute_values(uris, "email")
        .into_iter()
        .map(|value| {
            let value = value?;
            if !valid_email(&value) {
                return Err(Invalid {
                    value,
                    error: ValidationError::NotAnEmailAddress,
                });
            }

            Ok(value.to_lowercase())
        })
        .collect();

    resolve_claim(emails, str::to_owned)
}

fn extract_account_id(uris: &[&str]) -> Claim {
    resolve_claim(uuid_values(uris, "account-id"), str::to_owned)
}

fn uuid_values(uris: &[&str], attribute: &str) -> Vec<Result<String, Invalid>> {
    firezone_attribute_values(uris, attribute)
        .into_iter()
        .map(|value| {
            let value = value?;
            let Ok(uuid) = uuid::Uuid::parse_str(&value) else {
                return Err(Invalid {
                    value,
                    error: ValidationError::NotAUuid,
                });
            };

            Ok(uuid.hyphenated().to_string().to_lowercase())
        })
        .collect()
}

fn extract_actor_id(uris: &[&str]) -> Claim {
    resolve_claim(uuid_values(uris, "actor-id"), str::to_owned)
}

fn extract_device_serial(uris: &[&str]) -> Claim {
    let mut serials = firezone_attribute_values(uris, "serial");
    serials.extend(firezone_attribute_values(uris, "apple-serial"));

    // A serial is compared case-insensitively but shown the way the certificate spells it.
    resolve_claim(serials, str::to_lowercase)
}

fn firezone_attribute_values(
    uris: &[&str],
    expected_attribute: &str,
) -> Vec<Result<String, Invalid>> {
    let mut values = Vec::new();

    for uri in uris {
        let Some((attribute, raw_value)) = firezone_claim(uri) else {
            continue;
        };
        if attribute != expected_attribute {
            continue;
        }

        let decoded = percent_decode(raw_value).unwrap_or_else(|| raw_value.to_owned());
        let value = decoded.trim();
        if !valid_identifier(value) {
            values.push(Err(Invalid {
                value: value.to_owned(),
                error: invalid_identifier_error(value),
            }));
            continue;
        }

        values.push(Ok(value.to_owned()));
    }

    values
}

/// A value a certificate gave a claim that is not usable as it, and why.
struct Invalid {
    value: String,
    error: ValidationError,
}

/// The state a claim resolves to, comparing the values a certificate gave it by `key`.
///
/// Repeating the same value is not a conflict. Giving two different ones is, and neither is
/// usable: picking one would let a certificate decide which identity it is read as. Both are
/// still shown, because a template that writes two is fixed by seeing which.
fn resolve_claim(values: Vec<Result<String, Invalid>>, key: impl Fn(&str) -> String) -> Claim {
    let mut seen = HashSet::new();
    let mut accepted = Vec::new();
    let mut error = None;

    for value in values {
        match value {
            Ok(value) if seen.insert(key(&value)) => accepted.push(value),
            Ok(_) => {}
            Err(invalid) => {
                error.get_or_insert(invalid);
            }
        }
    }

    match (accepted.as_slice(), error) {
        ([value], _) => Claim::present(value.clone()),
        ([], None) => Claim::absent(),
        ([], Some(invalid)) => Claim::invalid(&invalid.value, invalid.error),
        (values, _) => Claim::invalid(&values.join(", "), ValidationError::Ambiguous),
    }
}

/// The lower-cased attribute and the raw value of a `firezone://` name, [`None`] for other URIs.
fn firezone_claim(uri: &str) -> Option<(String, &str)> {
    let (scheme, remainder) = uri.split_once("://")?;
    if !scheme.eq_ignore_ascii_case("firezone") {
        return None;
    }
    let (attribute, value) = match remainder.split_once('/') {
        Some(pair) => pair,
        // A name that stops at the attribute still claims it, with no value in it. Only
        // where the attribute is one we read, though: a bare device identifier is a name in
        // its own right rather than an empty claim.
        None if known_attribute(&remainder.to_ascii_lowercase()) => (remainder, ""),
        None => return None,
    };

    Some((attribute.to_ascii_lowercase(), value))
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

fn extract_mdm_device_id(uris: &[&str]) -> Claim {
    let uris = uris
        .iter()
        .copied()
        .flat_map(split_comma_joined_uris)
        .filter(|uri| {
            !uri.to_ascii_lowercase()
                .starts_with("tag:microsoft.com,2022-09-14:sid:")
        })
        .collect::<Vec<_>>();
    let mut saw_typed_identifier = false;
    let mut typed_mdm_device_id = None;
    let mut error = None;

    for uri in &uris {
        let Some((id_type, value)) = firezone_claim(uri) else {
            continue;
        };
        if !mdm_attribute(&id_type) {
            continue;
        }
        // The same escaping the other typed claims go through: an MDM that percent-encodes its
        // identifier must not end up with the literal escape sequence as its device ID.
        let value = percent_decode(value).unwrap_or_else(|| value.to_owned());
        let value = value.as_str();
        if !valid_identifier(value) {
            if device_id_attribute(&id_type) {
                error.get_or_insert(Invalid {
                    value: value.to_owned(),
                    error: invalid_identifier_error(value),
                });
            }

            continue;
        }

        saw_typed_identifier = true;
        if !device_id_attribute(&id_type) || typed_mdm_device_id.is_some() {
            continue;
        }

        typed_mdm_device_id = normalize_mdm_device_id(value);
        if typed_mdm_device_id.is_none() {
            error.get_or_insert(Invalid {
                value: value.to_owned(),
                error: ValidationError::PlaceholderIdentifier,
            });
        }
    }

    let device_id = if saw_typed_identifier {
        typed_mdm_device_id
    } else {
        uris.into_iter().find_map(|uri| {
            let value = uri.trim();
            (value.len() == 36 && uuid::Uuid::parse_str(value).is_ok())
                .then(|| normalize_mdm_device_id(value))
                .flatten()
        })
    };

    match (device_id, error) {
        (Some(device_id), _) => Claim::present(device_id),
        (None, Some(invalid)) => Claim::invalid(&invalid.value, invalid.error),
        (None, None) => Claim::absent(),
    }
}

fn extract_unrecognised_claims(uris: &[&str]) -> Vec<String> {
    uris.iter()
        .copied()
        .filter(|uri| {
            firezone_claim(uri).is_some_and(|(attribute, _)| !known_attribute(&attribute))
        })
        .map(format_claim_value)
        .collect()
}

/// Whether the parser reads this `firezone://` attribute at all, however it uses the value.
fn known_attribute(attribute: &str) -> bool {
    matches!(attribute, "email" | "account-id" | "actor-id") || mdm_attribute(attribute)
}

/// Whether the attribute is an identifier an MDM writes into a certificate, including the ones
/// that only say a device was enrolled.
fn mdm_attribute(attribute: &str) -> bool {
    matches!(
        attribute,
        "serial" | "apple-serial" | "udid" | "apple-udid" | "smbios-uuid"
    ) || device_id_attribute(attribute)
}

/// Whether the attribute is one the portal matches a device by.
fn device_id_attribute(attribute: &str) -> bool {
    matches!(
        attribute,
        "intune-id" | "entra-id" | "ws1-uuid" | "jamf-id" | "kandji-id"
    )
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

/// Why [`valid_identifier`] does not accept a value.
fn invalid_identifier_error(value: &str) -> ValidationError {
    if value.trim().is_empty() {
        return ValidationError::Empty;
    }

    ValidationError::TooLong
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

/// Marks a URI entry in the formatted subject alternative names.
const URI_PREFIX: &str = "URI: ";

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
                .map(|value| format!("{URI_PREFIX}{value}"))
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

/// RFC 5280 bounds a serial number to 20 octets, which a leading sign padding byte pushes to 21.
///
/// Nothing past that came from an issuer we would trust, and rendering it costs three characters
/// and an allocation per octet, so a certificate that spends its whole size on a serial number
/// would take longer to display than to parse.
const MAX_RENDERED_SERIAL_OCTETS: usize = 21;

fn format_serial(raw: &[u8]) -> String {
    let rendered = raw
        .iter()
        .take(MAX_RENDERED_SERIAL_OCTETS)
        .map(|byte| format!("{byte:02x}"))
        .collect::<Vec<_>>()
        .join(":");
    let elided = raw.len().saturating_sub(MAX_RENDERED_SERIAL_OCTETS);
    if elided == 0 {
        return rendered;
    }

    format!("{rendered} (+{elided} octets)")
}

/// A `firezone://` name the parser does not read goes straight into a diagnostics row, and a
/// certificate can spend its whole size on one.
const MAX_RENDERED_CLAIM_CHARS: usize = 64;

fn format_claim_value(value: &str) -> String {
    let rendered = value
        .chars()
        .take(MAX_RENDERED_CLAIM_CHARS)
        .collect::<String>();
    let elided = value
        .chars()
        .count()
        .saturating_sub(MAX_RENDERED_CLAIM_CHARS);
    if elided == 0 {
        return rendered;
    }

    format!("{rendered} (+{elided} characters)")
}

fn field(label: impl Into<String>, value: impl Into<String>) -> DetailField {
    DetailField {
        label: label.into(),
        value: Some(value.into()),
        problem: None,
    }
}

/// A row for something the certificate may leave out, which nothing is wrong with either way.
fn optional_field(label: impl Into<String>, value: Option<String>) -> DetailField {
    DetailField {
        label: label.into(),
        value,
        problem: None,
    }
}

fn claim_field(label: impl Into<String>, claim: Claim) -> DetailField {
    DetailField {
        label: label.into(),
        value: claim.value,
        problem: claim.error,
    }
}

/// The row for a `firezone://` name whose attribute the parser does not read.
///
/// Splitting the name lets it read like every other claim: the attribute labels the row and
/// its value fills it, so a template with a typo shows what it wrote as well as where.
fn unrecognised_claim_field(claim: &str) -> DetailField {
    let (attribute, value) = split_claim_attribute(claim);

    DetailField {
        label: attribute.to_owned(),
        value: value.filter(|value| !value.is_empty()).map(str::to_owned),
        problem: Some(ValidationError::UnknownAttribute),
    }
}

/// A `firezone://` name up to its value, and the value itself.
///
/// A name that carries no value, or one elided before it, has only the attribute to show.
fn split_claim_attribute(claim: &str) -> (&str, Option<&str>) {
    let Some(start) = claim.find("://").map(|index| index + "://".len()) else {
        return (claim, None);
    };
    let Some(separator) = claim[start..].find('/').map(|index| start + index) else {
        return (claim, None);
    };

    (&claim[..separator], Some(&claim[separator + 1..]))
}

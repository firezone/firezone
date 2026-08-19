//! X.509 client identities held by a PKCS#11 token.

use std::{path::PathBuf, sync::Arc, time::SystemTime};

use anyhow::{Context as _, ErrorExt as _, Result, anyhow, bail};
use cryptoki::{
    context::{CInitializeArgs, CInitializeFlags, Pkcs11},
    error::RvError,
    mechanism::{
        Mechanism, MechanismType,
        rsa::{PkcsMgfType, PkcsPssParams},
    },
    object::{Attribute, AttributeType, CertificateType, KeyType, ObjectClass, ObjectHandle},
    session::{Session, UserType},
    types::AuthPin,
};
use rustls::{SignatureAlgorithm, SignatureScheme, pki_types::CertificateDer};
use sha2::{Digest as _, Sha256, Sha384, Sha512};
use x509_claims::{ParsedCertificate, SigningAlgorithm, parse_certificate};
use x509_credential::{PrivateKey, SigningError};

use crate::{Config, DetailField, DetailSection, Identity, Status, field};

pub(crate) fn status(config: &Config, subject_cn: &str) -> Result<Status> {
    let Some(uri) = config.pkcs11_uri.as_deref() else {
        return Ok(Status {
            summary: "No PKCS#11 token is configured.".to_owned(),
            sections: vec![DetailSection {
                title: "PKCS#11 Configuration".to_owned(),
                fields: vec![field("PKCS#11 URI", "Not configured")],
            }],
        });
    };

    let uri = Pkcs11Uri::parse(uri).context("Invalid PKCS#11 configuration")?;
    let session = open_session(&uri)?;
    let certificates = matching_certificates(&session, &uri, subject_cn)?;
    let usable = certificates
        .iter()
        .filter(|certificate| certificate.usable)
        .count();

    let mut sections = vec![configuration_section(&uri)];
    sections.extend(
        certificates
            .iter()
            .enumerate()
            .map(|(index, certificate)| DetailSection {
                title: format!("Matching Certificate {}", index + 1),
                fields: certificate.detail_fields(),
            }),
    );

    let summary = match (usable, certificates.len()) {
        (0, 0) => format!(
            "No X.509 certificate with subject CN '{subject_cn}' is on the configured PKCS#11 token."
        ),
        (0, count) => format!(
            "Found {count} matching X.509 certificate(s), but none of them are usable as a client identity."
        ),
        (count, _) => {
            format!("{count} X.509 client identity certificate(s) are available for mutual TLS.")
        }
    };

    Ok(Status { summary, sections })
}

pub(crate) fn identity(config: &Config, subject_cn: &str) -> Result<Option<Identity>> {
    let Some(uri) = config.pkcs11_uri.as_deref() else {
        tracing::debug!("No PKCS#11 token is configured for mutual TLS");

        return Ok(None);
    };

    let uri = Pkcs11Uri::parse(uri).context("Invalid PKCS#11 configuration")?;
    let session = open_session(&uri)?;
    let certificates = matching_certificates(&session, &uri, subject_cn)?;
    // The URI's `object` attribute names the leaf. Intermediates usually carry a different label,
    // so the chain is assembled from every certificate on the token.
    let issuers = certificate_objects(&session, &uri, IncludeIssuers::Yes)?;

    let Some(certificate) = certificates
        .into_iter()
        .filter(|certificate| certificate.usable)
        .max_by_key(|certificate| certificate.metadata.not_before_timestamp)
    else {
        return Ok(None);
    };

    let algorithm = certificate
        .metadata
        .signing_algorithm
        .context("The selected PKCS#11 certificate uses an unsupported key algorithm")?;
    let chain = certificate_chain(&certificate.der, &issuers)
        .into_iter()
        .map(CertificateDer::from)
        .collect();
    let key = Arc::new(Pkcs11Key {
        uri,
        key_id: certificate.id,
        key_label: certificate.label,
        algorithm,
    });

    tracing::info!(
        fingerprint = %certificate.metadata.fingerprint,
        "Selected a PKCS#11 X.509 identity for mutual TLS"
    );

    Ok(Some(Identity { chain, key }))
}

/// A private key on a PKCS#11 token, addressed by the attributes its certificate shares with it.
///
/// Sessions cannot be shared between threads, so each signature opens its own.
#[derive(Debug)]
struct Pkcs11Key {
    uri: Pkcs11Uri,
    key_id: Option<Vec<u8>>,
    key_label: Option<String>,
    algorithm: SigningAlgorithm,
}

impl PrivateKey for Pkcs11Key {
    fn supported_schemes(&self) -> Vec<SignatureScheme> {
        signature_schemes(self.algorithm).to_vec()
    }

    fn algorithm(&self) -> SignatureAlgorithm {
        match self.algorithm {
            SigningAlgorithm::RsaSha256 => SignatureAlgorithm::RSA,
            SigningAlgorithm::EcdsaSha256 => SignatureAlgorithm::ECDSA,
            SigningAlgorithm::EcdsaSha384 => SignatureAlgorithm::ECDSA,
            SigningAlgorithm::EcdsaSha512 => SignatureAlgorithm::ECDSA,
        }
    }

    fn sign(&self, scheme: SignatureScheme, message: &[u8]) -> Result<Vec<u8>, SigningError> {
        let session = open_session(&self.uri).map_err(classify_signing_error)?;
        let key = find_private_key(
            &session,
            self.key_id.as_deref(),
            self.key_label.as_deref(),
            Some(self.algorithm),
        )
        .map_err(classify_signing_error)?
        .ok_or_else(|| {
            SigningError::KeyUnavailable(
                "the PKCS#11 token no longer holds the private key".to_owned(),
            )
        })?;
        let signature = sign_with_key(&session, key, scheme, message)?;

        Ok(signature)
    }
}

fn signature_schemes(algorithm: SigningAlgorithm) -> &'static [SignatureScheme] {
    match algorithm {
        SigningAlgorithm::RsaSha256 => &[
            SignatureScheme::RSA_PSS_SHA512,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PKCS1_SHA512,
            SignatureScheme::RSA_PKCS1_SHA384,
            SignatureScheme::RSA_PKCS1_SHA256,
        ],
        SigningAlgorithm::EcdsaSha256 => &[SignatureScheme::ECDSA_NISTP256_SHA256],
        SigningAlgorithm::EcdsaSha384 => &[SignatureScheme::ECDSA_NISTP384_SHA384],
        SigningAlgorithm::EcdsaSha512 => &[SignatureScheme::ECDSA_NISTP521_SHA512],
    }
}

#[expect(
    clippy::wildcard_enum_match_arm,
    reason = "rustls only ever asks for a scheme we advertised in `supported_schemes`"
)]
fn sign_with_key(
    session: &Session,
    key: ObjectHandle,
    scheme: SignatureScheme,
    message: &[u8],
) -> Result<Vec<u8>, SigningError> {
    let signature = match scheme {
        SignatureScheme::RSA_PSS_SHA256 => session.sign(
            &Mechanism::Sha256RsaPkcsPss(PkcsPssParams {
                hash_alg: MechanismType::SHA256,
                mgf: PkcsMgfType::MGF1_SHA256,
                s_len: 32.into(),
            }),
            key,
            message,
        ),
        SignatureScheme::RSA_PSS_SHA384 => session.sign(
            &Mechanism::Sha384RsaPkcsPss(PkcsPssParams {
                hash_alg: MechanismType::SHA384,
                mgf: PkcsMgfType::MGF1_SHA384,
                s_len: 48.into(),
            }),
            key,
            message,
        ),
        SignatureScheme::RSA_PSS_SHA512 => session.sign(
            &Mechanism::Sha512RsaPkcsPss(PkcsPssParams {
                hash_alg: MechanismType::SHA512,
                mgf: PkcsMgfType::MGF1_SHA512,
                s_len: 64.into(),
            }),
            key,
            message,
        ),
        SignatureScheme::RSA_PKCS1_SHA256 => session.sign(&Mechanism::Sha256RsaPkcs, key, message),
        SignatureScheme::RSA_PKCS1_SHA384 => session.sign(&Mechanism::Sha384RsaPkcs, key, message),
        SignatureScheme::RSA_PKCS1_SHA512 => session.sign(&Mechanism::Sha512RsaPkcs, key, message),
        SignatureScheme::ECDSA_NISTP256_SHA256 => {
            let raw = session
                .sign(&Mechanism::Ecdsa, key, &Sha256::digest(message))
                .map_err(pkcs11_error)?;

            return der_encode_ecdsa_signature(&raw);
        }
        SignatureScheme::ECDSA_NISTP384_SHA384 => {
            let raw = session
                .sign(&Mechanism::Ecdsa, key, &Sha384::digest(message))
                .map_err(pkcs11_error)?;

            return der_encode_ecdsa_signature(&raw);
        }
        SignatureScheme::ECDSA_NISTP521_SHA512 => {
            let raw = session
                .sign(&Mechanism::Ecdsa, key, &Sha512::digest(message))
                .map_err(pkcs11_error)?;

            return der_encode_ecdsa_signature(&raw);
        }
        _ => return Err(SigningError::UnsupportedScheme(scheme)),
    }
    .map_err(pkcs11_error)?;

    Ok(signature)
}

/// Names the cause behind a failure that carries a PKCS#11 return value.
fn classify_signing_error(error: anyhow::Error) -> SigningError {
    let reason = format!("{error:#}");
    let Some(cryptoki::error::Error::Pkcs11(value, _)) =
        error.any_downcast_ref::<cryptoki::error::Error>()
    else {
        return SigningError::Keystore(reason);
    };

    classify_return_value(*value, reason)
}

fn pkcs11_error(error: cryptoki::error::Error) -> SigningError {
    let reason = error.to_string();
    let cryptoki::error::Error::Pkcs11(value, _) = error else {
        return SigningError::Keystore(reason);
    };

    classify_return_value(value, reason)
}

/// Tells a token that lost the key from one that refuses to use it.
///
/// A PIN the token rejected and a key whose attributes forbid signing are both refusals: the
/// token is present and answers, it just will not sign for us.
#[expect(
    clippy::wildcard_enum_match_arm,
    reason = "PKCS#11 defines far more return values than the ones we can act on"
)]
fn classify_return_value(value: RvError, reason: String) -> SigningError {
    match value {
        RvError::DeviceRemoved => SigningError::KeyUnavailable(reason),
        RvError::TokenNotPresent => SigningError::KeyUnavailable(reason),
        RvError::KeyHandleInvalid => SigningError::KeyUnavailable(reason),
        RvError::ObjectHandleInvalid => SigningError::KeyUnavailable(reason),
        RvError::PinIncorrect => SigningError::AccessDenied(reason),
        RvError::PinExpired => SigningError::AccessDenied(reason),
        RvError::PinLocked => SigningError::AccessDenied(reason),
        RvError::UserNotLoggedIn => SigningError::AccessDenied(reason),
        RvError::KeyFunctionNotPermitted => SigningError::AccessDenied(reason),
        RvError::FunctionCanceled => SigningError::AccessDenied(reason),
        _ => SigningError::Keystore(reason),
    }
}

/// Wraps the fixed-width `r` and `s` values the token returns into the DER sequence TLS expects.
fn der_encode_ecdsa_signature(raw: &[u8]) -> Result<Vec<u8>, SigningError> {
    if raw.is_empty() || !raw.len().is_multiple_of(2) {
        return Err(SigningError::Keystore(format!(
            "the token returned a {}-byte ECDSA signature",
            raw.len()
        )));
    }

    let half = raw.len() / 2;
    let r = der_integer(&raw[..half]);
    let s = der_integer(&raw[half..]);
    let mut output = vec![0x30];
    encode_der_length(&mut output, r.len() + s.len());
    output.extend(r);
    output.extend(s);

    Ok(output)
}

fn der_integer(value: &[u8]) -> Vec<u8> {
    let first_nonzero = value
        .iter()
        .position(|byte| *byte != 0)
        .unwrap_or(value.len().saturating_sub(1));
    let value = &value[first_nonzero..];
    let needs_padding = value.first().is_some_and(|byte| byte & 0x80 != 0);
    let mut output = vec![0x02];
    encode_der_length(&mut output, value.len() + usize::from(needs_padding));
    if needs_padding {
        output.push(0);
    }
    output.extend(value);

    output
}

fn encode_der_length(output: &mut Vec<u8>, length: usize) {
    if length < 0x80 {
        output.push(length as u8);
    } else if length < 0x100 {
        output.extend([0x81, length as u8]);
    } else {
        output.extend([0x82, (length >> 8) as u8, length as u8]);
    }
}

/// Opens a read-only session on the configured token, unlocking it when a PIN is configured.
fn open_session(uri: &Pkcs11Uri) -> Result<Session> {
    let pkcs11 = Pkcs11::new(&uri.module_path)
        .with_context(|| format!("Failed to load {}", uri.module_path.display()))?;
    pkcs11
        .initialize(CInitializeArgs::new(CInitializeFlags::OS_LOCKING_OK))
        .context("PKCS#11 initialization failed")?;

    let slot = find_slot(&pkcs11, uri.token_label.as_deref())?;
    let session = pkcs11
        .open_ro_session(slot)
        .context("Failed to open the PKCS#11 token")?;

    if let Some(pin) = uri.read_pin()? {
        session
            .login(UserType::User, Some(&AuthPin::new(pin.into_boxed_str())))
            .context("Failed to unlock the PKCS#11 token")?;
    }

    Ok(session)
}

fn find_slot(pkcs11: &Pkcs11, token_label: Option<&str>) -> Result<cryptoki::slot::Slot> {
    let slots = pkcs11
        .get_slots_with_token()
        .context("Failed to enumerate PKCS#11 tokens")?;

    let Some(label) = token_label else {
        let slot = slots
            .into_iter()
            .next()
            .ok_or_else(|| anyhow!("No PKCS#11 tokens are available"))?;

        return Ok(slot);
    };

    for slot in slots {
        if pkcs11.get_token_info(slot)?.label().trim() == label {
            return Ok(slot);
        }
    }

    bail!("No PKCS#11 token with label '{label}' was found");
}

/// A certificate on the token whose subject CN is the one we look for.
struct Certificate {
    der: Vec<u8>,
    id: Option<Vec<u8>>,
    label: Option<String>,
    metadata: ParsedCertificate,
    key_available: bool,
    usable: bool,
}

impl Certificate {
    fn detail_fields(&self) -> Vec<DetailField> {
        let mut fields = vec![
            field(
                "Object Label",
                self.label.as_deref().unwrap_or("Unavailable"),
            ),
            field(
                "Private Key Access",
                if self.key_available {
                    "Available"
                } else {
                    "Unavailable"
                },
            ),
            field(
                "Usable as a Client Identity",
                if self.usable { "Yes" } else { "No" },
            ),
        ];
        fields.extend(
            self.metadata
                .detail_fields()
                .into_iter()
                .map(DetailField::from),
        );

        fields
    }
}

fn matching_certificates(
    session: &Session,
    uri: &Pkcs11Uri,
    subject_cn: &str,
) -> Result<Vec<Certificate>> {
    let now = SystemTime::now();
    let mut certificates = Vec::new();

    for object in certificate_objects(session, uri, IncludeIssuers::No)? {
        let Some(metadata) = parse_certificate(&object.der, now) else {
            tracing::warn!(
                object_label = ?object.label,
                "Ignoring an invalid PKCS#11 X.509 certificate"
            );
            continue;
        };
        if metadata.subject_cn.as_deref() != Some(subject_cn) {
            continue;
        }

        let key_available = find_private_key(
            session,
            object.id.as_deref(),
            object.label.as_deref(),
            metadata.signing_algorithm,
        )?
        .is_some();

        certificates.push(Certificate {
            der: object.der,
            id: object.id,
            label: object.label,
            usable: metadata.is_usable(subject_cn) && key_available,
            metadata,
            key_available,
        });
    }

    Ok(certificates)
}

/// Whether to look past the object label the URI selects, which only names the leaf.
#[derive(Clone, Copy, PartialEq, Eq)]
enum IncludeIssuers {
    Yes,
    No,
}

struct CertificateObject {
    der: Vec<u8>,
    id: Option<Vec<u8>>,
    label: Option<String>,
}

fn certificate_objects(
    session: &Session,
    uri: &Pkcs11Uri,
    include_issuers: IncludeIssuers,
) -> Result<Vec<CertificateObject>> {
    let handles = session
        .find_objects(&[
            Attribute::Class(ObjectClass::CERTIFICATE),
            Attribute::CertificateType(CertificateType::X_509),
        ])
        .context("Failed to enumerate PKCS#11 certificates")?;
    let mut certificates = Vec::new();

    for handle in handles {
        let attributes = match session.get_attributes(
            handle,
            &[
                AttributeType::Value,
                AttributeType::Id,
                AttributeType::Label,
            ],
        ) {
            Ok(attributes) => attributes,
            Err(error) => {
                tracing::warn!(?error, "Failed to read a PKCS#11 certificate object");
                continue;
            }
        };

        let mut der = None;
        let mut id = None;
        let mut label = None;
        for attribute in attributes {
            #[expect(
                clippy::wildcard_enum_match_arm,
                reason = "PKCS#11 may return attributes we did not ask for"
            )]
            match attribute {
                Attribute::Value(value) => der = Some(value),
                Attribute::Id(value) => id = Some(value),
                Attribute::Label(value) => label = String::from_utf8(value).ok(),
                _ => {}
            }
        }

        if include_issuers == IncludeIssuers::No
            && uri.object_label.is_some()
            && label != uri.object_label
        {
            continue;
        }
        if let Some(der) = der {
            certificates.push(CertificateObject { der, id, label });
        }
    }

    Ok(certificates)
}

fn find_private_key(
    session: &Session,
    id: Option<&[u8]>,
    label: Option<&str>,
    algorithm: Option<SigningAlgorithm>,
) -> Result<Option<ObjectHandle>> {
    let key_type = match algorithm {
        Some(SigningAlgorithm::RsaSha256) => KeyType::RSA,
        Some(SigningAlgorithm::EcdsaSha256) => KeyType::EC,
        Some(SigningAlgorithm::EcdsaSha384) => KeyType::EC,
        Some(SigningAlgorithm::EcdsaSha512) => KeyType::EC,
        None => return Ok(None),
    };
    let mut template = vec![
        Attribute::Class(ObjectClass::PRIVATE_KEY),
        Attribute::KeyType(key_type),
    ];
    match (id, label) {
        (Some(id), _) => template.push(Attribute::Id(id.to_vec())),
        (None, Some(label)) => template.push(Attribute::Label(label.as_bytes().to_vec())),
        (None, None) => return Ok(None),
    }

    let key = session
        .find_objects(&template)
        .context("Failed to locate the PKCS#11 private key")?
        .into_iter()
        .next();

    Ok(key)
}

/// Walks up from the leaf, collecting the issuers the token holds.
///
/// Stops at the first issuer the token does not have, leaving the portal to complete the chain
/// from its own trust store.
fn certificate_chain(leaf: &[u8], issuers: &[CertificateObject]) -> Vec<Vec<u8>> {
    let now = SystemTime::now();
    let mut chain = vec![leaf.to_vec()];
    let Some(mut current) = parse_certificate(leaf, now) else {
        return chain;
    };

    while current.subject != current.issuer {
        let Some((der, metadata)) = issuers.iter().find_map(|candidate| {
            if chain.contains(&candidate.der) {
                return None;
            }
            let metadata = parse_certificate(&candidate.der, now)?;

            (metadata.subject == current.issuer).then_some((&candidate.der, metadata))
        }) else {
            break;
        };

        chain.push(der.clone());
        current = metadata;
    }

    chain
}

fn configuration_section(uri: &Pkcs11Uri) -> DetailSection {
    DetailSection {
        title: "PKCS#11 Configuration".to_owned(),
        fields: vec![
            field("Certificate Storage", "PKCS#11 token"),
            field(
                "Private Key Storage",
                "PKCS#11 token (hardware backing is provider-specific)",
            ),
            field("Module Path", uri.module_path.display().to_string()),
            field(
                "Token Label",
                uri.token_label
                    .as_deref()
                    .unwrap_or("First available token"),
            ),
            field(
                "Object Label",
                uri.object_label.as_deref().unwrap_or("Any object"),
            ),
            field(
                "PIN Source",
                uri.pin_source.as_deref().unwrap_or("Not configured"),
            ),
        ],
    }
}

/// The [RFC 7512](https://www.rfc-editor.org/rfc/rfc7512) URI naming the module, token and object.
#[derive(Debug, Default, Clone)]
struct Pkcs11Uri {
    module_path: PathBuf,
    token_label: Option<String>,
    object_label: Option<String>,
    pin_source: Option<String>,
}

impl Pkcs11Uri {
    fn parse(uri: &str) -> Result<Self> {
        let body = uri
            .strip_prefix("pkcs11:")
            .ok_or_else(|| anyhow!("PKCS#11 URI must begin with 'pkcs11:'"))?;
        let (path, query) = body
            .split_once('?')
            .map_or((body, None), |(path, query)| (path, Some(query)));
        let mut parsed = Self::default();

        for component in path.split(';').filter(|component| !component.is_empty()) {
            let (key, value) = component
                .split_once('=')
                .ok_or_else(|| anyhow!("Malformed PKCS#11 URI component '{component}'"))?;
            let value = percent_decode(value)?;
            match key {
                "module-path" => parsed.module_path = PathBuf::from(value),
                "token" => parsed.token_label = Some(value),
                "object" => parsed.object_label = Some(value),
                _ => {}
            }
        }

        for component in query
            .unwrap_or_default()
            .split('&')
            .filter(|component| !component.is_empty())
        {
            let (key, value) = component
                .split_once('=')
                .ok_or_else(|| anyhow!("Malformed PKCS#11 URI query '{component}'"))?;
            let value = percent_decode(value)?;
            match key {
                "module-path" => parsed.module_path = PathBuf::from(value),
                "pin-source" => parsed.pin_source = Some(value),
                "pin-value" => {
                    bail!("PKCS#11 pin-value is not supported; use pin-source=file:/path instead")
                }
                _ => {}
            }
        }

        if parsed.module_path.as_os_str().is_empty() {
            bail!("PKCS#11 URI is missing the required module-path attribute");
        }

        Ok(parsed)
    }

    /// Reads the token's PIN from the file the URI names.
    ///
    /// Inline `pin-value` credentials are rejected while parsing, so a PIN never travels in
    /// configuration that is logged or passed on a command line.
    fn read_pin(&self) -> Result<Option<String>> {
        let Some(source) = self.pin_source.as_deref() else {
            return Ok(None);
        };
        let Some(path) = source.strip_prefix("file:") else {
            bail!("Unsupported PKCS#11 pin-source scheme; only file: is supported");
        };

        let pin = std::fs::read_to_string(path)
            .with_context(|| format!("Failed to read the PKCS#11 PIN from {path}"))?;

        Ok(Some(pin.trim_end_matches(['\n', '\r']).to_owned()))
    }
}

fn percent_decode(input: &str) -> Result<String> {
    let input = input.as_bytes();
    let mut output = Vec::with_capacity(input.len());
    let mut index = 0;

    while index < input.len() {
        if input[index] != b'%' {
            output.push(input[index]);
            index += 1;
            continue;
        }

        let encoded = input
            .get(index + 1..index + 3)
            .context("Truncated percent escape in PKCS#11 URI")?;
        let encoded = std::str::from_utf8(encoded)?;
        output.push(u8::from_str_radix(encoded, 16).context("Invalid percent escape")?);
        index += 3;
    }

    let decoded = String::from_utf8(output).context("PKCS#11 URI component is not UTF-8")?;

    Ok(decoded)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_pkcs11_uri() {
        let uri = "pkcs11:token=Firezone;object=device%20identity?module-path=/usr/lib/libpkcs11.so&pin-source=file:/etc/firezone/pin";

        let parsed = Pkcs11Uri::parse(uri).expect("URI should be valid");

        assert_eq!(parsed.module_path, PathBuf::from("/usr/lib/libpkcs11.so"));
        assert_eq!(parsed.token_label.as_deref(), Some("Firezone"));
        assert_eq!(parsed.object_label.as_deref(), Some("device identity"));
        assert_eq!(parsed.pin_source.as_deref(), Some("file:/etc/firezone/pin"));
    }

    #[test]
    fn rejects_inline_pin_and_missing_module() {
        assert!(Pkcs11Uri::parse("pkcs11:token=Firezone?pin-value=1234").is_err());
        assert!(Pkcs11Uri::parse("pkcs11:token=Firezone").is_err());
    }

    #[test]
    fn names_the_cause_behind_a_token_failure() {
        assert!(matches!(
            classify_return_value(RvError::DeviceRemoved, String::new()),
            SigningError::KeyUnavailable(_)
        ));
        assert!(matches!(
            classify_return_value(RvError::PinLocked, String::new()),
            SigningError::AccessDenied(_)
        ));
        assert!(matches!(
            classify_return_value(RvError::DeviceError, String::new()),
            SigningError::Keystore(_)
        ));
    }

    #[test]
    fn ecdsa_signature_is_der_encoded() {
        let mut raw = vec![0; 64];
        raw[31] = 1;
        raw[63] = 2;

        assert_eq!(
            der_encode_ecdsa_signature(&raw).expect("signature should encode"),
            vec![0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02]
        );
    }
}

//! Linux X.509 identities backed by a PKCS#11 token.

use std::{path::PathBuf, sync::Arc, time::SystemTime};

use anyhow::{Context as _, Result, anyhow, bail};
use cryptoki::{
    context::{CInitializeArgs, Pkcs11},
    mechanism::{
        Mechanism, MechanismType,
        rsa::{PkcsMgfType, PkcsPssParams},
    },
    object::{Attribute, AttributeType, CertificateType, KeyType, ObjectClass, ObjectHandle},
    session::{Session, UserType},
    types::AuthPin,
};
use rustls::{
    SignatureAlgorithm, SignatureScheme,
    pki_types::CertificateDer,
    sign::{CertifiedKey, Signer, SigningKey},
};
use sha2::{Digest as _, Sha256, Sha384, Sha512};

use crate::{
    Config, DetailSection, PlatformIdentity, Status,
    policy::{CertificateMetadata, SigningAlgorithm, field, parse_certificate},
};

pub(crate) fn status(config: &Config, subject_cn: &str) -> Result<Status> {
    let Some(uri) = config.pkcs11_uri.as_deref() else {
        return Ok(Status {
            summary: "No X.509 device identity is configured.".to_owned(),
            sections: vec![DetailSection {
                title: "Linux PKCS#11 Configuration".to_owned(),
                fields: vec![field("PKCS#11 URI", "Not configured")],
            }],
        });
    };

    let parsed = Pkcs11Uri::parse(uri).context("Invalid Linux X.509 PKCS#11 configuration")?;
    with_session(&parsed, |session| {
        let identities = identities(session, &parsed, subject_cn)?;
        let usable = identities.iter().filter(|identity| identity.usable).count();
        let mut sections = vec![configuration_section(&parsed)];
        sections.extend(identities.iter().enumerate().map(|(index, identity)| {
            let mut fields = vec![
                field(
                    "Object Label",
                    identity.label.as_deref().unwrap_or("Unavailable"),
                ),
                field(
                    "Private Key Access",
                    if identity.key.is_some() {
                        "Available"
                    } else {
                        "Unavailable"
                    },
                ),
                field(
                    "Usable for Device Attestation",
                    if identity.usable { "Yes" } else { "No" },
                ),
            ];
            fields.extend(identity.metadata.detail_fields());
            DetailSection {
                title: format!("Matching Certificate {}", index + 1),
                fields,
            }
        }));

        let summary = match (usable, identities.len()) {
            (0, 0) => format!(
                "No X.509 certificate with subject CN '{subject_cn}' was found in the configured PKCS#11 token."
            ),
            (0, count) => format!(
                "Found {count} matching X.509 certificate(s), but none are usable for device attestation."
            ),
            (count, _) => format!(
                "{count} X.509 device identity certificate(s) are available for device attestation."
            ),
        };

        Ok(Status { summary, sections })
    })
}

pub(crate) fn identity(config: &Config, subject_cn: &str) -> Result<Option<PlatformIdentity>> {
    let Some(uri) = config.pkcs11_uri.as_deref() else {
        tracing::info!("No Linux PKCS#11 identity is configured for mutual TLS");
        return Ok(None);
    };

    let parsed = Pkcs11Uri::parse(uri).context("Invalid Linux X.509 PKCS#11 configuration")?;
    with_session(&parsed, |session| {
        let identities = identities(session, &parsed, subject_cn)?;
        // The URI's `object` attribute selects leaf identities. Intermediates often use
        // different labels, so enumerate every certificate when assembling each chain.
        let all_certificates = certificate_objects(session, &parsed, false)?;
        let Some(identity) = identities
            .into_iter()
            .filter(|identity| identity.usable)
            .max_by_key(|identity| identity.metadata.not_before_timestamp)
        else {
            return Ok(None);
        };
        let algorithm = identity
            .metadata
            .signing_algorithm
            .context("The selected PKCS#11 certificate uses an unsupported key algorithm")?;
        let signing_key = Arc::new(Pkcs11SigningKey {
            parsed: parsed.clone(),
            key_id: identity.id.clone(),
            key_label: identity.label.clone(),
            algorithm,
        });
        let chain = certificate_chain(&identity.der, &all_certificates)
            .into_iter()
            .map(CertificateDer::from)
            .collect();

        tracing::info!(
            fingerprint = %identity.metadata.fingerprint,
            mdm_device_id = identity.metadata.mdm_device_id.as_deref(),
            "Selected the newest Linux X.509 identity for mutual TLS"
        );

        Ok(Some(PlatformIdentity {
            certified_key: Arc::new(CertifiedKey::new(chain, signing_key)),
            mdm_device_id: identity.metadata.mdm_device_id,
        }))
    })
}

#[derive(Debug)]
struct Pkcs11SigningKey {
    parsed: Pkcs11Uri,
    key_id: Option<Vec<u8>>,
    key_label: Option<String>,
    algorithm: SigningAlgorithm,
}

impl SigningKey for Pkcs11SigningKey {
    fn choose_scheme(&self, offered: &[SignatureScheme]) -> Option<Box<dyn Signer>> {
        signature_schemes(self.algorithm)
            .iter()
            .copied()
            .find(|scheme| offered.contains(scheme))
            .map(|scheme| {
                Box::new(Pkcs11Signer {
                    parsed: self.parsed.clone(),
                    key_id: self.key_id.clone(),
                    key_label: self.key_label.clone(),
                    algorithm: self.algorithm,
                    scheme,
                }) as Box<dyn Signer>
            })
    }

    fn algorithm(&self) -> SignatureAlgorithm {
        match self.algorithm {
            SigningAlgorithm::RsaSha256 => SignatureAlgorithm::RSA,
            SigningAlgorithm::EcdsaSha256
            | SigningAlgorithm::EcdsaSha384
            | SigningAlgorithm::EcdsaSha512 => SignatureAlgorithm::ECDSA,
        }
    }
}

#[derive(Debug)]
struct Pkcs11Signer {
    parsed: Pkcs11Uri,
    key_id: Option<Vec<u8>>,
    key_label: Option<String>,
    algorithm: SigningAlgorithm,
    scheme: SignatureScheme,
}

impl Signer for Pkcs11Signer {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, rustls::Error> {
        with_session(&self.parsed, |session| {
            let key = find_private_key(
                session,
                self.key_id.as_deref(),
                self.key_label.as_deref(),
                Some(self.algorithm),
            )?
            .context("The selected PKCS#11 private key is no longer available")?;
            sign(session, key, self.scheme, message)
        })
        .map_err(|error| rustls::Error::General(format!("PKCS#11 TLS signing failed: {error:#}")))
    }

    fn scheme(&self) -> SignatureScheme {
        self.scheme
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

fn with_session<T>(parsed: &Pkcs11Uri, operation: impl FnOnce(&Session) -> Result<T>) -> Result<T> {
    let pkcs11 = Pkcs11::new(&parsed.module_path)
        .with_context(|| format!("Failed to load {}", parsed.module_path.display()))?;
    pkcs11
        .initialize(CInitializeArgs::OsThreads)
        .context("PKCS#11 initialization failed")?;
    let slot = find_slot(&pkcs11, parsed.token_label.as_deref())?;
    let session = pkcs11
        .open_ro_session(slot)
        .context("Failed to open the PKCS#11 token")?;

    if let Some(pin) = parsed.read_pin()? {
        session
            .login(UserType::User, Some(&AuthPin::new(pin)))
            .context("Failed to unlock the PKCS#11 token")?;
    }

    operation(&session)
}

struct CertificateIdentity {
    der: Vec<u8>,
    id: Option<Vec<u8>>,
    label: Option<String>,
    metadata: CertificateMetadata,
    key: Option<ObjectHandle>,
    usable: bool,
}

fn identities(
    session: &Session,
    parsed: &Pkcs11Uri,
    subject_cn: &str,
) -> Result<Vec<CertificateIdentity>> {
    let now = SystemTime::now();
    let mut identities = Vec::new();

    for certificate in certificate_objects(session, parsed, true)? {
        let Some(metadata) = parse_certificate(&certificate.der, now) else {
            tracing::warn!(
                object_label = ?certificate.label,
                "Ignoring an invalid PKCS#11 X.509 certificate"
            );
            continue;
        };
        if !metadata.matches_subject(subject_cn) {
            continue;
        }

        let key = find_private_key(
            session,
            certificate.id.as_deref(),
            certificate.label.as_deref(),
            metadata.signing_algorithm,
        )?;
        let usable = metadata.is_usable(subject_cn) && key.is_some();
        identities.push(CertificateIdentity {
            der: certificate.der,
            id: certificate.id,
            label: certificate.label,
            metadata,
            key,
            usable,
        });
    }

    Ok(identities)
}

struct CertificateObject {
    der: Vec<u8>,
    id: Option<Vec<u8>>,
    label: Option<String>,
}

fn certificate_objects(
    session: &Session,
    parsed: &Pkcs11Uri,
    filter_object_label: bool,
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
            #[allow(clippy::wildcard_enum_match_arm)]
            match attribute {
                Attribute::Value(value) => der = Some(value),
                Attribute::Id(value) => id = Some(value),
                Attribute::Label(value) => label = String::from_utf8(value).ok(),
                _ => {}
            }
        }
        if filter_object_label
            && parsed.object_label.as_deref().is_some()
            && label.as_deref() != parsed.object_label.as_deref()
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
    let mut template = vec![Attribute::Class(ObjectClass::PRIVATE_KEY)];
    match algorithm {
        Some(SigningAlgorithm::RsaSha256) => template.push(Attribute::KeyType(KeyType::RSA)),
        Some(
            SigningAlgorithm::EcdsaSha256
            | SigningAlgorithm::EcdsaSha384
            | SigningAlgorithm::EcdsaSha512,
        ) => {
            template.push(Attribute::KeyType(KeyType::EC));
        }
        None => return Ok(None),
    }
    if let Some(id) = id {
        template.push(Attribute::Id(id.to_vec()));
    } else if let Some(label) = label {
        template.push(Attribute::Label(label.as_bytes().to_vec()));
    } else {
        return Ok(None);
    }

    Ok(session
        .find_objects(&template)
        .context("Failed to locate the PKCS#11 private key")?
        .into_iter()
        .next())
}

fn sign(
    session: &Session,
    key: ObjectHandle,
    scheme: SignatureScheme,
    message: &[u8],
) -> Result<Vec<u8>> {
    match scheme {
        SignatureScheme::RSA_PSS_SHA256 => session
            .sign(
                &Mechanism::Sha256RsaPkcsPss(PkcsPssParams {
                    hash_alg: MechanismType::SHA256,
                    mgf: PkcsMgfType::MGF1_SHA256,
                    s_len: 32,
                }),
                key,
                message,
            )
            .context("PKCS#11 RSA-PSS SHA-256 signing failed"),
        SignatureScheme::RSA_PSS_SHA384 => session
            .sign(
                &Mechanism::Sha384RsaPkcsPss(PkcsPssParams {
                    hash_alg: MechanismType::SHA384,
                    mgf: PkcsMgfType::MGF1_SHA384,
                    s_len: 48,
                }),
                key,
                message,
            )
            .context("PKCS#11 RSA-PSS SHA-384 signing failed"),
        SignatureScheme::RSA_PSS_SHA512 => session
            .sign(
                &Mechanism::Sha512RsaPkcsPss(PkcsPssParams {
                    hash_alg: MechanismType::SHA512,
                    mgf: PkcsMgfType::MGF1_SHA512,
                    s_len: 64,
                }),
                key,
                message,
            )
            .context("PKCS#11 RSA-PSS SHA-512 signing failed"),
        SignatureScheme::RSA_PKCS1_SHA256 => session
            .sign(&Mechanism::Sha256RsaPkcs, key, message)
            .context("PKCS#11 RSA signing failed"),
        SignatureScheme::RSA_PKCS1_SHA384 => session
            .sign(&Mechanism::Sha384RsaPkcs, key, message)
            .context("PKCS#11 RSA signing failed"),
        SignatureScheme::RSA_PKCS1_SHA512 => session
            .sign(&Mechanism::Sha512RsaPkcs, key, message)
            .context("PKCS#11 RSA signing failed"),
        SignatureScheme::ECDSA_NISTP256_SHA256 => {
            let raw = session
                .sign(&Mechanism::Ecdsa, key, &Sha256::digest(message))
                .context("PKCS#11 P-256 signing failed")?;
            der_encode_ecdsa_signature(&raw)
        }
        SignatureScheme::ECDSA_NISTP384_SHA384 => {
            let raw = session
                .sign(&Mechanism::Ecdsa, key, &Sha384::digest(message))
                .context("PKCS#11 P-384 signing failed")?;
            der_encode_ecdsa_signature(&raw)
        }
        SignatureScheme::ECDSA_NISTP521_SHA512 => {
            let raw = session
                .sign(&Mechanism::Ecdsa, key, &Sha512::digest(message))
                .context("PKCS#11 P-521 signing failed")?;
            der_encode_ecdsa_signature(&raw)
        }
        _ => bail!("Unsupported TLS signature scheme {scheme:?}"),
    }
}

fn certificate_chain(leaf: &[u8], certificates: &[CertificateObject]) -> Vec<Vec<u8>> {
    let now = SystemTime::now();
    let mut chain = vec![leaf.to_vec()];
    let Some(mut current) = parse_certificate(leaf, now) else {
        return chain;
    };

    while current.subject != current.issuer {
        let Some(issuer) = certificates.iter().find(|candidate| {
            !chain.contains(&candidate.der)
                && parse_certificate(&candidate.der, now)
                    .is_some_and(|metadata| metadata.subject == current.issuer)
        }) else {
            break;
        };
        chain.push(issuer.der.clone());
        let Some(metadata) = parse_certificate(&issuer.der, now) else {
            break;
        };
        current = metadata;
    }

    chain
}

fn find_slot(pkcs11: &Pkcs11, token_label: Option<&str>) -> Result<cryptoki::slot::Slot> {
    let slots = pkcs11
        .get_slots_with_token()
        .context("Failed to enumerate PKCS#11 tokens")?;
    if let Some(label) = token_label {
        for slot in slots {
            if pkcs11.get_token_info(slot)?.label().trim() == label {
                return Ok(slot);
            }
        }
        bail!("No PKCS#11 token with label '{label}' was found");
    }
    slots
        .into_iter()
        .next()
        .ok_or_else(|| anyhow!("No PKCS#11 tokens are available"))
}

fn configuration_section(parsed: &Pkcs11Uri) -> DetailSection {
    DetailSection {
        title: "Linux PKCS#11 Configuration".to_owned(),
        fields: vec![
            field("Certificate Storage", "PKCS#11 token"),
            field(
                "Private Key Storage",
                "PKCS#11 token (hardware backing is provider-specific)",
            ),
            field("Module Path", parsed.module_path.display().to_string()),
            field(
                "Token Label",
                parsed
                    .token_label
                    .as_deref()
                    .unwrap_or("First available token"),
            ),
            field(
                "Object Label",
                parsed.object_label.as_deref().unwrap_or("Any object"),
            ),
            field(
                "PIN Source",
                parsed.pin_source.as_deref().unwrap_or("Not configured"),
            ),
        ],
    }
}

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
        if let Some(query) = query {
            for component in query.split('&').filter(|component| !component.is_empty()) {
                let (key, value) = component
                    .split_once('=')
                    .ok_or_else(|| anyhow!("Malformed PKCS#11 URI query '{component}'"))?;
                let value = percent_decode(value)?;
                match key {
                    "module-path" => parsed.module_path = PathBuf::from(value),
                    "pin-source" => parsed.pin_source = Some(value),
                    "pin-value" => bail!(
                        "PKCS#11 pin-value is not supported; use pin-source=file:/path instead"
                    ),
                    _ => {}
                }
            }
        }
        if parsed.module_path.as_os_str().is_empty() {
            bail!("PKCS#11 URI is missing the required module-path attribute");
        }

        Ok(parsed)
    }

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
        if input[index] == b'%' {
            let encoded = input
                .get(index + 1..index + 3)
                .context("Truncated percent escape in PKCS#11 URI")?;
            let encoded = std::str::from_utf8(encoded)?;
            output.push(u8::from_str_radix(encoded, 16).context("Invalid percent escape")?);
            index += 3;
        } else {
            output.push(input[index]);
            index += 1;
        }
    }
    String::from_utf8(output).context("PKCS#11 URI component is not UTF-8")
}

fn der_encode_ecdsa_signature(raw: &[u8]) -> Result<Vec<u8>> {
    if raw.is_empty() || !raw.len().is_multiple_of(2) {
        bail!("Invalid raw ECDSA signature length: {}", raw.len());
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

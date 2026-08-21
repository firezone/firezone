//! X.509 client identities held by a PKCS#11 token.

#[cfg(test)]
mod tests;

use std::{
    collections::BTreeMap,
    fs::File,
    io::Read as _,
    os::unix::fs::MetadataExt as _,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, PoisonError},
    time::SystemTime,
};

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
    slot::{Slot, TokenInfo},
    types::AuthPin,
};
use rustls::{SignatureAlgorithm, SignatureScheme, pki_types::CertificateDer};
use sha2::{Digest as _, Sha256, Sha384, Sha512};
use x509_claims::{ParsedCertificate, SigningAlgorithm, parse_certificate};
use x509_credential::{PrivateKey, SigningError};

use crate::{DetailField, DetailSection, Identity, Status, field};

/// The only PKCS#11 module Firezone loads.
///
/// p11-kit's proxy federates every module registered on the system, so whichever driver an
/// administrator installed for their token is reachable without Firezone being told about it.
const PROXY_MODULE: &str = "p11-kit-proxy.so";

/// The file a token's PIN is read from.
const PIN_FILE: &str = "/etc/firezone/pkcs11-pin";

pub(crate) fn status(subject_cn: &str) -> Result<Status> {
    let status = status_on(&proxy_module()?, Path::new(PIN_FILE), subject_cn)?;

    Ok(status)
}

pub(crate) fn identity(subject_cn: &str) -> Result<Option<Identity>> {
    let identity = identity_on(&proxy_module()?, Path::new(PIN_FILE), subject_cn)?;

    Ok(identity)
}

fn status_on(module: &Path, pin_file: &Path, subject_cn: &str) -> Result<Status> {
    let Some(token) = find_token(module, pin_file, subject_cn)? else {
        return Ok(Status {
            summary: format!(
                "No PKCS#11 token holds an X.509 certificate with subject CN '{subject_cn}'."
            ),
            sections: vec![DetailSection {
                title: "PKCS#11 Token".to_owned(),
                fields: vec![field("Module Path", module.display().to_string())],
            }],
        });
    };

    let usable = token
        .certificates
        .iter()
        .filter(|certificate| certificate.usable)
        .count();

    let mut sections = vec![token_section(module, &token.info)];
    sections.extend(
        token
            .certificates
            .iter()
            .enumerate()
            .map(|(index, certificate)| DetailSection {
                title: format!("Matching Certificate {}", index + 1),
                fields: certificate.detail_fields(),
            }),
    );

    let summary = match usable {
        0 => format!(
            "Found {} matching X.509 certificate(s), but none of them are usable as a client identity.",
            token.certificates.len()
        ),
        count => {
            format!("{count} X.509 client identity certificate(s) are available for mutual TLS.")
        }
    };

    Ok(Status { summary, sections })
}

fn identity_on(module: &Path, pin_file: &Path, subject_cn: &str) -> Result<Option<Identity>> {
    let Some(token) = find_token(module, pin_file, subject_cn)? else {
        tracing::debug!("No PKCS#11 token holds a Firezone client identity");

        return Ok(None);
    };
    let unusable = token
        .certificates
        .iter()
        .filter(|certificate| !certificate.usable)
        .map(unusable_reason)
        .collect::<Vec<_>>();

    let Some(certificate) = token
        .certificates
        .into_iter()
        .filter(|certificate| certificate.usable)
        .max_by_key(|certificate| certificate.metadata.not_before_timestamp)
    else {
        // Skipping a certificate that was provisioned for Firezone reads to an administrator as if
        // none had been, so say which rule it failed instead of connecting without it.
        bail!(
            "The PKCS#11 token holds no usable Firezone client identity: {}",
            unusable.join("; ")
        );
    };

    let algorithm = certificate
        .metadata
        .signing_algorithm
        .context("The selected PKCS#11 certificate uses an unsupported key algorithm")?;
    let chain = certificate_chain(&certificate.der, &token.objects)
        .into_iter()
        .map(CertificateDer::from)
        .collect();
    let key = Arc::new(Pkcs11Key {
        module: module.to_owned(),
        pin_file: pin_file.to_owned(),
        slot: token.slot,
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
    module: PathBuf,
    pin_file: PathBuf,
    slot: Slot,
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
        let session = open_session(&self.module, self.slot, &self.pin_file)
            .map_err(classify_signing_error)?;
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

/// Returns the path of the p11-kit proxy module.
///
/// # Errors
///
/// Returns an error if p11-kit is not installed, because it is how Firezone reaches every token.
fn proxy_module() -> Result<PathBuf> {
    let module = module_directories()
        .map(|directory| directory.join(PROXY_MODULE))
        .find(|candidate| candidate.is_file())
        .ok_or_else(|| {
            anyhow!(
                "Failed to find {PROXY_MODULE}: Firezone reads PKCS#11 tokens through p11-kit, which has to be installed (the `p11-kit-modules` package on Debian)"
            )
        })?;

    Ok(module)
}

/// The directories a distribution may have installed PKCS#11 modules into.
fn module_directories() -> impl Iterator<Item = PathBuf> {
    // Debian keeps modules below a directory named after the architecture triplet, e.g.
    // `/usr/lib/x86_64-linux-gnu/pkcs11`.
    let multiarch = std::fs::read_dir("/usr/lib")
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path().join("pkcs11"));

    multiarch.chain(["/usr/lib/pkcs11", "/usr/lib64/pkcs11"].map(PathBuf::from))
}

/// The PKCS#11 context each module is used through, kept for the life of the process.
///
/// A module may only be initialized once: a second `C_Initialize` answers that it already is, so
/// two contexts for one module would cut each other off whenever they overlap, as a diagnostics
/// read and a handshake signature do. Holding on to the context is also what keeps the module
/// loaded for the sessions still using it.
static CONTEXTS: Mutex<BTreeMap<PathBuf, Pkcs11>> = Mutex::new(BTreeMap::new());

/// Returns the context for `module_path`, loading and initializing the module on first use.
fn context(module_path: &Path) -> Result<Pkcs11> {
    let mut contexts = CONTEXTS.lock().unwrap_or_else(PoisonError::into_inner);

    if let Some(context) = contexts.get(module_path) {
        return Ok(context.clone());
    }

    let context = Pkcs11::new(module_path)
        .with_context(|| format!("Failed to load {}", module_path.display()))?;
    context
        .initialize(CInitializeArgs::new(CInitializeFlags::OS_LOCKING_OK))
        .context("PKCS#11 initialization failed")?;
    // Only a context that initialized is remembered, so a module that failed to load can be
    // retried once whatever kept it from loading is fixed.
    contexts.insert(module_path.to_owned(), context.clone());

    Ok(context)
}

/// The token Firezone authenticates with, and everything it holds that bears on that.
struct Token {
    slot: Slot,
    info: TokenInfo,
    /// Every X.509 object on the token, which is what the chain of a certificate is built from.
    objects: Vec<CertificateObject>,
    /// The objects whose subject common name is the one Firezone looks for.
    certificates: Vec<Certificate>,
}

/// Returns the first token holding a certificate for `subject_cn`, unlocked and ready to sign.
///
/// Certificates are public objects, so every token can be searched without logging in, and only
/// the one that turns out to hold ours is unlocked. Logging into each token in turn would instead
/// spend the PIN attempts of tokens that have nothing to do with Firezone.
fn find_token(module: &Path, pin_file: &Path, subject_cn: &str) -> Result<Option<Token>> {
    let pkcs11 = context(module)?;
    let slots = pkcs11
        .get_slots_with_token()
        .context("Failed to enumerate PKCS#11 tokens")?;

    for slot in slots {
        let Some(candidate) = search_slot(&pkcs11, slot, subject_cn)
            .inspect_err(|error| tracing::debug!(?slot, "Skipping a PKCS#11 token: {error:#}"))
            .ok()
            .flatten()
        else {
            continue;
        };

        let Candidate {
            info,
            session,
            objects,
            matches,
        } = candidate;

        unlock(&session, pin_file)?;

        let certificates = matches
            .into_iter()
            .map(|(object, metadata)| {
                describe_certificate(&session, &objects[object], metadata, subject_cn)
            })
            .collect::<Result<Vec<_>>>()?;

        return Ok(Some(Token {
            slot,
            info,
            objects,
            certificates,
        }));
    }

    Ok(None)
}

/// A token that holds at least one certificate for the subject common name we look for.
struct Candidate {
    info: TokenInfo,
    session: Session,
    objects: Vec<CertificateObject>,
    /// The index of each matching object in `objects`, alongside what its certificate says.
    matches: Vec<(usize, ParsedCertificate)>,
}

/// Reads the certificates on `slot`, before any login, to see whether the token is one of ours.
fn search_slot(pkcs11: &Pkcs11, slot: Slot, subject_cn: &str) -> Result<Option<Candidate>> {
    let info = pkcs11
        .get_token_info(slot)
        .context("Failed to read the token information")?;
    let session = pkcs11
        .open_ro_session(slot)
        .context("Failed to open the token")?;
    let objects = certificate_objects(&session)?;
    let now = SystemTime::now();
    let matches = objects
        .iter()
        .enumerate()
        .filter_map(|(index, object)| {
            let Some(metadata) = parse_certificate(&object.der, now) else {
                tracing::debug!(
                    object_label = ?object.label,
                    "Ignoring an invalid PKCS#11 X.509 certificate"
                );

                return None;
            };

            (metadata.subject_cn.as_deref() == Some(subject_cn)).then_some((index, metadata))
        })
        .collect::<Vec<_>>();

    if matches.is_empty() {
        return Ok(None);
    }

    Ok(Some(Candidate {
        info,
        session,
        objects,
        matches,
    }))
}

/// Unlocks the token with the PIN Firezone keeps on disk, when there is one.
fn unlock(session: &Session, pin_file: &Path) -> Result<()> {
    if !pin_file.exists() {
        return Ok(());
    }

    let pin = read_pin(pin_file)?;

    log_in(session, &pin).context("Failed to unlock the PKCS#11 token")?;

    Ok(())
}

/// Logs into the token, treating a login an overlapping session already did as success.
///
/// PKCS#11 tracks the login per token rather than per session, so a token that another session of
/// this process unlocked is unlocked for this one too, and logging in again is refused.
fn log_in(session: &Session, pin: &AuthPin) -> Result<()> {
    let Err(error) = session.login(UserType::User, Some(pin)) else {
        return Ok(());
    };

    if matches!(
        error,
        cryptoki::error::Error::Pkcs11(RvError::UserAlreadyLoggedIn, _)
    ) {
        return Ok(());
    }

    Err(error.into())
}

/// Reads the token's PIN from `path`.
///
/// Ownership and permissions are checked on the open file rather than on its path, so that a file
/// swapped in between the check and the read cannot get its contents used.
///
/// # Errors
///
/// Returns an error if the file is missing or unreadable, or if it is not root's alone.
fn read_pin(path: &Path) -> Result<AuthPin> {
    let mut file = File::open(path)
        .with_context(|| format!("Failed to open the PKCS#11 PIN file '{}'", path.display()))?;
    let metadata = file
        .metadata()
        .with_context(|| format!("Failed to read the metadata of '{}'", path.display()))?;

    ensure_root_only(metadata.mode(), metadata.uid(), path)?;

    let mut contents = String::new();
    file.read_to_string(&mut contents)
        .with_context(|| format!("Failed to read '{}'", path.display()))?;

    // A PIN may deliberately begin or end with a space, so only the line ending is stripped.
    Ok(AuthPin::from(contents.trim_end_matches(['\n', '\r'])))
}

/// Refuses a PIN file that any account other than root can get at.
///
/// The Tunnel service runs as root, so a PIN file another account owns or can read is one a
/// compromised account could use to authenticate the device.
fn ensure_root_only(mode: u32, uid: u32, path: &Path) -> Result<()> {
    if mode & 0o077 != 0 {
        bail!(
            "Permissions 0{:o} for '{}' are too open; the PKCS#11 PIN file must not be accessible by group or others",
            mode & 0o777,
            path.display()
        );
    }

    if uid != 0 {
        bail!(
            "'{}' is owned by uid {uid} rather than by root; only root may hold the PKCS#11 PIN",
            path.display()
        );
    }

    Ok(())
}

/// Opens a read-only session on `slot`, unlocking its token.
fn open_session(module: &Path, slot: Slot, pin_file: &Path) -> Result<Session> {
    let pkcs11 = context(module)?;
    let session = pkcs11
        .open_ro_session(slot)
        .context("Failed to open the PKCS#11 token")?;

    unlock(&session, pin_file)?;

    Ok(session)
}

/// A certificate on the token whose subject CN is the one we look for.
struct Certificate {
    der: Vec<u8>,
    id: Option<Vec<u8>>,
    label: Option<String>,
    metadata: ParsedCertificate,
    key: Option<ObjectHandle>,
    usable: bool,
}

/// Says whether the token can sign with a certificate it holds, and how it describes it.
fn describe_certificate(
    session: &Session,
    object: &CertificateObject,
    metadata: ParsedCertificate,
    subject_cn: &str,
) -> Result<Certificate> {
    let key = find_private_key(
        session,
        object.id.as_deref(),
        object.label.as_deref(),
        metadata.signing_algorithm,
    )?;

    Ok(Certificate {
        der: object.der.clone(),
        id: object.id.clone(),
        label: object.label.clone(),
        usable: metadata.is_usable(subject_cn) && key.is_some(),
        metadata,
        key,
    })
}

/// Says why a certificate that matched the subject common name cannot be used.
fn unusable_reason(certificate: &Certificate) -> String {
    let metadata = &certificate.metadata;

    let reason = if !metadata.has_client_auth_eku {
        "it has no TLS client authentication extended key usage"
    } else if !metadata.digital_signature_allowed {
        "its key usage does not allow digital signatures"
    } else if !metadata.is_currently_valid {
        "it is expired or not yet valid"
    } else if metadata.signing_algorithm.is_none() {
        "it holds a key algorithm we cannot sign with"
    } else if certificate.key.is_none() {
        "the token holds no private key for it"
    } else {
        "it does not match the requested common name"
    };

    format!("{} is unusable because {reason}", metadata.fingerprint)
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
                if self.key.is_some() {
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

struct CertificateObject {
    der: Vec<u8>,
    id: Option<Vec<u8>>,
    label: Option<String>,
}

fn certificate_objects(session: &Session) -> Result<Vec<CertificateObject>> {
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

fn token_section(module: &Path, info: &TokenInfo) -> DetailSection {
    DetailSection {
        title: "PKCS#11 Token".to_owned(),
        fields: vec![
            field("Certificate Storage", "PKCS#11 token"),
            field(
                "Private Key Storage",
                "PKCS#11 token (hardware backing is provider-specific)",
            ),
            field("Module Path", module.display().to_string()),
            field("Token Label", info.label().trim()),
            field("Token Model", info.model().trim()),
            field(
                "Login Required",
                if info.login_required() { "Yes" } else { "No" },
            ),
        ],
    }
}

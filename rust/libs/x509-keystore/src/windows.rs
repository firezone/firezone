//! X.509 client identities from the Windows certificate stores, signed through CNG.

#[cfg(test)]
mod tests;

use std::{ffi::c_void, fmt, ptr, slice, sync::Arc, time::SystemTime};

use anyhow::{Context as _, Result, bail};
use rustls::{SignatureAlgorithm, SignatureScheme, pki_types::CertificateDer};
use sha2::{Digest as _, Sha256, Sha384, Sha512};
use windows::{
    Win32::{
        Foundation::{
            E_ACCESSDENIED, NTE_BAD_KEYSET, NTE_NO_KEY, NTE_NOT_FOUND, NTE_PERM,
            NTE_SILENT_CONTEXT, NTE_USER_CANCELLED, SCARD_W_CANCELLED_BY_USER,
        },
        Security::Cryptography::{
            BCRYPT_PKCS1_PADDING_INFO, BCRYPT_PSS_PADDING_INFO, BCRYPT_SHA256_ALGORITHM,
            BCRYPT_SHA384_ALGORITHM, BCRYPT_SHA512_ALGORITHM, CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL,
            CERT_CHAIN_DISABLE_AIA, CERT_CHAIN_PARA, CERT_CONTEXT, CERT_KEY_PROV_INFO_PROP_ID,
            CERT_KEY_SPEC, CERT_OPEN_STORE_FLAGS, CERT_QUERY_ENCODING_TYPE,
            CERT_STORE_OPEN_EXISTING_FLAG, CERT_STORE_PROV_SYSTEM_W, CERT_STORE_READONLY_FLAG,
            CERT_SYSTEM_STORE_LOCAL_MACHINE, CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG,
            CRYPT_ACQUIRE_SILENT_FLAG, CRYPT_KEY_PROV_INFO, CertCloseStore,
            CertDuplicateCertificateContext, CertEnumCertificatesInStore, CertFreeCertificateChain,
            CertFreeCertificateContext, CertGetCertificateChain, CertGetCertificateContextProperty,
            CertOpenStore, CryptAcquireCertificatePrivateKey, HCERTSTORE,
            HCRYPTPROV_OR_NCRYPT_KEY_HANDLE, NCRYPT_FLAGS, NCRYPT_HANDLE,
            NCRYPT_IMPL_HARDWARE_FLAG, NCRYPT_IMPL_SOFTWARE_FLAG, NCRYPT_IMPL_TYPE_PROPERTY,
            NCRYPT_KEY_HANDLE, NCRYPT_PAD_PKCS1_FLAG, NCRYPT_PAD_PSS_FLAG, NCRYPT_PROV_HANDLE,
            NCRYPT_PROVIDER_HANDLE_PROPERTY, NCryptFreeObject, NCryptGetProperty, NCryptSignHash,
        },
    },
    core::w,
};
use x509_claims::{ParsedCertificate, SigningAlgorithm, parse_certificate};
use x509_credential::{PrivateKey, SigningError};

use crate::{DetailField, DetailSection, Identity, Status, field};

/// The store MDM-provisioned identities land in.
///
/// The Tunnel service runs as LocalSystem, so `CERT_SYSTEM_STORE_CURRENT_USER` would resolve to
/// the SYSTEM profile rather than to the signed-in user, and reading it would only ever find
/// certificates nobody provisioned there. Device-scope profiles write here.
const STORE: (u32, &str) = (CERT_SYSTEM_STORE_LOCAL_MACHINE, "LocalMachine\\My");

pub(crate) fn status(subject_cn: &str) -> Result<Status> {
    let (certificates, store_errors) = enumerate_matching(subject_cn);
    if certificates.is_empty() && !store_errors.is_empty() {
        bail!(
            "The Windows certificate store could not be read: {}",
            store_errors.join("; ")
        );
    }

    let usable = certificates
        .iter()
        .filter(|certificate| certificate.usable)
        .count();
    let mut sections = vec![DetailSection {
        title: "Windows Certificate Store".to_owned(),
        fields: vec![
            field("Searched Store", STORE.1),
            field("Requested Common Name", subject_cn),
            field(
                "Store Read Errors",
                if store_errors.is_empty() {
                    "None".to_owned()
                } else {
                    store_errors.join("\n")
                },
            ),
        ],
    }];
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
            "No X.509 certificate with subject CN '{subject_cn}' is in the Windows certificate stores."
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

pub(crate) fn identity(subject_cn: &str) -> Result<Option<Identity>> {
    let (certificates, store_errors) = enumerate_matching(subject_cn);
    if certificates.is_empty() && !store_errors.is_empty() {
        bail!(
            "The Windows certificate store could not be read: {}",
            store_errors.join("; ")
        );
    }

    let unusable = certificates
        .iter()
        .filter(|certificate| !certificate.usable)
        .map(unusable_reason)
        .collect::<Vec<_>>();

    let Some(certificate) = certificates
        .into_iter()
        .filter(|certificate| certificate.usable)
        .max_by_key(|certificate| certificate.metadata.not_before_timestamp)
    else {
        // Only a store that holds nothing for us is the ordinary no-certificate case. Skipping a
        // certificate that was provisioned for Firezone reads to an administrator as if none had
        // been, so say which rule it failed instead of connecting without it.
        if !unusable.is_empty() {
            bail!(
                "The Windows certificate store holds no usable Firezone client identity: {}",
                unusable.join("; ")
            );
        }

        return Ok(None);
    };

    let algorithm = certificate
        .metadata
        .signing_algorithm
        .context("The selected Windows certificate uses an unsupported key algorithm")?;
    let signing_context = unsafe { CertDuplicateCertificateContext(Some(certificate.context)) };
    if signing_context.is_null() {
        bail!("Failed to retain the selected Windows certificate context");
    }

    let chain = certificate
        .chain
        .iter()
        .cloned()
        .map(CertificateDer::from)
        .collect();
    let key = Arc::new(CngKey {
        context: Arc::new(CertificateContext(signing_context)),
        algorithm,
    });

    tracing::debug!(
        store = certificate.store,
        fingerprint = %certificate.metadata.fingerprint,
        "Selected a Windows X.509 identity for mutual TLS"
    );

    Ok(Some(Identity { chain, key }))
}

/// A certificate context whose CNG private key signs the TLS handshake.
///
/// The key is only ever referenced by handle, so its material stays inside the CNG provider.
#[derive(Debug)]
struct CngKey {
    context: Arc<CertificateContext>,
    algorithm: SigningAlgorithm,
}

impl PrivateKey for CngKey {
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
        let signature = unsafe { sign_with_certificate(self.context.0, scheme, message) }?;

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
unsafe fn sign_with_certificate(
    context: *mut CERT_CONTEXT,
    scheme: SignatureScheme,
    message: &[u8],
) -> Result<Vec<u8>, SigningError> {
    let key = unsafe { acquire_key(context) }.map_err(classify_signing_error)?;

    match scheme {
        SignatureScheme::RSA_PSS_SHA256 => unsafe {
            sign_rsa_pss(
                key.handle,
                BCRYPT_SHA256_ALGORITHM,
                &Sha256::digest(message),
            )
        },
        SignatureScheme::RSA_PSS_SHA384 => unsafe {
            sign_rsa_pss(
                key.handle,
                BCRYPT_SHA384_ALGORITHM,
                &Sha384::digest(message),
            )
        },
        SignatureScheme::RSA_PSS_SHA512 => unsafe {
            sign_rsa_pss(
                key.handle,
                BCRYPT_SHA512_ALGORITHM,
                &Sha512::digest(message),
            )
        },
        SignatureScheme::RSA_PKCS1_SHA256 => unsafe {
            sign_rsa_pkcs1(
                key.handle,
                BCRYPT_SHA256_ALGORITHM,
                &Sha256::digest(message),
            )
        },
        SignatureScheme::RSA_PKCS1_SHA384 => unsafe {
            sign_rsa_pkcs1(
                key.handle,
                BCRYPT_SHA384_ALGORITHM,
                &Sha384::digest(message),
            )
        },
        SignatureScheme::RSA_PKCS1_SHA512 => unsafe {
            sign_rsa_pkcs1(
                key.handle,
                BCRYPT_SHA512_ALGORITHM,
                &Sha512::digest(message),
            )
        },
        SignatureScheme::ECDSA_NISTP256_SHA256 => {
            let raw = unsafe {
                sign_hash(
                    key.handle,
                    None,
                    &Sha256::digest(message),
                    NCRYPT_FLAGS::default(),
                )
            }?;

            der_encode_ecdsa_signature(&raw)
        }
        SignatureScheme::ECDSA_NISTP384_SHA384 => {
            let raw = unsafe {
                sign_hash(
                    key.handle,
                    None,
                    &Sha384::digest(message),
                    NCRYPT_FLAGS::default(),
                )
            }?;

            der_encode_ecdsa_signature(&raw)
        }
        SignatureScheme::ECDSA_NISTP521_SHA512 => {
            let raw = unsafe {
                sign_hash(
                    key.handle,
                    None,
                    &Sha512::digest(message),
                    NCRYPT_FLAGS::default(),
                )
            }?;

            der_encode_ecdsa_signature(&raw)
        }
        _ => Err(SigningError::UnsupportedScheme(scheme)),
    }
}

/// Names the cause behind a failed CNG key operation.
///
/// Windows reports a declined confirmation prompt and a missing key-usage permission as different
/// codes, but both mean the same to us: the keystore is there and refuses to use the key.
fn classify_signing_error(error: windows_core::Error) -> SigningError {
    let reason = error.to_string();

    match error.code() {
        NTE_NO_KEY => SigningError::KeyUnavailable(reason),
        NTE_BAD_KEYSET => SigningError::KeyUnavailable(reason),
        NTE_NOT_FOUND => SigningError::KeyUnavailable(reason),
        NTE_PERM => SigningError::AccessDenied(reason),
        NTE_SILENT_CONTEXT => SigningError::AccessDenied(reason),
        NTE_USER_CANCELLED => SigningError::AccessDenied(reason),
        SCARD_W_CANCELLED_BY_USER => SigningError::AccessDenied(reason),
        E_ACCESSDENIED => SigningError::AccessDenied(reason),
        _ => SigningError::Keystore(reason),
    }
}

unsafe fn sign_rsa_pss(
    key: NCRYPT_KEY_HANDLE,
    hash_algorithm: windows_core::PCWSTR,
    hash: &[u8],
) -> Result<Vec<u8>, SigningError> {
    let padding = BCRYPT_PSS_PADDING_INFO {
        pszAlgId: hash_algorithm,
        cbSalt: hash.len() as u32,
    };
    let signature = unsafe {
        sign_hash(
            key,
            Some((&raw const padding).cast()),
            hash,
            NCRYPT_PAD_PSS_FLAG,
        )
    }?;

    Ok(signature)
}

unsafe fn sign_rsa_pkcs1(
    key: NCRYPT_KEY_HANDLE,
    hash_algorithm: windows_core::PCWSTR,
    hash: &[u8],
) -> Result<Vec<u8>, SigningError> {
    let padding = BCRYPT_PKCS1_PADDING_INFO {
        pszAlgId: hash_algorithm,
    };
    let signature = unsafe {
        sign_hash(
            key,
            Some((&raw const padding).cast()),
            hash,
            NCRYPT_PAD_PKCS1_FLAG,
        )
    }?;

    Ok(signature)
}

unsafe fn sign_hash(
    key: NCRYPT_KEY_HANDLE,
    padding: Option<*const c_void>,
    hash: &[u8],
    flags: NCRYPT_FLAGS,
) -> Result<Vec<u8>, SigningError> {
    let mut needed = 0;
    unsafe { NCryptSignHash(key, padding, hash, None, &mut needed, flags) }
        .map_err(classify_signing_error)?;

    let mut signature = vec![0; needed as usize];
    let mut written = 0;
    unsafe {
        NCryptSignHash(
            key,
            padding,
            hash,
            Some(&mut signature),
            &mut written,
            flags,
        )
    }
    .map_err(classify_signing_error)?;
    signature.truncate(written as usize);

    Ok(signature)
}

/// Wraps the fixed-width `r` and `s` values CNG returns into the DER sequence TLS expects.
fn der_encode_ecdsa_signature(raw: &[u8]) -> Result<Vec<u8>, SigningError> {
    if raw.is_empty() || !raw.len().is_multiple_of(2) {
        return Err(SigningError::Keystore(format!(
            "CNG returned a {}-byte ECDSA signature",
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

/// A certificate in one of the searched stores whose subject CN is the one we look for.
struct Certificate {
    store: &'static str,
    context: *mut CERT_CONTEXT,
    chain: Vec<Vec<u8>>,
    chain_error: Option<String>,
    metadata: ParsedCertificate,
    key_available: bool,
    key_error: Option<String>,
    key_metadata: Option<PrivateKeyMetadata>,
    usable: bool,
}

struct PrivateKeyMetadata {
    provider: Option<String>,
    container: Option<String>,
    storage: &'static str,
    errors: Vec<String>,
}

impl Certificate {
    fn detail_fields(&self) -> Vec<DetailField> {
        let mut fields = vec![
            field("Store", self.store),
            field(
                "Private Key Access",
                if self.key_available {
                    "Available through Windows CNG"
                } else {
                    "Unavailable"
                },
            ),
            field(
                "Usable as a Client Identity",
                if self.usable { "Yes" } else { "No" },
            ),
        ];
        if let Some(error) = &self.key_error {
            fields.push(field("Private Key Error", error));
        }
        if let Some(metadata) = &self.key_metadata {
            fields.push(field(
                "Private Key Provider",
                metadata.provider.as_deref().unwrap_or("Unavailable"),
            ));
            fields.push(field("Private Key Storage", metadata.storage));
            if let Some(container) = &metadata.container {
                fields.push(field("Private Key Container", container));
            }
            if !metadata.errors.is_empty() {
                fields.push(field(
                    "Private Key Metadata Errors",
                    metadata.errors.join("\n"),
                ));
            }
        }
        fields.push(field(
            "Certificate Chain Count",
            self.chain.len().to_string(),
        ));
        if let Some(error) = &self.chain_error {
            fields.push(field("Certificate Chain Error", error));
        }
        fields.extend(
            self.metadata
                .detail_fields()
                .into_iter()
                .map(DetailField::from),
        );

        fields
    }
}

impl Drop for Certificate {
    fn drop(&mut self) {
        unsafe {
            let _ = CertFreeCertificateContext(Some(self.context));
        }
    }
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
    } else if !certificate.key_available {
        // CNG refuses a key held by a legacy CSP rather than a KSP, which is what an older
        // certificate template provisions.
        return match &certificate.key_error {
            Some(error) => format!(
                "{} has a private key CNG will not use: {error}",
                metadata.fingerprint
            ),
            None => format!("{} has no usable private key", metadata.fingerprint),
        };
    } else {
        "it does not match the requested common name"
    };

    format!("{} is unusable because {reason}", metadata.fingerprint)
}

fn enumerate_matching(subject_cn: &str) -> (Vec<Certificate>, Vec<String>) {
    let mut certificates = Vec::new();
    let mut errors = Vec::new();

    let (location, label) = STORE;

    match unsafe { enumerate_store(location, label, subject_cn) } {
        Ok(mut found) => certificates.append(&mut found),
        Err(error) => {
            tracing::warn!(
                store = label,
                ?error,
                "Failed to read Windows certificate store"
            );
            errors.push(format!("{label}: {error:#}"));
        }
    }

    (certificates, errors)
}

unsafe fn enumerate_store(
    location: u32,
    label: &'static str,
    subject_cn: &str,
) -> Result<Vec<Certificate>> {
    let store = unsafe { open_store(location) }.with_context(|| format!("Opening {label}"))?;
    let mut certificates = Vec::new();
    let mut previous: *mut CERT_CONTEXT = ptr::null_mut();

    loop {
        let context = unsafe {
            CertEnumCertificatesInStore(
                store,
                (!previous.is_null()).then_some(previous as *const CERT_CONTEXT),
            )
        };
        if context.is_null() {
            break;
        }
        previous = context;

        let der = unsafe {
            let context = &*context;
            slice::from_raw_parts(context.pbCertEncoded, context.cbCertEncoded as usize).to_vec()
        };
        let Some(metadata) = parse_certificate(&der, SystemTime::now()) else {
            continue;
        };
        if metadata.subject_cn.as_deref() != Some(subject_cn) {
            continue;
        }

        let (key_available, key_error, key_metadata) = match unsafe { acquire_key(context) } {
            Ok(key) => (
                true,
                None,
                Some(unsafe { private_key_metadata(context, &key) }),
            ),
            Err(error) => (false, Some(error.to_string()), None),
        };
        let (chain, chain_error) = match unsafe { certificate_chain(context) } {
            Ok(chain) => (chain, None),
            Err(error) => {
                tracing::warn!(
                    store = label,
                    ?error,
                    "Failed to build the Windows certificate chain; sending the leaf only"
                );
                (vec![der.clone()], Some(format!("{error:#}")))
            }
        };
        let owned_context = unsafe { CertDuplicateCertificateContext(Some(context)) };
        if owned_context.is_null() {
            tracing::warn!(
                store = label,
                "Failed to retain a Windows certificate context"
            );
            continue;
        }

        certificates.push(Certificate {
            store: label,
            context: owned_context,
            chain,
            chain_error,
            usable: metadata.is_usable(subject_cn) && key_available,
            metadata,
            key_available,
            key_error,
            key_metadata,
        });
    }

    unsafe {
        let _ = CertCloseStore(Some(store), 0);
    }

    Ok(certificates)
}

unsafe fn open_store(location: u32) -> Result<HCERTSTORE> {
    let flags = CERT_OPEN_STORE_FLAGS(
        location | CERT_STORE_READONLY_FLAG.0 | CERT_STORE_OPEN_EXISTING_FLAG.0,
    );
    let store = unsafe {
        CertOpenStore(
            CERT_STORE_PROV_SYSTEM_W,
            CERT_QUERY_ENCODING_TYPE::default(),
            None,
            flags,
            Some(w!("MY").as_ptr().cast::<c_void>()),
        )
    }
    .context("CertOpenStore failed")?;
    if store.is_invalid() {
        bail!("CertOpenStore returned an invalid handle");
    }

    Ok(store)
}

/// Collects the leaf and every issuer Windows can resolve from its local caches.
///
/// Fetching missing issuers over the network would stall the handshake, so authority information
/// access is disabled and the portal is left to complete the chain from its own trust store.
unsafe fn certificate_chain(context: *const CERT_CONTEXT) -> Result<Vec<Vec<u8>>> {
    let parameters = CERT_CHAIN_PARA {
        cbSize: std::mem::size_of::<CERT_CHAIN_PARA>() as u32,
        ..Default::default()
    };
    let mut chain_context = ptr::null_mut();
    unsafe {
        CertGetCertificateChain(
            None,
            context,
            None,
            None,
            &raw const parameters,
            CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL | CERT_CHAIN_DISABLE_AIA,
            None,
            &mut chain_context,
        )
    }
    .context("CertGetCertificateChain failed")?;

    let result = (|| {
        let chain_context = unsafe { chain_context.as_ref() }
            .context("CertGetCertificateChain returned a null context")?;
        anyhow::ensure!(
            chain_context.cChain > 0,
            "Windows returned no certificate chains"
        );
        let simple_chain = unsafe { chain_context.rgpChain.as_ref() }
            .context("Windows returned a null certificate-chain list")?;
        let simple_chain = *simple_chain;
        let simple_chain = unsafe { simple_chain.as_ref() }
            .context("Windows returned a null certificate chain")?;
        let elements = unsafe { simple_chain.rgpElement.as_ref() }
            .context("Windows returned a null certificate-chain element list")?;
        let mut certificates = Vec::with_capacity(simple_chain.cElement as usize);

        for index in 0..simple_chain.cElement as usize {
            let element = if index == 0 {
                *elements
            } else {
                unsafe { *simple_chain.rgpElement.add(index) }
            };
            let element = unsafe { element.as_ref() }
                .context("Windows returned a null certificate-chain element")?;
            let certificate = unsafe { element.pCertContext.as_ref() }
                .context("Windows returned a null certificate context")?;
            certificates.push(unsafe {
                slice::from_raw_parts(
                    certificate.pbCertEncoded,
                    certificate.cbCertEncoded as usize,
                )
                .to_vec()
            });
        }

        Ok(certificates)
    })();

    unsafe { CertFreeCertificateChain(chain_context) };

    result
}

/// A duplicated, reference-counted certificate context shared by every signing operation.
struct CertificateContext(*mut CERT_CONTEXT);

// SAFETY: Windows permits certificate contexts and their associated CNG key providers to be used
// from different threads; each signing call acquires its own key handle.
unsafe impl Send for CertificateContext {}
// SAFETY: see the `Send` implementation above. The pointed-to context is immutable.
unsafe impl Sync for CertificateContext {}

impl fmt::Debug for CertificateContext {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("CertificateContext(..)")
    }
}

impl Drop for CertificateContext {
    fn drop(&mut self) {
        unsafe {
            let _ = CertFreeCertificateContext(Some(self.0));
        }
    }
}

struct AcquiredKey {
    handle: NCRYPT_KEY_HANDLE,
    must_free: bool,
}

impl AcquiredKey {
    fn implementation_type(&self) -> Result<u32> {
        let provider: NCRYPT_PROV_HANDLE = unsafe {
            ncrypt_property(
                NCRYPT_HANDLE(self.handle.0),
                NCRYPT_PROVIDER_HANDLE_PROPERTY,
            )
        }
        .context("Reading the CNG provider handle failed")?;
        let implementation_type =
            unsafe { ncrypt_property(NCRYPT_HANDLE(provider.0), NCRYPT_IMPL_TYPE_PROPERTY) }
                .context("Reading the CNG implementation type failed")?;

        Ok(implementation_type)
    }
}

impl Drop for AcquiredKey {
    fn drop(&mut self) {
        if self.must_free {
            unsafe {
                let _ = NCryptFreeObject(NCRYPT_HANDLE(self.handle.0));
            }
        }
    }
}

/// Opens the certificate's CNG key without ever showing UI.
///
/// The Tunnel service runs without a desktop, so a key that insists on a confirmation prompt is
/// reported as [`SigningError::AccessDenied`] rather than hanging the connection.
unsafe fn acquire_key(context: *mut CERT_CONTEXT) -> windows_core::Result<AcquiredKey> {
    let mut handle = HCRYPTPROV_OR_NCRYPT_KEY_HANDLE::default();
    let mut key_spec = CERT_KEY_SPEC::default();
    let mut must_free = windows_core::BOOL(0);
    unsafe {
        CryptAcquireCertificatePrivateKey(
            context,
            CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG | CRYPT_ACQUIRE_SILENT_FLAG,
            None,
            &mut handle,
            Some(&mut key_spec),
            Some(&mut must_free),
        )
    }?;

    Ok(AcquiredKey {
        handle: NCRYPT_KEY_HANDLE(handle.0),
        must_free: must_free.as_bool(),
    })
}

unsafe fn private_key_metadata(
    context: *const CERT_CONTEXT,
    key: &AcquiredKey,
) -> PrivateKeyMetadata {
    let mut errors = Vec::new();
    let (provider, container) = match unsafe { certificate_key_provider_info(context) } {
        Ok(info) => info,
        Err(error) => {
            errors.push(format!("Provider: {error:#}"));
            (None, None)
        }
    };
    let implementation_type = match key.implementation_type() {
        Ok(value) => Some(value),
        Err(error) => {
            errors.push(format!("Implementation type: {error:#}"));
            None
        }
    };

    PrivateKeyMetadata {
        storage: classify_private_key_storage(provider.as_deref(), implementation_type),
        provider,
        container,
        errors,
    }
}

unsafe fn certificate_key_provider_info(
    context: *const CERT_CONTEXT,
) -> Result<(Option<String>, Option<String>)> {
    let mut needed = 0;
    unsafe {
        CertGetCertificateContextProperty(context, CERT_KEY_PROV_INFO_PROP_ID, None, &mut needed)
    }
    .context("Reading the CNG provider metadata size failed")?;
    anyhow::ensure!(
        needed as usize >= std::mem::size_of::<CRYPT_KEY_PROV_INFO>(),
        "Windows returned invalid CNG provider metadata"
    );

    // The property contains a CRYPT_KEY_PROV_INFO followed by referenced strings,
    // so allocate in pointer-sized units to preserve the struct's alignment.
    let words = (needed as usize).div_ceil(std::mem::size_of::<usize>());
    let mut buffer = vec![0usize; words];
    unsafe {
        CertGetCertificateContextProperty(
            context,
            CERT_KEY_PROV_INFO_PROP_ID,
            Some(buffer.as_mut_ptr().cast()),
            &mut needed,
        )
    }
    .context("Reading the CNG provider metadata failed")?;

    let info = unsafe { &*buffer.as_ptr().cast::<CRYPT_KEY_PROV_INFO>() };
    let provider = unsafe { wide_string(info.pwszProvName) };
    let container = unsafe { wide_string(info.pwszContainerName) };

    Ok((provider, container))
}

unsafe fn ncrypt_property<T: Default>(
    handle: NCRYPT_HANDLE,
    property: windows_core::PCWSTR,
) -> Result<T> {
    let mut value = T::default();
    let output = unsafe {
        slice::from_raw_parts_mut((&raw mut value).cast::<u8>(), std::mem::size_of::<T>())
    };
    let mut written = 0;
    unsafe {
        NCryptGetProperty(
            handle,
            property,
            Some(output),
            &mut written,
            Default::default(),
        )
    }
    .context("NCryptGetProperty failed")?;
    anyhow::ensure!(
        written as usize == std::mem::size_of::<T>(),
        "NCryptGetProperty returned {written} bytes, expected {}",
        std::mem::size_of::<T>()
    );

    Ok(value)
}

unsafe fn wide_string(value: windows_core::PWSTR) -> Option<String> {
    if value.is_null() {
        return None;
    }

    unsafe { value.to_string().ok() }
}

fn classify_private_key_storage(
    provider: Option<&str>,
    implementation_type: Option<u32>,
) -> &'static str {
    if provider
        .is_some_and(|provider| provider.eq_ignore_ascii_case("Microsoft Platform Crypto Provider"))
    {
        return "TPM (hardware-backed keystore)";
    }
    if implementation_type.is_some_and(|value| value & NCRYPT_IMPL_HARDWARE_FLAG != 0) {
        return "Hardware-backed keystore";
    }
    if provider.is_some_and(|provider| {
        provider.eq_ignore_ascii_case("Microsoft Software Key Storage Provider")
    }) || implementation_type.is_some_and(|value| value & NCRYPT_IMPL_SOFTWARE_FLAG != 0)
    {
        return "Software keystore";
    }

    "CNG provider (hardware backing unknown)"
}

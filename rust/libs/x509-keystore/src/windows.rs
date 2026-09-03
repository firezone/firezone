//! X.509 client identities from the Windows certificate stores, signed through CNG.

#[cfg(test)]
mod tests;

use std::{ffi::c_void, fmt, ptr, slice, sync::Arc, time::SystemTime};

use anyhow::{Context as _, Result, bail};
use rustls::{SignatureScheme, pki_types::CertificateDer};
use sha2::{Digest as _, Sha256, Sha384, Sha512};
use windows::{
    Win32::{
        Foundation::{
            E_ACCESSDENIED, NTE_BAD_KEYSET, NTE_NO_KEY, NTE_NOT_FOUND, NTE_NOT_SUPPORTED, NTE_PERM,
            NTE_SILENT_CONTEXT, NTE_USER_CANCELLED, SCARD_W_CANCELLED_BY_USER,
        },
        Security::{
            Cryptography::{
                BCRYPT_PKCS1_PADDING_INFO, BCRYPT_PSS_PADDING_INFO, BCRYPT_SHA256_ALGORITHM,
                BCRYPT_SHA384_ALGORITHM, BCRYPT_SHA512_ALGORITHM,
                CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL, CERT_CHAIN_DISABLE_AIA, CERT_CHAIN_PARA,
                CERT_CONTEXT, CERT_KEY_SPEC, CERT_NCRYPT_KEY_SPEC, CERT_OPEN_STORE_FLAGS,
                CERT_QUERY_ENCODING_TYPE, CERT_STORE_OPEN_EXISTING_FLAG, CERT_STORE_PROV_SYSTEM_W,
                CERT_STORE_READONLY_FLAG, CERT_SYSTEM_STORE_LOCAL_MACHINE, CRYPT_ACQUIRE_FLAGS,
                CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG, CRYPT_ACQUIRE_PREFER_NCRYPT_KEY_FLAG,
                CRYPT_ACQUIRE_SILENT_FLAG, CertCloseStore, CertDuplicateCertificateContext,
                CertEnumCertificatesInStore, CertFreeCertificateChain, CertFreeCertificateContext,
                CertGetCertificateChain, CertOpenStore, CryptAcquireCertificatePrivateKey,
                CryptReleaseContext, HCERTSTORE, HCRYPTPROV_OR_NCRYPT_KEY_HANDLE, NCRYPT_FLAGS,
                NCRYPT_HANDLE, NCRYPT_KEY_HANDLE, NCRYPT_PAD_PKCS1_FLAG, NCRYPT_PAD_PSS_FLAG,
                NCRYPT_PCP_PSS_SALT_SIZE_PROPERTY, NCRYPT_TPM_PSS_SALT_SIZE_HASHSIZE,
                NCryptFreeObject, NCryptGetProperty, NCryptSignHash,
            },
            OBJECT_SECURITY_INFORMATION,
        },
    },
    core::w,
};
use x509_claims::{ParsedCertificate, SigningAlgorithm, parse_certificate};
use x509_credential::SigningError;

use crate::{CandidateCertificate, Error, Identity, selected_certificate, sign};

/// The store MDM-provisioned identities land in.
///
/// The Tunnel service runs as LocalSystem, so `CERT_SYSTEM_STORE_CURRENT_USER` would resolve to
/// the SYSTEM profile rather than to the signed-in user, and reading it would only ever find
/// certificates nobody provisioned there. Device-scope profiles write here.
const STORE: (u32, &str) = (CERT_SYSTEM_STORE_LOCAL_MACHINE, "LocalMachine\\My");

pub(crate) fn identity(subject_cn: &str) -> Result<Option<Identity>, Error> {
    let mut certificates = enumerate_matching(subject_cn)?;

    let Some(index) = selected_certificate(&certificates) else {
        return Ok(None);
    };
    let certificate = certificates.swap_remove(index);

    let signing_context = unsafe { CertDuplicateCertificateContext(Some(certificate.context)) };
    if signing_context.is_null() {
        return Err(Error::IdentityUnavailable {
            message: "Failed to retain the selected Windows certificate context".to_owned(),
        });
    }

    let chain = certificate
        .chain
        .iter()
        .cloned()
        .map(CertificateDer::from)
        .collect();
    let key = sign::Key::new(
        certificate.algorithm,
        CngKey {
            context: Arc::new(CertificateContext(signing_context)),
        },
    );
    let key = Arc::new(match certificate.signs_rsa_pss {
        true => key,
        false => key.without_rsa_pss(),
    });

    tracing::debug!(
        store = STORE.1,
        fingerprint = %certificate.metadata.fingerprint,
        "Selected a Windows X.509 identity for mutual TLS"
    );

    Ok(Some(Identity {
        chain,
        key,
        certificate: certificate.metadata.clone(),
    }))
}

/// A certificate context whose CNG private key signs the TLS handshake.
///
/// The key is only ever referenced by handle, so its material stays inside the CNG provider.
#[derive(Debug)]
struct CngKey {
    context: Arc<CertificateContext>,
}

impl sign::Signer for CngKey {
    fn sign(&self, scheme: SignatureScheme, message: &[u8]) -> Result<Vec<u8>, SigningError> {
        let signature = unsafe { sign_with_certificate(self.context.0, scheme, message) }?;

        Ok(signature)
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
    let key = unsafe { acquire_key(context, CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG) }
        .map_err(|error| classify_signing_error(error, scheme))?;

    let signature = match scheme {
        SignatureScheme::RSA_PSS_SHA256 => unsafe {
            sign_rsa_pss(
                key.ncrypt(),
                BCRYPT_SHA256_ALGORITHM,
                &Sha256::digest(message),
            )
        },
        SignatureScheme::RSA_PSS_SHA384 => unsafe {
            sign_rsa_pss(
                key.ncrypt(),
                BCRYPT_SHA384_ALGORITHM,
                &Sha384::digest(message),
            )
        },
        SignatureScheme::RSA_PSS_SHA512 => unsafe {
            sign_rsa_pss(
                key.ncrypt(),
                BCRYPT_SHA512_ALGORITHM,
                &Sha512::digest(message),
            )
        },
        SignatureScheme::RSA_PKCS1_SHA256 => unsafe {
            sign_rsa_pkcs1(
                key.ncrypt(),
                BCRYPT_SHA256_ALGORITHM,
                &Sha256::digest(message),
            )
        },
        SignatureScheme::RSA_PKCS1_SHA384 => unsafe {
            sign_rsa_pkcs1(
                key.ncrypt(),
                BCRYPT_SHA384_ALGORITHM,
                &Sha384::digest(message),
            )
        },
        SignatureScheme::RSA_PKCS1_SHA512 => unsafe {
            sign_rsa_pkcs1(
                key.ncrypt(),
                BCRYPT_SHA512_ALGORITHM,
                &Sha512::digest(message),
            )
        },
        SignatureScheme::ECDSA_NISTP256_SHA256 => unsafe {
            sign_hash(
                key.ncrypt(),
                None,
                &Sha256::digest(message),
                NCRYPT_FLAGS::default(),
            )
        },
        SignatureScheme::ECDSA_NISTP384_SHA384 => unsafe {
            sign_hash(
                key.ncrypt(),
                None,
                &Sha384::digest(message),
                NCRYPT_FLAGS::default(),
            )
        },
        SignatureScheme::ECDSA_NISTP521_SHA512 => unsafe {
            sign_hash(
                key.ncrypt(),
                None,
                &Sha512::digest(message),
                NCRYPT_FLAGS::default(),
            )
        },
        _ => return Err(SigningError::UnsupportedScheme(scheme)),
    }
    .map_err(|error| classify_signing_error(error, scheme))?;

    Ok(signature)
}

/// Names the cause behind a failed CNG key operation on `scheme`.
///
/// Windows reports a declined confirmation prompt and a missing key-usage permission as different
/// codes, but both mean the same to us: the keystore is there and refuses to use the key.
/// `NTE_NOT_SUPPORTED` is how a provider turns down the padding rather than the key, which its own
/// message ("The requested operation is not supported") leaves for the reader to work out.
fn classify_signing_error(error: windows_core::Error, scheme: SignatureScheme) -> SigningError {
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
        NTE_NOT_SUPPORTED => SigningError::UnsupportedScheme(scheme),
        _ => SigningError::Keystore(reason),
    }
}

unsafe fn sign_rsa_pss(
    key: NCRYPT_KEY_HANDLE,
    hash_algorithm: windows_core::PCWSTR,
    hash: &[u8],
) -> windows_core::Result<Vec<u8>> {
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
) -> windows_core::Result<Vec<u8>> {
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
) -> windows_core::Result<Vec<u8>> {
    let mut needed = 0;
    unsafe { NCryptSignHash(key, padding, hash, None, &mut needed, flags) }?;

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
    }?;
    signature.truncate(written as usize);

    Ok(signature)
}

/// A matching certificate we can present: CNG signs with its private key.
struct Certificate {
    context: *mut CERT_CONTEXT,
    chain: Vec<Vec<u8>>,
    metadata: ParsedCertificate,
    algorithm: SigningAlgorithm,
    /// Whether the provider will produce RSA-PSS signatures; vacuously true for an ECDSA key.
    signs_rsa_pss: bool,
}

impl CandidateCertificate for Certificate {
    fn not_before_timestamp(&self) -> i64 {
        self.metadata.not_before_timestamp
    }
}

impl Drop for Certificate {
    fn drop(&mut self) {
        unsafe {
            let _ = CertFreeCertificateContext(Some(self.context));
        }
    }
}

fn enumerate_matching(subject_cn: &str) -> Result<Vec<Certificate>, Error> {
    let (location, label) = STORE;

    let certificates = match unsafe { enumerate_store(location, label, subject_cn) } {
        Ok(found) => found,
        Err(error) => {
            tracing::warn!(
                store = label,
                ?error,
                "Failed to read Windows certificate store"
            );

            return Err(Error::UnreadableStore {
                store: label.to_owned(),
                error: format!("{error:#}"),
            });
        }
    };

    Ok(certificates)
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

        // A certificate we cannot sign a TLS handshake with authenticates nothing; selecting
        // it anyway would only shadow an older certificate that still works.
        let Some(algorithm) = metadata.signing_algorithm else {
            tracing::debug!(
                store = label,
                fingerprint = %metadata.fingerprint,
                "Skipping a matching certificate: no scheme we sign with holds its key algorithm"
            );
            continue;
        };
        if let Err(error) = unsafe { acquire_key(context, CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG) } {
            tracing::debug!(
                store = label,
                fingerprint = %metadata.fingerprint,
                %error,
                "Skipping a matching certificate: CNG will not hand over its private key"
            );
            continue;
        }

        let signs_rsa_pss = match algorithm {
            SigningAlgorithm::RsaSha256 => unsafe {
                provider_signs_rsa_pss(context, &metadata.fingerprint)
            },
            SigningAlgorithm::EcdsaSha256 => true,
            SigningAlgorithm::EcdsaSha384 => true,
            SigningAlgorithm::EcdsaSha512 => true,
        };

        let chain = match unsafe { certificate_chain(context) } {
            Ok(chain) => chain,
            Err(error) => {
                tracing::warn!(
                    store = label,
                    ?error,
                    "Failed to build the Windows certificate chain; sending the leaf only"
                );

                vec![der.clone()]
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
            context: owned_context,
            chain,
            metadata,
            algorithm,
            signs_rsa_pss,
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

/// Whether the provider holding the certificate's key produces the RSA-PSS signatures TLS 1.3
/// asks for.
///
/// TLS 1.3 mandates a salt as long as the digest, which two kinds of provider cannot deliver: a
/// TPM that salts differently, and a legacy CryptoAPI provider, which has no RSA-PSS at all. Both
/// answer a signing request with `NTE_NOT_SUPPORTED`, so the answer is worked out here, from what
/// they say about themselves rather than from a signature nobody asked for.
///
/// Anything else keeps RSA-PSS: no property tells us, and a handshake that fails is a better
/// answer than a guess that quietly gives up TLS 1.3.
unsafe fn provider_signs_rsa_pss(context: *mut CERT_CONTEXT, fingerprint: &str) -> bool {
    let key = match unsafe { acquire_key(context, CRYPT_ACQUIRE_PREFER_NCRYPT_KEY_FLAG) } {
        Ok(key) => key,
        Err(error) => {
            tracing::debug!(
                store = STORE.1,
                fingerprint,
                %error,
                "Assuming RSA-PSS: the provider of this certificate's key did not answer"
            );

            return true;
        }
    };

    if key.key_spec != CERT_NCRYPT_KEY_SPEC {
        tracing::info!(
            store = STORE.1,
            fingerprint,
            "A legacy CryptoAPI provider holds this certificate's key, which rules out RSA-PSS and with it TLS 1.3"
        );

        return false;
    }

    let Some(salt_size) = (unsafe { tpm_pss_salt_size(key.ncrypt()) }) else {
        return true;
    };
    if salt_size == NCRYPT_TPM_PSS_SALT_SIZE_HASHSIZE {
        return true;
    }

    tracing::info!(
        store = STORE.1,
        fingerprint,
        salt_size,
        "The TPM holding this certificate's key salts RSA-PSS differently than TLS 1.3 requires"
    );

    false
}

/// The salt size the TPM holding `key` signs RSA-PSS with, if a TPM holds it at all.
///
/// Only the Platform Crypto Provider carries this property, so a key without it is one the TPM
/// never saw rather than one whose provider failed to answer.
unsafe fn tpm_pss_salt_size(key: NCRYPT_KEY_HANDLE) -> Option<u32> {
    let mut value = 0u32.to_ne_bytes();
    let mut written = 0;
    unsafe {
        NCryptGetProperty(
            NCRYPT_HANDLE(key.0),
            NCRYPT_PCP_PSS_SALT_SIZE_PROPERTY,
            Some(&mut value),
            &mut written,
            OBJECT_SECURITY_INFORMATION::default(),
        )
    }
    .ok()?;

    Some(u32::from_ne_bytes(value))
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
    handle: HCRYPTPROV_OR_NCRYPT_KEY_HANDLE,
    /// Which of the two key APIs answered, which also decides how the handle is released.
    key_spec: CERT_KEY_SPEC,
    must_free: bool,
}

impl AcquiredKey {
    /// The handle CNG signs with, which is what [`acquire_key`] answers with unless it fell back
    /// to CryptoAPI.
    fn ncrypt(&self) -> NCRYPT_KEY_HANDLE {
        NCRYPT_KEY_HANDLE(self.handle.0)
    }
}

impl Drop for AcquiredKey {
    fn drop(&mut self) {
        if !self.must_free {
            return;
        }

        match self.key_spec {
            CERT_NCRYPT_KEY_SPEC => unsafe {
                let _ = NCryptFreeObject(NCRYPT_HANDLE(self.handle.0));
            },
            _ => unsafe {
                let _ = CryptReleaseContext(self.handle.0, 0);
            },
        }
    }
}

/// Opens the certificate's private key through `flags`, without ever showing UI.
///
/// The Tunnel service runs without a desktop, so a key that insists on a confirmation prompt is
/// reported as [`SigningError::AccessDenied`] rather than hanging the connection.
unsafe fn acquire_key(
    context: *mut CERT_CONTEXT,
    flags: CRYPT_ACQUIRE_FLAGS,
) -> windows_core::Result<AcquiredKey> {
    let mut handle = HCRYPTPROV_OR_NCRYPT_KEY_HANDLE::default();
    let mut key_spec = CERT_KEY_SPEC::default();
    let mut must_free = windows_core::BOOL(0);
    unsafe {
        CryptAcquireCertificatePrivateKey(
            context,
            flags | CRYPT_ACQUIRE_SILENT_FLAG,
            None,
            &mut handle,
            Some(&mut key_spec),
            Some(&mut must_free),
        )
    }?;

    Ok(AcquiredKey {
        handle,
        key_spec,
        must_free: must_free.as_bool(),
    })
}

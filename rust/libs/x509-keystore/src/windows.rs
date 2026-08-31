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
            E_ACCESSDENIED, NTE_BAD_KEYSET, NTE_NO_KEY, NTE_NOT_FOUND, NTE_PERM,
            NTE_SILENT_CONTEXT, NTE_USER_CANCELLED, SCARD_W_CANCELLED_BY_USER,
        },
        Security::Cryptography::{
            BCRYPT_PKCS1_PADDING_INFO, BCRYPT_PSS_PADDING_INFO, BCRYPT_SHA256_ALGORITHM,
            BCRYPT_SHA384_ALGORITHM, BCRYPT_SHA512_ALGORITHM, CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL,
            CERT_CHAIN_DISABLE_AIA, CERT_CHAIN_PARA, CERT_CONTEXT, CERT_KEY_SPEC,
            CERT_OPEN_STORE_FLAGS, CERT_QUERY_ENCODING_TYPE, CERT_STORE_OPEN_EXISTING_FLAG,
            CERT_STORE_PROV_SYSTEM_W, CERT_STORE_READONLY_FLAG, CERT_SYSTEM_STORE_LOCAL_MACHINE,
            CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG, CRYPT_ACQUIRE_SILENT_FLAG, CertCloseStore,
            CertDuplicateCertificateContext, CertEnumCertificatesInStore, CertFreeCertificateChain,
            CertFreeCertificateContext, CertGetCertificateChain, CertOpenStore,
            CryptAcquireCertificatePrivateKey, HCERTSTORE, HCRYPTPROV_OR_NCRYPT_KEY_HANDLE,
            NCRYPT_FLAGS, NCRYPT_HANDLE, NCRYPT_KEY_HANDLE, NCRYPT_PAD_PKCS1_FLAG,
            NCRYPT_PAD_PSS_FLAG, NCryptFreeObject, NCryptSignHash,
        },
    },
    core::w,
};
use x509_claims::{ParsedCertificate, parse_certificate};
use x509_credential::SigningError;

use crate::{
    CandidateCertificate, Error, Identity, Loaded, ReportedCertificate, UnusableCause,
    selected_certificate, sign,
};

/// The store MDM-provisioned identities land in.
///
/// The Tunnel service runs as LocalSystem, so `CERT_SYSTEM_STORE_CURRENT_USER` would resolve to
/// the SYSTEM profile rather than to the signed-in user, and reading it would only ever find
/// certificates nobody provisioned there. Device-scope profiles write here.
const STORE: (u32, &str) = (CERT_SYSTEM_STORE_LOCAL_MACHINE, "LocalMachine\\My");

pub(crate) fn load(subject_cn: &str) -> Result<Loaded, Error> {
    let mut certificates = enumerate_matching(subject_cn)?;

    let Some(index) = selected_certificate(&certificates) else {
        return Ok(Loaded::default());
    };
    let certificate = certificates.swap_remove(index);

    // A certificate that was provisioned for Firezone but fails one of our rules must not read
    // to an administrator as if none had been: it is reported with the rule it failed, and
    // nothing is presented.
    if let Some(cause) = certificate.unusable() {
        return Ok(Loaded {
            certificate: Some(ReportedCertificate {
                certificate: certificate.metadata.clone(),
                unusable: Some(cause),
            }),
            identity: None,
        });
    }

    let Some(algorithm) = certificate.metadata.signing_algorithm else {
        return Err(Error::IdentityUnavailable {
            message: "The selected Windows certificate uses an unsupported key algorithm"
                .to_owned(),
        });
    };
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
    let key = Arc::new(sign::Key::new(
        algorithm,
        CngKey {
            context: Arc::new(CertificateContext(signing_context)),
        },
    ));

    tracing::info!(
        store = STORE.1,
        fingerprint = %certificate.metadata.fingerprint,
        "Selected a Windows X.509 identity for mutual TLS"
    );

    Ok(Loaded {
        certificate: Some(ReportedCertificate {
            certificate: certificate.metadata.clone(),
            unusable: None,
        }),
        identity: Some(Identity { chain, key }),
    })
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
        SignatureScheme::ECDSA_NISTP256_SHA256 => unsafe {
            sign_hash(
                key.handle,
                None,
                &Sha256::digest(message),
                NCRYPT_FLAGS::default(),
            )
        },
        SignatureScheme::ECDSA_NISTP384_SHA384 => unsafe {
            sign_hash(
                key.handle,
                None,
                &Sha384::digest(message),
                NCRYPT_FLAGS::default(),
            )
        },
        SignatureScheme::ECDSA_NISTP521_SHA512 => unsafe {
            sign_hash(
                key.handle,
                None,
                &Sha512::digest(message),
                NCRYPT_FLAGS::default(),
            )
        },
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

/// A certificate in the searched store whose subject CN is the one we look for.
struct Certificate {
    context: *mut CERT_CONTEXT,
    chain: Vec<Vec<u8>>,
    metadata: ParsedCertificate,
    key_error: Option<String>,
    usable: bool,
}

impl CandidateCertificate for Certificate {
    fn unusable(&self) -> Option<UnusableCause> {
        // CNG refuses a key held by a legacy CSP rather than a KSP, which is what an older
        // certificate template provisions.
        match (
            &self.key_error,
            self.metadata.signing_algorithm,
            self.usable,
        ) {
            (Some(error), _, _) => Some(UnusableCause::KeyRefused {
                error: error.clone(),
            }),
            (None, None, _) => Some(UnusableCause::UnsupportedKeyAlgorithm),
            (None, Some(_), false) => Some(UnusableCause::KeyMissing),
            (None, Some(_), true) => None,
        }
    }

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

        let (key_available, key_error) = match unsafe { acquire_key(context) } {
            Ok(_) => (true, None),
            Err(error) => (false, Some(error.to_string())),
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
            usable: metadata.signing_algorithm.is_some() && key_available,
            metadata,
            key_error,
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

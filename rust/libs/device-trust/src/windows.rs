//! Windows X.509 identities from the machine/user certificate stores and CNG.

use std::{ffi::c_void, fmt, ptr, slice, sync::Arc, time::SystemTime};

use anyhow::{Context as _, Result, bail};
use rustls::{
    SignatureAlgorithm, SignatureScheme,
    pki_types::CertificateDer,
    sign::{CertifiedKey, Signer, SigningKey},
};
use sha2::{Digest as _, Sha256, Sha384, Sha512};
use windows::{
    Win32::Security::Cryptography::{
        BCRYPT_PKCS1_PADDING_INFO, BCRYPT_PSS_PADDING_INFO, BCRYPT_SHA256_ALGORITHM,
        BCRYPT_SHA384_ALGORITHM, BCRYPT_SHA512_ALGORITHM, CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL,
        CERT_CHAIN_DISABLE_AIA, CERT_CHAIN_PARA, CERT_CONTEXT, CERT_KEY_PROV_INFO_PROP_ID,
        CERT_KEY_SPEC, CERT_OPEN_STORE_FLAGS, CERT_QUERY_ENCODING_TYPE,
        CERT_STORE_OPEN_EXISTING_FLAG, CERT_STORE_PROV_SYSTEM_W, CERT_STORE_READONLY_FLAG,
        CERT_SYSTEM_STORE_CURRENT_USER, CERT_SYSTEM_STORE_LOCAL_MACHINE,
        CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG, CRYPT_ACQUIRE_SILENT_FLAG, CRYPT_KEY_PROV_INFO,
        CertCloseStore, CertDuplicateCertificateContext, CertEnumCertificatesInStore,
        CertFreeCertificateChain, CertFreeCertificateContext, CertGetCertificateChain,
        CertGetCertificateContextProperty, CertOpenStore, CryptAcquireCertificatePrivateKey,
        HCERTSTORE, HCRYPTPROV_OR_NCRYPT_KEY_HANDLE, NCRYPT_FLAGS, NCRYPT_HANDLE,
        NCRYPT_IMPL_HARDWARE_FLAG, NCRYPT_IMPL_SOFTWARE_FLAG, NCRYPT_IMPL_TYPE_PROPERTY,
        NCRYPT_KEY_HANDLE, NCRYPT_PAD_PKCS1_FLAG, NCRYPT_PAD_PSS_FLAG, NCRYPT_PROV_HANDLE,
        NCRYPT_PROVIDER_HANDLE_PROPERTY, NCryptFreeObject, NCryptGetProperty, NCryptSignHash,
    },
    core::w,
};

use crate::{
    Config, DetailSection, PlatformIdentity, Status,
    policy::{CertificateMetadata, SigningAlgorithm, field, parse_certificate},
};

const STORES: &[(u32, &str)] = &[
    (CERT_SYSTEM_STORE_LOCAL_MACHINE, "LocalMachine\\My"),
    (CERT_SYSTEM_STORE_CURRENT_USER, "CurrentUser\\My"),
];

pub(crate) fn status(_config: &Config, subject_cn: &str) -> Result<Status> {
    let (certificates, errors) = enumerate_matching(subject_cn);
    if certificates.is_empty() && errors.len() == STORES.len() {
        bail!(
            "The Windows certificate stores could not be read: {}",
            errors.join("; ")
        );
    }

    let usable = certificates
        .iter()
        .filter(|certificate| certificate.usable)
        .count();
    let mut sections = vec![DetailSection {
        title: "Windows Certificate Store".to_owned(),
        fields: vec![
            field("Searched Stores", "LocalMachine\\My\nCurrentUser\\My"),
            field("Requested Common Name", subject_cn),
            field(
                "Store Read Errors",
                if errors.is_empty() {
                    "None".to_owned()
                } else {
                    errors.join("\n")
                },
            ),
        ],
    }];
    sections.extend(certificates.iter().enumerate().map(|(index, certificate)| {
        let mut fields = vec![
            field("Store", certificate.store),
            field(
                "Private Key Access",
                if certificate.key_available {
                    "Available through Windows CNG"
                } else {
                    "Unavailable"
                },
            ),
            field(
                "Usable for Device Attestation",
                if certificate.usable { "Yes" } else { "No" },
            ),
        ];
        if let Some(error) = &certificate.key_error {
            fields.push(field("Private Key Error", error));
        }
        if let Some(metadata) = &certificate.key_metadata {
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
            certificate.chain.len().to_string(),
        ));
        if let Some(error) = &certificate.chain_error {
            fields.push(field("Certificate Chain Error", error));
        }
        fields.extend(certificate.metadata.detail_fields());
        DetailSection {
            title: format!("Matching Certificate {}", index + 1),
            fields,
        }
    }));

    let summary = match (usable, certificates.len()) {
        (0, 0) => format!(
            "No X.509 certificate with subject CN '{subject_cn}' was found in the Windows certificate stores."
        ),
        (0, count) => format!(
            "Found {count} matching X.509 certificate(s), but none are usable for device attestation."
        ),
        (count, _) => format!(
            "{count} X.509 device identity certificate(s) are available for device attestation."
        ),
    };

    Ok(Status { summary, sections })
}

pub(crate) fn identity(_config: &Config, subject_cn: &str) -> Result<Option<PlatformIdentity>> {
    let (certificates, store_errors) = enumerate_matching(subject_cn);
    if certificates.is_empty() && store_errors.len() == STORES.len() {
        bail!(
            "The Windows certificate stores could not be read: {}",
            store_errors.join("; ")
        );
    }

    let Some(certificate) = certificates
        .into_iter()
        .filter(|certificate| certificate.metadata.is_usable(subject_cn))
        .max_by_key(|certificate| certificate.metadata.not_before_timestamp)
    else {
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
    let signing_key = Arc::new(WindowsSigningKey {
        context: Arc::new(CertificateContext(signing_context)),
        algorithm,
    });
    let chain = certificate
        .chain
        .iter()
        .cloned()
        .map(CertificateDer::from)
        .collect();

    tracing::info!(
        store = certificate.store,
        fingerprint = %certificate.metadata.fingerprint,
        mdm_device_id = certificate.metadata.mdm_device_id.as_deref(),
        "Selected the newest Windows X.509 identity for mutual TLS"
    );

    Ok(Some(PlatformIdentity {
        certified_key: Arc::new(CertifiedKey::new(chain, signing_key)),
        mdm_device_id: certificate.metadata.mdm_device_id.clone(),
    }))
}

struct CertificateContext(*mut CERT_CONTEXT);

// SAFETY: this owns a duplicated, reference-counted CERT_CONTEXT. Windows permits
// certificate contexts and their associated CNG key providers to be used from
// different threads; all signing calls acquire their own key handle.
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

#[derive(Debug)]
struct WindowsSigningKey {
    context: Arc<CertificateContext>,
    algorithm: SigningAlgorithm,
}

impl SigningKey for WindowsSigningKey {
    fn choose_scheme(&self, offered: &[SignatureScheme]) -> Option<Box<dyn Signer>> {
        signature_schemes(self.algorithm)
            .iter()
            .copied()
            .find(|scheme| offered.contains(scheme))
            .map(|scheme| {
                Box::new(WindowsSigner {
                    context: self.context.clone(),
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
struct WindowsSigner {
    context: Arc<CertificateContext>,
    scheme: SignatureScheme,
}

impl Signer for WindowsSigner {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, rustls::Error> {
        unsafe { sign_with_certificate(self.context.0, self.scheme, message) }.map_err(|error| {
            rustls::Error::General(format!("Windows TLS signing failed: {error:#}"))
        })
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

struct Certificate {
    store: &'static str,
    context: *mut CERT_CONTEXT,
    chain: Vec<Vec<u8>>,
    chain_error: Option<String>,
    metadata: CertificateMetadata,
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

impl Drop for Certificate {
    fn drop(&mut self) {
        unsafe {
            let _ = CertFreeCertificateContext(Some(self.context));
        }
    }
}

fn enumerate_matching(subject_cn: &str) -> (Vec<Certificate>, Vec<String>) {
    let mut certificates = Vec::new();
    let mut errors = Vec::new();
    for &(location, label) in STORES {
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
        if !metadata.matches_subject(subject_cn) {
            continue;
        }

        let (key_available, key_error, key_metadata) = match unsafe { acquire_key(context) } {
            Ok(key) => {
                let metadata = unsafe { private_key_metadata(context, &key) };
                (true, None, Some(metadata))
            }
            Err(error) => (false, Some(format!("{error:#}")), None),
        };
        let usable = metadata.is_usable(subject_cn) && key_available;
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
            metadata,
            key_available,
            key_error,
            key_metadata,
            usable,
        });
    }

    unsafe {
        let _ = CertCloseStore(Some(store), 0);
    }
    Ok(certificates)
}

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
        let mut certificates = Vec::with_capacity(simple_chain.cElement as usize);
        let elements = unsafe { simple_chain.rgpElement.as_ref() }
            .context("Windows returned a null certificate-chain element list")?;
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

struct AcquiredKey {
    handle: NCRYPT_KEY_HANDLE,
    must_free: bool,
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
    let storage = classify_private_key_storage(provider.as_deref(), implementation_type);

    PrivateKeyMetadata {
        provider,
        container,
        storage,
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

unsafe fn wide_string(value: windows_core::PWSTR) -> Option<String> {
    if value.is_null() {
        None
    } else {
        unsafe { value.to_string().ok() }
    }
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

impl AcquiredKey {
    fn implementation_type(&self) -> Result<u32> {
        let provider: NCRYPT_PROV_HANDLE = unsafe {
            ncrypt_property(
                NCRYPT_HANDLE(self.handle.0),
                NCRYPT_PROVIDER_HANDLE_PROPERTY,
            )
        }
        .context("Reading the CNG provider handle failed")?;
        unsafe { ncrypt_property(NCRYPT_HANDLE(provider.0), NCRYPT_IMPL_TYPE_PROPERTY) }
            .context("Reading the CNG implementation type failed")
    }
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

impl Drop for AcquiredKey {
    fn drop(&mut self) {
        if self.must_free {
            unsafe {
                let _ = NCryptFreeObject(NCRYPT_HANDLE(self.handle.0));
            }
        }
    }
}

unsafe fn acquire_key(context: *mut CERT_CONTEXT) -> Result<AcquiredKey> {
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
    }
    .context("Windows could not acquire the certificate's CNG private key")?;
    Ok(AcquiredKey {
        handle: NCRYPT_KEY_HANDLE(handle.0),
        must_free: must_free.as_bool(),
    })
}

unsafe fn sign_with_certificate(
    context: *mut CERT_CONTEXT,
    scheme: SignatureScheme,
    message: &[u8],
) -> Result<Vec<u8>> {
    let key = unsafe { acquire_key(context) }?;
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
            let hash = Sha256::digest(message);
            let raw = unsafe { sign_hash(key.handle, None, &hash, NCRYPT_FLAGS::default()) }?;
            der_encode_ecdsa_signature(&raw)
        }
        SignatureScheme::ECDSA_NISTP384_SHA384 => {
            let hash = Sha384::digest(message);
            let raw = unsafe { sign_hash(key.handle, None, &hash, NCRYPT_FLAGS::default()) }?;
            der_encode_ecdsa_signature(&raw)
        }
        SignatureScheme::ECDSA_NISTP521_SHA512 => {
            let hash = Sha512::digest(message);
            let raw = unsafe { sign_hash(key.handle, None, &hash, NCRYPT_FLAGS::default()) }?;
            der_encode_ecdsa_signature(&raw)
        }
        _ => bail!("Unsupported TLS signature scheme {scheme:?}"),
    }
}

unsafe fn sign_rsa_pss(
    key: NCRYPT_KEY_HANDLE,
    hash_algorithm: windows_core::PCWSTR,
    hash: &[u8],
) -> Result<Vec<u8>> {
    let padding = BCRYPT_PSS_PADDING_INFO {
        pszAlgId: hash_algorithm,
        cbSalt: hash.len() as u32,
    };
    unsafe {
        sign_hash(
            key,
            Some((&raw const padding).cast()),
            hash,
            NCRYPT_PAD_PSS_FLAG,
        )
    }
}

unsafe fn sign_rsa_pkcs1(
    key: NCRYPT_KEY_HANDLE,
    hash_algorithm: windows_core::PCWSTR,
    hash: &[u8],
) -> Result<Vec<u8>> {
    let padding = BCRYPT_PKCS1_PADDING_INFO {
        pszAlgId: hash_algorithm,
    };
    unsafe {
        sign_hash(
            key,
            Some((&raw const padding).cast()),
            hash,
            NCRYPT_PAD_PKCS1_FLAG,
        )
    }
}

unsafe fn sign_hash(
    key: NCRYPT_KEY_HANDLE,
    padding: Option<*const c_void>,
    hash: &[u8],
    flags: NCRYPT_FLAGS,
) -> Result<Vec<u8>> {
    let mut needed = 0;
    unsafe { NCryptSignHash(key, padding, hash, None, &mut needed, flags) }
        .context("NCryptSignHash size query failed")?;
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
    .context("NCryptSignHash failed")?;
    signature.truncate(written as usize);
    Ok(signature)
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
    fn classifies_windows_key_storage() {
        assert_eq!(
            classify_private_key_storage(Some("Microsoft Platform Crypto Provider"), None),
            "TPM (hardware-backed keystore)"
        );
        assert_eq!(
            classify_private_key_storage(Some("Microsoft Software Key Storage Provider"), None),
            "Software keystore"
        );
        assert_eq!(
            classify_private_key_storage(Some("Third-party KSP"), Some(NCRYPT_IMPL_HARDWARE_FLAG)),
            "Hardware-backed keystore"
        );
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

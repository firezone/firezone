//! Windows device-trust signer using Windows Certificate Store + CNG.
//!
//! We enumerate `LocalMachine\My` (where AD CS auto-enrollment and Intune SCEP/PKCS deposit
//! device certificates) and fall back to `CurrentUser\My`, filter for our expected leaf-cert
//! subject CN with the clientAuth EKU and a current validity window, then sign the
//! portal-supplied nonce with `NCryptSignHash`. When the certificate's private key was
//! provisioned against the Microsoft Platform Crypto Provider, signing happens inside the TPM
//! and the key never leaves the chip.

use std::ffi::c_void;
use std::ptr;
use std::slice;
use std::time::SystemTime;

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use sha2::{Digest, Sha256};
use tracing::{debug, warn};
use windows::Win32::Security::Cryptography::{
    BCRYPT_PKCS1_PADDING_INFO, BCRYPT_SHA256_ALGORITHM, CERT_CONTEXT, CERT_KEY_SPEC,
    CERT_OPEN_STORE_FLAGS, CERT_QUERY_ENCODING_TYPE, CERT_STORE_OPEN_EXISTING_FLAG,
    CERT_STORE_PROV_SYSTEM_W, CERT_STORE_READONLY_FLAG, CERT_SYSTEM_STORE_CURRENT_USER,
    CERT_SYSTEM_STORE_LOCAL_MACHINE, CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG, CRYPT_ACQUIRE_SILENT_FLAG,
    CertCloseStore, CertEnumCertificatesInStore, CertOpenStore, CryptAcquireCertificatePrivateKey,
    HCERTSTORE, HCRYPTPROV_OR_NCRYPT_KEY_HANDLE, NCRYPT_FLAGS, NCRYPT_HANDLE, NCRYPT_KEY_HANDLE,
    NCRYPT_PAD_PKCS1_FLAG, NCryptFreeObject, NCryptSignHash,
};
use windows::core::w;
use windows_core::BOOL;

use crate::DeviceTrustSignedChallenge;
use crate::policy::{CertMetadata, PublicKeyKind, matches_client_auth_identity, parse_metadata};

pub(crate) fn sign(nonce: &[u8], subject_cn: &str) -> Result<Vec<DeviceTrustSignedChallenge>> {
    let now = SystemTime::now();
    let mut signed = Vec::new();

    for (location_flag, label) in [
        (CERT_SYSTEM_STORE_LOCAL_MACHINE, "LocalMachine\\My"),
        (CERT_SYSTEM_STORE_CURRENT_USER, "CurrentUser\\My"),
    ] {
        match enumerate_and_sign(location_flag, label, subject_cn, nonce, now) {
            Ok(mut more) => signed.append(&mut more),
            Err(e) => warn!(store = label, error = ?e, "Device trust: store enumeration failed"),
        }
    }

    debug!(
        signed_count = signed.len(),
        "Device trust: produced signed challenges"
    );
    Ok(signed)
}

fn enumerate_and_sign(
    location_flag: u32,
    label: &str,
    subject_cn: &str,
    nonce: &[u8],
    now: SystemTime,
) -> Result<Vec<DeviceTrustSignedChallenge>> {
    let store =
        unsafe { open_my_store(location_flag) }.with_context(|| format!("opening {label}"))?;
    let mut signed = Vec::new();

    let result = (|| -> Result<()> {
        let mut prev: *mut CERT_CONTEXT = ptr::null_mut();
        loop {
            // After this call returns a non-null cert, that cert context now belongs to the
            // store iterator — we must not free it ourselves. Passing it back in the next
            // iteration releases it.
            let next = unsafe {
                CertEnumCertificatesInStore(
                    store,
                    if prev.is_null() {
                        None
                    } else {
                        Some(prev as *const CERT_CONTEXT)
                    },
                )
            };
            if next.is_null() {
                break;
            }
            prev = next;

            let cert_der = unsafe {
                let ctx = &*next;
                slice::from_raw_parts(ctx.pbCertEncoded, ctx.cbCertEncoded as usize).to_vec()
            };

            let Some(metadata) = parse_metadata(&cert_der) else {
                debug!(
                    store = label,
                    "Device trust: failed to parse cert DER, skipping"
                );
                continue;
            };

            if !matches_client_auth_identity(&metadata, subject_cn, now) {
                continue;
            }

            match unsafe { sign_with_cert(next, &metadata, nonce) } {
                Ok(signature) => {
                    debug!(
                        store = label,
                        subject_cn = ?metadata.subject_cn,
                        signature_byte_count = signature.len(),
                        "Device trust: signed challenge"
                    );
                    signed.push(DeviceTrustSignedChallenge {
                        signed_challenge: BASE64.encode(&signature),
                        cert: BASE64.encode(&cert_der),
                    });
                }
                Err(e) => warn!(
                    store = label,
                    subject_cn = ?metadata.subject_cn,
                    error = ?e,
                    "Device trust: signing failed for matching cert; trying others"
                ),
            }
        }

        Ok(())
    })();

    unsafe {
        let _ = CertCloseStore(Some(store), 0);
    }

    result?;
    Ok(signed)
}

unsafe fn open_my_store(location_flag: u32) -> Result<HCERTSTORE> {
    // CERT_STORE_PROV_SYSTEM_W reads the Microsoft system stores ("MY", "ROOT", "CA", ...) and
    // honors registry-level redirection. CERT_STORE_OPEN_EXISTING_FLAG avoids creating a store
    // if one does not exist, and READONLY because we never modify the store ourselves.
    let flags = CERT_OPEN_STORE_FLAGS(
        location_flag | CERT_STORE_READONLY_FLAG.0 | CERT_STORE_OPEN_EXISTING_FLAG.0,
    );
    let store_name = w!("MY");

    let store = unsafe {
        CertOpenStore(
            CERT_STORE_PROV_SYSTEM_W,
            CERT_QUERY_ENCODING_TYPE::default(),
            None,
            flags,
            Some(store_name.as_ptr() as *const c_void),
        )
    }
    .context("CertOpenStore")?;

    if store.is_invalid() {
        bail!("CertOpenStore returned invalid handle");
    }

    Ok(store)
}

unsafe fn sign_with_cert(
    cert_context: *mut CERT_CONTEXT,
    metadata: &CertMetadata,
    nonce: &[u8],
) -> Result<Vec<u8>> {
    let mut key_handle = HCRYPTPROV_OR_NCRYPT_KEY_HANDLE::default();
    let mut key_spec = CERT_KEY_SPEC::default();
    let mut caller_must_free = BOOL(0);

    // CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG forces a CNG handle, which is what TPM-backed certs and
    // modern Microsoft Platform Crypto Provider keys use. CRYPT_ACQUIRE_SILENT_FLAG ensures we
    // never pop a UI prompt — the headless and tunnel-service contexts must not block on user
    // input.
    let flags = CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG | CRYPT_ACQUIRE_SILENT_FLAG;

    unsafe {
        CryptAcquireCertificatePrivateKey(
            cert_context,
            flags,
            None,
            &mut key_handle,
            Some(&mut key_spec),
            Some(&mut caller_must_free),
        )
    }
    .context("CryptAcquireCertificatePrivateKey")?;

    let key = NCRYPT_KEY_HANDLE(key_handle.0);
    let result = unsafe { ncrypt_sign(key, metadata, nonce) };

    if caller_must_free.as_bool() {
        unsafe {
            let _ = NCryptFreeObject(NCRYPT_HANDLE(key_handle.0));
        }
    }

    result
}

unsafe fn ncrypt_sign(
    key: NCRYPT_KEY_HANDLE,
    metadata: &CertMetadata,
    nonce: &[u8],
) -> Result<Vec<u8>> {
    let hash = Sha256::digest(nonce);
    let hash_bytes: &[u8] = hash.as_slice();

    let key_kind = metadata
        .public_key_kind
        .ok_or_else(|| anyhow!("unsupported certificate public-key algorithm"))?;

    match key_kind {
        PublicKeyKind::Rsa => {
            let padding = BCRYPT_PKCS1_PADDING_INFO {
                pszAlgId: BCRYPT_SHA256_ALGORITHM,
            };
            let padding_ptr: *const c_void = &padding as *const _ as *const c_void;
            unsafe { ncrypt_sign_raw(key, Some(padding_ptr), hash_bytes, NCRYPT_PAD_PKCS1_FLAG) }
        }
        PublicKeyKind::Ecdsa => {
            let raw = unsafe { ncrypt_sign_raw(key, None, hash_bytes, NCRYPT_FLAGS::default())? };
            der_encode_ecdsa_signature(&raw)
        }
    }
}

unsafe fn ncrypt_sign_raw(
    key: NCRYPT_KEY_HANDLE,
    padding: Option<*const c_void>,
    hash: &[u8],
    flags: NCRYPT_FLAGS,
) -> Result<Vec<u8>> {
    let mut needed: u32 = 0;
    unsafe { NCryptSignHash(key, padding, hash, None, &mut needed, flags) }
        .context("NCryptSignHash size query")?;

    let mut signature = vec![0u8; needed as usize];
    let mut written: u32 = 0;
    unsafe {
        NCryptSignHash(
            key,
            padding,
            hash,
            Some(signature.as_mut_slice()),
            &mut written,
            flags,
        )
    }
    .context("NCryptSignHash")?;

    signature.truncate(written as usize);
    Ok(signature)
}

// Convert NCrypt's raw `r || s` ECDSA output into the X9.62 DER-encoded
// SEQUENCE { r INTEGER, s INTEGER } that Erlang's :public_key.verify/4 expects on the server.
fn der_encode_ecdsa_signature(raw: &[u8]) -> Result<Vec<u8>> {
    if raw.is_empty() || !raw.len().is_multiple_of(2) {
        bail!("invalid raw ECDSA signature length: {}", raw.len());
    }
    let half = raw.len() / 2;
    let r = &raw[..half];
    let s = &raw[half..];

    let r_der = der_integer(r);
    let s_der = der_integer(s);

    let body_len = r_der.len() + s_der.len();
    let mut out = Vec::with_capacity(2 + body_len + 4);
    out.push(0x30); // SEQUENCE
    encode_length(&mut out, body_len);
    out.extend_from_slice(&r_der);
    out.extend_from_slice(&s_der);
    Ok(out)
}

fn der_integer(value: &[u8]) -> Vec<u8> {
    // Strip leading zero bytes, but keep at least one zero so the value is never empty.
    let mut start = 0;
    while start < value.len() - 1 && value[start] == 0 {
        start += 1;
    }
    let trimmed = &value[start..];

    // If the high bit is set, prepend a 0 byte so the DER INTEGER is interpreted as positive.
    let needs_pad = (trimmed[0] & 0x80) != 0;
    let body_len = trimmed.len() + usize::from(needs_pad);

    let mut out = Vec::with_capacity(body_len + 2);
    out.push(0x02); // INTEGER
    encode_length(&mut out, body_len);
    if needs_pad {
        out.push(0x00);
    }
    out.extend_from_slice(trimmed);
    out
}

fn encode_length(out: &mut Vec<u8>, len: usize) {
    if len < 0x80 {
        out.push(len as u8);
    } else if len < 0x100 {
        out.push(0x81);
        out.push(len as u8);
    } else if len < 0x10000 {
        out.push(0x82);
        out.push((len >> 8) as u8);
        out.push(len as u8);
    } else {
        // ECDSA signatures are well under 64 KiB; this branch is unreachable in practice.
        out.push(0x83);
        out.push((len >> 16) as u8);
        out.push((len >> 8) as u8);
        out.push(len as u8);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ecdsa_der_minimal() {
        let mut raw = vec![0u8; 64];
        raw[31] = 1;
        raw[63] = 2;
        let der = der_encode_ecdsa_signature(&raw).unwrap();
        assert_eq!(der, vec![0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02]);
    }

    #[test]
    fn ecdsa_der_pads_high_bit() {
        let mut raw = vec![0u8; 64];
        raw[0] = 0x80;
        raw[32] = 0x80;
        let der = der_encode_ecdsa_signature(&raw).unwrap();
        assert_eq!(der[0], 0x30);
        assert_eq!(der[2], 0x02);
        assert_eq!(der[3], 0x21);
        assert_eq!(der[4], 0x00);
    }
}

//! Linux device-trust signer using PKCS#11.
//!
//! The administrator points the client at a PKCS#11 module via an RFC 7512 URI; the URI carries
//! the module path, token label, object label, and (optionally) a `pin-source=file:...` for
//! unlocking the token. Common modules: `tpm2-pkcs11` for TPM-backed device keys, `OpenSC` for
//! smartcards, `softhsm2` for development. The client never has access to the private key
//! material — signing happens inside the module.

use std::path::PathBuf;
use std::time::SystemTime;

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use cryptoki::context::{CInitializeArgs, Pkcs11};
use cryptoki::mechanism::Mechanism;
use cryptoki::object::{Attribute, AttributeType, CertificateType, KeyType, ObjectClass};
use cryptoki::session::UserType;
use cryptoki::types::AuthPin;
use sha2::{Digest, Sha256};
use tracing::{debug, warn};

use crate::DeviceTrustSignedChallenge;
use crate::policy::{PublicKeyKind, matches_client_auth_identity, parse_metadata};

pub(crate) fn sign(
    nonce: &[u8],
    subject_cn: &str,
    pkcs11_uri: Option<&str>,
) -> Result<Vec<DeviceTrustSignedChallenge>> {
    let Some(uri) = pkcs11_uri else {
        warn!(
            "Device trust: no PKCS#11 URI configured (FIREZONE_DEVICE_TRUST_PKCS11_URI / device_trust_pkcs11_uri); skipping"
        );
        return Ok(Vec::new());
    };

    let parsed = Pkcs11Uri::parse(uri).context("parsing PKCS#11 URI")?;

    let pkcs11 = Pkcs11::new(&parsed.module_path)
        .with_context(|| format!("loading PKCS#11 module at {}", parsed.module_path.display()))?;
    pkcs11
        .initialize(CInitializeArgs::OsThreads)
        .context("PKCS#11 C_Initialize")?;

    let slot = find_slot(&pkcs11, parsed.token_label.as_deref())?;
    let session = pkcs11
        .open_ro_session(slot)
        .context("PKCS#11 open session")?;

    if let Some(pin) = parsed.read_pin().context("reading PKCS#11 PIN")? {
        session
            .login(UserType::User, Some(&AuthPin::new(pin)))
            .context("PKCS#11 C_Login")?;
    }

    let now = SystemTime::now();
    let mut signed = Vec::new();

    let cert_handles = session
        .find_objects(&[
            Attribute::Class(ObjectClass::CERTIFICATE),
            Attribute::CertificateType(CertificateType::X_509),
        ])
        .context("PKCS#11 find certificates")?;

    debug!(
        candidate_count = cert_handles.len(),
        token_label = ?parsed.token_label,
        "Device trust: enumerated PKCS#11 certificate objects"
    );

    for cert_handle in cert_handles {
        let attrs = match session.get_attributes(
            cert_handle,
            &[
                AttributeType::Value,
                AttributeType::Id,
                AttributeType::Label,
            ],
        ) {
            Ok(a) => a,
            Err(e) => {
                warn!(
                    ?e,
                    "Device trust: failed reading PKCS#11 cert attributes; skipping"
                );
                continue;
            }
        };

        let mut cert_der: Option<Vec<u8>> = None;
        let mut cert_id: Option<Vec<u8>> = None;
        let mut cert_label: Option<String> = None;

        for attr in attrs {
            // Cryptoki's `Attribute` is a large open enum; we only care about three variants and
            // explicitly ignore the rest.
            #[allow(clippy::wildcard_enum_match_arm)]
            match attr {
                Attribute::Value(v) => cert_der = Some(v),
                Attribute::Id(v) => cert_id = Some(v),
                Attribute::Label(v) => cert_label = String::from_utf8(v).ok(),
                _ => {}
            }
        }

        let Some(cert_der) = cert_der else { continue };

        if let Some(expected_label) = parsed.object_label.as_deref()
            && cert_label.as_deref() != Some(expected_label)
        {
            continue;
        }

        let Some(metadata) = parse_metadata(&cert_der) else {
            debug!(
                cert_label = ?cert_label,
                "Device trust: failed to parse cert DER, skipping"
            );
            continue;
        };

        if !matches_client_auth_identity(&metadata, subject_cn, now) {
            continue;
        }

        let mechanism = match metadata.public_key_kind {
            Some(PublicKeyKind::Rsa) => Mechanism::Sha256RsaPkcs,
            Some(PublicKeyKind::Ecdsa) => Mechanism::EcdsaSha256,
            None => {
                warn!(
                    cert_label = ?cert_label,
                    "Device trust: unsupported public-key algorithm, skipping"
                );
                continue;
            }
        };

        let private_key_handle = match find_matching_private_key(
            &session,
            cert_id.as_deref(),
            cert_label.as_deref(),
            metadata.public_key_kind,
        ) {
            Ok(Some(h)) => h,
            Ok(None) => {
                debug!(
                    cert_label = ?cert_label,
                    "Device trust: no matching private key for cert, skipping"
                );
                continue;
            }
            Err(e) => {
                warn!(?e, cert_label = ?cert_label, "Device trust: error looking up private key");
                continue;
            }
        };

        // For RSA we let the token hash internally (CKM_SHA256_RSA_PKCS hashes then signs). For
        // ECDSA the cryptoki mechanism we use signs the supplied hash, so we hash here.
        let payload: Vec<u8> = match metadata.public_key_kind {
            Some(PublicKeyKind::Rsa) => nonce.to_vec(),
            Some(PublicKeyKind::Ecdsa) => Sha256::digest(nonce).to_vec(),
            None => continue,
        };

        let signature = match session.sign(&mechanism, private_key_handle, &payload) {
            Ok(s) => s,
            Err(e) => {
                warn!(?e, cert_label = ?cert_label, "Device trust: PKCS#11 C_Sign failed");
                continue;
            }
        };

        let final_signature = match metadata.public_key_kind {
            Some(PublicKeyKind::Rsa) => signature,
            Some(PublicKeyKind::Ecdsa) => der_encode_ecdsa_signature(&signature)?,
            None => continue,
        };

        signed.push(DeviceTrustSignedChallenge {
            signed_challenge: BASE64.encode(&final_signature),
            cert: BASE64.encode(&cert_der),
        });
    }

    debug!(
        signed_count = signed.len(),
        "Device trust: produced signed challenges"
    );

    Ok(signed)
}

fn find_slot(pkcs11: &Pkcs11, token_label: Option<&str>) -> Result<cryptoki::slot::Slot> {
    let slots = pkcs11
        .get_slots_with_token()
        .context("PKCS#11 get_slots_with_token")?;

    if let Some(label) = token_label {
        for slot in &slots {
            let info = pkcs11
                .get_token_info(*slot)
                .context("PKCS#11 get_token_info")?;
            if info.label().trim() == label {
                return Ok(*slot);
            }
        }
        bail!("no PKCS#11 token with label \"{label}\"");
    }

    slots
        .into_iter()
        .next()
        .ok_or_else(|| anyhow!("no PKCS#11 tokens available"))
}

fn find_matching_private_key(
    session: &cryptoki::session::Session,
    cert_id: Option<&[u8]>,
    cert_label: Option<&str>,
    kind: Option<PublicKeyKind>,
) -> Result<Option<cryptoki::object::ObjectHandle>> {
    let mut template = vec![Attribute::Class(ObjectClass::PRIVATE_KEY)];
    if let Some(kind) = kind {
        let key_type = match kind {
            PublicKeyKind::Rsa => KeyType::RSA,
            PublicKeyKind::Ecdsa => KeyType::EC,
        };
        template.push(Attribute::KeyType(key_type));
    }
    if let Some(id) = cert_id {
        template.push(Attribute::Id(id.to_vec()));
    } else if let Some(label) = cert_label {
        template.push(Attribute::Label(label.as_bytes().to_vec()));
    }

    let handles = session
        .find_objects(&template)
        .context("PKCS#11 find private keys")?;
    Ok(handles.into_iter().next())
}

#[derive(Debug, Default, Clone)]
struct Pkcs11Uri {
    module_path: PathBuf,
    token_label: Option<String>,
    object_label: Option<String>,
    pin_source: Option<String>,
    pin_value: Option<String>,
}

impl Pkcs11Uri {
    fn parse(uri: &str) -> Result<Self> {
        // Minimal RFC 7512 parser: splits the path-part components and the query-part components.
        // We don't aim to support every attribute — just the subset needed to unambiguously
        // identify a key+cert pair on the local module.
        let body = uri
            .strip_prefix("pkcs11:")
            .ok_or_else(|| anyhow!("PKCS#11 URI must begin with `pkcs11:`"))?;

        let (path, query) = match body.split_once('?') {
            Some((p, q)) => (p, Some(q)),
            None => (body, None),
        };

        let mut parsed = Pkcs11Uri::default();

        for component in path.split(';') {
            if component.is_empty() {
                continue;
            }
            let (key, value) = component
                .split_once('=')
                .ok_or_else(|| anyhow!("malformed PKCS#11 URI component: {component}"))?;
            let value = pct_decode(value)?;
            match key {
                "module-path" => parsed.module_path = PathBuf::from(value),
                "token" => parsed.token_label = Some(value),
                "object" => parsed.object_label = Some(value),
                _ => {} // ignore — additional RFC 7512 attributes we don't act on
            }
        }

        if let Some(query) = query {
            for component in query.split('&') {
                if component.is_empty() {
                    continue;
                }
                let (key, value) = component
                    .split_once('=')
                    .ok_or_else(|| anyhow!("malformed PKCS#11 URI query: {component}"))?;
                let value = pct_decode(value)?;
                match key {
                    "pin-source" => parsed.pin_source = Some(value),
                    "pin-value" => parsed.pin_value = Some(value),
                    "module-path" => parsed.module_path = PathBuf::from(value),
                    _ => {}
                }
            }
        }

        if parsed.module_path.as_os_str().is_empty() {
            bail!("PKCS#11 URI is missing required `module-path=` attribute");
        }

        Ok(parsed)
    }

    fn read_pin(&self) -> Result<Option<String>> {
        if let Some(value) = &self.pin_value {
            return Ok(Some(value.clone()));
        }

        let Some(source) = &self.pin_source else {
            return Ok(None);
        };

        // RFC 7512 PIN sources are URLs. We support `file:` here; other schemes (e.g. `env:`)
        // can be added when there's a concrete need.
        if let Some(path) = source.strip_prefix("file:") {
            let pin = std::fs::read_to_string(path)
                .with_context(|| format!("reading PKCS#11 PIN from {path}"))?;
            // Trim trailing newline that admins commonly leave on `echo "pin" > pin.txt`.
            return Ok(Some(pin.trim_end_matches(['\n', '\r']).to_string()));
        }

        bail!("unsupported PKCS#11 pin-source scheme: {source}");
    }
}

fn pct_decode(input: &str) -> Result<String> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3])
                    .context("invalid percent-encoded sequence in PKCS#11 URI")?;
                let byte = u8::from_str_radix(hex, 16)
                    .context("invalid percent-encoded sequence in PKCS#11 URI")?;
                out.push(byte);
                i += 3;
            }
            other => {
                out.push(other);
                i += 1;
            }
        }
    }
    String::from_utf8(out).context("PKCS#11 URI component is not valid UTF-8")
}

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
    out.push(0x30);
    encode_length(&mut out, body_len);
    out.extend_from_slice(&r_der);
    out.extend_from_slice(&s_der);
    Ok(out)
}

fn der_integer(value: &[u8]) -> Vec<u8> {
    let mut start = 0;
    while start < value.len() - 1 && value[start] == 0 {
        start += 1;
    }
    let trimmed = &value[start..];
    let needs_pad = (trimmed[0] & 0x80) != 0;
    let body_len = trimmed.len() + usize::from(needs_pad);

    let mut out = Vec::with_capacity(body_len + 2);
    out.push(0x02);
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
    fn parses_pkcs11_uri_components() {
        let uri = "pkcs11:module-path=/usr/lib/libsofthsm2.so;token=firezone;object=device-trust?pin-source=file:/etc/firezone/pin";
        let parsed = Pkcs11Uri::parse(uri).expect("parse");
        assert_eq!(parsed.module_path, PathBuf::from("/usr/lib/libsofthsm2.so"));
        assert_eq!(parsed.token_label.as_deref(), Some("firezone"));
        assert_eq!(parsed.object_label.as_deref(), Some("device-trust"));
        assert_eq!(parsed.pin_source.as_deref(), Some("file:/etc/firezone/pin"));
    }

    #[test]
    fn pkcs11_uri_requires_module_path() {
        assert!(Pkcs11Uri::parse("pkcs11:token=firezone").is_err());
    }

    #[test]
    fn ecdsa_signature_der_encodes() {
        // r = 1, s = 2 — minimal example with a 64-byte raw blob.
        let mut raw = vec![0u8; 64];
        raw[31] = 1;
        raw[63] = 2;
        let der = der_encode_ecdsa_signature(&raw).unwrap();
        assert_eq!(der, vec![0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02]);
    }

    #[test]
    fn ecdsa_signature_der_pads_high_bit() {
        // r and s both have the high bit set; need a leading zero in DER INTEGER.
        let mut raw = vec![0u8; 64];
        raw[0] = 0x80;
        raw[32] = 0x80;
        let der = der_encode_ecdsa_signature(&raw).unwrap();
        assert_eq!(der[0], 0x30);
        assert_eq!(der[2], 0x02); // INTEGER tag for r
        assert_eq!(der[3], 0x21); // length 33
        assert_eq!(der[4], 0x00); // leading zero pad
    }
}

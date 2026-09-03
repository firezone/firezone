//! TLS signing shared by the keystore backends.

#![allow(
    dead_code,
    reason = "only the keystore backends sign, and not every build compiles one"
)]

use rustls::{SignatureAlgorithm, SignatureScheme};
use x509_claims::SigningAlgorithm;
use x509_credential::{PrivateKey, SigningError};

/// Signs with the platform keystore's native call.
///
/// ECDSA signatures come back raw (`r || s`); [`Key`] DER-encodes them.
pub(crate) trait Signer: std::fmt::Debug + Send + Sync {
    fn sign(&self, scheme: SignatureScheme, message: &[u8]) -> Result<Vec<u8>, SigningError>;
}

/// A keystore-held private key, presented to rustls as a [`PrivateKey`].
///
/// The platform contributes only the native signing call; which schemes the key advertises and
/// how a raw ECDSA signature becomes the DER sequence TLS expects are decided here.
#[derive(Debug)]
pub(crate) struct Key<S> {
    /// What the parsed certificate says the key signs with.
    algorithm: SigningAlgorithm,
    schemes: Vec<SignatureScheme>,
    signer: S,
}

impl<S> Key<S> {
    pub(crate) fn new(algorithm: SigningAlgorithm, signer: S) -> Self {
        Self {
            algorithm,
            schemes: signature_schemes(algorithm).to_vec(),
            signer,
        }
    }

    /// Returns the key with the RSA-PSS schemes taken out of what it advertises.
    ///
    /// rustls signs with the first advertised scheme the peer offers, so a keystore that cannot
    /// produce RSA-PSS signatures has to stop offering them: it would otherwise refuse in the
    /// middle of the handshake, where the connection has no way left to recover.
    pub(crate) fn without_rsa_pss(self) -> Self {
        let Self {
            algorithm,
            schemes,
            signer,
        } = self;
        let schemes = schemes
            .into_iter()
            .filter(|scheme| {
                !matches!(
                    scheme,
                    SignatureScheme::RSA_PSS_SHA256
                        | SignatureScheme::RSA_PSS_SHA384
                        | SignatureScheme::RSA_PSS_SHA512
                )
            })
            .collect();

        Self {
            algorithm,
            schemes,
            signer,
        }
    }
}

impl<S: Signer> PrivateKey for Key<S> {
    fn supported_schemes(&self) -> Vec<SignatureScheme> {
        self.schemes.clone()
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
        let raw = self.signer.sign(scheme, message)?;
        let signature = match self.algorithm {
            SigningAlgorithm::RsaSha256 => raw,
            SigningAlgorithm::EcdsaSha256 => der_encode_ecdsa_signature(&raw)?,
            SigningAlgorithm::EcdsaSha384 => der_encode_ecdsa_signature(&raw)?,
            SigningAlgorithm::EcdsaSha512 => der_encode_ecdsa_signature(&raw)?,
        };

        Ok(signature)
    }
}

/// The schemes a key of `algorithm` signs with, most preferred first.
///
/// The RSA schemes are ordered by digest rather than by padding, SHA-256 first, because a TPM
/// commonly implements SHA-1 and SHA-256 alone: a key held by one refuses a SHA-512 signature
/// outright, and only the first scheme the peer also offers is ever tried.
fn signature_schemes(algorithm: SigningAlgorithm) -> &'static [SignatureScheme] {
    match algorithm {
        SigningAlgorithm::RsaSha256 => &[
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PKCS1_SHA384,
            SignatureScheme::RSA_PSS_SHA512,
            SignatureScheme::RSA_PKCS1_SHA512,
        ],
        SigningAlgorithm::EcdsaSha256 => &[SignatureScheme::ECDSA_NISTP256_SHA256],
        SigningAlgorithm::EcdsaSha384 => &[SignatureScheme::ECDSA_NISTP384_SHA384],
        SigningAlgorithm::EcdsaSha512 => &[SignatureScheme::ECDSA_NISTP521_SHA512],
    }
}

/// Wraps the fixed-width `r` and `s` values a keystore returns into the DER sequence TLS expects.
pub(crate) fn der_encode_ecdsa_signature(raw: &[u8]) -> Result<Vec<u8>, SigningError> {
    if raw.is_empty() || !raw.len().is_multiple_of(2) {
        return Err(SigningError::Keystore(format!(
            "the keystore returned a {}-byte ECDSA signature",
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

pub(crate) fn der_integer(value: &[u8]) -> Vec<u8> {
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

pub(crate) fn encode_der_length(output: &mut Vec<u8>, length: usize) {
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

//! Adapts a [`ClientTlsIdentity`] handed to us by the platform bindings to the `x509-credential` interfaces.

use std::sync::Arc;

use anyhow::{Context as _, Result, bail};
use rustls::{SignatureAlgorithm, SignatureScheme, pki_types::CertificateDer};
use x509_credential::{ClientCertificate, PrivateKey, SigningError};

use crate::{ClientTlsIdentity, TlsSignatureScheme};

/// Turns the platform's TLS identity into the client certificate we present to the portal.
///
/// # Errors
///
/// Returns an error if the identity does not yield a usable certificate chain and key.
pub(crate) fn certificate(identity: Arc<dyn ClientTlsIdentity>) -> Result<ClientCertificate> {
    let chain = identity
        .certificate_chain()
        .context("Failed to read the client certificate chain")?
        .into_iter()
        .map(CertificateDer::from)
        .collect();
    let key = PlatformKey::new(identity)?;
    let certificate = ClientCertificate::new(chain, Arc::new(key))?;

    Ok(certificate)
}

/// A private key whose signatures are produced by the platform bindings.
#[derive(Debug)]
struct PlatformKey {
    identity: Arc<dyn ClientTlsIdentity>,
    schemes: Vec<TlsSignatureScheme>,
    algorithm: SignatureAlgorithm,
}

impl PlatformKey {
    fn new(identity: Arc<dyn ClientTlsIdentity>) -> Result<Self> {
        let schemes = identity
            .supported_signature_schemes()
            .context("Failed to read the supported TLS signature schemes")?;

        let Some(first) = schemes.first().copied() else {
            bail!("The client identity supports no TLS signature schemes");
        };
        let algorithm = SignatureAlgorithm::from(first);

        if schemes
            .iter()
            .any(|scheme| SignatureAlgorithm::from(*scheme) != algorithm)
        {
            bail!("The client identity mixes signature schemes of different key algorithms");
        }

        Ok(Self {
            identity,
            schemes,
            algorithm,
        })
    }
}

impl PrivateKey for PlatformKey {
    fn supported_schemes(&self) -> Vec<SignatureScheme> {
        self.schemes
            .iter()
            .copied()
            .map(SignatureScheme::from)
            .collect()
    }

    fn algorithm(&self) -> SignatureAlgorithm {
        self.algorithm
    }

    fn sign(&self, scheme: SignatureScheme, message: &[u8]) -> Result<Vec<u8>, SigningError> {
        let scheme = self
            .schemes
            .iter()
            .copied()
            .find(|supported| SignatureScheme::from(*supported) == scheme)
            .ok_or(SigningError::UnsupportedScheme(scheme))?;

        let signature = self
            .identity
            .sign(scheme, message.to_vec())
            .map_err(|e| SigningError::Keystore(e.to_string()))?;

        Ok(signature)
    }
}

impl From<TlsSignatureScheme> for SignatureScheme {
    fn from(value: TlsSignatureScheme) -> Self {
        match value {
            TlsSignatureScheme::RsaPkcs1Sha256 => Self::RSA_PKCS1_SHA256,
            TlsSignatureScheme::RsaPkcs1Sha384 => Self::RSA_PKCS1_SHA384,
            TlsSignatureScheme::RsaPkcs1Sha512 => Self::RSA_PKCS1_SHA512,
            TlsSignatureScheme::RsaPssSha256 => Self::RSA_PSS_SHA256,
            TlsSignatureScheme::RsaPssSha384 => Self::RSA_PSS_SHA384,
            TlsSignatureScheme::RsaPssSha512 => Self::RSA_PSS_SHA512,
            TlsSignatureScheme::EcdsaNistp256Sha256 => Self::ECDSA_NISTP256_SHA256,
            TlsSignatureScheme::EcdsaNistp384Sha384 => Self::ECDSA_NISTP384_SHA384,
            TlsSignatureScheme::EcdsaNistp521Sha512 => Self::ECDSA_NISTP521_SHA512,
        }
    }
}

impl From<TlsSignatureScheme> for SignatureAlgorithm {
    fn from(value: TlsSignatureScheme) -> Self {
        match value {
            TlsSignatureScheme::RsaPkcs1Sha256 => Self::RSA,
            TlsSignatureScheme::RsaPkcs1Sha384 => Self::RSA,
            TlsSignatureScheme::RsaPkcs1Sha512 => Self::RSA,
            TlsSignatureScheme::RsaPssSha256 => Self::RSA,
            TlsSignatureScheme::RsaPssSha384 => Self::RSA,
            TlsSignatureScheme::RsaPssSha512 => Self::RSA,
            TlsSignatureScheme::EcdsaNistp256Sha256 => Self::ECDSA,
            TlsSignatureScheme::EcdsaNistp384Sha384 => Self::ECDSA,
            TlsSignatureScheme::EcdsaNistp521Sha512 => Self::ECDSA,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::CallbackError;

    #[test]
    fn signs_with_the_scheme_rustls_picked() {
        let key = PlatformKey::new(Arc::new(StubIdentity {
            schemes: Ok(vec![
                TlsSignatureScheme::RsaPssSha512,
                TlsSignatureScheme::RsaPssSha256,
            ]),
        }))
        .expect("stub identity should yield a key");

        let signature = key
            .sign(SignatureScheme::RSA_PSS_SHA256, &[4, 5])
            .expect("stub identity should sign");

        assert_eq!(key.algorithm(), SignatureAlgorithm::RSA);
        assert_eq!(signature, vec![4, 5, 0x08, 0x04]);
    }

    #[test]
    fn reports_a_failing_keystore_with_its_message() {
        let key = PlatformKey::new(Arc::new(StubIdentity {
            schemes: Ok(vec![
                TlsSignatureScheme::RsaPssSha256,
                TlsSignatureScheme::RsaPssSha512,
            ]),
        }))
        .expect("stub identity should yield a key");

        let error = key
            .sign(SignatureScheme::RSA_PSS_SHA512, &[4, 5])
            .expect_err("the stub keystore should refuse SHA-512");

        assert_eq!(
            error.to_string(),
            "the keystore failed to sign: the keystore is locked"
        );
    }

    #[test]
    fn rejects_a_scheme_the_identity_did_not_advertise() {
        let key = PlatformKey::new(Arc::new(StubIdentity {
            schemes: Ok(vec![TlsSignatureScheme::RsaPssSha256]),
        }))
        .expect("stub identity should yield a key");

        let error = key
            .sign(SignatureScheme::ED25519, &[4, 5])
            .expect_err("Ed25519 is not advertised");

        assert_eq!(error.to_string(), "the keystore cannot sign with ED25519");
    }

    #[test]
    fn rejects_an_identity_that_mixes_key_algorithms() {
        let error = PlatformKey::new(Arc::new(StubIdentity {
            schemes: Ok(vec![
                TlsSignatureScheme::RsaPssSha256,
                TlsSignatureScheme::EcdsaNistp256Sha256,
            ]),
        }))
        .expect_err("a key cannot be RSA and ECDSA at once");

        assert_eq!(
            error.to_string(),
            "The client identity mixes signature schemes of different key algorithms"
        );
    }

    #[test]
    fn reports_a_keystore_that_cannot_list_its_schemes() {
        let error = PlatformKey::new(Arc::new(StubIdentity {
            schemes: Err("the keystore is locked".to_owned()),
        }))
        .expect_err("a locked keystore cannot list its schemes");

        assert_eq!(
            format!("{error:#}"),
            "Failed to read the supported TLS signature schemes: the keystore is locked"
        );
    }

    #[derive(Debug)]
    struct StubIdentity {
        schemes: Result<Vec<TlsSignatureScheme>, String>,
    }

    impl ClientTlsIdentity for StubIdentity {
        fn certificate_chain(&self) -> Result<Vec<Vec<u8>>, CallbackError> {
            Ok(vec![vec![1, 2, 3]])
        }

        fn supported_signature_schemes(&self) -> Result<Vec<TlsSignatureScheme>, CallbackError> {
            self.schemes.clone().map_err(CallbackError::Failed)
        }

        fn sign(
            &self,
            scheme: TlsSignatureScheme,
            message: Vec<u8>,
        ) -> Result<Vec<u8>, CallbackError> {
            if scheme != TlsSignatureScheme::RsaPssSha256 {
                return Err(CallbackError::Failed("the keystore is locked".to_owned()));
            }

            Ok([message.as_slice(), &[0x08, 0x04]].concat())
        }
    }
}

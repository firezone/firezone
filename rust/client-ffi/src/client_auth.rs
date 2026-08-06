use std::{fmt, sync::Arc};

use anyhow::{Context as _, Result, bail};
use rustls::{
    SignatureAlgorithm, SignatureScheme,
    pki_types::CertificateDer,
    sign::{CertifiedKey, Signer, SigningKey},
};

use crate::{ClientTlsIdentity, TlsSignatureScheme};

pub(crate) fn certified_key(identity: Arc<dyn ClientTlsIdentity>) -> Result<Arc<CertifiedKey>> {
    let certificates = identity
        .certificate_chain()
        .context("Failed to read the platform client certificate chain")?;
    if certificates.is_empty() {
        bail!("The platform client certificate chain is empty");
    }

    let signing_key = Arc::new(PlatformSigningKey::new(identity)?);
    let certificates = certificates.into_iter().map(CertificateDer::from).collect();

    Ok(Arc::new(CertifiedKey::new(certificates, signing_key)))
}

#[derive(Debug)]
struct PlatformSigningKey {
    identity: Arc<dyn ClientTlsIdentity>,
    schemes: Vec<TlsSignatureScheme>,
    algorithm: SignatureAlgorithm,
}

impl PlatformSigningKey {
    fn new(identity: Arc<dyn ClientTlsIdentity>) -> Result<Self> {
        let schemes = identity.supported_signature_schemes();
        let Some(first) = schemes.first() else {
            bail!("The platform client certificate key supports no TLS signature schemes");
        };
        let algorithm = first.algorithm();

        if schemes.iter().any(|scheme| scheme.algorithm() != algorithm) {
            bail!("The platform client certificate returned mixed key algorithms");
        }

        Ok(Self {
            identity,
            schemes,
            algorithm,
        })
    }
}

impl SigningKey for PlatformSigningKey {
    fn choose_scheme(&self, offered: &[SignatureScheme]) -> Option<Box<dyn Signer>> {
        self.schemes
            .iter()
            .copied()
            .find(|scheme| offered.contains(&scheme.rustls()))
            .map(|scheme| {
                Box::new(PlatformSigner {
                    identity: self.identity.clone(),
                    scheme,
                }) as Box<dyn Signer>
            })
    }

    fn algorithm(&self) -> SignatureAlgorithm {
        self.algorithm
    }
}

struct PlatformSigner {
    identity: Arc<dyn ClientTlsIdentity>,
    scheme: TlsSignatureScheme,
}

impl fmt::Debug for PlatformSigner {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PlatformSigner")
            .field("scheme", &self.scheme)
            .finish_non_exhaustive()
    }
}

impl Signer for PlatformSigner {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, rustls::Error> {
        self.identity
            .sign(self.scheme, message.to_vec())
            .map_err(|error| {
                rustls::Error::General(format!("Platform TLS signing failed: {error}"))
            })
    }

    fn scheme(&self) -> SignatureScheme {
        self.scheme.rustls()
    }
}

impl TlsSignatureScheme {
    fn rustls(self) -> SignatureScheme {
        match self {
            Self::RsaPkcs1Sha256 => SignatureScheme::RSA_PKCS1_SHA256,
            Self::RsaPkcs1Sha384 => SignatureScheme::RSA_PKCS1_SHA384,
            Self::RsaPkcs1Sha512 => SignatureScheme::RSA_PKCS1_SHA512,
            Self::RsaPssSha256 => SignatureScheme::RSA_PSS_SHA256,
            Self::RsaPssSha384 => SignatureScheme::RSA_PSS_SHA384,
            Self::RsaPssSha512 => SignatureScheme::RSA_PSS_SHA512,
            Self::EcdsaNistp256Sha256 => SignatureScheme::ECDSA_NISTP256_SHA256,
            Self::EcdsaNistp384Sha384 => SignatureScheme::ECDSA_NISTP384_SHA384,
            Self::EcdsaNistp521Sha512 => SignatureScheme::ECDSA_NISTP521_SHA512,
        }
    }

    fn algorithm(self) -> SignatureAlgorithm {
        match self {
            Self::RsaPkcs1Sha256
            | Self::RsaPkcs1Sha384
            | Self::RsaPkcs1Sha512
            | Self::RsaPssSha256
            | Self::RsaPssSha384
            | Self::RsaPssSha512 => SignatureAlgorithm::RSA,
            Self::EcdsaNistp256Sha256 | Self::EcdsaNistp384Sha384 | Self::EcdsaNistp521Sha512 => {
                SignatureAlgorithm::ECDSA
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::CallbackError;

    #[derive(Debug)]
    struct MockIdentity {
        schemes: Vec<TlsSignatureScheme>,
    }

    impl ClientTlsIdentity for MockIdentity {
        fn certificate_chain(&self) -> Result<Vec<Vec<u8>>, CallbackError> {
            Ok(vec![vec![1, 2, 3]])
        }

        fn supported_signature_schemes(&self) -> Vec<TlsSignatureScheme> {
            self.schemes.clone()
        }

        fn sign(
            &self,
            scheme: TlsSignatureScheme,
            mut message: Vec<u8>,
        ) -> Result<Vec<u8>, CallbackError> {
            assert_eq!(scheme, TlsSignatureScheme::RsaPssSha256);
            message.extend_from_slice(&[0x08, 0x04]);
            Ok(message)
        }
    }

    #[test]
    fn chooses_a_mutually_supported_scheme_and_delegates_signing() {
        let certified_key = certified_key(Arc::new(MockIdentity {
            schemes: vec![
                TlsSignatureScheme::RsaPssSha512,
                TlsSignatureScheme::RsaPssSha256,
            ],
        }))
        .expect("mock identity should produce a certified key");

        let signer = certified_key
            .key
            .choose_scheme(&[
                SignatureScheme::ECDSA_NISTP256_SHA256,
                SignatureScheme::RSA_PSS_SHA256,
            ])
            .expect("RSA-PSS SHA-256 should be mutually supported");

        assert_eq!(signer.scheme(), SignatureScheme::RSA_PSS_SHA256);
        assert_eq!(
            signer.sign(&[4, 5]).expect("mock signing should succeed"),
            vec![4, 5, 0x08, 0x04]
        );
    }

    #[test]
    fn rejects_an_empty_certificate_chain() {
        #[derive(Debug)]
        struct EmptyIdentity;

        impl ClientTlsIdentity for EmptyIdentity {
            fn certificate_chain(&self) -> Result<Vec<Vec<u8>>, CallbackError> {
                Ok(Vec::new())
            }

            fn supported_signature_schemes(&self) -> Vec<TlsSignatureScheme> {
                vec![TlsSignatureScheme::EcdsaNistp256Sha256]
            }

            fn sign(
                &self,
                _scheme: TlsSignatureScheme,
                _message: Vec<u8>,
            ) -> Result<Vec<u8>, CallbackError> {
                unreachable!()
            }
        }

        assert!(certified_key(Arc::new(EmptyIdentity)).is_err());
    }
}

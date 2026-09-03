//! Client-side TLS building blocks for authenticating to the portal with an X.509 client certificate.
//!
//! The private key of such a certificate is managed by a platform keystore and is not exportable, so signing is delegated to the keystore through [`PrivateKey`].
//! Adapting that interface to rustls happens here, which keeps the keystore backends and the portal connection unaware of each other.
//! Backends implement [`PrivateKey`]: the Apple clients through UniFFI, Windows through CNG and Linux through PKCS#11.

use std::{fmt, sync::Arc};

use rustls::{
    SignatureAlgorithm, SignatureScheme,
    client::ResolvesClientCert,
    pki_types::CertificateDer,
    sign::{CertifiedKey, Signer, SigningKey, SingleCertAndKey},
};

/// An X.509 client certificate presented to the portal during the TLS handshake.
///
/// Constructing a `phoenix_channel::LoginUrl` with a certificate dials the portal's mTLS endpoint instead of the regular one.
/// This carries the client identity alone: how the portal's own certificate is verified belongs to `phoenix-channel`, so presenting a certificate cannot change it.
#[derive(Debug, Clone)]
pub struct ClientCertificate {
    certified_key: Arc<CertifiedKey>,
    key: Arc<dyn PrivateKey>,
}

impl ClientCertificate {
    /// Builds a client identity from a DER-encoded certificate chain and a platform-held key.
    ///
    /// # Errors
    ///
    /// Returns [`EmptyCertificateChain`] if the chain has no elements; rustls expects the end-entity certificate as its first one.
    pub fn new(
        chain: Vec<CertificateDer<'static>>,
        key: Arc<dyn PrivateKey>,
    ) -> Result<Self, EmptyCertificateChain> {
        if chain.is_empty() {
            return Err(EmptyCertificateChain);
        }

        let certified_key = CertifiedKey::new(chain, Arc::new(PlatformSigningKey(key.clone())));

        Ok(Self {
            certified_key: Arc::new(certified_key),
            key,
        })
    }

    /// Offers this certificate whenever the portal asks for a client identity.
    pub fn resolver(&self) -> Arc<dyn ResolvesClientCert> {
        Arc::new(SingleCertAndKey::from(self.certified_key.clone()))
    }

    /// Whether this identity can authenticate over TLS 1.3.
    ///
    /// A key that signs with none of the schemes TLS 1.3 admits can only present itself over TLS 1.2, so a connection offering it has to negotiate that version.
    pub fn supports_tls13(&self) -> bool {
        self.key
            .supported_schemes()
            .iter()
            .any(|scheme| !REFUSED_BY_TLS13.contains(scheme))
    }
}

/// The signature schemes a TLS 1.3 handshake cannot carry.
///
/// RFC 8446, section 4.2.3 leaves the PKCS#1 v1.5 schemes to certificate signatures and outlaws SHA-1 in handshake signatures altogether.
/// It states the rule as a denylist, so a scheme it does not name is admissible.
const REFUSED_BY_TLS13: &[SignatureScheme] = &[
    SignatureScheme::RSA_PKCS1_SHA1,
    SignatureScheme::RSA_PKCS1_SHA256,
    SignatureScheme::RSA_PKCS1_SHA384,
    SignatureScheme::RSA_PKCS1_SHA512,
    SignatureScheme::ECDSA_SHA1_Legacy,
];

/// A private key that is held by a platform keystore.
///
/// Implementations sign by asking the keystore to do so; the key material itself never becomes available to us.
pub trait PrivateKey: fmt::Debug + Send + Sync {
    /// Returns the TLS signature schemes this key can sign with, most preferred first.
    fn supported_schemes(&self) -> Vec<SignatureScheme>;

    /// Returns the algorithm of this key.
    fn algorithm(&self) -> SignatureAlgorithm;

    /// Signs the unhashed TLS handshake message with the requested scheme.
    ///
    /// # Errors
    ///
    /// Returns a [`SigningError`] if the keystore refuses or fails to sign, or if `scheme` is not one of [`PrivateKey::supported_schemes`].
    fn sign(&self, scheme: SignatureScheme, message: &[u8]) -> Result<Vec<u8>, SigningError>;
}

/// A platform keystore failed to sign a TLS handshake message.
///
/// [`rustls::Error::Other`] carries this error through the TLS stack with its type intact, allowing `phoenix-channel` to downcast it back out.
/// The concrete type is what makes a failed client signature distinguishable from a failed server certificate verification, which rustls reports as [`rustls::Error::General`] or as [`rustls::Error::Other`] depending on the verifier.
///
/// Variants name the cause as the platform reports it, so that the decision of which causes are terminal is made once here rather than separately by each keystore implementation.
#[derive(Debug, thiserror::Error)]
pub enum SigningError {
    /// The keystore no longer holds the private key of the certificate we selected.
    #[error("the keystore no longer holds the private key: {0}")]
    KeyUnavailable(String),
    /// The keystore refused to use the private key, e.g. because a confirmation prompt was declined or we lack permission on the key.
    #[error("the keystore refused to use the private key: {0}")]
    AccessDenied(String),
    /// The keystore cannot produce a signature for the scheme rustls picked.
    #[error("the keystore cannot sign with {0:?}")]
    UnsupportedScheme(SignatureScheme),
    /// The keystore failed to sign for a reason that is neither the key's absence nor a refusal.
    #[error("the keystore failed to sign: {0}")]
    Keystore(String),
}

/// A certificate chain offered as a client identity had no elements.
#[derive(Debug, thiserror::Error)]
#[error("the client certificate chain is empty")]
pub struct EmptyCertificateChain;

#[derive(Debug)]
struct PlatformSigningKey(Arc<dyn PrivateKey>);

impl SigningKey for PlatformSigningKey {
    fn choose_scheme(&self, offered: &[SignatureScheme]) -> Option<Box<dyn Signer>> {
        let scheme = self
            .0
            .supported_schemes()
            .into_iter()
            .find(|scheme| offered.contains(scheme))?;

        Some(Box::new(PlatformSigner {
            key: self.0.clone(),
            scheme,
        }))
    }

    fn algorithm(&self) -> SignatureAlgorithm {
        self.0.algorithm()
    }
}

#[derive(Debug)]
struct PlatformSigner {
    key: Arc<dyn PrivateKey>,
    scheme: SignatureScheme,
}

impl Signer for PlatformSigner {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, rustls::Error> {
        let signature = self
            .key
            .sign(self.scheme, message)
            .map_err(|e| rustls::Error::Other(rustls::OtherError(Arc::new(e))))?;

        Ok(signature)
    }

    fn scheme(&self) -> SignatureScheme {
        self.scheme
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chooses_a_mutually_supported_scheme_and_delegates_signing() {
        let certificate = ClientCertificate::new(
            vec![CertificateDer::from(vec![1, 2, 3])],
            Arc::new(MockKey {
                schemes: vec![
                    SignatureScheme::RSA_PSS_SHA512,
                    SignatureScheme::RSA_PSS_SHA256,
                ],
            }),
        )
        .expect("mock key should produce a client certificate");

        let signer = certificate
            .certified_key
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
        let error = ClientCertificate::new(
            Vec::new(),
            Arc::new(MockKey {
                schemes: vec![SignatureScheme::ECDSA_NISTP256_SHA256],
            }),
        )
        .expect_err("an empty chain should be rejected");

        assert_eq!(error.to_string(), "the client certificate chain is empty");
    }

    #[test]
    fn offers_the_certificate_to_a_server_that_asks_for_one() {
        let certificate = ClientCertificate::new(
            vec![CertificateDer::from(vec![1, 2, 3])],
            Arc::new(MockKey {
                schemes: vec![SignatureScheme::RSA_PSS_SHA256],
            }),
        )
        .expect("mock key should produce a client certificate");

        let resolver = certificate.resolver();

        assert!(resolver.has_certs());
        assert_eq!(
            resolver
                .resolve(&[], &[SignatureScheme::RSA_PSS_SHA256])
                .expect("the certificate should be offered")
                .cert,
            vec![CertificateDer::from(vec![1, 2, 3])]
        );
    }

    #[test]
    fn reports_signing_failures_as_a_downcastable_other_error() {
        let certificate = ClientCertificate::new(
            vec![CertificateDer::from(vec![1, 2, 3])],
            Arc::new(FailingKey),
        )
        .expect("failing key should produce a client certificate");
        let signer = certificate
            .certified_key
            .key
            .choose_scheme(&[SignatureScheme::ECDSA_NISTP256_SHA256])
            .expect("ECDSA NIST P-256 should be mutually supported");

        let error = signer
            .sign(&[4, 5])
            .expect_err("the failing key should not sign");

        let rustls::Error::Other(other) = error else {
            panic!("expected `rustls::Error::Other`, got {error:?}");
        };
        let signing_error = other
            .0
            .downcast_ref::<SigningError>()
            .expect("expected a `SigningError`");
        assert!(
            matches!(signing_error, SigningError::AccessDenied(_)),
            "got {signing_error:?}"
        );
    }

    #[test]
    fn a_key_without_the_pss_schemes_rules_out_tls13() {
        let certificate = ClientCertificate::new(
            vec![CertificateDer::from(vec![1, 2, 3])],
            Arc::new(MockKey {
                schemes: vec![
                    SignatureScheme::RSA_PKCS1_SHA512,
                    SignatureScheme::RSA_PKCS1_SHA384,
                    SignatureScheme::RSA_PKCS1_SHA256,
                ],
            }),
        )
        .expect("mock key should produce a client certificate");

        assert!(!certificate.supports_tls13());
    }

    #[test]
    fn an_rsa_pss_or_ecdsa_key_authenticates_over_tls13() {
        let rsa_pss = ClientCertificate::new(
            vec![CertificateDer::from(vec![1, 2, 3])],
            Arc::new(MockKey {
                schemes: vec![
                    SignatureScheme::RSA_PSS_SHA256,
                    SignatureScheme::RSA_PKCS1_SHA256,
                ],
            }),
        )
        .expect("mock key should produce a client certificate");
        let ecdsa = ClientCertificate::new(
            vec![CertificateDer::from(vec![1, 2, 3])],
            Arc::new(FailingKey),
        )
        .expect("failing key should produce a client certificate");

        assert!(rsa_pss.supports_tls13());
        assert!(ecdsa.supports_tls13());
    }

    #[derive(Debug)]
    struct MockKey {
        schemes: Vec<SignatureScheme>,
    }

    impl PrivateKey for MockKey {
        fn supported_schemes(&self) -> Vec<SignatureScheme> {
            self.schemes.clone()
        }

        fn algorithm(&self) -> SignatureAlgorithm {
            SignatureAlgorithm::RSA
        }

        fn sign(&self, scheme: SignatureScheme, message: &[u8]) -> Result<Vec<u8>, SigningError> {
            assert_eq!(scheme, SignatureScheme::RSA_PSS_SHA256);

            Ok([message, &[0x08, 0x04]].concat())
        }
    }

    #[derive(Debug)]
    struct FailingKey;

    impl PrivateKey for FailingKey {
        fn supported_schemes(&self) -> Vec<SignatureScheme> {
            vec![SignatureScheme::ECDSA_NISTP256_SHA256]
        }

        fn algorithm(&self) -> SignatureAlgorithm {
            SignatureAlgorithm::ECDSA
        }

        fn sign(&self, _: SignatureScheme, _: &[u8]) -> Result<Vec<u8>, SigningError> {
            Err(SigningError::AccessDenied(
                "the user declined the keystore prompt".to_owned(),
            ))
        }
    }
}

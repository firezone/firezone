//! Assembling the TLS configuration for the portal connection.
//!
//! Only a connection that presents a client certificate needs one built here; without a certificate `tokio-tungstenite` builds an equivalent configuration itself.
//! Keeping the assembly in this crate is what stops a client certificate from also deciding how the portal is verified.

use std::sync::Arc;

use x509_credential::ClientCertificate;

/// Builds the TLS configuration that presents `certificate` to the portal.
///
/// The portal is verified against the same roots as a connection that presents no certificate, so offering a client identity cannot change who we trust.
///
/// # Errors
///
/// Returns a [`rustls::Error`] if the crypto provider does not support the protocol versions we ask for.
pub(crate) fn client_config(
    certificate: &ClientCertificate,
) -> Result<Arc<rustls::ClientConfig>, rustls::Error> {
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(protocol_versions(certificate))?
    .with_root_certificates(root_store())
    .with_client_cert_resolver(certificate.resolver());

    Ok(Arc::new(config))
}

/// The TLS versions offered to the portal when presenting `certificate`.
///
/// TLS 1.3 signs the handshake with schemes not every keystore can produce, most notably RSA-PSS with a digest-length salt, which TPM firmware refuses.
/// Such a certificate authenticates over TLS 1.2 alone, so the version it needs follows from the schemes its key advertises.
fn protocol_versions(
    certificate: &ClientCertificate,
) -> &'static [&'static rustls::SupportedProtocolVersion] {
    const TLS12_ONLY: &[&rustls::SupportedProtocolVersion] = &[&rustls::version::TLS12];

    if certificate.supports_tls13() {
        return rustls::DEFAULT_VERSIONS;
    }

    tracing::info!(
        "Offering TLS 1.2 only: the keystore cannot sign a TLS 1.3 handshake with this certificate's key"
    );

    TLS12_ONLY
}

/// The roots bundled with the binary.
#[cfg(not(system_certs))]
fn root_store() -> rustls::RootCertStore {
    rustls::RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    }
}

/// The roots the platform trusts.
#[cfg(system_certs)]
fn root_store() -> rustls::RootCertStore {
    let native = rustls_native_certs::load_native_certs();

    for error in &native.errors {
        tracing::warn!("Failed to load a native root certificate: {error}");
    }

    let mut store = rustls::RootCertStore::empty();
    let (added, ignored) = store.add_parsable_certificates(native.certs);

    tracing::debug!(%added, %ignored, "Loaded native root certificates");

    store
}

#[cfg(test)]
mod tests {
    use rustls::{SignatureAlgorithm, SignatureScheme, pki_types::CertificateDer};
    use x509_credential::{PrivateKey, SigningError};

    use super::*;

    #[test]
    fn a_key_that_cannot_sign_a_tls13_handshake_restricts_the_connection_to_tls12() {
        let certificate = certificate(vec![SignatureScheme::RSA_PKCS1_SHA256]);

        assert_eq!(protocol_versions(&certificate), [&rustls::version::TLS12]);
    }

    #[test]
    fn any_other_key_keeps_the_default_versions() {
        let certificate = certificate(vec![SignatureScheme::RSA_PSS_SHA256]);

        assert_eq!(protocol_versions(&certificate), rustls::DEFAULT_VERSIONS);
    }

    fn certificate(schemes: Vec<SignatureScheme>) -> ClientCertificate {
        ClientCertificate::new(
            vec![CertificateDer::from(vec![1, 2, 3])],
            Arc::new(StubKey { schemes }),
        )
        .expect("a single-element chain should be accepted")
    }

    #[derive(Debug)]
    struct StubKey {
        schemes: Vec<SignatureScheme>,
    }

    impl PrivateKey for StubKey {
        fn supported_schemes(&self) -> Vec<SignatureScheme> {
            self.schemes.clone()
        }

        fn algorithm(&self) -> SignatureAlgorithm {
            SignatureAlgorithm::RSA
        }

        fn sign(&self, _: SignatureScheme, _: &[u8]) -> Result<Vec<u8>, SigningError> {
            unimplemented!("these tests never complete a handshake")
        }
    }
}

//! Assembling the TLS configuration for the portal connection.
//!
//! Only a connection that presents a client certificate needs one built here; without a certificate `tokio-tungstenite` builds an equivalent configuration itself.
//! Keeping the assembly in this crate is what stops a client certificate from also deciding how the portal is verified.

use std::sync::Arc;

use client_tls::ClientCertificate;

/// Builds the TLS configuration that presents `certificate` to the portal.
///
/// The portal is verified against the same roots as a connection that presents no certificate, so offering a client identity cannot change who we trust.
///
/// # Errors
///
/// Returns a [`rustls::Error`] if the crypto provider does not support the default protocol versions.
pub(crate) fn client_config(
    certificate: &ClientCertificate,
) -> Result<Arc<rustls::ClientConfig>, rustls::Error> {
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()?
    .with_root_certificates(root_store())
    .with_client_cert_resolver(certificate.resolver());

    Ok(Arc::new(config))
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

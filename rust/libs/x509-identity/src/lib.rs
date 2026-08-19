//! X.509 device identity certificates for the Firezone clients.
//!
//! For now the crate only reads certificates: [`parse_certificate`] turns DER bytes into
//! [`ParsedCertificate`] plus the label-value rows the clients render on their
//! diagnostics screens. The native identity providers (Windows CNG and Linux PKCS#11)
//! join this crate once that work lands.
//!
//! Nothing here depends on `uniffi`, so the GUI and headless clients can link it
//! directly. `x509-identity-ffi` wraps this crate for the mobile and Apple clients and is
//! the only place the binding types live.

mod policy;

pub use policy::{ParsedCertificate, SigningAlgorithm, parse_certificate};

/// A portal user identity encoded in a managed certificate's URI SANs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserIdentity {
    pub email: String,
    pub account_id: String,
}

/// A label-value pair for the clients' certificate diagnostics screens.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DetailField {
    pub label: String,
    pub value: String,
}

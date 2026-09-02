//! X.509 client identities held by a desktop platform keystore.
//!
//! [`identity`] walks the keystore once and hands out both faces of the selected identity: the
//! [`ClientCertificate`] presented to the portal for device attestation, and its parsed metadata.
//! Loading once and reusing the result keeps the certificate a client presents and the one it
//! describes the same, even when the keystore changes between two reads.
//!
//! Reading certificates and evaluating Firezone's rules for them is `x509-claims`'s job; this
//! crate only talks to the keystores. Private-key material never leaves them: every handshake
//! signature is delegated back to the keystore.

use std::{fmt, sync::Arc};

use rustls::pki_types::CertificateDer;
use serde::{Deserialize, Serialize};
use x509_credential::PrivateKey;

/// Re-exported because [`Identity`] carries a [`ParsedCertificate`]: a caller reading its
/// device claims and rows needs to name their types.
pub use x509_claims::{Claim, DetailField, ParsedCertificate, ValidationError};
/// Re-exported because [`Identity::client_certificate`] hands out a [`ClientCertificate`].
pub use x509_credential::ClientCertificate;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
use linux as keystore;

#[cfg(any(target_os = "linux", target_os = "windows"))]
mod sign;

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
use windows as keystore;

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
mod unsupported;
#[cfg(not(any(target_os = "linux", target_os = "windows")))]
use unsupported as keystore;

/// The subject common name of the certificates Firezone's MDM integrations provision.
const SUBJECT_COMMON_NAME: &str = "dev.firezone.device-trust";

/// The X.509 client identity the platform keystore holds, if any.
///
/// # Errors
///
/// Returns an error whenever the walk fails; which failures a caller tolerates is its policy.
pub fn identity() -> Result<Option<Identity>, Error> {
    keystore::identity(SUBJECT_COMMON_NAME)
}

/// A client identity a keystore backend selected.
pub struct Identity {
    /// The end-entity certificate first, then as many issuers as the keystore could resolve.
    pub(crate) chain: Vec<CertificateDer<'static>>,
    pub(crate) key: Arc<dyn PrivateKey>,
    /// What the end-entity certificate says.
    pub certificate: ParsedCertificate,
}

impl Identity {
    /// The certificate and key to present when connecting.
    ///
    /// Borrows, so a held identity can authenticate any number of connects.
    ///
    /// # Errors
    ///
    /// Returns an error if the keystore handed over a certificate without a chain.
    pub fn client_certificate(&self) -> Result<ClientCertificate, Error> {
        ClientCertificate::new(self.chain.clone(), self.key.clone()).map_err(|_| {
            Error::IdentityUnavailable {
                message: "The keystore returned a certificate without a chain".to_owned(),
            }
        })
    }
}

/// Why the keystore could not hand out an X.509 client identity.
///
/// One enum for every backend, compiled on every platform, including the variants only one
/// backend produces: the clients' mock keystores and the screenshot gallery run wherever they
/// are built, not on the platform whose screen they draw.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub enum Error {
    /// The Windows certificate store could not be read.
    UnreadableStore { store: String, error: String },
    /// No PKCS#11 module is registered, or p11-kit itself is missing, so there is no keystore
    /// to read certificates through.
    ///
    /// The clients recommend p11-kit rather than depend on it, so a machine without it is a
    /// supported installation that has to be told what is missing instead of failing to connect.
    MissingP11Kit,
    /// Every registered PKCS#11 module failed, so the keystore could not be read at all.
    ///
    /// Each entry names one module and what loading or reading it said.
    UnreadablePkcs11Keystore { modules: Vec<String> },
    /// The keystore holds a matching identity it could not hand over, e.g. a token that rejects
    /// its PIN, described in the platform's own words.
    IdentityUnavailable { message: String },
    /// The keystore could not be read, in a client that has only a failure message to go on.
    ///
    /// The GUI reads the keystore over IPC, so a Tunnel service whose read failed in transit
    /// leaves it with an error message rather than with a typed cause.
    UnreadableKeystore { message: String },
}

impl Error {
    /// Wraps a backend failure whose only structure is its message.
    #[cfg(any(target_os = "linux", target_os = "windows"))]
    #[allow(
        dead_code,
        reason = "only the keystore backends wrap failures, and not every build compiles one"
    )]
    pub(crate) fn identity_unavailable(error: anyhow::Error) -> Self {
        Self::IdentityUnavailable {
            message: format!("{error:#}"),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnreadableStore { store, error } => write!(
                formatter,
                "The Windows certificate store {store} could not be read: {error}"
            ),
            Self::MissingP11Kit => formatter.write_str(
                "No PKCS#11 module is registered, or p11-kit is not installed, so no X.509 client identity certificate can be found. Firezone reads certificates through PKCS#11 modules registered with p11-kit. See https://www.firezone.dev/kb/install/linux for what to install.",
            ),
            Self::UnreadablePkcs11Keystore { modules } => write!(
                formatter,
                "The PKCS#11 keystore cannot be read, so no X.509 client identity certificate can be found: {}. See https://www.firezone.dev/kb/install/linux for what the keystore needs installed and running.",
                join(modules, "; ")
            ),
            Self::IdentityUnavailable { message } => formatter.write_str(message),
            Self::UnreadableKeystore { message } => write!(
                formatter,
                "The platform keystore could not be read: {message}"
            ),
        }
    }
}

impl std::error::Error for Error {}

/// What [`selected_certificate`] reads from a backend's certificate.
#[cfg(any(target_os = "linux", target_os = "windows"))]
#[allow(
    dead_code,
    reason = "only the keystore backends rank candidates, and not every build compiles one"
)]
pub(crate) trait CandidateCertificate {
    /// When the certificate's validity begins, as seconds since the Unix epoch.
    fn not_before_timestamp(&self) -> i64;
}

/// Returns the certificate a backend presents as the client identity, as an index into
/// `certificates`.
///
/// The backends only rank certificates they can sign a TLS handshake with; one they cannot is
/// skipped, and logged, before it gets here. The most recently issued certificate wins, so a
/// rotation hands over the renewal rather than the certificate it replaced.
#[cfg(any(target_os = "linux", target_os = "windows"))]
#[allow(
    dead_code,
    reason = "only the keystore backends rank candidates, and not every build compiles one"
)]
pub(crate) fn selected_certificate<C: CandidateCertificate>(certificates: &[C]) -> Option<usize> {
    certificates
        .iter()
        .enumerate()
        .max_by_key(|(_, certificate)| certificate.not_before_timestamp())
        .map(|(index, _)| index)
}

/// Renders `items` on one line, separated by `separator`.
fn join(items: &[impl fmt::Display], separator: &str) -> String {
    items
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(separator)
}

#[cfg(all(test, any(target_os = "linux", target_os = "windows")))]
mod tests {
    use super::*;

    struct Candidate {
        not_before: i64,
    }

    impl CandidateCertificate for Candidate {
        fn not_before_timestamp(&self) -> i64 {
            self.not_before
        }
    }

    #[test]
    fn the_newest_certificate_wins() {
        let certificates = [
            Candidate { not_before: 1 },
            Candidate { not_before: 3 },
            Candidate { not_before: 2 },
        ];

        assert_eq!(selected_certificate(&certificates), Some(1));
        assert_eq!(selected_certificate::<Candidate>(&[]), None);
    }
}

//! X.509 client identities held by a desktop platform keystore.
//!
//! [`certificate`] picks the identity that authenticates the portal connection and hands it to
//! `phoenix-channel` as a [`ClientCertificate`]. [`status`] describes what the keystore holds, so
//! the clients can show enrollment diagnostics without connecting to the portal first.
//!
//! Reading certificates and evaluating Firezone's rules for them is `x509-claims`'s job; this
//! crate only talks to the keystores. Private-key material never leaves them: every handshake
//! signature is delegated back to the keystore.

use std::{fmt, sync::Arc};

use anyhow::{Context as _, Result};
use rustls::pki_types::CertificateDer;
use serde::{Deserialize, Serialize};
use x509_credential::{ClientCertificate, PrivateKey};

/// Re-exported because [`Status`] carries them: a caller matching on one needs to name it.
pub use x509_claims::{RejectionReason, UnusableReason};

#[cfg(any(target_os = "linux", target_os = "windows"))]
mod sign;

mod unsupported;

use unsupported as keystore;

/// The subject common name of the certificates Firezone's MDM integrations provision.
const SUBJECT_COMMON_NAME: &str = "dev.firezone.device-trust";

/// Returns the client certificate for the portal connection, if the keystore holds a usable one.
///
/// # Errors
///
/// Returns an error if the keystore cannot be read at all. A readable keystore that holds no
/// usable identity yields [`None`], because running without mTLS is the normal case.
pub fn certificate() -> Result<Option<ClientCertificate>> {
    let Some(identity) = keystore::identity(SUBJECT_COMMON_NAME)? else {
        return Ok(None);
    };

    let certificate = ClientCertificate::new(identity.chain, identity.key)
        .context("The keystore returned a certificate without a chain")?;

    Ok(Some(certificate))
}

/// Returns what the keystore holds, for the clients' certificate diagnostics screens.
///
/// # Errors
///
/// Returns an error if the keystore cannot be read.
pub fn status() -> Result<Status> {
    let status = keystore::status(SUBJECT_COMMON_NAME)?;

    Ok(status)
}

/// A client identity a keystore backend selected.
pub(crate) struct Identity {
    /// The end-entity certificate first, then as many issuers as the keystore could resolve.
    pub(crate) chain: Vec<CertificateDer<'static>>,
    pub(crate) key: Arc<dyn PrivateKey>,
}

/// What [`selected_certificate`] and [`unusable_certificates`] read from a backend's certificate.
#[cfg(any(target_os = "linux", target_os = "windows"))]
#[allow(
    dead_code,
    reason = "only the keystore backends rank candidates, and not every build compiles one"
)]
pub(crate) trait CandidateCertificate {
    /// Whether the certificate and its private key can authenticate the client.
    fn usable(&self) -> bool;

    /// When the certificate's validity begins, as seconds since the Unix epoch.
    fn not_before_timestamp(&self) -> i64;

    /// Says why this certificate cannot be presented for mutual TLS.
    fn unusable(&self) -> UnusableCertificate;
}

/// Returns the certificate a backend presents as the client identity, as an index into
/// `certificates`.
///
/// The most recently issued usable certificate wins, so a rotation hands over the renewal
/// rather than the certificate it replaced.
#[cfg(any(target_os = "linux", target_os = "windows"))]
#[allow(
    dead_code,
    reason = "only the keystore backends rank candidates, and not every build compiles one"
)]
pub(crate) fn selected_certificate<C: CandidateCertificate>(certificates: &[C]) -> Option<usize> {
    certificates
        .iter()
        .enumerate()
        .filter(|(_, certificate)| certificate.usable())
        .max_by_key(|(_, certificate)| certificate.not_before_timestamp())
        .map(|(index, _)| index)
}

/// Says why each certificate that matched the subject common name cannot be used.
#[cfg(any(target_os = "linux", target_os = "windows"))]
#[allow(
    dead_code,
    reason = "only the keystore backends rank candidates, and not every build compiles one"
)]
pub(crate) fn unusable_certificates<C: CandidateCertificate>(
    certificates: &[C],
) -> Vec<UnusableCertificate> {
    certificates
        .iter()
        .filter(|certificate| !certificate.usable())
        .map(C::unusable)
        .collect()
}

/// Read-only diagnostics about the keystore's X.509 identities.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Status {
    /// What keeps a client identity from being used, if anything.
    ///
    /// A status without a problem reports a usable identity: the certificate it describes says
    /// the rest, so there is no all-good text to repeat. Backends report the problems they found
    /// separately rather than as one sentence, because a keystore can hold both an unusable
    /// certificate and a part it could not read at all.
    pub problems: Vec<Problem>,
    pub sections: Vec<DetailSection>,
}

/// What keeps a keystore from handing out an X.509 client identity.
///
/// Every variant is compiled on every platform, including the ones only one backend produces. A
/// build that can produce none of them still has to render all of them: the clients' mock
/// keystores and the screenshot gallery run wherever they are built, not on the platform whose
/// screen they draw.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub enum Problem {
    /// No certificate in the Windows certificate stores carries the subject common name.
    NoWindowsCertificate { subject_cn: String },
    /// The Windows certificate stores carry matching certificates, none of them usable.
    NoUsableWindowsCertificate {
        certificates: Vec<UnusableCertificate>,
    },
    /// Some of the Windows certificate stores could not be read.
    UnreadableWindowsStores { stores: Vec<UnreadableStore> },
    /// No PKCS#11 token holds a certificate carrying the subject common name.
    NoPkcs11Certificate { subject_cn: String },
    /// A PKCS#11 token holds matching certificates, none of them usable.
    NoUsablePkcs11Certificate {
        certificates: Vec<UnusableCertificate>,
    },
    /// Every registered PKCS#11 module failed, so the keystore could not be read at all.
    UnreadablePkcs11Keystore,
    /// The keystore could not be read, in a client that has only the failure to go on.
    ///
    /// The GUI reads the keystore over IPC, so a Tunnel service that failed leaves it with an
    /// error message rather than with the backend's own account of what went wrong.
    UnreadableKeystore,
    /// A package the keystore reads certificates through is not installed.
    MissingPackage { package: Package },
    /// The platform has no keystore backend.
    UnsupportedPlatform,
}

/// A package a keystore reads certificates through.
///
/// The clients recommend these rather than depend on them, so a machine without one is a
/// supported installation that has to be told what is missing instead of failing to connect.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
pub enum Package {
    /// p11-kit, whose registry names the PKCS#11 modules a machine has.
    P11Kit,
}

/// A certificate that carries the subject common name and cannot authenticate the client.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct UnusableCertificate {
    /// The SHA-256 fingerprint, which is how the diagnostics name a certificate.
    pub fingerprint: String,
    pub cause: UnusableCause,
}

/// What keeps one matching certificate from being presented for mutual TLS.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub enum UnusableCause {
    /// The rules the certificate itself fails, at least one of them.
    FailsRules { reasons: Vec<UnusableReason> },
    /// CNG will not use the certificate's private key, as for a key a legacy CSP holds.
    WindowsKeyRefused { error: String },
    /// Windows holds no private key for the certificate.
    WindowsKeyMissing,
    /// The PKCS#11 token holds no private key for the certificate.
    Pkcs11KeyMissing,
}

/// A certificate store a keystore could not read.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct UnreadableStore {
    /// The store's name, e.g. `LocalMachine\My`.
    pub store: String,
    /// What the platform said when it turned the store down.
    pub error: String,
}

/// A group of related diagnostic rows, e.g. one certificate.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct DetailSection {
    pub title: String,
    pub fields: Vec<DetailField>,
}

/// A label-value row of the diagnostics.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct DetailField {
    pub label: String,
    pub value: FieldValue,
}

/// What the keystore knows about one row.
///
/// A keystore that could not produce a row hands on whatever the platform said about it, because
/// a platform refusal has no closed set of rules behind it the way a [`RejectionReason`] has.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub enum FieldValue {
    Present(String),
    Absent,
    /// The certificate carries a value the parser will not attest.
    Rejected(RejectionReason),
    /// The keystore could not produce the row, in the platform's own words.
    Failed(String),
}

impl FieldValue {
    /// The text a caller with nowhere to show a state renders instead.
    pub fn text(&self) -> &str {
        match self {
            Self::Present(value) => value,
            Self::Absent => "Not present",
            Self::Rejected(reason) => reason.label(),
            Self::Failed(message) => message,
        }
    }
}

impl Status {
    /// Renders the diagnostics as indented plain text for terminal output.
    pub fn text_description(&self) -> String {
        use std::fmt::Write as _;

        let mut output = String::new();

        if !self.problems.is_empty() {
            let _ = writeln!(output, "{}", join(&self.problems, " "));
        }

        for section in &self.sections {
            if !output.is_empty() {
                output.push('\n');
            }
            let _ = writeln!(output, "[{}]", section.title);

            for field in &section.fields {
                let _ = writeln!(output, "{}:", field.label);

                for line in field.value.text().split('\n') {
                    let _ = writeln!(output, "  {line}");
                }
            }
        }

        output
    }
}

impl fmt::Display for Problem {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoWindowsCertificate { subject_cn } => write!(
                formatter,
                "No X.509 certificate with subject CN '{subject_cn}' is in the Windows certificate stores."
            ),
            Self::NoUsableWindowsCertificate { certificates } => write!(
                formatter,
                "Matching certificates are in the Windows certificate store, but none is usable as a client identity: {}",
                join(certificates, "; ")
            ),
            Self::UnreadableWindowsStores { stores } => write!(
                formatter,
                "Some Windows certificate stores could not be read: {}",
                join(stores, "; ")
            ),
            Self::NoPkcs11Certificate { subject_cn } => write!(
                formatter,
                "No PKCS#11 token holds an X.509 certificate with subject CN '{subject_cn}'."
            ),
            Self::NoUsablePkcs11Certificate { certificates } => write!(
                formatter,
                "Matching certificates were found, but none is usable as a client identity: {}",
                join(certificates, "; ")
            ),
            Self::UnreadablePkcs11Keystore => formatter.write_str(
                "The PKCS#11 keystore cannot be read, so no X.509 client identity certificate can be found. See https://www.firezone.dev/kb/reference/device-certificates for what the keystore needs installed and running.",
            ),
            Self::UnreadableKeystore => formatter.write_str(
                "The platform keystore could not be read, so no X.509 client identity certificate can be found.",
            ),
            Self::MissingPackage { package } => formatter.write_str(package.missing_description()),
            Self::UnsupportedPlatform => {
                formatter.write_str("This platform has no X.509 keystore backend.")
            }
        }
    }
}

impl Package {
    /// What a machine without this package cannot do, and where to read what to install.
    ///
    /// Every package says this for itself: what its absence costs is particular to the package,
    /// and a sentence general enough to cover all of them would tell an administrator nothing.
    fn missing_description(self) -> &'static str {
        match self {
            Self::P11Kit => {
                "No PKCS#11 module is registered, so no X.509 client identity certificate can be found. Firezone reads certificates through PKCS#11 modules registered with p11-kit. See https://www.firezone.dev/kb/reference/device-certificates for what to install."
            }
        }
    }
}

impl fmt::Display for UnusableCertificate {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let Self { fingerprint, cause } = self;

        match cause {
            UnusableCause::FailsRules { reasons } => {
                let reasons = reasons
                    .iter()
                    .map(|reason| reason.label())
                    .collect::<Vec<_>>()
                    .join(", ");

                write!(formatter, "{fingerprint} is unusable: {reasons}")
            }
            UnusableCause::WindowsKeyRefused { error } => write!(
                formatter,
                "{fingerprint} has a private key CNG will not use: {error}"
            ),
            UnusableCause::WindowsKeyMissing => {
                write!(formatter, "{fingerprint} has no usable private key")
            }
            UnusableCause::Pkcs11KeyMissing => write!(
                formatter,
                "{fingerprint} is unusable: the token holds no private key for it"
            ),
        }
    }
}

impl fmt::Display for UnreadableStore {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let Self { store, error } = self;

        write!(formatter, "{store}: {error}")
    }
}

/// Renders `items` on one line, separated by `separator`.
fn join(items: &[impl fmt::Display], separator: &str) -> String {
    items
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(separator)
}

pub(crate) fn field(label: impl Into<String>, value: impl Into<String>) -> DetailField {
    DetailField {
        label: label.into(),
        value: FieldValue::Present(value.into()),
    }
}

/// A row for something the keystore looked for and did not find.
#[cfg(any(target_os = "linux", target_os = "windows"))]
#[allow(
    dead_code,
    reason = "only the keystore backends build these rows, and not every build compiles one"
)]
pub(crate) fn absent_field(label: impl Into<String>) -> DetailField {
    DetailField {
        label: label.into(),
        value: FieldValue::Absent,
    }
}

/// A row the keystore could not fill, carrying what the platform said about it.
#[cfg(any(target_os = "linux", target_os = "windows"))]
#[allow(
    dead_code,
    reason = "only the keystore backends build these rows, and not every build compiles one"
)]
pub(crate) fn failed_field(label: impl Into<String>, message: impl Into<String>) -> DetailField {
    DetailField {
        label: label.into(),
        value: FieldValue::Failed(message.into()),
    }
}

impl From<x509_claims::DetailField> for DetailField {
    fn from(field: x509_claims::DetailField) -> Self {
        Self {
            label: field.label,
            value: field.value.into(),
        }
    }
}

impl From<x509_claims::ClaimValue> for FieldValue {
    fn from(value: x509_claims::ClaimValue) -> Self {
        match value {
            x509_claims::ClaimValue::Present { value } => Self::Present(value),
            x509_claims::ClaimValue::Absent => Self::Absent,
            x509_claims::ClaimValue::Invalid { reason } => Self::Rejected(reason),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_sections_as_indented_text() {
        let sections = vec![DetailSection {
            title: "Certificate".to_owned(),
            fields: vec![field("Subject", "CN=one\nOU=two")],
        }];
        let with_problem = Status {
            problems: vec![Problem::UnsupportedPlatform],
            sections: sections.clone(),
        };
        let without_problem = Status {
            problems: Vec::new(),
            sections,
        };

        assert_eq!(
            with_problem.text_description(),
            "This platform has no X.509 keystore backend.\n\n[Certificate]\nSubject:\n  CN=one\n  OU=two\n"
        );
        assert_eq!(
            without_problem.text_description(),
            "[Certificate]\nSubject:\n  CN=one\n  OU=two\n"
        );
    }

    #[test]
    fn every_problem_reads_in_one_warning() {
        let status = Status {
            problems: vec![
                Problem::NoWindowsCertificate {
                    subject_cn: SUBJECT_COMMON_NAME.to_owned(),
                },
                Problem::UnreadableWindowsStores {
                    stores: vec![UnreadableStore {
                        store: "LocalMachine\\My".to_owned(),
                        error: "CertOpenStore failed".to_owned(),
                    }],
                },
            ],
            sections: Vec::new(),
        };

        assert_eq!(
            status.text_description(),
            "No X.509 certificate with subject CN 'dev.firezone.device-trust' is in the Windows certificate stores. Some Windows certificate stores could not be read: LocalMachine\\My: CertOpenStore failed\n"
        );
    }

    #[test]
    fn an_unusable_certificate_names_every_rule_it_fails() {
        let certificate = UnusableCertificate {
            fingerprint: "AA:BB".to_owned(),
            cause: UnusableCause::FailsRules {
                reasons: vec![
                    UnusableReason::NoClientAuthEku,
                    UnusableReason::OutsideValidityPeriod,
                ],
            },
        };

        assert_eq!(
            certificate.to_string(),
            "AA:BB is unusable: no TLS client authentication extended key usage, expired or not yet valid"
        );
    }

    #[cfg(any(target_os = "linux", target_os = "windows"))]
    #[test]
    fn the_newest_usable_certificate_wins() {
        struct Candidate {
            usable: bool,
            not_before: i64,
        }

        impl CandidateCertificate for Candidate {
            fn usable(&self) -> bool {
                self.usable
            }

            fn not_before_timestamp(&self) -> i64 {
                self.not_before
            }

            fn unusable(&self) -> UnusableCertificate {
                UnusableCertificate {
                    fingerprint: self.not_before.to_string(),
                    cause: UnusableCause::FailsRules {
                        reasons: vec![UnusableReason::OutsideValidityPeriod],
                    },
                }
            }
        }

        let certificates = [
            Candidate {
                usable: true,
                not_before: 1,
            },
            Candidate {
                usable: false,
                not_before: 3,
            },
            Candidate {
                usable: true,
                not_before: 2,
            },
        ];

        assert_eq!(selected_certificate(&certificates), Some(2));
        assert_eq!(
            unusable_certificates(&certificates)
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>(),
            ["3 is unusable: expired or not yet valid"]
        );
        assert_eq!(selected_certificate::<Candidate>(&[]), None);
    }
}

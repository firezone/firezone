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

/// Re-exported because [`Status`] carries it: a caller matching on one needs to name it.
pub use x509_claims::{Identity as ClientIdentity, ValidationError};

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

/// Returns the client certificate for the portal connection, if the keystore holds a usable one.
///
/// # Errors
///
/// Returns an error if the keystore holds a matching identity that cannot be used, e.g. a token
/// that rejects its PIN. A keystore that holds no usable identity yields [`None`], because
/// running without mTLS is the normal case; on Linux an unreadable PKCS#11 keystore counts as
/// holding none, so a broken module cannot keep the client from connecting.
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
/// Returns an error if the keystore cannot describe a matching identity it holds. On Linux an
/// unreadable PKCS#11 keystore is itself described, as a [`Status`] whose problems name what
/// failed.
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

/// What [`certificate_sections`] and [`selected_certificate`] read from a backend's certificate.
#[cfg(any(target_os = "linux", target_os = "windows"))]
#[allow(
    dead_code,
    reason = "only the keystore backends rank candidates, and not every build compiles one"
)]
pub(crate) trait CandidateCertificate {
    /// Says why we cannot sign a TLS handshake with the certificate's private key, [`None`]
    /// when we can.
    ///
    /// Whether the portal accepts the certificate is the portal's to decide, so only what stops
    /// us signing with it belongs in this answer.
    fn unusable(&self) -> Option<UnusableCause>;

    /// When the certificate's validity begins, as seconds since the Unix epoch.
    fn not_before_timestamp(&self) -> i64;

    /// The rows describing the certificate, as the backend read it.
    fn detail_fields(&self) -> Vec<DetailField>;
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
        .filter(|(_, certificate)| certificate.unusable().is_none())
        .max_by_key(|(_, certificate)| certificate.not_before_timestamp())
        .map(|(index, _)| index)
}

/// Says why each certificate that matched the subject common name cannot be used.
#[cfg(any(target_os = "linux", target_os = "windows"))]
#[allow(
    dead_code,
    reason = "only the keystore backends rank candidates, and not every build compiles one"
)]
pub(crate) fn unusable_causes<C: CandidateCertificate>(certificates: &[C]) -> Vec<UnusableCause> {
    certificates.iter().filter_map(C::unusable).collect()
}

/// Describes every certificate a backend found, starting with the one it presents.
///
/// A certificate we could read is described whatever is wrong with it, and what is wrong reads as
/// a row of its own section rather than as a warning about the keystore: the keystore did find it.
#[cfg(any(target_os = "linux", target_os = "windows"))]
#[allow(
    dead_code,
    reason = "only the keystore backends rank candidates, and not every build compiles one"
)]
pub(crate) fn certificate_sections<C: CandidateCertificate>(
    certificates: &[C],
    selected: Option<usize>,
) -> Vec<DetailSection> {
    let mut order = (0..certificates.len()).collect::<Vec<_>>();
    order.sort_by_key(|index| Some(*index) != selected);

    order
        .into_iter()
        .map(|index| {
            let certificate = &certificates[index];
            let unusable = certificate.unusable().map(|cause| DetailField {
                // No X.509 attribute says whether we hold a key we can sign with, so the row
                // names what the keystore looked for.
                label: "Private Key".to_owned(),
                value: None,
                problem: Some(FieldProblem::Unusable(cause)),
            });

            DetailSection {
                title: "Certificate".to_owned(),
                fields: unusable
                    .into_iter()
                    .chain(certificate.detail_fields())
                    .collect(),
            }
        })
        .collect()
}

/// Read-only diagnostics about the keystore's X.509 identities.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Status {
    /// What the keystore could not do, if anything.
    ///
    /// A problem describes the keystore, never a certificate we managed to read: what is wrong
    /// with one of those reads as a row of its own section. Backends report the problems they
    /// found separately rather than as one sentence, because a keystore can hold both a part it
    /// could not read and a part that holds nothing for us.
    pub problems: Vec<Problem>,
    pub sections: Vec<DetailSection>,
    /// Who the certificate the keystore would present says is connecting.
    ///
    /// The clients read this to decide whether to offer signing in with a token, so it comes
    /// from the same read that describes the certificate rather than from a second one.
    pub identity: ClientIdentity,
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
    /// Some of the Windows certificate stores could not be read.
    UnreadableWindowsStores { stores: Vec<UnreadableStore> },
    /// No PKCS#11 token holds a certificate carrying the subject common name.
    NoPkcs11Certificate { subject_cn: String },
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

/// What keeps one matching certificate from being presented for mutual TLS.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub enum UnusableCause {
    /// Nothing we can sign a TLS handshake with holds the certificate's key algorithm.
    UnsupportedKeyAlgorithm,
    /// The keystore will not use the certificate's private key, as for a key a legacy CSP holds.
    KeyRefused { error: String },
    /// The keystore holds no private key for the certificate.
    KeyMissing,
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

/// A label-value row of the diagnostics, and what is wrong with it.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct DetailField {
    pub label: String,
    /// What the row carries, [`None`] when it carries nothing.
    pub value: Option<String>,
    /// What is wrong with the value, [`None`] when nothing is.
    pub problem: Option<FieldProblem>,
}

/// What is wrong with one row of the diagnostics.
///
/// A keystore that could not produce a row hands on whatever the platform said about it, because
/// a platform refusal has no closed set of rules behind it the way the parser's problems have.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub enum FieldProblem {
    /// The certificate carries a value that is not usable as what the row names.
    Invalid(ValidationError),
    /// The keystore could not read the row, in the platform's own words.
    Unreadable(String),
    /// The row says why the certificate cannot be presented for mutual TLS.
    Unusable(UnusableCause),
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

                for line in field.value.as_deref().unwrap_or("Not present").split('\n') {
                    let _ = writeln!(output, "  {line}");
                }

                if let Some(problem) = &field.problem {
                    let _ = writeln!(output, "  ({problem})");
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
            Self::UnreadableWindowsStores { stores } => write!(
                formatter,
                "Some Windows certificate stores could not be read: {}",
                join(stores, "; ")
            ),
            Self::NoPkcs11Certificate { subject_cn } => write!(
                formatter,
                "No PKCS#11 token holds an X.509 certificate with subject CN '{subject_cn}'."
            ),
            Self::UnreadablePkcs11Keystore => formatter.write_str(
                "The PKCS#11 keystore cannot be read, so no X.509 client identity certificate can be found. See https://www.firezone.dev/kb/install/linux#device-certificates for what the keystore needs installed and running.",
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
                "No PKCS#11 module is registered, so no X.509 client identity certificate can be found. Firezone reads certificates through PKCS#11 modules registered with p11-kit. See https://www.firezone.dev/kb/install/linux#device-certificates for what to install."
            }
        }
    }
}

impl fmt::Display for UnusableCause {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedKeyAlgorithm => {
                formatter.write_str("we cannot sign with this certificate's key algorithm")
            }
            Self::KeyRefused { error } => {
                write!(
                    formatter,
                    "the keystore would not hand over the private key: {error}"
                )
            }
            Self::KeyMissing => {
                formatter.write_str("the keystore holds no private key for this certificate")
            }
        }
    }
}

impl fmt::Display for FieldProblem {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Invalid(error) => formatter.write_str(error.label()),
            Self::Unreadable(message) => formatter.write_str(message),
            Self::Unusable(cause) => cause.fmt(formatter),
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

#[cfg_attr(
    all(windows, not(test)),
    expect(dead_code, reason = "Windows renders only error rows")
)]
pub(crate) fn field(label: impl Into<String>, value: impl Into<String>) -> DetailField {
    DetailField {
        label: label.into(),
        value: Some(value.into()),
        problem: None,
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
        value: None,
        problem: None,
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
        value: None,
        problem: Some(FieldProblem::Unreadable(message.into())),
    }
}

impl From<x509_claims::DetailField> for DetailField {
    fn from(field: x509_claims::DetailField) -> Self {
        Self {
            label: field.label,
            value: field.value,
            problem: field.problem.map(FieldProblem::Invalid),
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
            identity: ClientIdentity::Absent,
        };
        let without_problem = Status {
            problems: Vec::new(),
            sections,
            identity: ClientIdentity::Absent,
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
    fn a_rows_problem_reads_underneath_its_value() {
        let status = Status {
            problems: Vec::new(),
            sections: vec![DetailSection {
                title: "Certificate".to_owned(),
                fields: vec![
                    DetailField {
                        label: "Account ID".to_owned(),
                        value: Some("not-a-uuid".to_owned()),
                        problem: Some(FieldProblem::Invalid(ValidationError::NotAUuid)),
                    },
                    DetailField {
                        label: "Serial Number".to_owned(),
                        value: None,
                        problem: Some(FieldProblem::Unreadable(
                            "CertGetNameString failed".to_owned(),
                        )),
                    },
                ],
            }],
            identity: ClientIdentity::Absent,
        };

        assert_eq!(
            status.text_description(),
            "[Certificate]\nAccount ID:\n  not-a-uuid\n  (not a UUID)\nSerial Number:\n  Not present\n  (CertGetNameString failed)\n"
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
            identity: ClientIdentity::Absent,
        };

        assert_eq!(
            status.text_description(),
            "No X.509 certificate with subject CN 'dev.firezone.device-trust' is in the Windows certificate stores. Some Windows certificate stores could not be read: LocalMachine\\My: CertOpenStore failed\n"
        );
    }

    #[cfg(any(target_os = "linux", target_os = "windows"))]
    struct Candidate {
        unusable: Option<UnusableCause>,
        not_before: i64,
    }

    #[cfg(any(target_os = "linux", target_os = "windows"))]
    impl CandidateCertificate for Candidate {
        fn unusable(&self) -> Option<UnusableCause> {
            self.unusable.clone()
        }

        fn not_before_timestamp(&self) -> i64 {
            self.not_before
        }

        fn detail_fields(&self) -> Vec<DetailField> {
            vec![field("Not Before", self.not_before.to_string())]
        }
    }

    #[cfg(any(target_os = "linux", target_os = "windows"))]
    #[test]
    fn the_newest_usable_certificate_wins() {
        let certificates = [
            Candidate {
                unusable: None,
                not_before: 1,
            },
            Candidate {
                unusable: Some(UnusableCause::KeyMissing),
                not_before: 3,
            },
            Candidate {
                unusable: None,
                not_before: 2,
            },
        ];

        assert_eq!(selected_certificate(&certificates), Some(2));
        assert_eq!(unusable_causes(&certificates), [UnusableCause::KeyMissing]);
        assert_eq!(selected_certificate::<Candidate>(&[]), None);
    }

    #[cfg(any(target_os = "linux", target_os = "windows"))]
    #[test]
    fn a_certificate_we_cannot_present_says_why_in_its_own_section() {
        let certificates = [
            Candidate {
                unusable: Some(UnusableCause::KeyMissing),
                not_before: 3,
            },
            Candidate {
                unusable: None,
                not_before: 2,
            },
        ];
        let status = Status {
            problems: Vec::new(),
            sections: certificate_sections(&certificates, selected_certificate(&certificates)),
            identity: ClientIdentity::Absent,
        };

        assert_eq!(
            status.text_description(),
            "[Certificate]\nNot Before:\n  2\n\n[Certificate]\nPrivate Key:\n  Not present\n  (the keystore holds no private key for this certificate)\nNot Before:\n  3\n"
        );
    }
}

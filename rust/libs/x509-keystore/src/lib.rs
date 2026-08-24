//! X.509 client identities held by a desktop platform keystore.
//!
//! [`certificate`] picks the identity that authenticates the portal connection and hands it to
//! `phoenix-channel` as a [`ClientCertificate`]. [`status`] describes what the keystore holds, so
//! the clients can show enrollment diagnostics without connecting to the portal first.
//!
//! Reading certificates and evaluating Firezone's rules for them is `x509-claims`'s job; this
//! crate only talks to the keystores. Private-key material never leaves them: every handshake
//! signature is delegated back to the keystore.

use std::sync::Arc;

use anyhow::{Context as _, Result};
use rustls::pki_types::CertificateDer;
use serde::{Deserialize, Serialize};
use x509_credential::{ClientCertificate, PrivateKey};

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

/// Read-only diagnostics about the keystore's X.509 identities.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Status {
    pub severity: StatusSeverity,
    pub summary: String,
    pub sections: Vec<DetailSection>,
}

/// Whether a [`Status`] reports a usable client identity or a problem to fix.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
pub enum StatusSeverity {
    Ok,
    Warning,
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
/// A platform refusal is a free-form message rather than one of the parser's rules, so this
/// carries text where [`x509_claims::ClaimValue`] carries a [`x509_claims::RejectionReason`].
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub enum FieldValue {
    Present(String),
    Absent,
    Invalid(String),
}

impl FieldValue {
    /// The text a caller with nowhere to show a state renders instead.
    pub fn text(&self) -> &str {
        match self {
            Self::Present(value) => value,
            Self::Absent => "Not present",
            Self::Invalid(message) => message,
        }
    }
}

impl Status {
    /// Renders the diagnostics as indented plain text for terminal output.
    pub fn text_description(&self) -> String {
        use std::fmt::Write as _;

        let mut output = self.summary.clone();
        output.push('\n');

        for section in &self.sections {
            output.push('\n');
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
            x509_claims::ClaimValue::Invalid { reason } => Self::Invalid(reason.label().to_owned()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_sections_as_indented_text() {
        let status = Status {
            severity: StatusSeverity::Ok,
            summary: "One identity is available.".to_owned(),
            sections: vec![DetailSection {
                title: "Certificate".to_owned(),
                fields: vec![DetailField {
                    label: "Subject".to_owned(),
                    value: FieldValue::Present("CN=one\nOU=two".to_owned()),
                }],
            }],
        };

        assert_eq!(
            status.text_description(),
            "One identity is available.\n\n[Certificate]\nSubject:\n  CN=one\n  OU=two\n"
        );
    }
}

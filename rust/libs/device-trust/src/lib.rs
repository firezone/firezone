//! Native X.509 device identities for the Windows and Linux clients.
//!
//! Windows identities are discovered in the system certificate stores and used
//! through CNG. Linux identities are configured with an RFC 7512 PKCS#11 URI.
//! Neither backend exports private-key material.

use std::sync::Arc;

use anyhow::{Context as _, Result};
use rustls::sign::{CertifiedKey, SingleCertAndKey};
use rustls_platform_verifier::BuilderVerifierExt as _;
use serde::{Deserialize, Serialize};

pub const DEFAULT_SUBJECT_COMMON_NAME: &str = "dev.firezone.device-trust";

#[cfg(any(target_os = "linux", target_os = "windows", test))]
mod policy;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "windows")]
mod windows;

#[derive(Clone, Default)]
pub struct Config {
    /// RFC 7512 URI identifying the Linux PKCS#11 module, token and identity.
    /// Ignored on Windows.
    pub pkcs11_uri: Option<String>,
}

impl std::fmt::Debug for Config {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Config")
            .field(
                "pkcs11_uri",
                &self.pkcs11_uri.as_ref().map(|_| "[configured]"),
            )
            .finish()
    }
}

/// A selected native identity ready for a mutual-TLS Phoenix connection.
#[derive(Clone)]
pub struct Identity {
    tls_client_config: Arc<rustls::ClientConfig>,
    mdm_device_id: Option<String>,
}

impl std::fmt::Debug for Identity {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Identity")
            .field("mdm_device_id", &self.mdm_device_id)
            .finish_non_exhaustive()
    }
}

impl Identity {
    pub fn tls_client_config(&self) -> Arc<rustls::ClientConfig> {
        self.tls_client_config.clone()
    }

    pub fn mdm_device_id(&self) -> Option<&str> {
        self.mdm_device_id.as_deref()
    }
}

pub(crate) struct PlatformIdentity {
    pub certified_key: Arc<CertifiedKey>,
    pub mdm_device_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct DetailField {
    pub label: String,
    pub value: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct DetailSection {
    pub title: String,
    pub fields: Vec<DetailField>,
}

/// Read-only diagnostics shared by the desktop GUI and headless command.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Status {
    pub summary: String,
    pub sections: Vec<DetailSection>,
}

impl Status {
    pub fn text_description(&self) -> String {
        use std::fmt::Write as _;

        let mut output = self.summary.clone();
        output.push('\n');

        for section in &self.sections {
            output.push('\n');
            let _ = writeln!(output, "[{}]", section.title);
            for field in &section.fields {
                let _ = writeln!(output, "{}:", field.label);
                for line in field.value.split('\n') {
                    let _ = writeln!(output, "  {line}");
                }
            }
        }

        output
    }
}

pub fn status(config: &Config) -> Result<Status> {
    platform::status(config, DEFAULT_SUBJECT_COMMON_NAME)
}

pub fn identity(config: &Config) -> Result<Option<Identity>> {
    let Some(identity) = platform::identity(config, DEFAULT_SUBJECT_COMMON_NAME)? else {
        return Ok(None);
    };
    let resolver = Arc::new(SingleCertAndKey::from(identity.certified_key));
    let config = rustls::ClientConfig::builder()
        .with_platform_verifier()
        .context("Failed to configure the TLS server certificate verifier")?
        .with_client_cert_resolver(resolver);

    Ok(Some(Identity {
        tls_client_config: Arc::new(config),
        mdm_device_id: identity.mdm_device_id,
    }))
}

#[cfg(target_os = "linux")]
use linux as platform;
#[cfg(target_os = "windows")]
use windows as platform;

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
mod platform {
    use super::*;

    #[expect(
        clippy::unnecessary_wraps,
        reason = "Keep the unsupported-platform API identical to the native providers"
    )]
    pub fn status(_config: &Config, _subject_cn: &str) -> Result<Status> {
        Ok(Status {
            summary: "X.509 device identity is not supported on this platform.".to_owned(),
            sections: vec![],
        })
    }

    #[expect(
        clippy::unnecessary_wraps,
        reason = "Keep the unsupported-platform API identical to the native providers"
    )]
    pub fn identity(_config: &Config, _subject_cn: &str) -> Result<Option<PlatformIdentity>> {
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_text_matches_mobile_diagnostic_format() {
        let status = Status {
            summary: "Identity available.".to_owned(),
            sections: vec![DetailSection {
                title: "Certificate".to_owned(),
                fields: vec![DetailField {
                    label: "Subject".to_owned(),
                    value: "CN=one\nOU=two".to_owned(),
                }],
            }],
        };

        assert_eq!(
            status.text_description(),
            "Identity available.\n\n[Certificate]\nSubject:\n  CN=one\n  OU=two\n"
        );
    }
}

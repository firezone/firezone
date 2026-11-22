use std::path::PathBuf;

use crate::{
    controller::ControllerRequest,
    settings::{
        AdvancedSettings, AdvancedSettingsPatch, ControlPlane, GeneralSettings, MdmSettings,
    },
};
use anyhow::{Context as _, Result};
use url::Url;

/// The settings the user changed, [`None`] for those they left alone.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ClientSettingsForm {
    pub start_minimized: Option<bool>,
    pub start_on_login: Option<bool>,
    pub connect_on_start: Option<bool>,
    pub account_slug: Option<String>,
    pub control_plane: Option<ControlPlane>,
    /// Only used for [`ControlPlane::Custom`].
    pub auth_url: Option<String>,
    /// Only used for [`ControlPlane::Custom`].
    pub api_url: Option<String>,
}

impl ClientSettingsForm {
    /// Returns the general settings and the requested advanced settings changes.
    ///
    /// A managed URL wins over the saved one, so the form leaves it alone. Saving with
    /// [`ControlPlane::Custom`] also remembers the URLs for the next time it is picked.
    pub fn apply(
        self,
        mdm_settings: &MdmSettings,
        general_settings: GeneralSettings,
        advanced_settings: AdvancedSettings,
    ) -> Result<(GeneralSettings, AdvancedSettingsPatch)> {
        let control_plane = self.control_plane.unwrap_or_else(|| {
            ControlPlane::from_urls(&advanced_settings.auth_url, &advanced_settings.api_url)
        });
        let (auth_url, api_url) = self.urls(&advanced_settings)?;
        let mut general_settings = general_settings;
        if let Some(start_minimized) = self.start_minimized {
            general_settings.start_minimized = start_minimized;
        }
        if let Some(start_on_login) = self.start_on_login {
            general_settings.start_on_login = Some(start_on_login);
        }
        if let Some(connect_on_start) = self.connect_on_start {
            general_settings.connect_on_start = Some(connect_on_start);
        }
        let selected_cloud = self.control_plane.and_then(ControlPlane::urls).is_some();
        let patch = AdvancedSettingsPatch {
            auth_url: ((self.auth_url.is_some() || selected_cloud)
                && mdm_settings.auth_url.is_none())
            .then_some(auth_url.clone()),
            api_url: ((self.api_url.is_some() || selected_cloud) && mdm_settings.api_url.is_none())
                .then_some(api_url.clone()),
            log_filter: None,
        };
        if let Some(account_slug) = self.account_slug {
            let account_slug = account_slug.trim();
            general_settings.account_slug =
                (!account_slug.is_empty()).then(|| account_slug.to_owned());
        }
        if control_plane == ControlPlane::Custom {
            if self.auth_url.is_some() {
                general_settings.custom_auth_url = Some(auth_url);
            } else {
                general_settings
                    .custom_auth_url
                    .get_or_insert_with(|| advanced_settings.auth_url.clone());
            }
            if self.api_url.is_some() {
                general_settings.custom_api_url = Some(api_url);
            } else {
                general_settings
                    .custom_api_url
                    .get_or_insert_with(|| advanced_settings.api_url.clone());
            }
        } else if ControlPlane::from_urls(&advanced_settings.auth_url, &advanced_settings.api_url)
            == ControlPlane::Custom
        {
            general_settings
                .custom_auth_url
                .get_or_insert_with(|| advanced_settings.auth_url.clone());
            general_settings
                .custom_api_url
                .get_or_insert_with(|| advanced_settings.api_url.clone());
        }

        Ok((general_settings, patch))
    }

    /// Returns the auth and API URLs of the selected control plane, or the typed ones for [`ControlPlane::Custom`].
    pub fn urls(&self, current: &AdvancedSettings) -> Result<(Url, Url)> {
        if let Some(urls) = self.control_plane.and_then(ControlPlane::urls) {
            return Ok(urls);
        }

        Ok((
            parse_url(
                self.auth_url
                    .as_deref()
                    .unwrap_or(current.auth_url.as_str()),
                &["http", "https"],
            )
            .context("Invalid auth URL")?,
            parse_url(
                self.api_url.as_deref().unwrap_or(current.api_url.as_str()),
                &["ws", "wss"],
            )
            .context("Invalid API URL")?,
        ))
    }
}

fn parse_url(value: &str, schemes: &[&str]) -> Result<Url> {
    let url = Url::parse(value)?;

    anyhow::ensure!(url.has_host(), "URL has no host");
    anyhow::ensure!(
        schemes.contains(&url.scheme()),
        "URL scheme must be one of {schemes:?}"
    );

    Ok(url)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionViewModel {
    SignedIn {
        account_slug: String,
        actor_name: String,
    },
    Loading,
    SignedOut,
}

/// A certificate the Tunnel service loaded from the platform keystore.
#[derive(Clone, Debug, PartialEq)]
pub struct X509Certificate {
    pub fields: Vec<X509DetailField>,
}

/// A label-value row of the certificate, and what is wrong with it.
#[derive(Clone, Debug, PartialEq)]
pub struct X509DetailField {
    pub label: String,
    /// What the row carries, [`None`] when it carries nothing.
    pub value: Option<String>,
    /// Why the value is not usable as what the row names, [`None`] when it is.
    pub problem: Option<X509ValidationError>,
}

/// Mirrors [`x509_keystore::ValidationError`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum X509ValidationError {
    Empty,
    TooLong,
    Ambiguous,
    PlaceholderIdentifier,
    UnknownAttribute,
    NotYetValid,
    Expired,
    MissingClientAuthEku,
    DigitalSignatureNotAllowed,
}

impl From<&x509_keystore::ParsedCertificate> for X509Certificate {
    fn from(certificate: &x509_keystore::ParsedCertificate) -> Self {
        Self {
            fields: certificate
                .detail_fields()
                .into_iter()
                .map(X509DetailField::from)
                .collect(),
        }
    }
}

impl From<x509_keystore::DetailField> for X509DetailField {
    fn from(field: x509_keystore::DetailField) -> Self {
        Self {
            label: field.label,
            value: field.value,
            problem: field.problem.map(X509ValidationError::from),
        }
    }
}

impl From<x509_keystore::ValidationError> for X509ValidationError {
    fn from(error: x509_keystore::ValidationError) -> Self {
        match error {
            x509_keystore::ValidationError::Empty => Self::Empty,
            x509_keystore::ValidationError::TooLong => Self::TooLong,
            x509_keystore::ValidationError::Ambiguous => Self::Ambiguous,
            x509_keystore::ValidationError::PlaceholderIdentifier => Self::PlaceholderIdentifier,
            x509_keystore::ValidationError::UnknownAttribute => Self::UnknownAttribute,
            x509_keystore::ValidationError::NotYetValid => Self::NotYetValid,
            x509_keystore::ValidationError::Expired => Self::Expired,
            x509_keystore::ValidationError::MissingClientAuthEku => Self::MissingClientAuthEku,
            x509_keystore::ValidationError::DigitalSignatureNotAllowed => {
                Self::DigitalSignatureNotAllowed
            }
        }
    }
}

/// Returns why `log_filter` is rejected, if it is.
pub(crate) fn check_log_filter(log_filter: &str) -> Result<(), String> {
    logging::try_filter::<tracing_subscriber::Registry>(log_filter)
        .map_err(|e| format!("Invalid log filter: {e}"))?;

    Ok(())
}

/// Asks where to save the exported logs, [`None`] if the user cancels.
pub(crate) async fn pick_log_export() -> Option<ControllerRequest> {
    let now = jiff::Zoned::now();
    let datetime_string = now.strftime("%Y_%m_%d-%H-%M");
    let stem = PathBuf::from(format!("firezone_logs_{datetime_string}"));
    let filename = stem.with_extension("zip");

    let file = rfd::AsyncFileDialog::new()
        .add_filter("Zip", &["zip"])
        .set_file_name(filename.to_string_lossy())
        .save_file()
        .await?;

    Some(ControllerRequest::ExportLogs {
        path: file.path().to_owned(),
        stem,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cloud_control_plane_ignores_the_typed_urls() {
        let form = client_settings_form(
            ControlPlane::CloudEu,
            "not a URL",
            "wss://ignored.example.com",
        );

        let (auth_url, api_url) = form.urls(&AdvancedSettings::default()).unwrap();

        assert_eq!(auth_url.as_str(), "https://eu.app.firezone.dev/");
        assert_eq!(api_url.as_str(), "wss://eu.api.firezone.dev/");
    }

    #[test]
    fn custom_uses_the_typed_urls() {
        let form = client_settings_form(
            ControlPlane::Custom,
            "https://firezone.example.com",
            "wss://api.example.com",
        );

        let (auth_url, api_url) = form.urls(&AdvancedSettings::default()).unwrap();

        assert_eq!(auth_url.as_str(), "https://firezone.example.com/");
        assert_eq!(api_url.as_str(), "wss://api.example.com/");
    }

    #[test]
    fn custom_rejects_an_invalid_url() {
        let form = client_settings_form(ControlPlane::Custom, "not a URL", "wss://api.example.com");

        assert!(form.urls(&AdvancedSettings::default()).is_err());
    }

    #[test]
    fn accepts_a_log_filter_connlib_can_parse() {
        assert!(check_log_filter("info,connlib=debug").is_ok());
        assert!(check_log_filter("").is_ok());
    }

    #[test]
    fn rejects_a_log_filter_connlib_cannot_parse() {
        let message = check_log_filter("info,connlib=nonsense").unwrap_err();

        assert!(message.starts_with("Invalid log filter: "), "{message}");
    }

    #[test]
    fn custom_accepts_local_urls() {
        let form = client_settings_form(
            ControlPlane::Custom,
            "http://localhost:4000",
            "ws://localhost:8081",
        );

        assert!(form.urls(&AdvancedSettings::default()).is_ok());
    }

    #[test]
    fn custom_rejects_a_url_with_the_wrong_scheme() {
        let form = client_settings_form(ControlPlane::Custom, "ftp://x", "wss://api.example.com");

        assert!(form.urls(&AdvancedSettings::default()).is_err());
    }

    #[test]
    fn saving_custom_remembers_the_urls() {
        let form = client_settings_form(
            ControlPlane::Custom,
            "https://firezone.example.com",
            "wss://api.example.com",
        );

        let (general_settings, advanced_settings) = form
            .apply(
                &MdmSettings::default(),
                GeneralSettings::default(),
                AdvancedSettings::default(),
            )
            .unwrap();

        assert_eq!(
            general_settings.custom_auth_url.unwrap().as_str(),
            "https://firezone.example.com/"
        );
        assert_eq!(
            general_settings.custom_api_url.unwrap().as_str(),
            "wss://api.example.com/"
        );
        assert_eq!(
            advanced_settings.auth_url.unwrap().as_str(),
            "https://firezone.example.com/"
        );
    }

    #[test]
    fn switching_an_existing_custom_configuration_to_cloud_remembers_its_urls() {
        let saved = AdvancedSettings {
            auth_url: Url::parse("https://firezone.example.com").unwrap(),
            api_url: Url::parse("wss://api.example.com").unwrap(),
            ..AdvancedSettings::default()
        };
        let form = client_settings_form(ControlPlane::CloudEu, "", "");

        let (general_settings, advanced_settings) = form
            .apply(&MdmSettings::default(), GeneralSettings::default(), saved)
            .unwrap();

        assert_eq!(
            general_settings.custom_auth_url.unwrap().as_str(),
            "https://firezone.example.com/"
        );
        assert_eq!(
            general_settings.custom_api_url.unwrap().as_str(),
            "wss://api.example.com/"
        );
        assert_eq!(
            advanced_settings.auth_url.unwrap().as_str(),
            "https://eu.app.firezone.dev/"
        );
    }

    #[test]
    fn saving_a_cloud_control_plane_keeps_the_remembered_custom_urls() {
        let remembered = GeneralSettings {
            custom_auth_url: Some(Url::parse("https://firezone.example.com").unwrap()),
            custom_api_url: Some(Url::parse("wss://api.example.com").unwrap()),
            ..Default::default()
        };
        let form = client_settings_form(ControlPlane::CloudUs, "", "");

        let (general_settings, advanced_settings) = form
            .apply(
                &MdmSettings::default(),
                remembered,
                AdvancedSettings::default(),
            )
            .unwrap();

        assert_eq!(
            general_settings.custom_auth_url.unwrap().as_str(),
            "https://firezone.example.com/"
        );
        assert_eq!(
            general_settings.custom_api_url.unwrap().as_str(),
            "wss://api.example.com/"
        );
        assert_eq!(
            advanced_settings.auth_url.unwrap().as_str(),
            "https://app.firezone.dev/"
        );
        assert_eq!(
            advanced_settings.api_url.unwrap().as_str(),
            "wss://api.firezone.dev/"
        );
    }

    #[test]
    fn a_managed_url_keeps_the_saved_one() {
        let mdm_settings = MdmSettings {
            auth_url: Some(Url::parse("https://managed.example.com").unwrap()),
            ..Default::default()
        };
        let saved = AdvancedSettings {
            auth_url: Url::parse("https://saved.example.com").unwrap(),
            ..AdvancedSettings::default()
        };
        let form = client_settings_form(ControlPlane::CloudEu, "", "");

        let (_, advanced_settings) = form
            .apply(&mdm_settings, GeneralSettings::default(), saved)
            .unwrap();

        assert!(advanced_settings.auth_url.is_none());
        assert_eq!(
            advanced_settings.api_url.unwrap().as_str(),
            "wss://eu.api.firezone.dev/"
        );
    }

    fn client_settings_form(
        control_plane: ControlPlane,
        auth_url: &str,
        api_url: &str,
    ) -> ClientSettingsForm {
        ClientSettingsForm {
            control_plane: Some(control_plane),
            auth_url: Some(auth_url.to_owned()),
            api_url: Some(api_url.to_owned()),
            ..Default::default()
        }
    }
}

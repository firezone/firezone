use super::MdmSettings;
use anyhow::Result;

pub fn load_mdm_settings() -> Result<MdmSettings> {
    let registry_values = MdmRegistryValues::load_from_registry()?;

    Ok(MdmSettings {
        auth_url: registry_values.authURL.and_then(|url| url.parse().ok()),
        api_url: registry_values.apiURL.and_then(|url| url.parse().ok()),
        log_filter: registry_values.logFilter,
        account_slug: registry_values.accountSlug,
        hide_admin_portal_menu_item: registry_values.hideAdminPortalMenuItem,
        connect_on_start: registry_values.connectOnStart,
        check_for_updates: registry_values.checkForUpdates,
        support_url: registry_values.supportURL.and_then(|url| url.parse().ok()),
    })
}

/// Windows-specific struct for ADMX-backed MDM settings.
#[derive(Clone, Debug)]
#[admx_macro::admx(path = "../website/public/policy-templates/windows/firezone.admx")]
#[expect(non_snake_case, reason = "The values in the ADMX file are camel-case.")]
struct MdmRegistryValues {
    authURL: Option<String>,
    apiURL: Option<String>,
    logFilter: Option<String>,
    accountSlug: Option<String>,
    hideAdminPortalMenuItem: Option<bool>,
    connectOnStart: Option<bool>,
    checkForUpdates: Option<bool>,
    supportURL: Option<String>,
}

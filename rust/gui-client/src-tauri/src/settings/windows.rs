use std::io;

use super::MdmSettings;
use anyhow::{Context, Result};
use url::Url;

const MDM_CONFIG_KEY: &str = r"Software\Policies\Firezone";

pub fn load_mdm_settings() -> Result<MdmSettings> {
    let reg_key = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER)
        .open_subkey(MDM_CONFIG_KEY)
        .context("Failed to open MDM-config key")?;

    let auth_url = reg_key.get_value("authURL");
    let api_url = reg_key.get_value("apiURL");
    let log_filter = reg_key.get_value("logFilter");
    let account_slug = reg_key.get_value("accountSlug");
    let internet_resource_enabled = reg_key.get_value::<u32, _>("internetResourceEnabled");
    let hide_admin_portal_menu_item = reg_key.get_value::<u32, _>("hideAdminPortalMenuItem");
    let connect_on_start = reg_key.get_value("connectOnStart");
    let disable_update_check = reg_key.get_value::<u32, _>("disableUpdateCheck");
    let support_url = reg_key.get_value("supportURL");

    tracing::debug!(?auth_url);
    tracing::debug!(?api_url);
    tracing::debug!(?log_filter);
    tracing::debug!(?account_slug);
    tracing::debug!(?internet_resource_enabled);
    tracing::debug!(?hide_admin_portal_menu_item);
    tracing::debug!(?connect_on_start);
    tracing::debug!(?disable_update_check);
    tracing::debug!(?support_url);

    Ok(MdmSettings {
        auth_url: parse_url(auth_url),
        api_url: parse_url(api_url),
        log_filter: log_filter.ok(),
        account_slug: account_slug.ok(),
        internet_resource_enabled: internet_resource_enabled.ok().map(|_| ()),
        hide_admin_portal_menu_item: hide_admin_portal_menu_item.ok().map(|_| ()),
        connect_on_start: parse_bool(connect_on_start),
        disable_update_check: disable_update_check.ok().map(|_| ()),
        support_url: parse_url(support_url),
    })
}

fn parse_url(result: io::Result<String>) -> Option<Url> {
    result.ok().and_then(|url| url.parse().ok())
}

fn parse_bool(result: io::Result<u32>) -> Option<bool> {
    result.ok().map(|val| val == 1)
}

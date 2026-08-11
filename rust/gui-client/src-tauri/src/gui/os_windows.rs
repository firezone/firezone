use anyhow::{Context, Result};
use std::env;
use windows::{
    Data::Xml::Dom::XmlDocument,
    UI::Notifications::{ToastNotification, ToastNotificationManager},
    core::HSTRING,
};
use winreg::RegKey;
use winreg::enums::*;

pub async fn set_autostart(enabled: bool) -> Result<()> {
    // Get path to the current executable
    let exec_path = env::current_exe().context("Failed to get current executable path")?;
    let exec_path_str = format!("\"{}\"", exec_path.to_string_lossy());

    // Open the registry key for autostart configuration
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let run_key = hkcu
        .open_subkey_with_flags(
            r"Software\Microsoft\Windows\CurrentVersion\Run",
            KEY_READ | KEY_WRITE,
        )
        .context("Failed to open registry key for autostart")?;

    if enabled {
        // Add the application to autostart
        run_key
            .set_value("Firezone", &exec_path_str)
            .context("Failed to add application to autostart registry")?;

        tracing::debug!("Added application to autostart: {}", exec_path_str);
    } else {
        // Remove the application from autostart
        match run_key.delete_value("Firezone") {
            Ok(_) => tracing::debug!("Removed application from autostart"),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                return Err(e).context("Failed to remove application from autostart registry");
            }
        }
    }

    Ok(())
}

/// Show a notification in the bottom right of the screen
pub(crate) fn show_notification(title: String, body: String) -> Result<()> {
    let toast_xml = format!(
        r#"<toast>
    <visual>
        <binding template="ToastGeneric">
            <text id="1">{title}</text>
            <text id="2">{body}</text>
        </binding>
    </visual>
</toast>"#,
        title = xml_escape(&title),
        body = xml_escape(&body),
    );

    show_toast(&toast_xml).context("Failed to show notification")?;

    tracing::debug!(%title, %body, "Showing notification");

    Ok(())
}

/// Show a notification about a new release that opens `download_url` when activated
///
/// The toast declares `activationType="protocol"`, so the shell opens the URL
/// itself. Unlike an in-process activation callback, this also works after the
/// toast has moved into the notification center. `duration="long"` keeps the
/// toast on screen for 25 seconds instead of the default ~6.
pub(crate) fn show_update_notification(title: String, download_url: url::Url) -> Result<()> {
    let toast_xml = format!(
        r#"<toast duration="long" activationType="protocol" launch="{url}">
    <visual>
        <binding template="ToastGeneric">
            <text id="1">{title}</text>
            <text id="2">Click here to download the new version</text>
        </binding>
    </visual>
</toast>"#,
        url = xml_escape(download_url.as_str()),
        title = xml_escape(&title),
    );

    show_toast(&toast_xml).context("Failed to show update notification")?;

    tracing::debug!(%title, %download_url, "Showing update notification");

    Ok(())
}

/// Displays a toast notification from the given [toast content XML].
///
/// [toast content XML]: https://learn.microsoft.com/en-us/uwp/schemas/tiles/toastschema/element-toast
fn show_toast(toast_xml: &str) -> Result<()> {
    let xml = XmlDocument::new()?;
    xml.LoadXml(&HSTRING::from(toast_xml))
        .context("Failed to load toast XML")?;
    let toast =
        ToastNotification::CreateToastNotification(&xml).context("Failed to create toast")?;
    ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(&app_id()))
        .context("Failed to create toast notifier")?
        .Show(&toast)
        .context("Failed to show toast")?;

    Ok(())
}

/// The AppUserModelID Windows attributes our toasts to
///
/// Windows silently drops a toast whose AUMID doesn't match the calling
/// process's identity. Packaged builds run under the sparse MSIX identity, so
/// we register under the package AUMID (`Firezone` is the
/// `<Application Id="Firezone">` from `win_files/AppxManifest.xml`; together
/// with the package family name it forms the AUMID) and the title and icon
/// come from the manifest's `VisualElements`. Un-packaged dev builds (no
/// package identity) fall back to [`crate::BUNDLE_ID`].
/// <https://github.com/tauri-apps/winrt-notification/issues/17#issuecomment-1988715694>
fn app_id() -> String {
    if crate::package_identity::has_package_identity() {
        format!("{}!Firezone", crate::PACKAGE_FAMILY_NAME)
    } else {
        crate::BUNDLE_ID.to_owned()
    }
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

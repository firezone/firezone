use anyhow::{Context as _, Result};
use url::Url;
use windows::{
    Data::Xml::Dom::XmlDocument,
    UI::Notifications::{ToastNotification, ToastNotificationManager},
    core::HSTRING,
};

#[expect(clippy::unused_async, reason = "Signature must match other platforms.")]
pub(crate) async fn show(
    app_id: &str,
    title: &str,
    body: &str,
    open_url: Option<&Url>,
) -> Result<()> {
    let toast_xml = toast_xml(title, body, open_url);

    let xml = XmlDocument::new()?;
    xml.LoadXml(&HSTRING::from(&toast_xml))
        .context("Failed to load toast XML")?;
    let toast =
        ToastNotification::CreateToastNotification(&xml).context("Failed to create toast")?;
    ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(app_id))
        .context("Failed to create toast notifier")?
        .Show(&toast)
        .context("Failed to show toast")?;

    Ok(())
}

/// Renders the [toast content XML] for a notification.
///
/// A clickable toast declares `activationType="protocol"`, so the shell opens
/// the URL itself. Unlike an in-process activation callback, that also works
/// after the toast has moved into the notification center. Such a toast also
/// uses `duration="long"` to stay on screen for 25 seconds instead of the
/// default ~6, giving the user more time to actually click it.
///
/// [toast content XML]: https://learn.microsoft.com/en-us/uwp/schemas/tiles/toastschema/element-toast
fn toast_xml(title: &str, body: &str, open_url: Option<&Url>) -> String {
    let toast_attributes = match open_url {
        Some(url) => format!(
            r#" duration="long" activationType="protocol" launch="{}""#,
            xml_escape(url.as_str())
        ),
        None => String::new(),
    };

    format!(
        r#"<toast{toast_attributes}>
    <visual>
        <binding template="ToastGeneric">
            <text id="1">{title}</text>
            <text id="2">{body}</text>
        </binding>
    </visual>
</toast>"#,
        title = xml_escape(title),
        body = xml_escape(body),
    )
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// AppUserModelID of Windows PowerShell, which is registered on every
    /// Windows installation, so toasts under it are accepted even where our
    /// own identity isn't registered (e.g. in CI).
    const POWERSHELL_APP_ID: &str =
        "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe";

    #[tokio::test]
    async fn shows_toasts_end_to_end() {
        // A plain notification; XML-hostile characters must survive
        // `XmlDocument::LoadXml`, i.e. Windows' own parser.
        show(
            POWERSHELL_APP_ID,
            "Firezone <connected> & \"ready\"",
            "Resource 'R&D' says <hello>",
            None,
        )
        .await
        .unwrap();

        // A clickable notification, with a URL that needs escaping.
        let url = Url::parse("https://www.firezone.dev/dl?arch=x86_64&os=windows").unwrap();
        show(
            POWERSHELL_APP_ID,
            "Firezone 1.99.0 available for download",
            "Click here to download the new version",
            Some(&url),
        )
        .await
        .unwrap();
    }
}

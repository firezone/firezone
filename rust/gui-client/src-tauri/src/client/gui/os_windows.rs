use super::{ControllerRequest, CtlrTx, Error};
use connlib_shared::BUNDLE_ID;

/// Show a notification in the bottom right of the screen
///
/// May say "Windows Powershell" and have the wrong icon in dev mode
/// See <https://github.com/tauri-apps/tauri/issues/3700>
pub(crate) fn show_notification(title: &str, body: &str) -> Result<(), Error> {
    tauri_winrt_notification::Toast::new(BUNDLE_ID)
        .title(title)
        .text1(body)
        .show()
        .map_err(|_| Error::Notification(title.to_string()))?;

    Ok(())
}

/// Show a notification that signals `Controller` when clicked
///
/// May say "Windows Powershell" and have the wrong icon in dev mode
/// See <https://github.com/tauri-apps/tauri/issues/3700>
///
/// Known issue: If the notification times out and goes into the notification center
/// (the little thing that pops up when you click the bell icon), then we may not get the
/// click signal.
///
/// I've seen this reported by people using Powershell, C#, etc., so I think it might
/// be a Windows bug?
/// - <https://superuser.com/questions/1488763/windows-10-notifications-not-activating-the-associated-app-when-clicking-on-it>
/// - <https://stackoverflow.com/questions/65835196/windows-toast-notification-com-not-working>
/// - <https://answers.microsoft.com/en-us/windows/forum/all/notifications-not-activating-the-associated-app/7a3b31b0-3a20-4426-9c88-c6e3f2ac62c6>
///
/// Firefox doesn't have this problem. Maybe they're using a different API.
pub(crate) fn show_clickable_notification(
    title: &str,
    body: &str,
    tx: CtlrTx,
    req: ControllerRequest,
) -> Result<(), Error> {
    // For some reason `on_activated` is FnMut
    let mut req = Some(req);

    tauri_winrt_notification::Toast::new(BUNDLE_ID)
        .title(title)
        .text1(body)
        .scenario(tauri_winrt_notification::Scenario::Reminder)
        .on_activated(move || {
            if let Some(req) = req.take() {
                if let Err(error) = tx.blocking_send(req) {
                    tracing::error!(
                        ?error,
                        "User clicked on notification, but we couldn't tell `Controller`"
                    );
                }
            }
            Ok(())
        })
        .show()
        .map_err(|_| Error::ClickableNotification(title.to_string()))?;
    Ok(())
}

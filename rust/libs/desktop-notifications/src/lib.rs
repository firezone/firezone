#![cfg_attr(test, allow(clippy::unwrap_used))]
#![cfg_attr(test, allow(clippy::unwrap_in_result))]

//! Cross-platform desktop notifications.
//!
//! Notifications are shown natively: as toasts via WinRT on Windows and via
//! the `org.freedesktop.Notifications` D-Bus interface on Linux. macOS only
//! has a stub because the production macOS client is a native app; the stub
//! exists so the Tauri UI can be developed on a Mac.

use anyhow::Result;
use url::Url;

#[cfg(target_os = "linux")]
#[path = "platform/linux.rs"]
mod platform;

#[cfg(target_os = "macos")]
#[path = "platform/macos.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "platform/windows.rs"]
mod platform;

/// Shows a notification.
///
/// `app_id` is the application identity: on Windows, the AppUserModelID that
/// toasts are attributed to (Windows silently drops toasts whose AUMID
/// doesn't match the calling process's identity); on Linux, the application
/// name that some desktops use to group notifications.
///
/// Clicking the notification opens `open_url` (ignored on macOS).
///
/// Resolves once the notification has been handled: on Windows right after
/// hand-off to the toast platform, on Linux once the notification is closed.
/// Callers that don't want to wait for that should spawn the future into a
/// task.
pub async fn show(app_id: &str, title: &str, body: &str, open_url: Option<&Url>) -> Result<()> {
    platform::show(app_id, title, body, open_url).await?;

    Ok(())
}

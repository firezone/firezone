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

/// Shows notifications under a fixed application identity.
#[derive(Clone, Debug)]
pub struct Notifier {
    app_id: String,
}

impl Notifier {
    /// Creates a notifier for the given application identity.
    ///
    /// On Windows, this is the AppUserModelID that toasts are attributed to;
    /// Windows silently drops toasts whose AUMID doesn't match the calling
    /// process's identity. On Linux, it is the application name that some
    /// desktops use to group notifications.
    pub fn new(app_id: impl Into<String>) -> Self {
        Self {
            app_id: app_id.into(),
        }
    }

    /// Shows a notification.
    ///
    /// Activating the notification opens `open_url`; only Windows supports
    /// this, other platforms ignore it.
    ///
    /// Resolves once the notification has been handled: on Windows right
    /// after hand-off to the toast platform, on Linux once the notification
    /// is closed. Callers that don't want to wait for that should spawn the
    /// future into a task.
    pub async fn show(&self, title: &str, body: &str, open_url: Option<&Url>) -> Result<()> {
        platform::show(&self.app_id, title, body, open_url).await?;

        Ok(())
    }
}

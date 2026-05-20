//! `impl GuiIntegration for IcedIntegration` — the bridge between the
//! existing `Controller` and the iced UI.
//!
//! The Controller drives all sign-in / tunnel / settings logic; the iced
//! side is the *view*, receiving state updates via the
//! [`UiUpdate`] enum that this integration pushes into an unbounded
//! channel. Clicks in iced flow the other way as [`ControllerRequest`]
//! values (see `main.rs`).

use std::future::Future;

use anyhow::Result;
use firezone_gui_client::SessionViewModel;
use firezone_gui_client::controller::{GuiIntegration, NotificationHandle};
use firezone_gui_client::gui::system_tray::{self, AppState, Icon};
use firezone_gui_client::logging::FileCount;
use firezone_gui_client::settings::{self, AdvancedSettings, GeneralSettings, MdmSettings};
use tokio::sync::mpsc;

/// Outbound updates from the Controller to the iced UI. Iced subscribes
/// to a `Receiver<UiUpdate>` via `iced::stream::channel` and turns each
/// item into a `Message::Ui(UiUpdate)`.
///
/// Doesn't derive `Debug` because several of the inner Controller
/// types (`GeneralSettings`, `AdvancedSettings`, `system_tray::Icon`,
/// `AppState`, `FileCount`) don't implement it. The iced runtime only
/// requires `Send + 'static` on the message type.
pub enum UiUpdate {
    SessionChanged(SessionViewModel),
    SettingsChanged {
        mdm: MdmSettings,
        general: GeneralSettings,
        advanced: AdvancedSettings,
    },
    LogsRecounted(FileCount),
    TrayIcon(Icon),
    TrayMenu(Box<AppState>),
    SetWindowVisible(bool),
    NavigateOverview(SessionViewModel),
    NavigateSettings {
        mdm: MdmSettings,
        general: GeneralSettings,
        advanced: AdvancedSettings,
    },
    NavigateAbout,
}

/// The iced-side `GuiIntegration`. Cheap to clone — just clones the
/// channel handle.
#[derive(Clone)]
pub struct IcedIntegration {
    tx: mpsc::UnboundedSender<UiUpdate>,
}

impl IcedIntegration {
    pub fn new() -> (Self, mpsc::UnboundedReceiver<UiUpdate>) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Self { tx }, rx)
    }

    fn push(&self, update: UiUpdate) {
        // Channel never closes mid-run — receiver lives for the
        // lifetime of the iced application — so a send error here is
        // a bug, not a runtime condition. Log it just in case.
        if let Err(e) = self.tx.send(update) {
            tracing::warn!("dropping UI update — receiver gone: {e}");
        }
    }
}

impl GuiIntegration for IcedIntegration {
    fn notify_session_changed(&self, session: &SessionViewModel) -> Result<()> {
        self.push(UiUpdate::SessionChanged(session.clone()));
        Ok(())
    }

    fn notify_settings_changed(
        &self,
        mdm: MdmSettings,
        general: GeneralSettings,
        advanced: AdvancedSettings,
    ) -> Result<()> {
        self.push(UiUpdate::SettingsChanged {
            mdm,
            general,
            advanced,
        });
        Ok(())
    }

    fn notify_logs_recounted(&self, file_count: &FileCount) -> Result<()> {
        self.push(UiUpdate::LogsRecounted(file_count.clone()));
        Ok(())
    }

    fn open_url<P: AsRef<str>>(&self, url: P) -> Result<()> {
        let _ = open::that_detached(url.as_ref());
        Ok(())
    }

    fn set_tray_icon(&mut self, icon: system_tray::Icon) {
        self.push(UiUpdate::TrayIcon(icon));
    }

    fn set_tray_menu(&mut self, app_state: system_tray::AppState) {
        self.push(UiUpdate::TrayMenu(Box::new(app_state)));
    }

    fn show_notification(
        &self,
        title: impl Into<String>,
        body: impl Into<String>,
    ) -> Result<NotificationHandle> {
        // notify-rust doesn't talk to the iced runtime, so do it
        // here directly. Click feedback isn't wired yet — we hand
        // back a oneshot receiver that never fires.
        let (_click_tx, on_click) = futures::channel::oneshot::channel();
        #[cfg(target_os = "linux")]
        let _ = notify_rust::Notification::new()
            .summary(&title.into())
            .body(&body.into())
            .show();
        #[cfg(not(target_os = "linux"))]
        {
            let _ = (title, body);
        }
        Ok(NotificationHandle { on_click })
    }

    fn save_general_settings(
        &self,
        settings: &GeneralSettings,
    ) -> impl Future<Output = Result<()>> {
        let s = settings.clone();
        async move { settings::save_general(&s).await }
    }

    fn save_advanced_settings(
        &self,
        settings: &AdvancedSettings,
    ) -> impl Future<Output = Result<()>> {
        let s = settings.clone();
        async move { settings::save_advanced(&s).await }
    }

    fn set_window_visible(&self, visible: bool) -> Result<()> {
        self.push(UiUpdate::SetWindowVisible(visible));
        Ok(())
    }

    fn show_overview_page(&self, session: &SessionViewModel) -> Result<()> {
        self.push(UiUpdate::NavigateOverview(session.clone()));
        Ok(())
    }

    fn show_settings_page(
        &self,
        mdm: MdmSettings,
        general: GeneralSettings,
        advanced: AdvancedSettings,
    ) -> Result<()> {
        self.push(UiUpdate::NavigateSettings {
            mdm,
            general,
            advanced,
        });
        Ok(())
    }

    fn show_about_page(&self) -> Result<()> {
        self.push(UiUpdate::NavigateAbout);
        Ok(())
    }
}

//! `impl GuiIntegration for XilemIntegration` — the bridge between the existing
//! [`Controller`](crate::controller::Controller) and the xilem UI. A direct
//! parallel to [`crate::iced::integration`].
//!
//! The Controller drives all sign-in / tunnel / settings logic; the xilem side
//! is the *view*, receiving state updates via the [`UiUpdate`] enum this
//! integration pushes into an unbounded channel. The bridge `worker` (see
//! `entry.rs`) drains that channel and forwards each item to the app via a
//! `MessageProxy`. UI actions flow the other way as `ControllerRequest`s.

use std::future::Future;

use crate::SessionViewModel;
use crate::controller::{GuiIntegration, NotificationHandle};
use crate::gui::system_tray::{self, AppState, Icon};
use crate::logging::FileCount;
use crate::settings::{self, AdvancedSettings, GeneralSettings, MdmSettings};
use anyhow::Result;
use tokio::sync::mpsc;

/// Outbound updates from the Controller to the xilem UI.
///
/// The bridge `worker` hands each of these to `MessageProxy::message`, whose
/// bound (`AnyDebug = Any + Debug`) forces a `Debug` impl. Several inner
/// Controller types (`GeneralSettings`, `AdvancedSettings`, `Icon`,
/// `AppState`, `FileCount`) don't implement `Debug`, so — like the iced enum —
/// we can't `derive` it; the manual impl below prints variant names only.
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

impl std::fmt::Debug for UiUpdate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let name = match self {
            Self::SessionChanged(_) => "SessionChanged",
            Self::SettingsChanged { .. } => "SettingsChanged",
            Self::LogsRecounted(_) => "LogsRecounted",
            Self::TrayIcon(_) => "TrayIcon",
            Self::TrayMenu(_) => "TrayMenu",
            Self::SetWindowVisible(_) => "SetWindowVisible",
            Self::NavigateOverview(_) => "NavigateOverview",
            Self::NavigateSettings { .. } => "NavigateSettings",
            Self::NavigateAbout => "NavigateAbout",
        };
        f.write_str(name)
    }
}

/// The xilem-side `GuiIntegration`. Cheap to clone — just clones the channel
/// handle.
#[derive(Clone)]
pub struct XilemIntegration {
    tx: mpsc::UnboundedSender<UiUpdate>,
}

impl XilemIntegration {
    pub fn new() -> (Self, mpsc::UnboundedReceiver<UiUpdate>) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Self { tx }, rx)
    }

    fn push(&self, update: UiUpdate) {
        if let Err(e) = self.tx.send(update) {
            tracing::warn!("dropping UI update — receiver gone: {e}");
        }
    }
}

impl GuiIntegration for XilemIntegration {
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
        crate::gui::show_notification(title.into(), body.into())
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

//! Code for the system tray AKA notification area
//!
//! This manages the icon, menu, and tooltip.
//!
//! "Notification Area" is Microsoft's official name instead of "System tray":
//! <https://learn.microsoft.com/en-us/windows/win32/shell/notification-area?redirectedfrom=MSDN#notifications-and-the-notification-area>

use anyhow::Result;
use firezone_gui_client_common::{
    compositor::{self, Image},
    system_tray::{AppState, ConnlibState, Entry, Icon, IconBase, Item, Menu},
};
use tauri::{SystemTray, SystemTrayHandle};

// Figma is the source of truth for the tray icon layers
// <https://www.figma.com/design/THvQQ1QxKlsk47H9DZ2bhN/Core-Library?node-id=1250-772&t=nHBOzOnSY5Ol4asV-0>
const LOGO_BASE: &[u8] = include_bytes!("../../../icons/tray/Logo.png");
const LOGO_GREY_BASE: &[u8] = include_bytes!("../../../icons/tray/Logo grey.png");
const BUSY_LAYER: &[u8] = include_bytes!("../../../icons/tray/Busy layer.png");
const SIGNED_OUT_LAYER: &[u8] = include_bytes!("../../../icons/tray/Signed out layer.png");
const UPDATE_READY_LAYER: &[u8] = include_bytes!("../../../icons/tray/Update ready layer.png");

const TOOLTIP: &str = "Firezone";

pub(crate) fn loading() -> SystemTray {
    let state = AppState {
        connlib: ConnlibState::Loading,
        release: None,
    };
    SystemTray::new()
        .with_icon(icon_to_tauri_icon(&Icon::default()))
        .with_menu(build_app_state(state))
        .with_tooltip(TOOLTIP)
}

pub(crate) struct Tray {
    handle: SystemTrayHandle,
    last_icon_set: Icon,
}

fn icon_to_tauri_icon(that: &Icon) -> tauri::Icon {
    let layers = match that.base {
        IconBase::Busy => &[LOGO_GREY_BASE, BUSY_LAYER][..],
        IconBase::SignedIn => &[LOGO_BASE][..],
        IconBase::SignedOut => &[LOGO_GREY_BASE, SIGNED_OUT_LAYER][..],
    }
    .iter()
    .copied()
    .chain(that.update_ready.then_some(UPDATE_READY_LAYER));
    let composed =
        compositor::compose(layers).expect("PNG decoding should always succeed for baked-in PNGs");
    image_to_tauri_icon(composed)
}

fn image_to_tauri_icon(val: Image) -> tauri::Icon {
    tauri::Icon::Rgba {
        rgba: val.rgba,
        width: val.width,
        height: val.height,
    }
}

/// Generic icon for unusual terminating cases like if the IPC service stops running
pub(crate) fn icon_terminating() -> Icon {
    Icon {
        base: IconBase::SignedOut,
        update_ready: false,
    }
}

impl Tray {
    pub(crate) fn new(handle: SystemTrayHandle) -> Self {
        Self {
            handle,
            last_icon_set: Default::default(),
        }
    }

    pub(crate) fn update(&mut self, state: AppState) -> Result<()> {
        let base = match &state.connlib {
            ConnlibState::Loading
            | ConnlibState::RetryingConnection
            | ConnlibState::WaitingForBrowser
            | ConnlibState::WaitingForPortal
            | ConnlibState::WaitingForTunnel => IconBase::Busy,
            ConnlibState::SignedOut => IconBase::SignedOut,
            ConnlibState::SignedIn { .. } => IconBase::SignedIn,
        };
        let new_icon = Icon {
            base,
            update_ready: state.release.is_some(),
        };

        self.handle.set_tooltip(TOOLTIP)?;
        self.handle.set_menu(build_app_state(state))?;
        self.set_icon(new_icon)?;

        Ok(())
    }

    // Only needed for the stress test
    // Otherwise it would be inlined
    pub(crate) fn set_icon(&mut self, icon: Icon) -> Result<()> {
        if icon != self.last_icon_set {
            // Don't call `set_icon` too often. On Linux it writes a PNG to `/run/user/$UID/tao/tray-icon-*.png` every single time.
            // <https://github.com/tauri-apps/tao/blob/tao-v0.16.7/src/platform_impl/linux/system_tray.rs#L119>
            // Yes, even if you use `Icon::File` and tell Tauri that the icon is already
            // on disk.
            self.handle.set_icon(icon_to_tauri_icon(&icon))?;
            self.last_icon_set = icon;
        }
        Ok(())
    }
}

fn build_app_state(that: AppState) -> tauri::SystemTrayMenu {
    build_menu(&that.into_menu())
}

/// Builds this abstract `Menu` into a real menu that we can use in Tauri.
///
/// This recurses but we never go deeper than 3 or 4 levels so it's fine.
pub(crate) fn build_menu(that: &Menu) -> tauri::SystemTrayMenu {
    let mut menu = tauri::SystemTrayMenu::new();
    for entry in &that.entries {
        menu = match entry {
            Entry::Item(item) => menu.add_item(build_item(item)),
            Entry::Separator => menu.add_native_item(tauri::SystemTrayMenuItem::Separator),
            Entry::Submenu { title, inner } => {
                menu.add_submenu(tauri::SystemTraySubmenu::new(title, build_menu(inner)))
            }
        };
    }
    menu
}

/// Builds this abstract `Item` into a real item that we can use in Tauri.
fn build_item(that: &Item) -> tauri::CustomMenuItem {
    let mut item = tauri::CustomMenuItem::new(
        serde_json::to_string(&that.event)
            .expect("`serde_json` should always be able to serialize tray menu events"),
        &that.title,
    );

    if that.event.is_none() {
        item = item.disabled();
    }
    if that.selected {
        item = item.selected();
    }
    item
}

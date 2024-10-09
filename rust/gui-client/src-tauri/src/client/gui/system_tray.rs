//! Code for the system tray AKA notification area
//!
//! This manages the icon, menu, and tooltip.
//!
//! "Notification Area" is Microsoft's official name instead of "System tray":
//! <https://learn.microsoft.com/en-us/windows/win32/shell/notification-area?redirectedfrom=MSDN#notifications-and-the-notification-area>

use anyhow::Result;
use firezone_gui_client_common::{
    compositor::{self, Image},
    system_tray::{AppState, ConnlibState, Entry, Icon, IconBase, Menu},
};

// Figma is the source of truth for the tray icon layers
// <https://www.figma.com/design/THvQQ1QxKlsk47H9DZ2bhN/Core-Library?node-id=1250-772&t=nHBOzOnSY5Ol4asV-0>
const LOGO_BASE: &[u8] = include_bytes!("../../../icons/tray/Logo.png");
const LOGO_GREY_BASE: &[u8] = include_bytes!("../../../icons/tray/Logo grey.png");
const BUSY_LAYER: &[u8] = include_bytes!("../../../icons/tray/Busy layer.png");
const SIGNED_OUT_LAYER: &[u8] = include_bytes!("../../../icons/tray/Signed out layer.png");
const UPDATE_READY_LAYER: &[u8] = include_bytes!("../../../icons/tray/Update ready layer.png");

const TOOLTIP: &str = "Firezone";

pub(crate) struct Tray {
    app: tauri::AppHandle,
    handle: tauri::tray::TrayIcon,
    last_icon_set: Icon,
}

pub(crate) fn icon_to_tauri_icon(that: &Icon) -> tauri::image::Image<'static> {
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

fn image_to_tauri_icon(val: Image) -> tauri::image::Image<'static> {
    tauri::image::Image::new_owned(val.rgba, val.width, val.height)
}

impl Tray {
    pub(crate) fn new(app: tauri::AppHandle, handle: tauri::tray::TrayIcon) -> Self {
        Self {
            app,
            handle,
            last_icon_set: Default::default(),
        }
    }

    pub(crate) fn update(&mut self, state: AppState) -> Result<()> {
        let base = match &state.connlib {
            ConnlibState::Loading
            | ConnlibState::Quitting
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

        let app = self.app.clone();
        let handle = self.handle.clone();
        self.app
            .run_on_main_thread(move || {
                handle.set_tooltip(Some(TOOLTIP)).unwrap();
                handle.set_menu(Some(build_app_state(&app, state))).unwrap();
            })
            .unwrap();
        self.set_icon(new_icon)?;

        Ok(())
    }

    // Only needed for the stress test
    // Otherwise it would be inlined
    #[allow(clippy::unnecessary_wraps)]
    pub(crate) fn set_icon(&mut self, icon: Icon) -> Result<()> {
        if icon != self.last_icon_set {
            // Don't call `set_icon` too often. On Linux it writes a PNG to `/run/user/$UID/tao/tray-icon-*.png` every single time.
            // <https://github.com/tauri-apps/tao/blob/tao-v0.16.7/src/platform_impl/linux/system_tray.rs#L119>
            // Yes, even if you use `Icon::File` and tell Tauri that the icon is already
            // on disk.
            let handle = self.handle.clone();
            self.last_icon_set = icon.clone();
            self.app
                .run_on_main_thread(move || {
                    handle.set_icon(Some(icon_to_tauri_icon(&icon))).unwrap();
                })
                .unwrap();
        }
        Ok(())
    }
}

pub(crate) fn build_app_state(
    app: &tauri::AppHandle,
    that: AppState,
) -> tauri::menu::Menu<tauri::Wry> {
    build_menu(app, &that.into_menu())
}

/// Builds this abstract `Menu` into a real menu that we can use in Tauri.
///
/// This recurses but we never go deeper than 3 or 4 levels so it's fine.
pub(crate) fn build_menu(app: &tauri::AppHandle, that: &Menu) -> tauri::menu::Menu<tauri::Wry> {
    let mut menu = tauri::menu::MenuBuilder::new(app);
    for entry in &that.entries {
        menu = match entry {
            Entry::Item(item) => {
                if let Some(checked) = item.checked {
                    let mut tauri_item =
                        tauri::menu::CheckMenuItemBuilder::new(&item.title).checked(checked);
                    if let Some(event) = &item.event {
                        tauri_item = tauri_item.id(serde_json::to_string(event).unwrap());
                    } else {
                        tauri_item = tauri_item.enabled(false);
                    }
                    menu.item(&tauri_item.build(app).unwrap())
                } else {
                    let mut tauri_item = tauri::menu::MenuItemBuilder::new(&item.title);
                    if let Some(event) = &item.event {
                        tauri_item = tauri_item.id(serde_json::to_string(event).unwrap());
                    } else {
                        tauri_item = tauri_item.enabled(false);
                    }
                    menu.item(&tauri_item.build(app).unwrap())
                }
            }
            Entry::Separator => menu.separator(),
            Entry::Submenu { title, inner } => menu.item(&build_submenu(app, title, inner)),
        };
    }
    menu.build().unwrap()
}

pub(crate) fn build_submenu(
    app: &tauri::AppHandle,
    title: &str,
    that: &Menu,
) -> tauri::menu::Submenu<tauri::Wry> {
    let mut menu = tauri::menu::SubmenuBuilder::new(app, title);
    for entry in &that.entries {
        menu = match entry {
            Entry::Item(item) => {
                if let Some(checked) = item.checked {
                    let mut tauri_item =
                        tauri::menu::CheckMenuItemBuilder::new(&item.title).checked(checked);
                    if let Some(event) = &item.event {
                        tauri_item = tauri_item.id(serde_json::to_string(event).unwrap());
                    } else {
                        tauri_item = tauri_item.enabled(false);
                    }
                    menu.item(&tauri_item.build(app).unwrap())
                } else {
                    let mut tauri_item = tauri::menu::MenuItemBuilder::new(&item.title);
                    if let Some(event) = &item.event {
                        tauri_item = tauri_item.id(serde_json::to_string(event).unwrap());
                    } else {
                        tauri_item = tauri_item.enabled(false);
                    }
                    menu.item(&tauri_item.build(app).unwrap())
                }
            }
            Entry::Separator => menu.separator(),
            Entry::Submenu { title, inner } => menu.item(&build_submenu(app, title, inner)),
        };
    }
    menu.build().unwrap()
}

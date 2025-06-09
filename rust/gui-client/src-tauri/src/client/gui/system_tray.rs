//! Code for the system tray AKA notification area
//!
//! This manages the icon, menu, and tooltip.
//!
//! "Notification Area" is Microsoft's official name instead of "System tray":
//! <https://learn.microsoft.com/en-us/windows/win32/shell/notification-area?redirectedfrom=MSDN#notifications-and-the-notification-area>

use anyhow::{Context as _, Result};
use firezone_gui_client_common::{
    compositor::{self, Image},
    system_tray::{AppState, ConnlibState, Entry, Event, Icon, IconBase, Item, Menu},
};
use tauri::AppHandle;

type IsMenuItem = dyn tauri::menu::IsMenuItem<tauri::Wry>;
type TauriMenu = tauri::menu::Menu<tauri::Wry>;
type TauriSubmenu = tauri::menu::Submenu<tauri::Wry>;

// Figma is the source of truth for the tray icon layers
// <https://www.figma.com/design/THvQQ1QxKlsk47H9DZ2bhN/Core-Library?node-id=1250-772&t=nHBOzOnSY5Ol4asV-0>
const LOGO_BASE: &[u8] = include_bytes!("../../../icons/tray/Logo.png");
const LOGO_GREY_BASE: &[u8] = include_bytes!("../../../icons/tray/Logo grey.png");
const BUSY_LAYER: &[u8] = include_bytes!("../../../icons/tray/Busy layer.png");
const SIGNED_OUT_LAYER: &[u8] = include_bytes!("../../../icons/tray/Signed out layer.png");
const UPDATE_READY_LAYER: &[u8] = include_bytes!("../../../icons/tray/Update ready layer.png");

const TOOLTIP: &str = "Firezone";

pub(crate) struct Tray {
    app: AppHandle,
    handle: tauri::tray::TrayIcon,
    last_icon_set: Icon,
    last_menu_set: Option<Menu>,
}

fn icon_to_tauri_icon(that: &Icon) -> tauri::image::Image<'static> {
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
    pub(crate) fn new(
        app: AppHandle,
        on_event: impl Fn(&AppHandle, Event) + Send + Sync + 'static,
    ) -> Result<Self> {
        let tray = tauri::tray::TrayIconBuilder::new()
            .icon(icon_to_tauri_icon(
                &firezone_gui_client_common::system_tray::Icon::default(),
            ))
            .menu(&build_app_state(
                &app,
                &firezone_gui_client_common::system_tray::AppState::default().into_menu(),
            )?)
            .on_menu_event(move |app, event| {
                let id = &event.id.0;
                tracing::debug!(?id, "SystemTrayEvent::MenuItemClick");
                let event = match serde_json::from_str::<Event>(id) {
                    Ok(x) => x,
                    Err(e) => {
                        tracing::error!("{e}");
                        return;
                    }
                };

                on_event(app, event);
            })
            .tooltip("Firezone")
            .build(&app)
            .context("Cannot build Tauri tray icon")?;

        Ok(Self {
            app,
            handle: tray,
            last_icon_set: Default::default(),
            last_menu_set: None,
        })
    }

    pub(crate) fn update(&mut self, state: AppState) {
        let base = match &state.connlib {
            ConnlibState::Loading
            | ConnlibState::Quitting
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

        let menu = state.into_menu();
        let menu_clone = menu.clone();
        let app = self.app.clone();
        let handle = self.handle.clone();

        if Some(&menu) == self.last_menu_set.as_ref() {
            tracing::debug!("Skipping redundant menu update");
        } else {
            self.run_on_main_thread(move || {
                firezone_logging::unwrap_or_debug!(
                    update(handle, &app, &menu),
                    "Error while updating tray menu: {}"
                );
            });
        }
        self.set_icon(new_icon);
        self.last_menu_set = Some(menu_clone);
    }

    // Only needed for the stress test
    // Otherwise it would be inlined
    pub(crate) fn set_icon(&mut self, icon: Icon) {
        if icon == self.last_icon_set {
            return;
        }

        // Don't call `set_icon` too often. On Linux it writes a PNG to `/run/user/$UID/tao/tray-icon-*.png` every single time.
        // <https://github.com/tauri-apps/tao/blob/tao-v0.16.7/src/platform_impl/linux/system_tray.rs#L119>
        // Yes, even if you use `Icon::File` and tell Tauri that the icon is already
        // on disk.
        let handle = self.handle.clone();
        self.last_icon_set = icon.clone();
        self.run_on_main_thread(move || {
            let result = handle
                .set_icon(Some(icon_to_tauri_icon(&icon)))
                .context("Failed to set tray icon");

            firezone_logging::unwrap_or_debug!(result, "{}");
        });
    }

    fn run_on_main_thread(&self, f: impl FnOnce() + Send + 'static) {
        let result = self
            .app
            .run_on_main_thread(f)
            .context("Failed to run closure on main thread");

        firezone_logging::unwrap_or_debug!(result, "{}");
    }
}

fn update(handle: tauri::tray::TrayIcon, app: &AppHandle, menu: &Menu) -> Result<()> {
    let menu = build_app_state(app, menu).context("Failed to build tray menu")?;

    handle
        .set_tooltip(Some(TOOLTIP))
        .context("Failed to set tooltip")?;
    handle
        .set_menu(Some(menu))
        .context("Failed to set tray menu")?;

    Ok(())
}

fn build_app_state(app: &AppHandle, menu: &Menu) -> Result<TauriMenu> {
    build_menu(app, menu)
}

/// Builds this abstract `Menu` into a real menu that we can use in Tauri.
///
/// This recurses but we never go deeper than 3 or 4 levels so it's fine.
///
/// Note that Menus and Submenus are different in Tauri. Using a Submenu as a Menu
/// may crash on Windows. <https://github.com/tauri-apps/tauri/issues/11363>
fn build_menu(app: &AppHandle, that: &Menu) -> Result<TauriMenu> {
    let mut menu = tauri::menu::MenuBuilder::new(app);
    for entry in &that.entries {
        menu = menu.item(&*build_entry(app, entry)?);
    }
    Ok(menu.build()?)
}

fn build_submenu(app: &AppHandle, title: &str, that: &Menu) -> Result<TauriSubmenu> {
    let mut menu = tauri::menu::SubmenuBuilder::new(app, title);
    for entry in &that.entries {
        menu = menu.item(&*build_entry(app, entry)?);
    }
    Ok(menu.build()?)
}

fn build_entry(app: &AppHandle, entry: &Entry) -> Result<Box<IsMenuItem>> {
    let entry = match entry {
        Entry::Item(item) => build_item(app, item)?,
        Entry::Separator => Box::new(tauri::menu::PredefinedMenuItem::separator(app)?),
        Entry::Submenu { title, inner } => Box::new(build_submenu(app, title, inner)?),
    };
    Ok(entry)
}

fn build_item(app: &AppHandle, item: &Item) -> Result<Box<IsMenuItem>> {
    let item: Box<IsMenuItem> = if let Some(checked) = item.checked {
        let mut tauri_item = tauri::menu::CheckMenuItemBuilder::new(&item.title).checked(checked);
        if let Some(event) = &item.event {
            tauri_item = tauri_item.id(serde_json::to_string(event)?);
        } else {
            tauri_item = tauri_item.enabled(false);
        }
        Box::new(tauri_item.build(app)?)
    } else {
        let mut tauri_item = tauri::menu::MenuItemBuilder::new(&item.title);
        if let Some(event) = &item.event {
            tauri_item = tauri_item.id(serde_json::to_string(event)?);
        } else {
            tauri_item = tauri_item.enabled(false);
        }
        Box::new(tauri_item.build(app)?)
    };
    Ok(item)
}

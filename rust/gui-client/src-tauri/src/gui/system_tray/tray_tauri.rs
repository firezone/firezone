//! Windows / macOS tray backend using Tauri's built-in tray.
//!
//! Tauri renders per-item icons natively here (Win32 bitmaps / `NSImage`), so
//! the Site-status dots show up next to the menu text. Linux can't use this
//! path — its tray is exported over DBusMenu via `libappindicator`, which
//! drops the icon — so it uses the `tray_ksni` backend instead.

use anyhow::{Context as _, Result};
use tauri::{AppHandle, Manager as _, menu::ContextMenu as _};

use super::{
    AppState, Entry, Event, Icon, Image, Item, Menu, MenuItemIcon, TOOLTIP, compose_icon,
    compositor, icon_from_state,
};

type IsMenuItem = dyn tauri::menu::IsMenuItem<tauri::Wry>;
type TauriMenu = tauri::menu::Menu<tauri::Wry>;
type TauriSubmenu = tauri::menu::Submenu<tauri::Wry>;

// Status dots shown next to Site status items, mirroring the native status
// images the macOS client uses (`NSImage.statusAvailableName` and friends).
const STATUS_ONLINE_ICON: &[u8] = include_bytes!("../../../icons/menu/status-online.png");
const STATUS_OFFLINE_ICON: &[u8] = include_bytes!("../../../icons/menu/status-offline.png");
const STATUS_UNKNOWN_ICON: &[u8] = include_bytes!("../../../icons/menu/status-unknown.png");

pub(crate) struct Tray {
    app: AppHandle,
    handle: tauri::tray::TrayIcon,
    last_icon_set: Icon,
    last_menu_set: Option<Menu>,
    /// The window an open menu is anchored to, resolved up front because Tauri
    /// answers `hwnd` on the main thread, which an open menu blocks. Held as an
    /// integer so that `Tray` stays `Send`.
    #[cfg(target_os = "windows")]
    main_window: isize,
}

fn icon_to_tauri_icon(that: &Icon) -> tauri::image::Image<'static> {
    image_to_tauri_icon(compose_icon(that))
}

fn image_to_tauri_icon(val: Image) -> tauri::image::Image<'static> {
    tauri::image::Image::new_owned(val.rgba, val.width, val.height)
}

fn menu_item_icon(icon: MenuItemIcon) -> tauri::image::Image<'static> {
    let png = match icon {
        MenuItemIcon::Green => STATUS_ONLINE_ICON,
        MenuItemIcon::Red => STATUS_OFFLINE_ICON,
        MenuItemIcon::Grey => STATUS_UNKNOWN_ICON,
    };
    let decoded =
        compositor::compose([png]).expect("PNG decoding should always succeed for baked-in PNGs");
    image_to_tauri_icon(decoded)
}

impl Tray {
    pub(crate) fn new(
        _rt: tokio::runtime::Handle,
        app: AppHandle,
        on_event: impl Fn(&AppHandle, Event) + Send + Sync + 'static,
    ) -> Result<Self> {
        let tray = tauri::tray::TrayIconBuilder::new()
            .icon(icon_to_tauri_icon(&Icon::default()))
            .menu(&build_menu(&app, &AppState::default().into_menu())?)
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
            .tooltip(TOOLTIP)
            .build(&app)
            .context("Cannot build Tauri tray icon")?;

        #[cfg(target_os = "windows")]
        let main_window = app
            .get_webview_window("main")
            .context("Couldn't get handle to window")?
            .hwnd()
            .context("Couldn't get the window's HWND")?
            .0 as isize;

        Ok(Self {
            app,
            handle: tray,
            last_icon_set: Default::default(),
            last_menu_set: None,
            #[cfg(target_os = "windows")]
            main_window,
        })
    }

    pub(crate) fn update(&mut self, state: AppState) {
        let new_icon = icon_from_state(&state);

        let menu = state.into_menu();

        if Some(&menu) == self.last_menu_set.as_ref() {
            tracing::debug!("Skipping redundant menu update");
        } else {
            let app = self.app.clone();
            let handle = self.handle.clone();
            let menu = menu.clone();

            self.run_on_main_thread(move || {
                logging::unwrap_or_debug!(
                    set_menu(handle, &app, &menu),
                    "Error while updating tray menu: {}"
                );
            });
        }
        self.set_icon(new_icon);
        self.last_menu_set = Some(menu);
    }

    /// Opens the menu we installed last on screen, so CI can photograph it.
    pub(crate) fn open_menu(&self) -> Result<()> {
        let menu = self
            .last_menu_set
            .clone()
            .context("No tray menu has been set yet")?;
        let app = self.app.clone();

        self.run_on_main_thread(move || {
            logging::unwrap_or_debug!(open_menu(&app, &menu), "Failed to open the tray menu: {}");
        });

        Ok(())
    }

    /// Closes the menu again, including any open submenu.
    #[cfg(target_os = "windows")]
    pub(crate) fn close_menu(&self) -> Result<()> {
        use windows::Win32::{
            Foundation::{HWND, LPARAM, WPARAM},
            UI::WindowsAndMessaging::{PostMessageW, WM_CANCELMODE},
        };

        let owner = HWND(self.main_window as *mut _);

        // `EndMenu` would need the main thread, which stays inside `TrackPopupMenu`
        // until the menu closes.
        // SAFETY: `PostMessageW` takes no pointers and is safe from any thread.
        unsafe { PostMessageW(Some(owner), WM_CANCELMODE, WPARAM(0), LPARAM(0)) }
            .context("Failed to post `WM_CANCELMODE`")
    }

    #[cfg(not(target_os = "windows"))]
    pub(crate) fn close_menu(&self) -> Result<()> {
        anyhow::bail!("Closing the tray menu is not supported on macOS")
    }

    // Only needed for the stress test
    // Otherwise it would be inlined
    pub(crate) fn set_icon(&mut self, icon: Icon) {
        if icon == self.last_icon_set {
            return;
        }

        // Skip redundant updates; rebuilding and handing a new icon to the OS
        // on every state change is wasteful.
        let handle = self.handle.clone();
        self.last_icon_set = icon.clone();
        self.run_on_main_thread(move || {
            let result = handle
                .set_icon(Some(icon_to_tauri_icon(&icon)))
                .context("Failed to set tray icon");

            logging::unwrap_or_debug!(result, "{}");
        });
    }

    fn run_on_main_thread(&self, f: impl FnOnce() + Send + 'static) {
        let result = self
            .app
            .run_on_main_thread(f)
            .context("Failed to run closure on main thread");

        logging::unwrap_or_debug!(result, "{}");
    }
}

fn set_menu(handle: tauri::tray::TrayIcon, app: &AppHandle, menu: &Menu) -> Result<()> {
    let menu = build_menu(app, menu).context("Failed to build tray menu")?;

    handle
        .set_tooltip(Some(TOOLTIP))
        .context("Failed to set tooltip")?;
    handle
        .set_menu(Some(menu))
        .context("Failed to set tray menu")?;

    Ok(())
}

/// Opens `menu` at the cursor, anchored to the (hidden) main window, for screenshots.
///
/// Builds its own Tauri menu: [`set_menu`] keeps only the abstract one.
fn open_menu(app: &AppHandle, menu: &Menu) -> Result<()> {
    let menu = build_menu(app, menu).context("Failed to build tray menu")?;
    let window = app
        .get_webview_window("main")
        .context("Couldn't get handle to window")?
        .as_ref()
        .window();

    // Tauri's `popup` runs `TrackPopupMenu` on the main thread and only returns
    // once the menu closes, so it has to be requested from another thread.
    std::thread::spawn(move || {
        logging::unwrap_or_debug!(
            menu.popup(window).context("Failed to open the tray menu"),
            "{}"
        );
    });

    Ok(())
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
    } else if let Some(icon) = item.icon {
        let mut tauri_item =
            tauri::menu::IconMenuItemBuilder::new(&item.title).icon(menu_item_icon(icon));
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn menu_item_icons_decode() {
        for icon in [MenuItemIcon::Green, MenuItemIcon::Red, MenuItemIcon::Grey] {
            let image = menu_item_icon(icon);
            assert!(image.width() > 0 && image.height() > 0);
        }
    }
}

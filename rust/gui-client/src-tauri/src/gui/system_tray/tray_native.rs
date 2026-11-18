//! Windows / macOS tray backend built on `tray-icon`.
//!
//! The menus are native (Win32 / `NSMenu`), so the Site-status dots show up
//! next to the menu text. Linux uses the `tray_ksni` backend instead, because
//! `tray-icon` exports its menu there through `libappindicator`, which drops
//! the icons and links GTK.

use std::cell::RefCell;

use anyhow::{Context as _, Result};
use tokio::sync::oneshot;
use tray_icon::{
    TrayIcon, TrayIconBuilder,
    menu::{
        CheckMenuItem, IconMenuItem, IsMenuItem, Menu as NativeMenu, MenuItem, PredefinedMenuItem,
        Submenu,
    },
};

use super::{
    AppState, Entry, Event, Icon, Image, Item, Menu, MenuItemIcon, TOOLTIP, compose_icon,
    compositor, icon_from_state,
};

// Status dots shown next to Site status items, mirroring the native status
// images the macOS client uses (`NSImage.statusAvailableName` and friends).
const STATUS_ONLINE_ICON: &[u8] = include_bytes!("../../../icons/menu/status-online.png");
const STATUS_OFFLINE_ICON: &[u8] = include_bytes!("../../../icons/menu/status-offline.png");
const STATUS_UNKNOWN_ICON: &[u8] = include_bytes!("../../../icons/menu/status-unknown.png");

const TRAY_SETUP_DROPPED: &str = "The GUI event loop dropped the tray setup";

/// Runs a closure on the thread that runs the GUI event loop.
pub(crate) type MainThread = Box<dyn Fn(Box<dyn FnOnce() + Send>) + Send + Sync>;

thread_local! {
    /// `TrayIcon` is neither `Send` nor `Sync`, so it lives on the main thread.
    static TRAY: RefCell<Option<(TrayIcon, NativeMenu)>> = const { RefCell::new(None) };
}

pub(crate) struct Tray {
    main_thread: MainThread,
    last_icon_set: Icon,
    last_menu_set: Option<Menu>,
    /// The tray's message window, which owns the menu.
    #[cfg(target_os = "windows")]
    hwnd: isize,
}

impl Tray {
    pub(crate) async fn new(main_thread: MainThread) -> Result<Self> {
        let (tx, rx) = oneshot::channel();

        main_thread(Box::new(move || {
            let _ = tx.send(build_tray().map(install));
        }));

        #[cfg(target_os = "windows")]
        let hwnd = rx.await.context(TRAY_SETUP_DROPPED)??;
        #[cfg(not(target_os = "windows"))]
        rx.await.context(TRAY_SETUP_DROPPED)??;

        Ok(Self {
            main_thread,
            last_icon_set: Default::default(),
            last_menu_set: None,
            #[cfg(target_os = "windows")]
            hwnd,
        })
    }

    pub(crate) fn update(&mut self, state: AppState) {
        let new_icon = icon_from_state(&state);

        let menu = state.into_menu();

        if Some(&menu) == self.last_menu_set.as_ref() {
            tracing::debug!("Skipping redundant menu update");
        } else {
            let new_menu = menu.clone();
            self.with_tray(move |tray, menu| {
                let built = build_menu(&new_menu).context("Failed to build tray menu")?;
                tray.set_menu(Some(Box::new(built.clone())));
                tray.set_tooltip(Some(TOOLTIP))
                    .context("Failed to set tooltip")?;
                *menu = built;

                Ok(())
            });
        }
        self.set_icon(new_icon);
        self.last_menu_set = Some(menu);
    }

    /// Opens the menu we installed last on screen, so CI can photograph it.
    #[cfg(target_os = "windows")]
    #[expect(
        clippy::unnecessary_wraps,
        reason = "The other tray backends cannot open their menu"
    )]
    pub(crate) fn open_menu(&self) -> Result<()> {
        use tray_icon::menu::ContextMenu as _;

        let hwnd = self.hwnd;

        // Returns only once the menu closes.
        self.with_tray(move |_, menu| {
            // SAFETY: `hwnd` is the tray's window, which lives as long as `TRAY`.
            unsafe { menu.show_context_menu_for_hwnd(hwnd, None) };

            Ok(())
        });

        Ok(())
    }

    #[cfg(not(target_os = "windows"))]
    pub(crate) fn open_menu(&self) -> Result<()> {
        anyhow::bail!("Opening the tray menu is not supported on macOS")
    }

    /// Closes the menu again, including any open submenu.
    #[cfg(target_os = "windows")]
    pub(crate) fn close_menu(&self) -> Result<()> {
        use windows::Win32::{
            Foundation::{HWND, LPARAM, WPARAM},
            UI::WindowsAndMessaging::{PostMessageW, WM_CANCELMODE},
        };

        // `EndMenu` would need the main thread, which stays inside `TrackPopupMenu`
        // until the menu closes.
        // SAFETY: `PostMessageW` takes no pointers and is safe from any thread.
        unsafe {
            PostMessageW(
                Some(HWND(self.hwnd as *mut _)),
                WM_CANCELMODE,
                WPARAM(0),
                LPARAM(0),
            )
        }
        .context("Failed to post `WM_CANCELMODE`")
    }

    #[cfg(not(target_os = "windows"))]
    pub(crate) fn close_menu(&self) -> Result<()> {
        anyhow::bail!("Closing the tray menu is not supported on macOS")
    }

    pub(crate) fn set_icon(&mut self, icon: Icon) {
        if icon == self.last_icon_set {
            return;
        }

        self.last_icon_set = icon.clone();
        self.with_tray(move |tray, _| {
            tray.set_icon(Some(tray_icon(&icon)?))
                .context("Failed to set tray icon")
        });
    }

    fn with_tray(&self, f: impl FnOnce(&TrayIcon, &mut NativeMenu) -> Result<()> + Send + 'static) {
        (self.main_thread)(Box::new(move || {
            TRAY.with_borrow_mut(|tray| {
                let Some((tray, menu)) = tray else {
                    return;
                };

                logging::unwrap_or_debug!(f(tray, menu), "{}");
            });
        }));
    }
}

impl Drop for Tray {
    fn drop(&mut self) {
        // Removes the icon from the notification area before the event loop exits.
        (self.main_thread)(Box::new(|| drop(TRAY.take())));
    }
}

/// Decodes the [`Event`] of a menu item clicked in a menu built by [`Tray`].
pub(crate) fn decode_menu_event(id: &str) -> Option<Event> {
    tracing::debug!(?id, "SystemTrayEvent::MenuItemClick");

    serde_json::from_str::<Event>(id)
        .inspect_err(|e| tracing::error!("Unknown tray menu item: {e}"))
        .ok()
}

/// Keeps the tray on the main thread and returns the window that owns its menu.
#[cfg(target_os = "windows")]
fn install((tray, menu): (TrayIcon, NativeMenu)) -> isize {
    let hwnd = tray.window_handle() as isize;
    TRAY.set(Some((tray, menu)));

    hwnd
}

#[cfg(not(target_os = "windows"))]
fn install(tray: (TrayIcon, NativeMenu)) {
    TRAY.set(Some(tray));
}

fn build_tray() -> Result<(TrayIcon, NativeMenu)> {
    let menu = build_menu(&AppState::default().into_menu())?;
    let tray = TrayIconBuilder::new()
        .with_icon(tray_icon(&Icon::default())?)
        .with_menu(Box::new(menu.clone()))
        .with_tooltip(TOOLTIP)
        .build()
        .context("Cannot build tray icon")?;

    Ok((tray, menu))
}

fn tray_icon(icon: &Icon) -> Result<tray_icon::Icon> {
    let Image {
        width,
        height,
        rgba,
    } = compose_icon(icon);
    let icon = tray_icon::Icon::from_rgba(rgba, width, height)?;

    Ok(icon)
}

fn menu_item_icon(icon: MenuItemIcon) -> Result<tray_icon::menu::Icon> {
    let png = match icon {
        MenuItemIcon::Green => STATUS_ONLINE_ICON,
        MenuItemIcon::Red => STATUS_OFFLINE_ICON,
        MenuItemIcon::Grey => STATUS_UNKNOWN_ICON,
    };
    let Image {
        width,
        height,
        rgba,
    } = compositor::compose([png])?;
    let icon = tray_icon::menu::Icon::from_rgba(rgba, width, height)?;

    Ok(icon)
}

/// Builds this abstract `Menu` into a native menu.
///
/// This recurses but we never go deeper than 3 or 4 levels so it's fine.
fn build_menu(that: &Menu) -> Result<NativeMenu> {
    let menu = NativeMenu::new();
    for entry in &that.entries {
        menu.append(&*build_entry(entry)?)?;
    }

    Ok(menu)
}

fn build_entry(entry: &Entry) -> Result<Box<dyn IsMenuItem>> {
    let entry: Box<dyn IsMenuItem> = match entry {
        Entry::Item(item) => build_item(item)?,
        Entry::Separator => Box::new(PredefinedMenuItem::separator()),
        Entry::Submenu { title, inner } => {
            let submenu = Submenu::new(title, true);
            for entry in &inner.entries {
                submenu.append(&*build_entry(entry)?)?;
            }
            Box::new(submenu)
        }
    };

    Ok(entry)
}

fn build_item(item: &Item) -> Result<Box<dyn IsMenuItem>> {
    let Some(event) = &item.event else {
        let item: Box<dyn IsMenuItem> = match (item.checked, item.icon) {
            (Some(checked), _) => Box::new(CheckMenuItem::new(&item.title, false, checked, None)),
            (None, Some(icon)) => Box::new(IconMenuItem::new(
                &item.title,
                false,
                Some(menu_item_icon(icon)?),
                None,
            )),
            (None, None) => Box::new(MenuItem::new(&item.title, false, None)),
        };

        return Ok(item);
    };

    let id = serde_json::to_string(event)?;
    let item: Box<dyn IsMenuItem> = match (item.checked, item.icon) {
        (Some(checked), _) => {
            Box::new(CheckMenuItem::with_id(id, &item.title, true, checked, None))
        }
        (None, Some(icon)) => Box::new(IconMenuItem::with_id(
            id,
            &item.title,
            true,
            Some(menu_item_icon(icon)?),
            None,
        )),
        (None, None) => Box::new(MenuItem::with_id(id, &item.title, true, None)),
    };

    Ok(item)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn menu_item_icons_decode() {
        for icon in [MenuItemIcon::Green, MenuItemIcon::Red, MenuItemIcon::Grey] {
            assert!(menu_item_icon(icon).is_ok());
        }
    }
}

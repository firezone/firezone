//! Linux tray backend built on `ksni` (StatusNotifierItem + DBusMenu).
//!
//! ksni speaks the tray D-Bus protocols directly, so it can attach an
//! `icon-name` to each menu item — letting GNOME (with the AppIndicator
//! extension) and KDE render the Site-status dots, which Tauri's
//! `libappindicator` path could not. The icon names are freedesktop presence
//! icons, which the host renders at its own DPI-aware menu-icon size.

use std::sync::Arc;
use std::task::Poll;

use anyhow::Result;
use ksni::{
    Icon as KsniIcon,
    menu::{CheckmarkItem, MenuItem, StandardItem, SubMenu},
};
use tauri::AppHandle;
use tokio::runtime;
use tokio::sync::mpsc;

use super::{
    AppState, Entry, Event, Icon, Item, Menu, MenuItemIcon, TOOLTIP, compose_icon, icon_from_state,
};

type OnEvent = Arc<dyn Fn(&AppHandle, Event) + Send + Sync>;

pub(crate) struct Tray {
    menu_tx: mpsc::UnboundedSender<Menu>,
    icon_tx: mpsc::UnboundedSender<Icon>,
    last_icon: Icon,
    last_menu: Option<Menu>,
}

impl Tray {
    // Returns `Result` to match the Tauri backend's fallible constructor, so
    // `Tray::new` has one signature across platforms. ksni reports spawn
    // failures asynchronously (logged in the service task) instead.
    #[allow(clippy::unnecessary_wraps)]
    pub(crate) fn new(
        rt: runtime::Handle,
        app: AppHandle,
        on_event: impl Fn(&AppHandle, Event) + Send + Sync + 'static,
    ) -> Result<Self> {
        let (menu_tx, menu_rx) = mpsc::unbounded_channel();
        let (icon_tx, icon_rx) = mpsc::unbounded_channel();

        let tray = FzTray {
            app,
            on_event: Arc::new(on_event),
            menu: Menu::default(),
            icon: Icon::default(),
        };

        // ksni talks D-Bus (via zbus) on the provided runtime. Menu and icon
        // updates are delivered to the running tray over the channels.
        rt.spawn(async move {
            use ksni::TrayMethods as _;
            let handle = match tray.spawn().await {
                Ok(handle) => handle,
                Err(e) => {
                    tracing::warn!("Failed to spawn ksni tray: {e}");
                    return;
                }
            };
            Service {
                handle,
                menu_rx,
                icon_rx,
            }
            .run()
            .await;
        });

        Ok(Self {
            menu_tx,
            icon_tx,
            last_icon: Icon::default(),
            last_menu: None,
        })
    }

    pub(crate) fn update(&mut self, state: AppState) {
        let new_icon = icon_from_state(&state);

        let menu = state.into_menu();
        if self.last_menu.as_ref() == Some(&menu) {
            tracing::debug!("Skipping redundant menu update");
        } else {
            // A send error only means the tray service has stopped, which is
            // already logged when it happens.
            let _ = self.menu_tx.send(menu.clone());
            self.last_menu = Some(menu);
        }

        self.set_icon(new_icon);
    }

    pub(crate) fn set_icon(&mut self, icon: Icon) {
        if icon == self.last_icon {
            return;
        }
        self.last_icon = icon.clone();
        let _ = self.icon_tx.send(icon);
    }
}

/// The background loop that applies menu and icon updates to the running tray.
struct Service {
    handle: ksni::Handle<FzTray>,
    menu_rx: mpsc::UnboundedReceiver<Menu>,
    icon_rx: mpsc::UnboundedReceiver<Icon>,
}

/// One unit of work for the [`Service`] loop.
enum Tick {
    Menu(Menu),
    Icon(Icon),
    /// A sender was dropped (the `Tray` is gone); stop the loop.
    Shutdown,
}

impl Service {
    async fn run(mut self) {
        loop {
            match self.tick().await {
                Tick::Menu(menu) => {
                    self.handle.update(|tray| tray.menu = menu).await;
                }
                Tick::Icon(icon) => {
                    self.handle.update(|tray| tray.icon = icon).await;
                }
                Tick::Shutdown => break,
            }
        }
    }

    /// Awaits the next menu or icon update, composing the two channels by hand
    /// rather than reaching for `select!`.
    async fn tick(&mut self) -> Tick {
        std::future::poll_fn(|cx| {
            if let Poll::Ready(maybe_menu) = self.menu_rx.poll_recv(cx) {
                return Poll::Ready(maybe_menu.map_or(Tick::Shutdown, Tick::Menu));
            }
            if let Poll::Ready(maybe_icon) = self.icon_rx.poll_recv(cx) {
                return Poll::Ready(maybe_icon.map_or(Tick::Shutdown, Tick::Icon));
            }
            Poll::Pending
        })
        .await
    }
}

struct FzTray {
    app: AppHandle,
    on_event: OnEvent,
    menu: Menu,
    icon: Icon,
}

impl ksni::Tray for FzTray {
    fn id(&self) -> String {
        crate::BUNDLE_ID.to_owned()
    }

    fn title(&self) -> String {
        TOOLTIP.to_owned()
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip {
            title: TOOLTIP.to_owned(),
            description: String::new(),
            icon_name: String::new(),
            icon_pixmap: Vec::new(),
        }
    }

    fn icon_pixmap(&self) -> Vec<KsniIcon> {
        let composed = compose_icon(&self.icon);
        // ksni wants ARGB32 (network byte order); the compositor produces RGBA.
        let mut data = Vec::with_capacity(composed.rgba.len());
        for px in composed.rgba.chunks_exact(4) {
            data.extend_from_slice(&[px[3], px[0], px[1], px[2]]);
        }
        vec![KsniIcon {
            width: composed.width as i32,
            height: composed.height as i32,
            data,
        }]
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        build_menu(&self.menu)
    }
}

fn build_menu(menu: &Menu) -> Vec<MenuItem<FzTray>> {
    menu.entries.iter().map(build_entry).collect()
}

fn build_entry(entry: &Entry) -> MenuItem<FzTray> {
    match entry {
        Entry::Separator => MenuItem::Separator,
        Entry::Submenu { title, inner } => SubMenu {
            label: title.clone(),
            submenu: build_menu(inner),
            ..Default::default()
        }
        .into(),
        Entry::Item(item) => build_item(item),
    }
}

fn build_item(item: &Item) -> MenuItem<FzTray> {
    let label = item.title.clone();
    let enabled = item.event.is_some();
    let event = item.event.clone();
    let activate = Box::new(move |tray: &mut FzTray| {
        if let Some(event) = event.clone() {
            let on_event = Arc::clone(&tray.on_event);
            on_event(&tray.app, event);
        }
    });

    if let Some(checked) = item.checked {
        CheckmarkItem {
            label,
            enabled,
            checked,
            activate,
            ..Default::default()
        }
        .into()
    } else {
        StandardItem {
            label,
            enabled,
            icon_name: themed_icon_name(item.icon),
            activate,
            ..Default::default()
        }
        .into()
    }
}

/// Maps a Site-status icon to a freedesktop themed icon name.
///
/// These presence icons render as green / red / grey dots in common icon
/// themes, matching the colors the macOS client uses for Site status.
fn themed_icon_name(icon: Option<MenuItemIcon>) -> String {
    match icon {
        Some(MenuItemIcon::Online) => "user-available",
        Some(MenuItemIcon::Offline) => "user-busy",
        Some(MenuItemIcon::Unknown) => "user-offline",
        None => "",
    }
    .to_owned()
}

//! Linux tray backend built on `ksni` (StatusNotifierItem + DBusMenu).
//!
//! ksni speaks the tray D-Bus protocols directly, so it can attach per-item
//! `icon-data` (a PNG) — letting GNOME (with the AppIndicator extension) and
//! KDE render the colored Site-status dots, which Tauri's `libappindicator`
//! path could not. Stock icon themes only ship monochrome *symbolic* status
//! icons, so rather than a themed `icon-name` we embed our own PNGs — the same
//! green/red/grey assets the Windows tray uses.

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

// Status dots embedded as `icon-data`, shared with the Windows tray. Stock
// icon themes don't ship colored status icons, so we ship our own.
const STATUS_ONLINE_ICON: &[u8] = include_bytes!("../../../icons/menu/status-online.png");
const STATUS_OFFLINE_ICON: &[u8] = include_bytes!("../../../icons/menu/status-offline.png");
const STATUS_UNKNOWN_ICON: &[u8] = include_bytes!("../../../icons/menu/status-unknown.png");

type OnEvent = Arc<dyn Fn(&AppHandle, Event) + Send + Sync>;

pub(crate) struct Tray {
    menu_tx: mpsc::UnboundedSender<Menu>,
    icon_tx: mpsc::UnboundedSender<Icon>,
    last_icon: Icon,
    last_menu: Option<Menu>,
}

impl Tray {
    #[expect(
        clippy::unnecessary_wraps,
        reason = "The Tauri backend's `new` is fallible; the signatures must match"
    )]
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
            Eventloop {
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
struct Eventloop {
    handle: ksni::Handle<FzTray>,
    menu_rx: mpsc::UnboundedReceiver<Menu>,
    icon_rx: mpsc::UnboundedReceiver<Icon>,
}

/// One unit of work for the [`Eventloop`].
enum Tick {
    Menu(Menu),
    Icon(Icon),
    /// A sender was dropped (the `Tray` is gone); stop the loop.
    Shutdown,
}

impl Eventloop {
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
            icon_data: icon_data(item.icon),
            activate,
            ..Default::default()
        }
        .into()
    }
}

/// Returns the PNG bytes for a menu-item status dot, for ksni's `icon-data`.
fn icon_data(icon: Option<MenuItemIcon>) -> Vec<u8> {
    let png: &[u8] = match icon {
        Some(MenuItemIcon::Green) => STATUS_ONLINE_ICON,
        Some(MenuItemIcon::Red) => STATUS_OFFLINE_ICON,
        Some(MenuItemIcon::Grey) => STATUS_UNKNOWN_ICON,
        None => return Vec::new(),
    };
    png.to_vec()
}

//! System tray for the iced binary.
//!
//! Two backends, picked at compile time:
//!
//! - **Linux**: `ksni` — a pure-Rust StatusNotifierItem implementation
//!   that talks D-Bus directly. No GTK link dep. Works on KDE Plasma,
//!   XFCE, Cinnamon, MATE, and on GNOME *if* the user has the
//!   "AppIndicator and KStatusNotifierItem Support" GNOME Shell
//!   extension installed (same desktop requirement as the Tauri
//!   client).
//! - **macOS / Windows**: tauri-apps's `tray-icon`, which uses
//!   `NSStatusItem` / Win32 directly.
//!
//! Both backends consume the platform-neutral [`Menu`] IR produced by
//! the existing `gui::system_tray::AppState::into_menu` (shared with
//! the Tauri client — same favorites, devices, internet-resource
//! toggle, update-ready download URL, etc.) and forward each menu
//! click as a `system_tray::Event` back to the iced application as a
//! `Message::TrayEvent`. The iced `update` fn then re-emits it as
//! `ControllerRequest::SystemTrayMenu`, which is the same single
//! sink the Tauri client uses — so the Controller handles all eleven
//! event variants uniformly regardless of which UI is driving.

use crate::Message;
use firezone_gui_client::gui::system_tray::{Icon, Menu};

/// Set up the tray's static state and (on Win/Mac) the `TrayIcon`.
/// Must be called from the main thread *before* iced takes it over —
/// the Win/Mac `TrayIcon` lives in a `thread_local` on the thread it
/// was created on, and we want the event-channel statics initialised
/// before iced first polls our subscription (otherwise the
/// subscription stream sees `EVENT_RX = None`, returns immediately,
/// and iced never restarts it).
pub fn install() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    backend::install()
}

/// Linux only: spawn the ksni service onto the ambient tokio
/// runtime. Must be called from inside a tokio context (i.e. an iced
/// `Task::future`). No-op on Win/Mac.
pub fn spawn_service() {
    backend::spawn_service();
}

/// Push a new menu IR into the running tray.
pub fn set_menu(menu: Menu) {
    backend::set_menu(menu);
}

/// Push a new icon state into the running tray.
pub fn set_icon(icon: Icon) {
    backend::set_icon(icon);
}

/// A subscription that emits a [`Message::TrayEvent`] for every tray
/// menu click.
pub fn subscription() -> iced::Subscription<Message> {
    backend::subscription()
}

// ---------------------------------------------------------------------------
// Linux backend (ksni)
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
mod backend {
    use std::sync::OnceLock;

    use iced::futures::SinkExt as _;
    use iced::stream;
    use ksni::{
        Icon as KsniIcon,
        menu::{CheckmarkItem, MenuItem, StandardItem, SubMenu},
    };
    use tokio::sync::mpsc;

    use crate::Message;
    use firezone_gui_client::gui::system_tray::{self, Entry, Event, Icon, Item, Menu};

    /// Sender into the ksni service. Each menu click pushes an
    /// `Event` here; the iced subscription drains it into Messages.
    static EVENT_TX: OnceLock<mpsc::UnboundedSender<Event>> = OnceLock::new();
    /// Receiver, taken by the iced subscription on first poll.
    static EVENT_RX: OnceLock<parking_lot::Mutex<Option<mpsc::UnboundedReceiver<Event>>>> =
        OnceLock::new();
    /// Sender for menu updates from iced → ksni service.
    static MENU_TX: OnceLock<mpsc::UnboundedSender<Menu>> = OnceLock::new();
    /// Sender for icon updates from iced → ksni service.
    static ICON_TX: OnceLock<mpsc::UnboundedSender<Icon>> = OnceLock::new();
    /// Pending receivers handed off from `install` to `spawn_service`.
    /// Stuffed in a `Mutex<Option<_>>` because the receivers aren't
    /// `Clone` and can only be owned by the ksni service task.
    static SERVICE_RECEIVERS: OnceLock<parking_lot::Mutex<Option<ServiceReceivers>>> =
        OnceLock::new();

    struct ServiceReceivers {
        menu_rx: mpsc::UnboundedReceiver<Menu>,
        icon_rx: mpsc::UnboundedReceiver<Icon>,
        event_tx: mpsc::UnboundedSender<Event>,
    }

    #[allow(clippy::unnecessary_wraps)]
    pub fn install() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if EVENT_TX.get().is_some() {
            return Ok(());
        }
        let (event_tx, event_rx) = mpsc::unbounded_channel::<Event>();
        let (menu_tx, menu_rx) = mpsc::unbounded_channel::<Menu>();
        let (icon_tx, icon_rx) = mpsc::unbounded_channel::<Icon>();
        let _ = EVENT_TX.set(event_tx.clone());
        let _ = EVENT_RX.set(parking_lot::Mutex::new(Some(event_rx)));
        let _ = MENU_TX.set(menu_tx);
        let _ = ICON_TX.set(icon_tx);
        let _ = SERVICE_RECEIVERS.set(parking_lot::Mutex::new(Some(ServiceReceivers {
            menu_rx,
            icon_rx,
            event_tx,
        })));
        Ok(())
    }

    pub fn spawn_service() {
        let Some(slot) = SERVICE_RECEIVERS.get() else {
            tracing::warn!("tray::spawn_service called before tray::install");
            return;
        };
        let Some(ServiceReceivers {
            mut menu_rx,
            mut icon_rx,
            event_tx,
        }) = slot.lock().take()
        else {
            // Already spawned — idempotent.
            return;
        };

        let tray = FzTray {
            sender: event_tx,
            menu: Menu::default(),
            icon: Icon::default(),
        };
        // `tokio::spawn` onto the caller's runtime (iced's, in
        // practice). Using a separate `new_current_thread` runtime
        // here used to race with zbus's spans on the global tracing
        // subscriber; running on the same runtime keeps everything
        // on one executor.
        tokio::spawn(async move {
            use ksni::TrayMethods as _;
            let handle = match tray.spawn().await {
                Ok(handle) => handle,
                Err(e) => {
                    tracing::warn!("ksni tray failed to spawn: {e}");
                    return;
                }
            };
            loop {
                tokio::select! {
                    Some(menu) = menu_rx.recv() => {
                        handle.update(|t| { t.menu = menu; }).await;
                    }
                    Some(icon) = icon_rx.recv() => {
                        handle.update(|t| { t.icon = icon; }).await;
                    }
                    else => break,
                }
            }
        });
    }

    pub fn set_menu(menu: Menu) {
        if let Some(tx) = MENU_TX.get() {
            let _ = tx.send(menu);
        }
    }

    pub fn set_icon(icon: Icon) {
        if let Some(tx) = ICON_TX.get() {
            let _ = tx.send(icon);
        }
    }

    pub fn subscription() -> iced::Subscription<Message> {
        iced::Subscription::run(menu_events_stream)
    }

    fn menu_events_stream() -> impl iced::futures::Stream<Item = Message> {
        stream::channel(
            16,
            |mut output: iced::futures::channel::mpsc::Sender<Message>| async move {
                let mut rx = match EVENT_RX.get().and_then(|m| m.lock().take()) {
                    Some(rx) => rx,
                    None => return,
                };
                while let Some(event) = rx.recv().await
                    && output.send(Message::TrayEvent(event)).await.is_ok()
                {}
            },
        )
    }

    struct FzTray {
        sender: mpsc::UnboundedSender<Event>,
        menu: Menu,
        icon: Icon,
    }

    impl std::fmt::Debug for FzTray {
        // ksni requires `Tray: Debug`; the inner Menu / Icon don't
        // derive it (the IR is `Serialize`/`PartialEq` only).
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.debug_struct("FzTray").finish_non_exhaustive()
        }
    }

    impl ksni::Tray for FzTray {
        fn id(&self) -> String {
            "dev.firezone.client".to_owned()
        }
        fn title(&self) -> String {
            "Firezone".to_owned()
        }
        fn tool_tip(&self) -> ksni::ToolTip {
            ksni::ToolTip {
                icon_name: String::new(),
                icon_pixmap: Vec::new(),
                title: "Firezone".to_owned(),
                description: String::new(),
            }
        }
        fn icon_pixmap(&self) -> Vec<KsniIcon> {
            let composed = system_tray::compose_icon(&self.icon);
            // ksni wants ARGB; the compositor produces RGBA — swizzle.
            let mut argb = Vec::with_capacity(composed.rgba.len());
            for px in composed.rgba.chunks_exact(4) {
                argb.push(px[3]);
                argb.push(px[0]);
                argb.push(px[1]);
                argb.push(px[2]);
            }
            vec![KsniIcon {
                width: composed.width as i32,
                height: composed.height as i32,
                data: argb,
            }]
        }
        fn menu(&self) -> Vec<MenuItem<Self>> {
            build_menu(&self.menu, &self.sender)
        }
    }

    fn build_menu(menu: &Menu, sender: &mpsc::UnboundedSender<Event>) -> Vec<MenuItem<FzTray>> {
        menu.entries
            .iter()
            .map(|entry| build_entry(entry, sender))
            .collect()
    }

    fn build_entry(entry: &Entry, sender: &mpsc::UnboundedSender<Event>) -> MenuItem<FzTray> {
        match entry {
            Entry::Separator => MenuItem::Separator,
            Entry::Submenu { title, inner } => SubMenu {
                label: title.clone(),
                submenu: build_menu(inner, sender),
                ..Default::default()
            }
            .into(),
            Entry::Item(item) => build_item(item, sender),
        }
    }

    fn build_item(item: &Item, sender: &mpsc::UnboundedSender<Event>) -> MenuItem<FzTray> {
        let label = item.title.clone();
        let enabled = item.event.is_some();
        let event = item.event.clone();
        let sender = sender.clone();
        let activate = Box::new(move |_: &mut FzTray| {
            if let Some(e) = event.clone() {
                let _ = sender.send(e);
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
                activate,
                ..Default::default()
            }
            .into()
        }
    }
}

// ---------------------------------------------------------------------------
// Windows / macOS backend (tray-icon)
// ---------------------------------------------------------------------------

#[cfg(not(target_os = "linux"))]
mod backend {
    use std::cell::RefCell;

    use iced::futures::SinkExt as _;
    use iced::stream;
    use tray_icon::{
        Icon as MudaIcon, TrayIcon, TrayIconBuilder,
        menu::{
            CheckMenuItem, IsMenuItem, Menu as MudaMenu, MenuEvent, MenuId, MenuItem,
            PredefinedMenuItem, Submenu,
        },
    };

    use crate::Message;
    use firezone_gui_client::gui::system_tray::{self, Entry, Icon, Item, Menu};

    thread_local! {
        /// The TrayIcon lives on the main thread (where iced's winit
        /// event loop runs). `RefCell` for interior mutability when
        /// rebuilding the menu / swapping the icon.
        static TRAY: RefCell<Option<TrayIcon>> = const { RefCell::new(None) };
    }

    pub fn install() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let initial_menu = build_muda_menu(&Menu::default());
        let initial_icon = to_muda_icon(&Icon::default())?;
        let tray = TrayIconBuilder::new()
            .with_tooltip("Firezone")
            .with_menu(Box::new(initial_menu))
            .with_icon(initial_icon)
            .build()?;
        TRAY.with(|t| {
            *t.borrow_mut() = Some(tray);
        });
        Ok(())
    }

    /// No-op on Win/Mac; the `TrayIcon` is set up synchronously in
    /// `install()` and muda's global `MenuEvent::receiver()` doesn't
    /// need a service task.
    pub fn spawn_service() {}

    pub fn set_menu(menu: Menu) {
        TRAY.with(|cell| {
            let mut slot = cell.borrow_mut();
            if let Some(tray) = slot.as_mut() {
                // `TrayIcon::set_menu` returns `()` on all platforms
                // — no Result to inspect.
                tray.set_menu(Some(Box::new(build_muda_menu(&menu))));
            }
        });
    }

    pub fn set_icon(icon: Icon) {
        TRAY.with(|cell| {
            let mut slot = cell.borrow_mut();
            if let Some(tray) = slot.as_mut() {
                match to_muda_icon(&icon) {
                    Ok(muda_icon) => {
                        if let Err(e) = tray.set_icon(Some(muda_icon)) {
                            tracing::warn!("failed to set tray icon: {e}");
                        }
                    }
                    Err(e) => tracing::warn!("failed to compose tray icon: {e}"),
                }
            }
        });
    }

    fn to_muda_icon(icon: &Icon) -> Result<MudaIcon, tray_icon::BadIcon> {
        let composed = system_tray::compose_icon(icon);
        MudaIcon::from_rgba(composed.rgba, composed.width, composed.height)
    }

    fn build_muda_menu(menu: &Menu) -> MudaMenu {
        let muda = MudaMenu::new();
        for entry in &menu.entries {
            match make_entry(entry) {
                Ok(item) => {
                    if let Err(e) = muda.append(&*item) {
                        tracing::warn!("failed to append tray menu entry: {e}");
                    }
                }
                Err(e) => tracing::warn!("failed to build tray menu entry: {e}"),
            }
        }
        muda
    }

    fn make_entry(entry: &Entry) -> Result<Box<dyn IsMenuItem>, serde_json::Error> {
        let item: Box<dyn IsMenuItem> = match entry {
            Entry::Separator => Box::new(PredefinedMenuItem::separator()),
            Entry::Submenu { title, inner } => {
                let sub = Submenu::new(title, true);
                for entry in &inner.entries {
                    match make_entry(entry) {
                        Ok(item) => {
                            if let Err(e) = sub.append(&*item) {
                                tracing::warn!("failed to append tray submenu entry: {e}");
                            }
                        }
                        Err(e) => tracing::warn!("failed to build tray submenu entry: {e}"),
                    }
                }
                Box::new(sub)
            }
            Entry::Item(item) => make_item(item)?,
        };
        Ok(item)
    }

    fn make_item(item: &Item) -> Result<Box<dyn IsMenuItem>, serde_json::Error> {
        let Some(event) = &item.event else {
            // No event → disabled placeholder ("Signed in as Foo",
            // "Loading...", "Resources" section header, etc.).
            return Ok(Box::new(MenuItem::new(&item.title, false, None)));
        };
        let id = MenuId::new(serde_json::to_string(event)?);
        let widget: Box<dyn IsMenuItem> = match item.checked {
            Some(checked) => Box::new(CheckMenuItem::with_id(id, &item.title, true, checked, None)),
            None => Box::new(MenuItem::with_id(id, &item.title, true, None)),
        };
        Ok(widget)
    }

    pub fn subscription() -> iced::Subscription<Message> {
        iced::Subscription::run(menu_events)
    }

    fn menu_events() -> impl iced::futures::Stream<Item = Message> {
        stream::channel(
            16,
            |mut output: iced::futures::channel::mpsc::Sender<Message>| async move {
                let receiver = MenuEvent::receiver().clone();
                loop {
                    let event = tokio::task::spawn_blocking({
                        let receiver = receiver.clone();
                        move || receiver.recv()
                    })
                    .await;
                    let Ok(Ok(event)) = event else { break };
                    let Some(msg) = to_message(&event) else {
                        continue;
                    };
                    if output.send(msg).await.is_err() {
                        break;
                    }
                }
            },
        )
    }

    fn to_message(event: &MenuEvent) -> Option<Message> {
        // The menu ID is the JSON-serialized `Event` — same encoding the
        // Tauri client uses, so disabled / placeholder items (without an
        // ID) deserialize to `None` and are silently ignored.
        let event: system_tray::Event = serde_json::from_str(event.id.as_ref()).ok()?;
        Some(Message::TrayEvent(event))
    }
}

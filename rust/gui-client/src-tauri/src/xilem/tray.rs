//! System tray for the xilem GUI.
//!
//! Backend logic (the ksni `StatusNotifierItem` on Linux, tauri-apps's
//! `tray-icon` on macOS/Windows) is the same as [`crate::iced::tray`] — both
//! render the platform-neutral [`Menu`] IR produced by
//! [`crate::gui::system_tray::AppState::into_menu`] and turn each click into a
//! [`Event`](crate::gui::system_tray::Event). The only difference from the
//! iced tray is delivery: instead of an `iced::Subscription`, menu clicks are
//! pushed onto a plain channel that the xilem bridge `worker` drains (see
//! `entry::bridge_main`) and re-emits as `ControllerRequest::SystemTrayMenu` —
//! the same single sink the Tauri and iced clients use.

use crate::gui::system_tray::{Icon, Menu};

/// Set up the tray's static channels and (on Win/Mac) the `TrayIcon`. Must be
/// called from the main thread *before* xilem takes it over (the Win/Mac
/// `TrayIcon` lives in a `thread_local` on its creating thread).
pub fn install() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    backend::install()
}

/// Spawn the platform tray service onto the ambient tokio runtime. On Linux
/// this is the ksni service; on Win/Mac it's a task that forwards muda menu
/// events onto our channel. Must be called from inside a tokio context.
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

/// Take the receiver of tray menu-click [`Event`](crate::gui::system_tray::Event)s.
/// Returns `Some` exactly once (the bridge `worker` owns it thereafter).
pub fn take_event_rx()
-> Option<tokio::sync::mpsc::UnboundedReceiver<crate::gui::system_tray::Event>> {
    backend::take_event_rx()
}

// ---------------------------------------------------------------------------
// Linux backend (ksni)
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
mod backend {
    use std::sync::OnceLock;

    use ksni::{
        Icon as KsniIcon,
        menu::{CheckmarkItem, MenuItem, StandardItem, SubMenu},
    };
    use tokio::sync::mpsc;

    use crate::gui::system_tray::{self, Entry, Event, Icon, Item, Menu};

    static EVENT_TX: OnceLock<mpsc::UnboundedSender<Event>> = OnceLock::new();
    static EVENT_RX: OnceLock<parking_lot::Mutex<Option<mpsc::UnboundedReceiver<Event>>>> =
        OnceLock::new();
    static MENU_TX: OnceLock<mpsc::UnboundedSender<Menu>> = OnceLock::new();
    static ICON_TX: OnceLock<mpsc::UnboundedSender<Icon>> = OnceLock::new();
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

    pub fn take_event_rx() -> Option<mpsc::UnboundedReceiver<Event>> {
        EVENT_RX.get().and_then(|m| m.lock().take())
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

    struct FzTray {
        sender: mpsc::UnboundedSender<Event>,
        menu: Menu,
        icon: Icon,
    }

    impl std::fmt::Debug for FzTray {
        // ksni requires `Tray: Debug`; the inner Menu / Icon don't derive it.
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
    use std::sync::OnceLock;

    use tokio::sync::mpsc;
    use tray_icon::{
        Icon as MudaIcon, TrayIcon, TrayIconBuilder,
        menu::{
            CheckMenuItem, IsMenuItem, Menu as MudaMenu, MenuEvent, MenuId, MenuItem,
            PredefinedMenuItem, Submenu,
        },
    };

    use crate::gui::system_tray::{self, Entry, Event, Icon, Item, Menu};

    thread_local! {
        /// The TrayIcon lives on the main thread (where xilem's winit event
        /// loop runs). `RefCell` for interior mutability when rebuilding the
        /// menu / swapping the icon.
        static TRAY: RefCell<Option<TrayIcon>> = const { RefCell::new(None) };
    }

    static EVENT_TX: OnceLock<mpsc::UnboundedSender<Event>> = OnceLock::new();
    static EVENT_RX: OnceLock<parking_lot::Mutex<Option<mpsc::UnboundedReceiver<Event>>>> =
        OnceLock::new();

    pub fn install() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if EVENT_TX.get().is_none() {
            let (event_tx, event_rx) = mpsc::unbounded_channel::<Event>();
            let _ = EVENT_TX.set(event_tx);
            let _ = EVENT_RX.set(parking_lot::Mutex::new(Some(event_rx)));
        }
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

    pub fn take_event_rx() -> Option<mpsc::UnboundedReceiver<Event>> {
        EVENT_RX.get().and_then(|m| m.lock().take())
    }

    /// Forward muda's global menu events onto our channel. muda's
    /// `MenuEvent::receiver()` is a blocking std channel, so poll it on a
    /// blocking task.
    pub fn spawn_service() {
        let Some(event_tx) = EVENT_TX.get().cloned() else {
            tracing::warn!("tray::spawn_service called before tray::install");
            return;
        };
        tokio::spawn(async move {
            let receiver = MenuEvent::receiver().clone();
            loop {
                let event = tokio::task::spawn_blocking({
                    let receiver = receiver.clone();
                    move || receiver.recv()
                })
                .await;
                let Ok(Ok(event)) = event else { break };
                // The menu ID is the JSON-serialized `Event` — disabled /
                // placeholder items (without an ID) deserialize to `None`.
                let Ok(parsed) = serde_json::from_str::<Event>(event.id.as_ref()) else {
                    continue;
                };
                if event_tx.send(parsed).is_err() {
                    break;
                }
            }
        });
    }

    pub fn set_menu(menu: Menu) {
        TRAY.with(|cell| {
            let mut slot = cell.borrow_mut();
            if let Some(tray) = slot.as_mut() {
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
            return Ok(Box::new(MenuItem::new(&item.title, false, None)));
        };
        let id = MenuId::new(serde_json::to_string(event)?);
        let widget: Box<dyn IsMenuItem> = match item.checked {
            Some(checked) => Box::new(CheckMenuItem::with_id(id, &item.title, true, checked, None)),
            None => Box::new(MenuItem::with_id(id, &item.title, true, None)),
        };
        Ok(widget)
    }
}

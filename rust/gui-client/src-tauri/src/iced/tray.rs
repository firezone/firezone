//! System tray for the iced binary.
//!
//! Two backends, picked at compile time:
//!
//! - **Linux**: [`ksni`] — a pure-Rust StatusNotifierItem implementation
//!   that talks D-Bus directly. No GTK link dep. Works on KDE Plasma,
//!   XFCE, Cinnamon, MATE, and on GNOME *if* the user has the
//!   "AppIndicator and KStatusNotifierItem Support" GNOME Shell
//!   extension installed.
//! - **macOS / Windows**: tauri-apps's [`tray-icon`], which uses
//!   `NSStatusItem` / Win32 directly (no GTK on those platforms).
//!
//! Both backends produce a `Stream<Message>` that the iced application
//! consumes via [`subscription`], and both expose [`set_session`] so the
//! menu can be rebuilt from the Controller's current state.

use crate::Message;

/// Subset of `system_tray::AppState` that the iced tray actually
/// renders. The Controller's full `AppState` carries resource lists,
/// connected devices, update info, etc.; the iced tray ignores those
/// for now and just reflects sign-in / loading / signed-out.
#[derive(Clone, Debug, Default)]
pub enum TraySession {
    #[default]
    Loading,
    SignedOut,
    SignedIn {
        actor_name: String,
    },
    Quitting,
}

impl TraySession {
    pub fn from_app_state(state: &firezone_gui_client::gui::system_tray::AppState) -> Self {
        use firezone_gui_client::gui::system_tray::ConnlibState;
        match &state.connlib {
            ConnlibState::SignedOut => Self::SignedOut,
            ConnlibState::Loading
            | ConnlibState::WaitingForBrowser
            | ConnlibState::WaitingForPortal
            | ConnlibState::WaitingForTunnel => Self::Loading,
            ConnlibState::SignedIn(s) => Self::SignedIn {
                actor_name: s.actor_name.clone(),
            },
            ConnlibState::Quitting => Self::Quitting,
        }
    }
}

/// URLs used by both tray backends. Match the `utm_url(...)` calls in
/// the Tauri client's `system_tray::add_bottom_section`.
pub(crate) const DOCS_URL: &str = "https://www.firezone.dev/kb?utm_source=gui-client";
pub(crate) const SUPPORT_URL: &str = "https://www.firezone.dev/support?utm_source=gui-client";

/// Build the tray.
pub fn install() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    backend::install()
}

/// Push a new session into the running tray; rebuilds the menu.
pub fn set_session(session: TraySession) {
    backend::set_session(session);
}

/// A subscription that emits a [`Message`] for every tray menu click.
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
        Icon,
        menu::{MenuItem, StandardItem, SubMenu},
    };
    use tokio::sync::mpsc;

    use super::TraySession;
    use crate::Message;
    use crate::state::Route;

    /// Sender into the ksni service thread. iced pushes Messages from
    /// menu activations.
    static MENU_TX: OnceLock<mpsc::UnboundedSender<Message>> = OnceLock::new();
    /// Receiver for menu activations; taken by the iced subscription
    /// on its first poll.
    static MENU_RX: OnceLock<parking_lot::Mutex<Option<mpsc::UnboundedReceiver<Message>>>> =
        OnceLock::new();
    /// Sender for session updates from iced → tray thread.
    static SESSION_TX: OnceLock<mpsc::UnboundedSender<TraySession>> = OnceLock::new();

    #[allow(clippy::unnecessary_wraps)]
    pub fn install() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if MENU_TX.get().is_some() {
            return Ok(());
        }
        let (menu_tx, menu_rx) = mpsc::unbounded_channel::<Message>();
        let (session_tx, mut session_rx) = mpsc::unbounded_channel::<TraySession>();
        let _ = MENU_TX.set(menu_tx.clone());
        let _ = MENU_RX.set(parking_lot::Mutex::new(Some(menu_rx)));
        let _ = SESSION_TX.set(session_tx);

        let tray = FzTray {
            sender: menu_tx,
            session: TraySession::Loading,
        };
        std::thread::spawn(move || {
            let rt = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    tracing::warn!("failed to build tokio runtime for tray: {e}");
                    return;
                }
            };
            rt.block_on(async move {
                use ksni::TrayMethods as _;
                match tray.spawn().await {
                    Ok(handle) => {
                        // Drain session updates and refresh the menu.
                        while let Some(s) = session_rx.recv().await {
                            handle
                                .update(|t| {
                                    t.session = s;
                                })
                                .await;
                        }
                    }
                    Err(e) => tracing::warn!("ksni tray failed to spawn: {e}"),
                }
            });
        });
        Ok(())
    }

    pub fn set_session(session: TraySession) {
        if let Some(tx) = SESSION_TX.get() {
            let _ = tx.send(session);
        }
    }

    pub fn subscription() -> iced::Subscription<Message> {
        iced::Subscription::run(menu_events_stream)
    }

    fn menu_events_stream() -> impl iced::futures::Stream<Item = Message> {
        stream::channel(
            16,
            |mut output: iced::futures::channel::mpsc::Sender<Message>| async move {
                let mut rx = match MENU_RX.get().and_then(|m| m.lock().take()) {
                    Some(rx) => rx,
                    None => return,
                };
                while let Some(msg) = rx.recv().await {
                    if output.send(msg).await.is_err() {
                        break;
                    }
                }
            },
        )
    }

    #[derive(Debug)]
    struct FzTray {
        sender: mpsc::UnboundedSender<Message>,
        session: TraySession,
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
        fn icon_pixmap(&self) -> Vec<Icon> {
            decode_logo_argb()
                .map(|(w, h, data)| {
                    vec![Icon {
                        width: w as i32,
                        height: h as i32,
                        data,
                    }]
                })
                .unwrap_or_default()
        }
        fn menu(&self) -> Vec<MenuItem<Self>> {
            build_menu(&self.session, &self.sender)
        }
    }

    fn build_menu(
        session: &TraySession,
        sender: &mpsc::UnboundedSender<Message>,
    ) -> Vec<MenuItem<FzTray>> {
        let send = |msg: Message| {
            let sender = sender.clone();
            Box::new(move |_: &mut FzTray| {
                let _ = sender.send(msg.clone());
            }) as Box<dyn Fn(&mut FzTray) + Send + Sync + 'static>
        };
        let quit_text = match session {
            TraySession::SignedIn { .. } => "Disconnect and quit Firezone",
            TraySession::Loading | TraySession::SignedOut | TraySession::Quitting => {
                "Quit Firezone"
            }
        };

        let mut items: Vec<MenuItem<FzTray>> = Vec::new();
        match session {
            TraySession::Loading => {
                items.push(
                    StandardItem {
                        label: "Loading...".into(),
                        enabled: false,
                        ..Default::default()
                    }
                    .into(),
                );
            }
            TraySession::SignedOut => {
                items.push(
                    StandardItem {
                        label: "Sign In".into(),
                        activate: send(Message::TraySignInClicked),
                        ..Default::default()
                    }
                    .into(),
                );
            }
            TraySession::SignedIn { actor_name } => {
                items.push(
                    StandardItem {
                        label: format!("Signed in as {actor_name}"),
                        enabled: false,
                        ..Default::default()
                    }
                    .into(),
                );
                items.push(
                    StandardItem {
                        label: "Sign Out".into(),
                        activate: send(Message::SignOutPressed),
                        ..Default::default()
                    }
                    .into(),
                );
            }
            TraySession::Quitting => {
                items.push(
                    StandardItem {
                        label: "Quitting...".into(),
                        enabled: false,
                        ..Default::default()
                    }
                    .into(),
                );
            }
        }

        items.push(MenuItem::Separator);
        items.push(
            StandardItem {
                label: "About Firezone".into(),
                activate: send(Message::Navigate(Route::About)),
                ..Default::default()
            }
            .into(),
        );
        items.push(
            StandardItem {
                label: "Admin Portal...".into(),
                activate: send(Message::TrayAdminPortalClicked),
                ..Default::default()
            }
            .into(),
        );
        items.push(
            SubMenu {
                label: "Help".into(),
                submenu: vec![
                    StandardItem {
                        label: "Documentation...".into(),
                        activate: send(Message::OpenExternalUrl(super::DOCS_URL)),
                        ..Default::default()
                    }
                    .into(),
                    StandardItem {
                        label: "Support...".into(),
                        activate: send(Message::OpenExternalUrl(super::SUPPORT_URL)),
                        ..Default::default()
                    }
                    .into(),
                ],
                ..Default::default()
            }
            .into(),
        );
        items.push(
            StandardItem {
                label: "Settings".into(),
                activate: send(Message::Navigate(Route::GeneralSettings)),
                ..Default::default()
            }
            .into(),
        );
        items.push(MenuItem::Separator);
        items.push(
            StandardItem {
                label: quit_text.into(),
                activate: send(Message::TrayQuitClicked),
                ..Default::default()
            }
            .into(),
        );
        items
    }

    fn decode_logo_argb() -> Result<(u32, u32, Vec<u8>), Box<dyn std::error::Error>> {
        let decoder = png::Decoder::new(std::io::Cursor::new(crate::assets::TRAY_LOGO_PNG));
        let mut reader = decoder.read_info()?;
        let size = reader
            .output_buffer_size()
            .ok_or("PNG decoder gave no buffer size")?;
        let mut buf = vec![0u8; size];
        let info = reader.next_frame(&mut buf)?;
        let rgba = match info.color_type {
            png::ColorType::Rgba => buf,
            png::ColorType::Rgb => {
                let mut out = Vec::with_capacity(buf.len() / 3 * 4);
                for chunk in buf.chunks_exact(3) {
                    out.extend_from_slice(chunk);
                    out.push(0xff);
                }
                out
            }
            png::ColorType::Grayscale
            | png::ColorType::GrayscaleAlpha
            | png::ColorType::Indexed => {
                return Err(format!("unsupported PNG color type: {:?}", info.color_type).into());
            }
        };
        let mut argb = Vec::with_capacity(rgba.len());
        for px in rgba.chunks_exact(4) {
            argb.push(px[3]);
            argb.push(px[0]);
            argb.push(px[1]);
            argb.push(px[2]);
        }
        Ok((info.width, info.height, argb))
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
        Icon, TrayIcon, TrayIconBuilder,
        menu::{Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem, Submenu},
    };

    use super::TraySession;
    use crate::Message;
    use crate::assets;
    use crate::state::Route;

    const ID_SIGN_IN: &str = "fz.sign_in";
    const ID_SIGN_OUT: &str = "fz.sign_out";
    const ID_ABOUT: &str = "fz.about";
    const ID_ADMIN_PORTAL: &str = "fz.admin_portal";
    const ID_DOCS: &str = "fz.docs";
    const ID_SUPPORT: &str = "fz.support";
    const ID_SETTINGS: &str = "fz.settings";
    const ID_QUIT: &str = "fz.quit";

    thread_local! {
        /// The TrayIcon lives on the main thread (where iced's winit
        /// event loop runs). `RefCell` for interior mutability when
        /// rebuilding the menu in `set_session`.
        static TRAY: RefCell<Option<TrayIcon>> = const { RefCell::new(None) };
    }

    pub fn install() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let tray = TrayIconBuilder::new()
            .with_tooltip("Firezone")
            .with_menu(Box::new(build_menu(&TraySession::Loading)))
            .with_icon(icon_from_png()?)
            .build()?;
        TRAY.with(|t| {
            *t.borrow_mut() = Some(tray);
        });
        Ok(())
    }

    pub fn set_session(session: TraySession) {
        TRAY.with(|cell| {
            let mut slot = cell.borrow_mut();
            if let Some(tray) = slot.as_mut() {
                let menu = build_menu(&session);
                if let Err(e) = tray.set_menu(Some(Box::new(menu))) {
                    tracing::warn!("failed to update tray menu: {e}");
                }
            }
        });
    }

    fn build_menu(session: &TraySession) -> Menu {
        let menu = Menu::new();
        match session {
            TraySession::Loading => {
                menu.append(&MenuItem::new("Loading...", false, None)).ok();
            }
            TraySession::SignedOut => {
                menu.append(&MenuItem::with_id(
                    MenuId::new(ID_SIGN_IN),
                    "Sign In",
                    true,
                    None,
                ))
                .ok();
            }
            TraySession::SignedIn { actor_name } => {
                menu.append(&MenuItem::new(
                    &format!("Signed in as {actor_name}"),
                    false,
                    None,
                ))
                .ok();
                menu.append(&MenuItem::with_id(
                    MenuId::new(ID_SIGN_OUT),
                    "Sign Out",
                    true,
                    None,
                ))
                .ok();
            }
            TraySession::Quitting => {
                menu.append(&MenuItem::new("Quitting...", false, None)).ok();
            }
        }

        menu.append(&PredefinedMenuItem::separator()).ok();
        menu.append(&MenuItem::with_id(
            MenuId::new(ID_ABOUT),
            "About Firezone",
            true,
            None,
        ))
        .ok();
        menu.append(&MenuItem::with_id(
            MenuId::new(ID_ADMIN_PORTAL),
            "Admin Portal...",
            true,
            None,
        ))
        .ok();

        let help = Submenu::new("Help", true);
        help.append(&MenuItem::with_id(
            MenuId::new(ID_DOCS),
            "Documentation...",
            true,
            None,
        ))
        .ok();
        help.append(&MenuItem::with_id(
            MenuId::new(ID_SUPPORT),
            "Support...",
            true,
            None,
        ))
        .ok();
        menu.append(&help).ok();

        menu.append(&MenuItem::with_id(
            MenuId::new(ID_SETTINGS),
            "Settings",
            true,
            None,
        ))
        .ok();
        menu.append(&PredefinedMenuItem::separator()).ok();
        let quit_label = match session {
            TraySession::SignedIn { .. } => "Disconnect and quit Firezone",
            _ => "Quit Firezone",
        };
        menu.append(&MenuItem::with_id(
            MenuId::new(ID_QUIT),
            quit_label,
            true,
            None,
        ))
        .ok();

        menu
    }

    fn icon_from_png() -> Result<Icon, Box<dyn std::error::Error + Send + Sync>> {
        let decoder = png::Decoder::new(std::io::Cursor::new(assets::TRAY_LOGO_PNG));
        let mut reader = decoder.read_info()?;
        let size = reader
            .output_buffer_size()
            .ok_or("PNG decoder gave no buffer size")?;
        let mut buf = vec![0u8; size];
        let info = reader.next_frame(&mut buf)?;
        let rgba = match info.color_type {
            png::ColorType::Rgba => buf,
            png::ColorType::Rgb => {
                let mut out = Vec::with_capacity(buf.len() / 3 * 4);
                for chunk in buf.chunks_exact(3) {
                    out.extend_from_slice(chunk);
                    out.push(0xff);
                }
                out
            }
            png::ColorType::Grayscale
            | png::ColorType::GrayscaleAlpha
            | png::ColorType::Indexed => {
                return Err(format!("unsupported PNG color type: {:?}", info.color_type).into());
            }
        };
        Ok(Icon::from_rgba(rgba, info.width, info.height)?)
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
                    if let Some(msg) = to_message(&event)
                        && output.send(msg).await.is_err()
                    {
                        break;
                    }
                }
            },
        )
    }

    fn to_message(event: &MenuEvent) -> Option<Message> {
        match event.id.as_ref() {
            ID_QUIT => Some(Message::TrayQuitClicked),
            ID_SIGN_IN => Some(Message::TraySignInClicked),
            ID_SIGN_OUT => Some(Message::SignOutPressed),
            ID_ABOUT => Some(Message::Navigate(Route::About)),
            ID_ADMIN_PORTAL => Some(Message::TrayAdminPortalClicked),
            ID_DOCS => Some(Message::OpenExternalUrl(super::DOCS_URL)),
            ID_SUPPORT => Some(Message::OpenExternalUrl(super::SUPPORT_URL)),
            ID_SETTINGS => Some(Message::Navigate(Route::GeneralSettings)),
            _ => None,
        }
    }
}

//! System tray for the iced binary.
//!
//! Two backends, picked at compile time:
//!
//! - **Linux**: [`ksni`] — a pure-Rust StatusNotifierItem implementation
//!   that talks D-Bus directly. No GTK link dep. Works on KDE Plasma,
//!   XFCE, Cinnamon, MATE, and on GNOME *if* the user has the
//!   "AppIndicator and KStatusNotifierItem Support" GNOME Shell
//!   extension installed (same prerequisite the current Tauri client
//!   already has — vanilla GNOME does not expose SNI by default).
//! - **macOS / Windows**: tauri-apps's [`tray-icon`], which uses
//!   `NSStatusItem` / Win32 directly (no GTK on those platforms).
//!
//! Both backends produce a `Stream<Message>` that the iced application
//! consumes via [`subscription`].

use crate::Message;

/// Build the tray. Idempotent on the platforms where it can be — on
/// Linux it spawns a ksni service; on Windows/macOS it constructs a
/// `TrayIcon` and leaks it.
pub fn install() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    backend::install()
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
        menu::{MenuItem, StandardItem},
    };
    use tokio::sync::mpsc;

    use crate::Message;
    use crate::state::Route;

    /// Sender shared with the running ksni service. Each menu-item
    /// activation closure clones this and pushes a `Message`.
    static SENDER: OnceLock<mpsc::UnboundedSender<Message>> = OnceLock::new();
    /// Receiver picked up by the iced subscription on first poll.
    static RECEIVER: OnceLock<parking_lot::Mutex<Option<mpsc::UnboundedReceiver<Message>>>> =
        OnceLock::new();

    // Returns `Result` to match the cross-platform signature; the
    // Linux side spawns a background thread and the error path will
    // grow real failures once we surface D-Bus connect errors.
    #[allow(clippy::unnecessary_wraps)]
    pub fn install() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if SENDER.get().is_some() {
            return Ok(());
        }
        let (tx, rx) = mpsc::unbounded_channel();
        let _ = SENDER.set(tx.clone());
        let _ = RECEIVER.set(parking_lot::Mutex::new(Some(rx)));

        // `Handle::spawn` returns a `Handle`. Dropping the handle stops
        // the tray, so leak it for the process lifetime.
        let tray = FzTray { sender: tx };
        std::thread::spawn(|| {
            // ksni::TrayMethods::spawn requires a tokio runtime in
            // scope. Build a single-threaded runtime here, dedicated
            // to the tray's D-Bus traffic so it doesn't fight with the
            // iced runtime.
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
                        // Keep the tray alive for the lifetime of the thread.
                        Box::leak(Box::new(handle));
                        // Park the runtime so the D-Bus connection stays open.
                        std::future::pending::<()>().await;
                    }
                    Err(e) => tracing::warn!("ksni tray failed to spawn: {e}"),
                }
            });
        });
        Ok(())
    }

    pub fn subscription() -> iced::Subscription<Message> {
        iced::Subscription::run(menu_events_stream)
    }

    fn menu_events_stream() -> impl iced::futures::Stream<Item = Message> {
        stream::channel(
            16,
            |mut output: iced::futures::channel::mpsc::Sender<Message>| async move {
                // First poll: take the receiver out of the static (only
                // one subscription drains it).
                let mut rx = match RECEIVER.get().and_then(|m| m.lock().take()) {
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

    /// The ksni tray. Implementing `ksni::Tray` is the menu definition.
    #[derive(Debug)]
    struct FzTray {
        sender: mpsc::UnboundedSender<Message>,
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
            let send = |msg: Message| {
                let sender = self.sender.clone();
                Box::new(move |_: &mut Self| {
                    let _ = sender.send(msg.clone());
                }) as Box<dyn Fn(&mut Self) + Send + Sync + 'static>
            };
            vec![
                StandardItem {
                    label: "Show Firezone".into(),
                    activate: send(Message::TrayShowWindow),
                    ..Default::default()
                }
                .into(),
                MenuItem::Separator,
                StandardItem {
                    label: "Overview".into(),
                    activate: send(Message::Navigate(Route::Overview)),
                    ..Default::default()
                }
                .into(),
                StandardItem {
                    label: "Settings".into(),
                    activate: send(Message::Navigate(Route::GeneralSettings)),
                    ..Default::default()
                }
                .into(),
                StandardItem {
                    label: "Diagnostics".into(),
                    activate: send(Message::Navigate(Route::Diagnostics)),
                    ..Default::default()
                }
                .into(),
                StandardItem {
                    label: "About Firezone".into(),
                    activate: send(Message::Navigate(Route::About)),
                    ..Default::default()
                }
                .into(),
                MenuItem::Separator,
                StandardItem {
                    label: "Quit".into(),
                    activate: send(Message::TrayQuitClicked),
                    ..Default::default()
                }
                .into(),
            ]
        }
    }

    /// Decode the bundled PNG to ARGB (the SNI / X11 icon format).
    /// PNG's `png` crate gives us RGBA; we shuffle channels to ARGB.
    fn decode_logo_argb() -> Result<(u32, u32, Vec<u8>), Box<dyn std::error::Error>> {
        let decoder = png::Decoder::new(std::io::Cursor::new(crate::assets::LOGO_PNG));
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
        // RGBA → ARGB (per pixel: R,G,B,A → A,R,G,B).
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
    use iced::futures::SinkExt as _;
    use iced::stream;
    use tray_icon::{
        Icon, TrayIconBuilder,
        menu::{Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem},
    };

    use crate::Message;
    use crate::assets;
    use crate::state::Route;

    const ID_SHOW: &str = "fz.show";
    const ID_OVERVIEW: &str = "fz.overview";
    const ID_SETTINGS: &str = "fz.settings";
    const ID_DIAGNOSTICS: &str = "fz.diagnostics";
    const ID_ABOUT: &str = "fz.about";
    const ID_QUIT: &str = "fz.quit";

    pub fn install() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let menu = Menu::new();
        menu.append(&MenuItem::with_id(
            MenuId::new(ID_SHOW),
            "Show Firezone",
            true,
            None,
        ))
        .ok();
        menu.append(&PredefinedMenuItem::separator()).ok();
        menu.append(&MenuItem::with_id(
            MenuId::new(ID_OVERVIEW),
            "Overview",
            true,
            None,
        ))
        .ok();
        menu.append(&MenuItem::with_id(
            MenuId::new(ID_SETTINGS),
            "Settings",
            true,
            None,
        ))
        .ok();
        menu.append(&MenuItem::with_id(
            MenuId::new(ID_DIAGNOSTICS),
            "Diagnostics",
            true,
            None,
        ))
        .ok();
        menu.append(&MenuItem::with_id(
            MenuId::new(ID_ABOUT),
            "About Firezone",
            true,
            None,
        ))
        .ok();
        menu.append(&PredefinedMenuItem::separator()).ok();
        menu.append(&MenuItem::with_id(MenuId::new(ID_QUIT), "Quit", true, None))
            .ok();

        let tray = TrayIconBuilder::new()
            .with_tooltip("Firezone")
            .with_menu(Box::new(menu))
            .with_icon(icon_from_png()?)
            .build()?;
        Box::leak(Box::new(tray));
        Ok(())
    }

    fn icon_from_png() -> Result<Icon, Box<dyn std::error::Error + Send + Sync>> {
        let decoder = png::Decoder::new(std::io::Cursor::new(assets::LOGO_PNG));
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
        stream::channel(16, |mut output| async move {
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
        })
    }

    fn to_message(event: &MenuEvent) -> Option<Message> {
        match event.id.as_ref() {
            ID_QUIT => Some(Message::TrayQuitClicked),
            ID_SHOW => Some(Message::TrayShowWindow),
            ID_OVERVIEW => Some(Message::Navigate(Route::Overview)),
            ID_SETTINGS => Some(Message::Navigate(Route::GeneralSettings)),
            ID_DIAGNOSTICS => Some(Message::Navigate(Route::Diagnostics)),
            ID_ABOUT => Some(Message::Navigate(Route::About)),
            _ => None,
        }
    }
}

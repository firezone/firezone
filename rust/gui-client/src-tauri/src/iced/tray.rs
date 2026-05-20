//! System tray for the iced binary.
//!
//! `tray-icon` (tauri-apps's, version 0.23) handles the platform plumbing.
//! Its events arrive on a global `crossbeam_channel::Receiver` returned by
//! `MenuEvent::receiver()`; we bridge that into iced via a long-running
//! `Subscription` (see [`subscription`]).
//!
//! ### Linux note
//! tray-icon talks AppIndicator/StatusNotifierItem over D-Bus on Linux.
//! Vanilla GNOME does *not* expose tray icons natively — users need the
//! "AppIndicator and KStatusNotifierItem Support" GNOME Shell extension
//! installed for the icon to appear. This is the same limitation the
//! existing Tauri client has, and there is no Rust-side fix.

use iced::futures::SinkExt as _;
use iced::stream;
use tray_icon::{
    Icon, TrayIconBuilder,
    menu::{Menu, MenuEvent, MenuId, MenuItem},
};

use crate::Message;
use crate::assets;
use crate::state::Route;

/// IDs we put on the menu items so we can recognise them when an event
/// comes back. Kept as constants so `MenuEvent::id` matching is robust.
const ID_SHOW: &str = "fz.show";
const ID_OVERVIEW: &str = "fz.overview";
const ID_SETTINGS: &str = "fz.settings";
const ID_DIAGNOSTICS: &str = "fz.diagnostics";
const ID_ABOUT: &str = "fz.about";
const ID_QUIT: &str = "fz.quit";

/// Build the tray. The `TrayIcon` is leaked so it stays alive for the
/// lifetime of the process (dropping it removes the icon from the
/// system tray, and `TrayIcon` on Linux is `!Send` so it can't live in
/// a regular `static`). Returns `Err` if the platform refuses to
/// attach the icon (most commonly: no D-Bus / no AppIndicator extension
/// on Linux).
pub fn install() -> Result<(), tray_icon::Error> {
    let menu = Menu::new();
    menu.append(&MenuItem::with_id(
        MenuId::new(ID_SHOW),
        "Show Firezone",
        true,
        None,
    ))
    .ok();
    menu.append(&tray_icon::menu::PredefinedMenuItem::separator())
        .ok();
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
    menu.append(&tray_icon::menu::PredefinedMenuItem::separator())
        .ok();
    menu.append(&MenuItem::with_id(MenuId::new(ID_QUIT), "Quit", true, None))
        .ok();

    let tray = TrayIconBuilder::new()
        .with_tooltip("Firezone")
        .with_menu(Box::new(menu))
        .with_icon(icon_from_png()?)
        .build()?;

    // `TrayIcon` on Linux holds an `Rc<RefCell<...>>` so it can't live
    // in a `static` (not `Send`). Leak it to keep the icon up for the
    // lifetime of the process.
    Box::leak(Box::new(tray));
    Ok(())
}

fn icon_from_png() -> Result<Icon, tray_icon::Error> {
    let decoder = png::Decoder::new(std::io::Cursor::new(assets::LOGO_PNG));
    let mut reader = decoder
        .read_info()
        .map_err(|e| tray_icon::Error::OsError(std::io::Error::other(e.to_string())))?;
    let size = reader.output_buffer_size().ok_or_else(|| {
        tray_icon::Error::OsError(std::io::Error::other("PNG decoder gave no buffer size"))
    })?;
    let mut buf = vec![0; size];
    let info = reader
        .next_frame(&mut buf)
        .map_err(|e| tray_icon::Error::OsError(std::io::Error::other(e.to_string())))?;
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
        png::ColorType::Grayscale | png::ColorType::GrayscaleAlpha | png::ColorType::Indexed => {
            return Err(tray_icon::Error::OsError(std::io::Error::other(format!(
                "unsupported PNG color type for tray icon: {:?}",
                info.color_type
            ))));
        }
    };
    Icon::from_rgba(rgba, info.width, info.height)
        .map_err(|e| tray_icon::Error::OsError(std::io::Error::other(e.to_string())))
}

/// A subscription that forwards tray menu events into iced as
/// [`Message`]s. tray-icon's event channel is sync (crossbeam_channel),
/// so we run a blocking-recv loop on a dedicated tokio task.
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
    let id = event.id.as_ref();
    match id {
        ID_QUIT => Some(Message::TrayQuitClicked),
        ID_SHOW => Some(Message::TrayShowWindow),
        ID_OVERVIEW => Some(Message::Navigate(Route::Overview)),
        ID_SETTINGS => Some(Message::Navigate(Route::GeneralSettings)),
        ID_DIAGNOSTICS => Some(Message::Navigate(Route::Diagnostics)),
        ID_ABOUT => Some(Message::Navigate(Route::About)),
        _ => None,
    }
}

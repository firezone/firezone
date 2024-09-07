//! The public tray wrapper that contains the icon and menu handles.

use super::{AppState, ConnlibState, Event, build_menu, builder::Item};
use crate::{
    compositor::{self, Image},
    updates::Release,
};
use anyhow::Result;
use connlib_shared::{
    callbacks::{ResourceDescription, Status},
    messages::ResourceId,
};
use std::collections::{BTreeMap, HashSet};
use tokio::sync::mpsc;
use tray_icon::menu as concrete;
use url::Url;

// Figma is the source of truth for the tray icon layers
// <https://www.figma.com/design/THvQQ1QxKlsk47H9DZ2bhN/Core-Library?node-id=1250-772&t=nHBOzOnSY5Ol4asV-0>
macro_rules! icon_layer {
    ($file:expr) => {
        include_bytes!(concat!("../../../src-tauri/icons/tray/", $file))
    };
}

const LOGO_BASE: &[u8] = icon_layer!("Logo.png");
const LOGO_GREY_BASE: &[u8] = icon_layer!("Logo grey.png");
const BUSY_LAYER: &[u8] = icon_layer!("Busy layer.png");
const SIGNED_OUT_LAYER: &[u8] = icon_layer!("Signed out layer.png");
const UPDATE_READY_LAYER: &[u8] = icon_layer!("Update ready layer.png");

// Strings
const TOOLTIP: &str = "Firezone";

pub(crate) struct Tray {
    handle: tray_icon::TrayIcon,
    last_icon_set: Icon,
    /// Maps from `tray_icons` menu IDs to GUI Client events
    map: BTreeMap<u32, Event>,
}

#[derive(PartialEq)]
pub struct Icon {
    pub base: IconBase,
    pub update_ready: bool,
}

#[derive(PartialEq)]
pub enum IconBase {
    /// Must be equivalent to the default app icon, since we assume this is set when we start
    Busy,
    SignedIn,
    SignedOut,
}

impl Default for Icon {
    fn default() -> Self {
        Self {
            base: IconBase::Busy,
            update_ready: false,
        }
    }
}

impl Tray {
    pub(crate) fn new() -> Result<(Self, mpsc::Receiver<tray_icon::TrayEvent>)> {
        // Hopefully this channel doesn't deadlock the GTK+ main loop by accident.
        let (tx, rx) = mpsc::channel(5);
        // This is global mutable state, but the GUI process will only ever have
        // zero or one tray icons so it should be okay.
        tray_icon::TrayEvent::set_event_handler(Some(move |event| {
            if let Err(error) = tx.blocking_send(event) {
                tracing::error!(?error, "Failed to send sys tray event to `Controller`.");
            }
        }));

        let MenuAndMap { map, menu } = build_app_state(AppState {
            connlib: ConnlibState::Loading,
            release: None,
        });
        let icon = Default::default();
        let tray_attrs = tray_icon::TrayIconAttributes {
            tooltip: Some(TOOLTIP.to_string()),
            menu: Some(Box::new(menu)),
            icon: Some(build_icon(&icon)),
            temp_dir_path: None, // This is probably where this silly PNGs get dumped.
            icon_is_template: false,
            menu_on_left_click: true, // Doesn't work on Windows
            title: Some("TODO".to_string()),
        };
        let handle = tray_icon::TrayIcon::new(tray_attrs)?;

        Ok((
            Self {
                handle,
                last_icon_set: icon,
                map,
            },
            rx,
        ))
    }

    pub(crate) fn translate_event(&self, input: tray_icon::TrayEvent) -> Option<Event> {
        self.map.get(&input.id).cloned()
    }

    pub(crate) fn update(&mut self, state: AppState) -> Result<()> {
        let base = match &state.connlib {
            ConnlibState::AppTerminating | ConnlibState::SignedOut => IconBase::SignedOut,
            ConnlibState::Loading
            | ConnlibState::RetryingConnection
            | ConnlibState::WaitingForBrowser
            | ConnlibState::WaitingForPortal
            | ConnlibState::WaitingForTunnel => IconBase::Busy,
            ConnlibState::SignedIn { .. } => IconBase::SignedIn,
        };
        let update_ready =
            state.release.is_some() && !matches!(state.connlib, ConnlibState::AppTerminating);
        let new_icon = Icon { base, update_ready };

        let MenuAndMap { map, menu } = build_app_state(state);

        self.map = map;
        self.handle.set_tooltip(Some(TOOLTIP))?;
        self.handle.set_menu(Some(Box::new(menu)));
        self.set_icon(new_icon)?;

        Ok(())
    }

    pub(crate) fn set_icon(&mut self, icon: Icon) -> Result<()> {
        if icon != self.last_icon_set {
            // Don't call `set_icon` too often. On Linux it writes a PNG to `/run/user/$UID/tao/tray-icon-*.png` every single time.
            // <https://github.com/tauri-apps/tao/blob/tao-v0.16.7/src/platform_impl/linux/system_tray.rs#L119>
            // Yes, even if you use `Icon::File` and tell Tauri that the icon is already
            // on disk.
            self.handle.set_icon(Some(build_icon(&icon)))?;
            self.last_icon_set = icon;
        }
        Ok(())
    }
}

fn build_icon(that: &Icon) -> tray_icon::icon::Icon {
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
    build_image(composed)
}

fn build_image(val: Image) -> tray_icon::icon::Icon {
    tray_icon::icon::Icon::from_rgba(val.rgba, val.width, val.height)
        .expect("Should always be able to convert our icon format to that of `tray_icon`")
}

struct MenuAndMap {
    map: BTreeMap<u32, Event>,
    menu: concrete::Submenu,
}

fn build_app_state(that: AppState) -> MenuAndMap {
    let mut map = BTreeMap::default();
    let menu = build_menu(that.into_menu(), &mut map);
    MenuAndMap { menu, map }
}

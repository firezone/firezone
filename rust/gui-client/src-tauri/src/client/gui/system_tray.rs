//! Code for the Windows notification area
//!
//! "Notification Area" is Microsoft's official name instead of "System tray":
//! <https://learn.microsoft.com/en-us/windows/win32/shell/notification-area?redirectedfrom=MSDN#notifications-and-the-notification-area>

use anyhow::Result;
use connlib_client_shared::callbacks::{ResourceDescription, Status};
use serde::{Deserialize, Serialize};
use tauri::{
    CustomMenuItem, SystemTray, SystemTrayHandle, SystemTrayMenu, SystemTrayMenuItem,
    SystemTraySubmenu,
};
use url::Url;

// Figma is the source of truth for the tray icons
// <https://www.figma.com/design/THvQQ1QxKlsk47H9DZ2bhN/Core-Library?node-id=1250-772&t=OGFabKWPx7PRUZmq-0>
const BUSY_ICON: &[u8] = include_bytes!("../../../icons/tray/Busy.png");
const SIGNED_IN_ICON: &[u8] = include_bytes!("../../../icons/tray/Signed In.png");
const SIGNED_OUT_ICON: &[u8] = include_bytes!("../../../icons/tray/Signed Out.png");
const TOOLTIP: &str = "Firezone";

pub(crate) fn loading() -> SystemTray {
    SystemTray::new()
        .with_icon(tauri::Icon::Raw(BUSY_ICON.into()))
        .with_menu(Menu::Loading.build())
        .with_tooltip(TOOLTIP)
}

pub(crate) struct Tray {
    handle: SystemTrayHandle,
    last_icon_set: Icon,
}

pub(crate) enum Menu<'a> {
    Loading,
    SignedOut,
    WaitingForBrowser,
    WaitingForConnlib,
    SignedIn {
        actor_name: &'a str,
        resources: &'a [ResourceDescription],
    },
}

#[derive(PartialEq)]
enum Icon {
    /// Must be equivalent to the default app icon, since we assume this is set when we start
    Busy,
    SignedIn,
    SignedOut,
}

impl Default for Icon {
    fn default() -> Self {
        Self::Busy
    }
}

impl Tray {
    pub(crate) fn new(handle: SystemTrayHandle) -> Self {
        Self {
            handle,
            last_icon_set: Default::default(),
        }
    }

    pub(crate) fn update(&mut self, menu: Menu) -> Result<()> {
        let new_icon = match &menu {
            Menu::Loading | Menu::WaitingForBrowser | Menu::WaitingForConnlib => Icon::Busy,
            Menu::SignedOut => Icon::SignedOut,
            Menu::SignedIn { .. } => Icon::SignedIn,
        };

        let handle = &self.handle;
        handle.set_tooltip(TOOLTIP)?;
        handle.set_menu(menu.build())?;

        if new_icon != self.last_icon_set {
            // Don't call `set_icon` too often. On Linux it writes a PNG to `/run/user/$UID/tao/tray-icon-*.png` every single time.
            // <https://github.com/tauri-apps/tao/blob/tao-v0.16.7/src/platform_impl/linux/system_tray.rs#L119>
            // Yes, even if you use `Icon::File` and tell Tauri that the icon is already
            // on disk.
            handle.set_icon(new_icon.tauri_icon())?;
            self.last_icon_set = new_icon;
        }

        Ok(())
    }
}

impl Icon {
    fn tauri_icon(&self) -> tauri::Icon {
        let bytes = match self {
            Self::Busy => BUSY_ICON,
            Self::SignedIn => SIGNED_IN_ICON,
            Self::SignedOut => SIGNED_OUT_ICON,
        };
        tauri::Icon::Raw(bytes.into())
    }
}

impl<'a> Menu<'a> {
    fn build(self) -> SystemTrayMenu {
        match self {
            Menu::Loading => SystemTrayMenu::new().disabled("Loading..."),
            Menu::SignedOut => SystemTrayMenu::new()
                .item(Event::SignIn, "Sign In")
                .add_bottom_section(QUIT_TEXT_SIGNED_OUT),
            Menu::WaitingForBrowser => signing_in("Waiting for browser..."),
            Menu::WaitingForConnlib => signing_in("Signing In..."),
            Menu::SignedIn {
                actor_name,
                resources,
            } => signed_in(actor_name, resources),
        }
    }
}

#[derive(Debug, Deserialize, PartialEq, Serialize)]
pub(crate) enum Event {
    AdminPortal,
    CancelSignIn,
    Copy(String),
    SignIn,
    SignOut,
    ShowWindow(Window),
    Url(Url),
    Quit,
}

#[derive(Debug, Deserialize, PartialEq, Serialize)]
pub(crate) enum Window {
    About,
    Settings,
}

const QUIT_TEXT_SIGNED_OUT: &str = "Quit Firezone";

fn get_submenu(res: &ResourceDescription) -> SystemTrayMenu {
    let submenu = SystemTrayMenu::new();

    let Some(address_description) = res.address_description() else {
        return submenu.copyable(&res.pastable());
    };

    if address_description.is_empty() {
        return submenu.copyable(&res.pastable());
    }

    let Ok(url) = Url::parse(address_description) else {
        return submenu.copyable(address_description);
    };

    submenu.item(Event::Url(url), address_description)
}

fn signed_in(user_name: &str, resources: &[ResourceDescription]) -> SystemTrayMenu {
    let mut menu = SystemTrayMenu::new()
        .disabled(format!("Signed in as {user_name}"))
        .item(Event::SignOut, "Sign out")
        .separator()
        .disabled("Resources");

    tracing::info!(
        resource_count = resources.len(),
        "Building signed-in tray menu"
    );
    for res in resources {
        let submenu = get_submenu(res);

        let submenu = submenu
            .separator()
            .disabled("Resource")
            .copyable(res.name())
            .copyable(res.pastable().as_ref());

        let submenu = if let Some(site) = res.sites().first() {
            // Emojis may be causing an issue on some Ubuntu desktop environments.
            let status = match res.status() {
                Status::Unknown => "[-] No activity",
                Status::Online => "[O] Gateway connected",
                Status::Offline => "[X] All Gateways offline",
            };

            submenu
                .separator()
                .disabled("Site")
                .item(None, &site.name)
                .item(None, status)
        } else {
            submenu
        };
        menu = menu.add_submenu(SystemTraySubmenu::new(res.name(), submenu));
    }

    menu.add_bottom_section("Disconnect and quit Firezone")
}

fn signing_in(waiting_message: &str) -> SystemTrayMenu {
    SystemTrayMenu::new()
        .disabled(waiting_message)
        .item(Event::CancelSignIn, "Cancel sign-in")
        .add_bottom_section(QUIT_TEXT_SIGNED_OUT)
}

trait FirezoneMenu {
    fn accelerated(self, id: Event, title: &str, accelerator: &str) -> Self;
    fn add_bottom_section(self, quit_text: &str) -> Self;
    fn copyable(self, s: &str) -> Self;
    fn disabled<S: Into<String>>(self, title: S) -> Self;
    fn item<E: Into<Option<Event>>, S: Into<String>>(self, id: E, title: S) -> Self;
    fn separator(self) -> Self;
}

impl FirezoneMenu for SystemTrayMenu {
    /// An item with an event and a keyboard accelerator
    ///
    /// Doesn't work on Windows: <https://github.com/tauri-apps/wry/issues/451>
    fn accelerated(self, id: Event, title: &str, accelerator: &str) -> Self {
        self.add_item(item(id, title).accelerator(accelerator))
    }

    /// Things that always show, like About, Settings, Help, Quit, etc.
    fn add_bottom_section(self, quit_text: &str) -> Self {
        self.separator()
            .item(Event::ShowWindow(Window::About), "About Firezone")
            .item(Event::AdminPortal, "Admin Portal...")
            .add_submenu(SystemTraySubmenu::new(
                "Help",
                SystemTrayMenu::new()
                    .item(
                        Event::Url(utm_url("https://www.firezone.dev/kb")),
                        "Documentation...",
                    )
                    .item(
                        Event::Url(utm_url("https://www.firezone.dev/support")),
                        "Support...",
                    ),
            ))
            .accelerated(
                Event::ShowWindow(Window::Settings),
                "Settings",
                "Ctrl+Shift+,",
            )
            .separator()
            .accelerated(Event::Quit, quit_text, "Ctrl+Q")
    }

    fn copyable(self, s: &str) -> Self {
        self.item(Event::Copy(s.to_string()), s)
    }

    /// A disabled item with no accelerator or event
    fn disabled<S: Into<String>>(self, title: S) -> Self {
        self.add_item(item(None, title).disabled())
    }

    fn item<E: Into<Option<Event>>, S: Into<String>>(self, id: E, title: S) -> Self {
        self.add_item(item(id, title))
    }

    fn separator(self) -> Self {
        self.add_native_item(SystemTrayMenuItem::Separator)
    }
}

// I just thought this function call was too verbose
fn item<E: Into<Option<Event>>, S: Into<String>>(id: E, title: S) -> CustomMenuItem {
    CustomMenuItem::new(
        serde_json::to_string(&id.into())
            .expect("`serde_json` should always be able to serialize tray menu events"),
        title,
    )
}

fn utm_url(base_url: &str) -> Url {
    Url::parse(&format!(
        "{base_url}?utm_source={}-client",
        std::env::consts::OS
    ))
    .expect("Hard-coded URL should always be parsable")
}

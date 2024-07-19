//! Code for the system tray AKA notification area
//!
//! This manages the icon, menu, and tooltip.
//!
//! "Notification Area" is Microsoft's official name instead of "System tray":
//! <https://learn.microsoft.com/en-us/windows/win32/shell/notification-area?redirectedfrom=MSDN#notifications-and-the-notification-area>

use anyhow::Result;
use connlib_client_shared::callbacks::{ResourceDescription, Status};
use connlib_shared::messages::ResourceId;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use tauri::{
    CustomMenuItem, SystemTray, SystemTrayHandle, SystemTrayMenu, SystemTrayMenuItem,
    SystemTraySubmenu,
};
use url::Url;

// Figma is the source of truth for the tray icons
// <https://www.figma.com/design/THvQQ1QxKlsk47H9DZ2bhN/Core-Library?node-id=1250-772&t=OGFabKWPx7PRUZmq-0>
const BUSY_ICON: &[u8] = include_bytes!("../../../icons/tray/Busy.png");
const SIGNED_IN_ICON: &[u8] = include_bytes!("../../../icons/tray/Signed in.png");
const SIGNED_OUT_ICON: &[u8] = include_bytes!("../../../icons/tray/Signed out.png");
const TOOLTIP: &str = "Firezone";
const QUIT_TEXT_SIGNED_OUT: &str = "Quit Firezone";

#[derive(Debug, Deserialize, PartialEq, Serialize)]
pub(crate) enum Event {
    AddFavorite(ResourceId),
    AdminPortal,
    CancelSignIn,
    Copy(String),
    RemoveFavorite(ResourceId),
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
    SignedIn(SignedIn<'a>),
}

pub(crate) struct SignedIn<'a> {
    pub(crate) actor_name: &'a str,
    pub(crate) favorite_resources: &'a HashSet<ResourceId>,
    pub(crate) resources: &'a [ResourceDescription],
}

impl<'a> SignedIn<'a> {
    fn has_any_favorites(&self) -> bool {
        !self.favorite_resources.is_empty()
    }

    fn is_favorite(&self, res: &ResourceDescription) -> bool {
        self.favorite_resources.contains(&res.id())
    }

    /// Builds the submenu that has the resource address, name, desc,
    /// sites online, etc.
    fn resource_submenu(&self, res: &ResourceDescription) -> SystemTrayMenu {
        let submenu = SystemTrayMenu::new().add_item(resource_header(res));

        let submenu = if self.is_favorite(res) {
            submenu.add_item(item(Event::RemoveFavorite(res.id()), "Remove favorite").selected())
        } else {
            submenu.item(Event::AddFavorite(res.id()), "Add favorite")
        };

        let submenu = submenu
            .separator()
            .disabled("Resource")
            .copyable(res.name())
            .copyable(res.pastable().as_ref());

        if let Some(site) = res.sites().first() {
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
        }
    }
}

fn resource_header(res: &ResourceDescription) -> CustomMenuItem {
    let Some(address_description) = res.address_description() else {
        return copyable(&res.pastable());
    };

    if address_description.is_empty() {
        return copyable(&res.pastable());
    }

    let Ok(url) = Url::parse(address_description) else {
        return copyable(address_description);
    };

    item(Event::Url(url), address_description)
}

#[derive(PartialEq)]
pub(crate) enum Icon {
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

        self.handle.set_tooltip(TOOLTIP)?;
        self.handle.set_menu(menu.build())?;
        self.set_icon(new_icon)?;

        Ok(())
    }

    // Normally only needed for the stress test
    pub(crate) fn set_icon(&mut self, icon: Icon) -> Result<()> {
        if icon != self.last_icon_set {
            // Don't call `set_icon` too often. On Linux it writes a PNG to `/run/user/$UID/tao/tray-icon-*.png` every single time.
            // <https://github.com/tauri-apps/tao/blob/tao-v0.16.7/src/platform_impl/linux/system_tray.rs#L119>
            // Yes, even if you use `Icon::File` and tell Tauri that the icon is already
            // on disk.
            self.handle.set_icon(icon.tauri_icon())?;
            self.last_icon_set = icon;
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
            Menu::SignedIn(x) => signed_in(&x),
        }
    }
}

fn signed_in(signed_in: &SignedIn) -> SystemTrayMenu {
    let SignedIn {
        actor_name,
        favorite_resources,
        resources,
    } = signed_in;

    let mut menu = SystemTrayMenu::new()
        .disabled(format!("Signed in as {actor_name}"))
        .item(Event::SignOut, "Sign out")
        .separator()
        .disabled("Resources");

    tracing::info!(
        resource_count = resources.len(),
        "Building signed-in tray menu"
    );
    if signed_in.has_any_favorites() {
        for res in resources
            .iter()
            .filter(|res| favorite_resources.contains(&res.id()))
        {
            menu = menu.add_submenu(SystemTraySubmenu::new(
                res.name(),
                signed_in.resource_submenu(res),
            ));
        }
    } else {
        // No favorites, show every Resource normally, just like before
        // the favoriting feature was created
        for res in *resources {
            menu = menu.add_submenu(SystemTraySubmenu::new(
                res.name(),
                signed_in.resource_submenu(res),
            ));
        }
    }

    if signed_in.has_any_favorites() {
        let mut submenu = SystemTrayMenu::new();
        for res in resources
            .iter()
            .filter(|res| !favorite_resources.contains(&res.id()))
        {
            submenu = submenu.add_submenu(SystemTraySubmenu::new(
                res.name(),
                signed_in.resource_submenu(res),
            ));
        }
        menu = menu.add_submenu(SystemTraySubmenu::new("Non-favorite resources", submenu));
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
    /// Appends an item with an event and a keyboard accelerator
    ///
    /// Doesn't work on Windows: <https://github.com/tauri-apps/wry/issues/451>
    fn accelerated(self, id: Event, title: &str, accelerator: &str) -> Self {
        self.add_item(item(id, title).accelerator(accelerator))
    }

    /// Appends things that always show, like About, Settings, Help, Quit, etc.
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

    /// Appends a menu item that copies its title when clicked
    fn copyable(self, s: &str) -> Self {
        self.add_item(copyable(s))
    }

    /// Appends a disabled item with no accelerator or event
    fn disabled<S: Into<String>>(self, title: S) -> Self {
        self.add_item(item(None, title).disabled())
    }

    /// Appends a generic menu item
    fn item<E: Into<Option<Event>>, S: Into<String>>(self, id: E, title: S) -> Self {
        self.add_item(item(id, title))
    }

    /// Appends a separator
    fn separator(self) -> Self {
        self.add_native_item(SystemTrayMenuItem::Separator)
    }
}

/// Creates a menu item that copies its title when clicked
fn copyable(s: &str) -> CustomMenuItem {
    item(Event::Copy(s.to_string()), s)
}

/// Creates a generic menu item with one of our events attached
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

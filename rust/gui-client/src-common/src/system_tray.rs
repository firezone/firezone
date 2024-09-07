//! Code for the system tray AKA notification area
//!
//! This manages the icon, menu, and tooltip.
//!
//! "Notification Area" is Microsoft's official name instead of "System tray":
//! <https://learn.microsoft.com/en-us/windows/win32/shell/notification-area?redirectedfrom=MSDN#notifications-and-the-notification-area>

use crate::compositor::{self, Image};
use crate::updates::Release;
use anyhow::Result;
use connlib_shared::{
    callbacks::{ResourceDescription, Status},
    messages::ResourceId,
};
use std::collections::{BTreeMap, HashSet};
use tokio::sync::mpsc;
use tray_icon::menu as concrete;
use url::Url;

use builder::item;
pub use builder::{Entry, Event, Item, Menu, Window};

const QUIT_TEXT_SIGNED_OUT: &str = "Quit Firezone";

const NO_ACTIVITY: &str = "[-] No activity";
const GATEWAY_CONNECTED: &str = "[O] Gateway connected";
const ALL_GATEWAYS_OFFLINE: &str = "[X] All Gateways offline";

const ENABLED_SYMBOL: &str = "<->";
const DISABLED_SYMBOL: &str = "—";

const ADD_FAVORITE: &str = "Add to favorites";
const REMOVE_FAVORITE: &str = "Remove from favorites";
const FAVORITE_RESOURCES: &str = "Favorite Resources";
const RESOURCES: &str = "Resources";
const OTHER_RESOURCES: &str = "Other Resources";
const SIGN_OUT: &str = "Sign out";
const DISCONNECT_AND_QUIT: &str = "Disconnect and quit Firezone";
const DISABLE: &str = "Disable this resource";
const ENABLE: &str = "Enable this resource";

mod builder;
mod tray;

#[cfg(test)]
mod tests;

pub(crate) use tray::Tray;

pub struct AppState<'a> {
    pub connlib: ConnlibState<'a>,
    pub release: Option<Release>,
}

impl<'a> AppState<'a> {
    fn into_menu(self) -> Menu {
        let quit_text = match &self.connlib {
            ConnlibState::AppTerminating
            | ConnlibState::Loading
            | ConnlibState::RetryingConnection
            | ConnlibState::SignedOut
            | ConnlibState::WaitingForBrowser
            | ConnlibState::WaitingForPortal
            | ConnlibState::WaitingForTunnel => QUIT_TEXT_SIGNED_OUT,
            ConnlibState::SignedIn(_) => DISCONNECT_AND_QUIT,
        };
        let menu = match self.connlib {
            ConnlibState::AppTerminating => Menu::default().disabled("Quitting..."),
            ConnlibState::Loading => Menu::default().disabled("Loading..."),
            ConnlibState::RetryingConnection => retrying_sign_in("Waiting for Internet access..."),
            ConnlibState::SignedIn(x) => signed_in(&x),
            ConnlibState::SignedOut => Menu::default().item(Event::SignIn, "Sign In"),
            ConnlibState::WaitingForBrowser => signing_in("Waiting for browser..."),
            ConnlibState::WaitingForPortal => signing_in("Connecting to Firezone Portal..."),
            ConnlibState::WaitingForTunnel => signing_in("Raising tunnel..."),
        };
        menu.add_bottom_section(self.release, quit_text)
    }

    /// Generic icon and empty menu for unusual terminating cases like if the IPC service stops running
    pub(crate) fn terminating() -> Self {
        Self {
            connlib: ConnlibState::AppTerminating,
            release: None,
        }
    }
}

pub enum ConnlibState<'a> {
    AppTerminating,
    Loading,
    RetryingConnection,
    SignedIn(SignedIn<'a>),
    SignedOut,
    WaitingForBrowser,
    WaitingForPortal,
    WaitingForTunnel,
}

pub struct SignedIn<'a> {
    pub actor_name: &'a str,
    pub favorite_resources: &'a HashSet<ResourceId>,
    pub resources: &'a [ResourceDescription],
    pub internet_resource_enabled: &'a Option<bool>,
}

impl<'a> SignedIn<'a> {
    fn is_favorite(&self, resource: &ResourceId) -> bool {
        self.favorite_resources.contains(resource)
    }

    fn add_favorite_toggle(&self, submenu: &mut Menu, resource: ResourceId) {
        if self.is_favorite(&resource) {
            submenu.add_item(item(Event::RemoveFavorite(resource), REMOVE_FAVORITE).selected());
        } else {
            submenu.add_item(item(Event::AddFavorite(resource), ADD_FAVORITE));
        }
    }

    /// Builds the submenu that has the resource address, name, desc,
    /// sites online, etc.
    fn resource_submenu(&self, res: &ResourceDescription) -> Menu {
        let mut name = res.name().to_string();
        if res.is_internet_resource() {
            name = append_status(&name, self.internet_resource_enabled.unwrap_or_default());
        }
        let mut submenu = Menu::new(name).resource_description(res);

        if res.is_internet_resource() {
            submenu.add_separator();
            if self.is_internet_resource_enabled() {
                submenu.add_item(item(Event::DisableInternetResource, DISABLE));
            } else {
                submenu.add_item(item(Event::EnableInternetResource, ENABLE));
            }
        }

        if !res.is_internet_resource() {
            self.add_favorite_toggle(&mut submenu, res.id());
        }

        if let Some(site) = res.sites().first() {
            // Emojis may be causing an issue on some Ubuntu desktop environments.
            let status = match res.status() {
                Status::Unknown => NO_ACTIVITY,
                Status::Online => GATEWAY_CONNECTED,
                Status::Offline => ALL_GATEWAYS_OFFLINE,
            };

            submenu
                .separator()
                .disabled("Site")
                .copyable(&site.name) // Hope this is okay - The code is simpler if every enabled item sends an `Event` on click
                .copyable(status)
        } else {
            submenu
        }
    }

    fn is_internet_resource_enabled(&self) -> bool {
        self.internet_resource_enabled.unwrap_or_default()
    }
}

fn signed_in(signed_in: &SignedIn) -> Menu {
    let SignedIn {
        actor_name,
        favorite_resources,
        resources, // Make sure these are presented in the order we receive them
        internet_resource_enabled,
        ..
    } = signed_in;

    let has_any_favorites = resources
        .iter()
        .any(|res| favorite_resources.contains(&res.id()));

    let mut menu = Menu::default()
        .disabled(format!("Signed in as {actor_name}"))
        .item(Event::SignOut, SIGN_OUT)
        .separator();

    tracing::debug!(
        resource_count = resources.len(),
        "Building signed-in tray menu"
    );
    if has_any_favorites {
        menu = menu.disabled(FAVORITE_RESOURCES);
        // The user has some favorites and they're in the list, so only show those
        // Always show Resources in the original order
        for res in resources
            .iter()
            .filter(|res| favorite_resources.contains(&res.id()) || res.is_internet_resource())
        {
            menu = menu.add_submenu(signed_in.resource_submenu(res));
        }
    } else {
        // No favorites, show every Resource normally, just like before
        // the favoriting feature was created
        // Always show Resources in the original order
        menu = menu.disabled(RESOURCES);
        for res in *resources {
            menu = menu.add_submenu(signed_in.resource_submenu(res));
        }
    }

    if has_any_favorites {
        let mut submenu = Menu::new(OTHER_RESOURCES);
        // Always show Resources in the original order
        for res in resources
            .iter()
            .filter(|res| !favorite_resources.contains(&res.id()) && !res.is_internet_resource())
        {
            submenu = submenu.add_submenu(signed_in.resource_submenu(res));
        }
        menu = menu.separator().add_submenu(submenu);
    }

    menu
}

fn retrying_sign_in(waiting_message: &str) -> Menu {
    Menu::default()
        .disabled(waiting_message)
        .item(Event::RetryPortalConnection, "Retry sign-in")
        .item(Event::CancelSignIn, "Cancel sign-in")
}

fn signing_in(waiting_message: &str) -> Menu {
    Menu::default()
        .disabled(waiting_message)
        .item(Event::CancelSignIn, "Cancel sign-in")
}

fn append_status(name: &str, enabled: bool) -> String {
    let symbol = if enabled {
        ENABLED_SYMBOL
    } else {
        DISABLED_SYMBOL
    };

    format!("{symbol} {name}")
}

impl Menu {
    /// Appends things that always show, like About, Settings, Help, Quit, etc.
    pub(crate) fn add_bottom_section(mut self, release: Option<Release>, quit_text: &str) -> Self {
        self = self.separator();
        if let Some(release) = release {
            self = self.item(
                Event::Url(release.download_url),
                format!("Download Firezone {}...", release.version),
            )
        }

        self.item(Event::ShowWindow(Window::About), "About Firezone")
            .item(Event::AdminPortal, "Admin Portal...")
            .add_submenu(
                Menu::new("Help")
                    .item(
                        Event::Url(utm_url("https://www.firezone.dev/kb")),
                        "Documentation...",
                    )
                    .item(
                        Event::Url(utm_url("https://www.firezone.dev/support")),
                        "Support...",
                    ),
            )
            .item(Event::ShowWindow(Window::Settings), "Settings")
            .separator()
            .item(Event::Quit, quit_text)
    }
}

pub(crate) fn utm_url(base_url: &str) -> Url {
    Url::parse(&format!(
        "{base_url}?utm_source={}-client",
        std::env::consts::OS
    ))
    .expect("Hard-coded URL should always be parsable")
}

/// Builds this abstract `Menu` into a concrete menu.
///
/// This recurses but we never go deeper than 3 or 4 levels so it's fine.
pub(crate) fn build_menu(that: Menu, map: &mut BTreeMap<u32, Event>) -> concrete::Submenu {
    let menu = concrete::Submenu::new(that.title, true);
    for entry in that.entries {
        match entry {
            Entry::Item(item) => menu.append(&build_item(item, map)),
            Entry::Separator => menu.append(&concrete::PredefinedMenuItem::separator()),
            Entry::Submenu(inner) => menu.append(&build_menu(inner, map)),
        };
    }
    menu
}

/// Builds this abstract `Item` into a concrete item.
fn build_item(item: Item, map: &mut BTreeMap<u32, Event>) -> concrete::CheckMenuItem {
    let Item {
        event,
        selected,
        title,
    } = item;

    let item = concrete::CheckMenuItem::new(title, event.is_some(), selected, None);

    if let Some(event) = event {
        if map.insert(item.id(), event).is_some() {
            panic!("Can't have two menu items with the same ID.");
        }
    }

    item
}

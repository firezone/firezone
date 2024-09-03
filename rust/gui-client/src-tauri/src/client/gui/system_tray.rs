//! Code for the system tray AKA notification area
//!
//! This manages the icon, menu, and tooltip.
//!
//! "Notification Area" is Microsoft's official name instead of "System tray":
//! <https://learn.microsoft.com/en-us/windows/win32/shell/notification-area?redirectedfrom=MSDN#notifications-and-the-notification-area>

use crate::client::updates::Release;
use anyhow::Result;
use connlib_shared::{
    callbacks::{ResourceDescription, Status},
    messages::ResourceId,
};
use std::collections::HashSet;
use tauri::{SystemTray, SystemTrayHandle};
use url::Url;

mod builder;
pub(crate) mod compositor;

pub(crate) use builder::{item, Event, Menu, Window};

// Figma is the source of truth for the tray icon layers
// <https://www.figma.com/design/THvQQ1QxKlsk47H9DZ2bhN/Core-Library?node-id=1250-772&t=nHBOzOnSY5Ol4asV-0>
const LOGO_BASE: &[u8] = include_bytes!("../../../icons/tray/Logo.png");
const LOGO_GREY_BASE: &[u8] = include_bytes!("../../../icons/tray/Logo grey.png");
const BUSY_LAYER: &[u8] = include_bytes!("../../../icons/tray/Busy layer.png");
const SIGNED_OUT_LAYER: &[u8] = include_bytes!("../../../icons/tray/Signed out layer.png");
const UPDATE_READY_LAYER: &[u8] = include_bytes!("../../../icons/tray/Update ready layer.png");

const TOOLTIP: &str = "Firezone";
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

pub(crate) const INTERNET_RESOURCE_DESCRIPTION: &str = "All network traffic";

pub(crate) fn loading() -> SystemTray {
    let state = AppState {
        connlib: ConnlibState::Loading,
        release: None,
    };
    SystemTray::new()
        .with_icon(Icon::default().tauri_icon())
        .with_menu(state.build())
        .with_tooltip(TOOLTIP)
}

pub(crate) struct Tray {
    handle: SystemTrayHandle,
    last_icon_set: Icon,
}

pub(crate) struct AppState<'a> {
    pub(crate) connlib: ConnlibState<'a>,
    pub(crate) release: Option<Release>,
}

pub(crate) enum ConnlibState<'a> {
    Loading,
    RetryingConnection,
    SignedIn(SignedIn<'a>),
    SignedOut,
    WaitingForBrowser,
    WaitingForPortal,
    WaitingForTunnel,
}

pub(crate) struct SignedIn<'a> {
    pub(crate) actor_name: &'a str,
    pub(crate) favorite_resources: &'a HashSet<ResourceId>,
    pub(crate) resources: &'a [ResourceDescription],
    pub(crate) internet_resource_enabled: &'a Option<bool>,
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
        let mut submenu = Menu::default().resource_description(res);

        if res.is_internet_resource() && res.can_be_disabled() {
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

#[derive(PartialEq)]
pub(crate) struct Icon {
    base: IconBase,
    update_ready: bool,
}

#[derive(PartialEq)]
enum IconBase {
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

impl Icon {
    fn tauri_icon(&self) -> tauri::Icon {
        let layers = match self.base {
            IconBase::Busy => &[LOGO_GREY_BASE, BUSY_LAYER][..],
            IconBase::SignedIn => &[LOGO_BASE][..],
            IconBase::SignedOut => &[LOGO_GREY_BASE, SIGNED_OUT_LAYER][..],
        }
        .iter()
        .copied()
        .chain(self.update_ready.then_some(UPDATE_READY_LAYER));
        let composed = compositor::compose(layers)
            .expect("PNG decoding should always succeed for baked-in PNGs");
        composed.into()
    }

    /// Generic icon for unusual terminating cases like if the IPC service stops running
    pub(crate) fn terminating() -> Self {
        Self {
            base: IconBase::SignedOut,
            update_ready: false,
        }
    }
}

impl Tray {
    pub(crate) fn new(handle: SystemTrayHandle) -> Self {
        Self {
            handle,
            last_icon_set: Default::default(),
        }
    }

    pub(crate) fn update(&mut self, state: AppState) -> Result<()> {
        let base = match &state.connlib {
            ConnlibState::Loading
            | ConnlibState::RetryingConnection
            | ConnlibState::WaitingForBrowser
            | ConnlibState::WaitingForPortal
            | ConnlibState::WaitingForTunnel => IconBase::Busy,
            ConnlibState::SignedOut => IconBase::SignedOut,
            ConnlibState::SignedIn { .. } => IconBase::SignedIn,
        };
        let new_icon = Icon {
            base,
            update_ready: state.release.is_some(),
        };

        self.handle.set_tooltip(TOOLTIP)?;
        self.handle.set_menu(state.build())?;
        self.set_icon(new_icon)?;

        Ok(())
    }

    // Only needed for the stress test
    // Otherwise it would be inlined
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

impl<'a> AppState<'a> {
    fn build(self) -> tauri::SystemTrayMenu {
        self.into_menu().build()
    }

    fn into_menu(self) -> Menu {
        let quit_text = match &self.connlib {
            ConnlibState::Loading
            | ConnlibState::RetryingConnection
            | ConnlibState::SignedOut
            | ConnlibState::WaitingForBrowser
            | ConnlibState::WaitingForPortal
            | ConnlibState::WaitingForTunnel => QUIT_TEXT_SIGNED_OUT,
            ConnlibState::SignedIn(_) => DISCONNECT_AND_QUIT,
        };
        let menu = match self.connlib {
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
}

fn append_status(name: &str, enabled: bool) -> String {
    let mut result = String::new();
    if enabled {
        result.push_str(ENABLED_SYMBOL);
    } else {
        result.push_str(DISABLED_SYMBOL);
    }

    result.push_str(" ");
    result.push_str(name);

    result
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
            let mut name = res.name().to_string();
            if res.is_internet_resource() {
                name = append_status(&name, internet_resource_enabled.unwrap_or_default());
            }

            menu = menu.add_submenu(name, signed_in.resource_submenu(res));
        }
    } else {
        // No favorites, show every Resource normally, just like before
        // the favoriting feature was created
        // Always show Resources in the original order
        menu = menu.disabled(RESOURCES);
        for res in *resources {
            let mut name = res.name().to_string();
            if res.is_internet_resource() {
                name = append_status(&name, internet_resource_enabled.unwrap_or_default());
            }

            menu = menu.add_submenu(name, signed_in.resource_submenu(res));
        }
    }

    if has_any_favorites {
        let mut submenu = Menu::default();
        // Always show Resources in the original order
        for res in resources
            .iter()
            .filter(|res| !favorite_resources.contains(&res.id()) && !res.is_internet_resource())
        {
            submenu = submenu.add_submenu(res.name(), signed_in.resource_submenu(res));
        }
        menu = menu.separator().add_submenu(OTHER_RESOURCES, submenu);
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
                "Help",
                Menu::default()
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

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::Result;
    use std::str::FromStr as _;

    impl Menu {
        fn selected_item<E: Into<Option<Event>>, S: Into<String>>(
            mut self,
            id: E,
            title: S,
        ) -> Self {
            self.add_item(item(id, title).selected());
            self
        }
    }

    fn signed_in<'a>(
        resources: &'a [ResourceDescription],
        favorite_resources: &'a HashSet<ResourceId>,
        internet_resource_enabled: &'a Option<bool>,
    ) -> AppState<'a> {
        AppState {
            connlib: ConnlibState::SignedIn(SignedIn {
                actor_name: "Jane Doe",
                favorite_resources,
                resources,
                internet_resource_enabled,
            }),
            release: None,
        }
    }

    fn resources() -> Vec<ResourceDescription> {
        let s = r#"[
            {
                "id": "73037362-715d-4a83-a749-f18eadd970e6",
                "type": "cidr",
                "name": "172.172.0.0/16",
                "address": "172.172.0.0/16",
                "address_description": "cidr resource",
                "sites": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
                "status": "Unknown",
                "can_be_disabled": false
            },
            {
                "id": "03000143-e25e-45c7-aafb-144990e57dcd",
                "type": "dns",
                "name": "MyCorp GitLab",
                "address": "gitlab.mycorp.com",
                "address_description": "https://gitlab.mycorp.com",
                "sites": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
                "status": "Online",
                "can_be_disabled": false
            },
            {
                "id": "1106047c-cd5d-4151-b679-96b93da7383b",
                "type": "internet",
                "name": "Internet Resource",
                "address": "All internet addresses",
                "sites": [{"name": "test", "id": "eb94482a-94f4-47cb-8127-14fb3afa5516"}],
                "status": "Offline",
                "can_be_disabled": false
            }
        ]"#;

        serde_json::from_str(s).unwrap()
    }

    #[test]
    fn no_resources_no_favorites() {
        let resources = vec![];
        let favorites = Default::default();
        let disabled_resources = Default::default();
        let input = signed_in(&resources, &favorites, &disabled_resources);
        let actual = input.into_menu();
        let expected = Menu::default()
            .disabled("Signed in as Jane Doe")
            .item(Event::SignOut, SIGN_OUT)
            .separator()
            .disabled(RESOURCES)
            .add_bottom_section(None, DISCONNECT_AND_QUIT); // Skip testing the bottom section, it's simple

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual).unwrap()
        );
    }

    #[test]
    fn no_resources_invalid_favorite() {
        let resources = vec![];
        let favorites = HashSet::from([ResourceId::from_u128(42)]);
        let disabled_resources = Default::default();
        let input = signed_in(&resources, &favorites, &disabled_resources);
        let actual = input.into_menu();
        let expected = Menu::default()
            .disabled("Signed in as Jane Doe")
            .item(Event::SignOut, SIGN_OUT)
            .separator()
            .disabled(RESOURCES)
            .add_bottom_section(None, DISCONNECT_AND_QUIT); // Skip testing the bottom section, it's simple

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual).unwrap()
        );
    }

    #[test]
    fn some_resources_no_favorites() {
        let resources = resources();
        let favorites = Default::default();
        let disabled_resources = Default::default();
        let input = signed_in(&resources, &favorites, &disabled_resources);
        let actual = input.into_menu();
        let expected = Menu::default()
            .disabled("Signed in as Jane Doe")
            .item(Event::SignOut, SIGN_OUT)
            .separator()
            .disabled(RESOURCES)
            .add_submenu(
                "172.172.0.0/16",
                Menu::default()
                    .copyable("cidr resource")
                    .separator()
                    .disabled("Resource")
                    .copyable("172.172.0.0/16")
                    .copyable("172.172.0.0/16")
                    .item(
                        Event::AddFavorite(
                            ResourceId::from_str("73037362-715d-4a83-a749-f18eadd970e6").unwrap(),
                        ),
                        ADD_FAVORITE,
                    )
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable(NO_ACTIVITY),
            )
            .add_submenu(
                "MyCorp GitLab",
                Menu::default()
                    .item(
                        Event::Url("https://gitlab.mycorp.com".parse().unwrap()),
                        "<https://gitlab.mycorp.com>",
                    )
                    .separator()
                    .disabled("Resource")
                    .copyable("MyCorp GitLab")
                    .copyable("gitlab.mycorp.com")
                    .item(
                        Event::AddFavorite(
                            ResourceId::from_str("03000143-e25e-45c7-aafb-144990e57dcd").unwrap(),
                        ),
                        ADD_FAVORITE,
                    )
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable(GATEWAY_CONNECTED),
            )
            .add_submenu(
                "Internet Resource",
                Menu::default()
                    .disabled(INTERNET_RESOURCE_DESCRIPTION)
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable(ALL_GATEWAYS_OFFLINE),
            )
            .add_bottom_section(None, DISCONNECT_AND_QUIT); // Skip testing the bottom section, it's simple
        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual).unwrap(),
        );
    }

    #[test]
    fn some_resources_one_favorite() -> Result<()> {
        let resources = resources();
        let favorites = HashSet::from([ResourceId::from_str(
            "03000143-e25e-45c7-aafb-144990e57dcd",
        )?]);
        let disabled_resources = Default::default();
        let input = signed_in(&resources, &favorites, &disabled_resources);
        let actual = input.into_menu();
        let expected = Menu::default()
            .disabled("Signed in as Jane Doe")
            .item(Event::SignOut, SIGN_OUT)
            .separator()
            .disabled(FAVORITE_RESOURCES)
            .add_submenu(
                "MyCorp GitLab",
                Menu::default()
                    .item(
                        Event::Url("https://gitlab.mycorp.com".parse().unwrap()),
                        "<https://gitlab.mycorp.com>",
                    )
                    .separator()
                    .disabled("Resource")
                    .copyable("MyCorp GitLab")
                    .copyable("gitlab.mycorp.com")
                    .selected_item(
                        Event::RemoveFavorite(ResourceId::from_str(
                            "03000143-e25e-45c7-aafb-144990e57dcd",
                        )?),
                        REMOVE_FAVORITE,
                    )
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable(GATEWAY_CONNECTED),
            )
            .add_submenu(
                "Internet Resource",
                Menu::default()
                    .disabled(INTERNET_RESOURCE_DESCRIPTION)
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable(ALL_GATEWAYS_OFFLINE),
            )
            .separator()
            .add_submenu(
                OTHER_RESOURCES,
                Menu::default().add_submenu(
                    "172.172.0.0/16",
                    Menu::default()
                        .copyable("cidr resource")
                        .separator()
                        .disabled("Resource")
                        .copyable("172.172.0.0/16")
                        .copyable("172.172.0.0/16")
                        .item(
                            Event::AddFavorite(ResourceId::from_str(
                                "73037362-715d-4a83-a749-f18eadd970e6",
                            )?),
                            ADD_FAVORITE,
                        )
                        .separator()
                        .disabled("Site")
                        .copyable("test")
                        .copyable(NO_ACTIVITY),
                ),
            )
            .add_bottom_section(None, DISCONNECT_AND_QUIT); // Skip testing the bottom section, it's simple

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual).unwrap()
        );

        Ok(())
    }

    #[test]
    fn some_resources_invalid_favorite() -> Result<()> {
        let resources = resources();
        let favorites = HashSet::from([ResourceId::from_str(
            "00000000-0000-0000-0000-000000000000",
        )?]);
        let disabled_resources = Default::default();
        let input = signed_in(&resources, &favorites, &disabled_resources);
        let actual = input.into_menu();
        let expected = Menu::default()
            .disabled("Signed in as Jane Doe")
            .item(Event::SignOut, SIGN_OUT)
            .separator()
            .disabled(RESOURCES)
            .add_submenu(
                "172.172.0.0/16",
                Menu::default()
                    .copyable("cidr resource")
                    .separator()
                    .disabled("Resource")
                    .copyable("172.172.0.0/16")
                    .copyable("172.172.0.0/16")
                    .item(
                        Event::AddFavorite(ResourceId::from_str(
                            "73037362-715d-4a83-a749-f18eadd970e6",
                        )?),
                        ADD_FAVORITE,
                    )
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable(NO_ACTIVITY),
            )
            .add_submenu(
                "MyCorp GitLab",
                Menu::default()
                    .item(
                        Event::Url("https://gitlab.mycorp.com".parse().unwrap()),
                        "<https://gitlab.mycorp.com>",
                    )
                    .separator()
                    .disabled("Resource")
                    .copyable("MyCorp GitLab")
                    .copyable("gitlab.mycorp.com")
                    .item(
                        Event::AddFavorite(ResourceId::from_str(
                            "03000143-e25e-45c7-aafb-144990e57dcd",
                        )?),
                        ADD_FAVORITE,
                    )
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable(GATEWAY_CONNECTED),
            )
            .add_submenu(
                "Internet Resource",
                Menu::default()
                    .disabled(INTERNET_RESOURCE_DESCRIPTION)
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable(ALL_GATEWAYS_OFFLINE),
            )
            .add_bottom_section(None, DISCONNECT_AND_QUIT); // Skip testing the bottom section, it's simple

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual).unwrap(),
        );

        Ok(())
    }
}

//! Code for the system tray AKA notification area
//!
//! This manages the icon, menu, and tooltip.
//!
//! "Notification Area" is Microsoft's official name instead of "System tray":
//! <https://learn.microsoft.com/en-us/windows/win32/shell/notification-area?redirectedfrom=MSDN#notifications-and-the-notification-area>

use compositor::Image;
use connlib_model::{ConnectedDeviceView, ResourceId, ResourceStatus, ResourceView};
use std::collections::HashSet;
use url::Url;

use crate::updates::Release;

/// `builder::Icon` is the icon shown *inside* a menu item (e.g. Site status),
/// distinct from the tray `Icon` defined in this module.
pub(crate) use builder::Icon as MenuItemIcon;
use builder::item;
pub use builder::{Entry, Event, Item, Menu, Window};

mod builder;
mod compositor;

// The tray is drawn by a platform-native backend rather than Tauri's own tray,
// so that menu-item icons (e.g. Site status) actually render:
//
// - **Windows / macOS**: Tauri's built-in tray (the `tray-icon` feature),
//   which renders per-item icons natively.
// - **Linux**: `ksni`, a pure-Rust StatusNotifierItem implementation that
//   speaks the DBusMenu protocol directly and can attach an `icon-name` to
//   each menu item — which GNOME (with the AppIndicator extension) and KDE
//   render, unlike Tauri's `libappindicator` path.
#[cfg(not(target_os = "linux"))]
mod tray_tauri;
#[cfg(not(target_os = "linux"))]
pub(crate) use tray_tauri::Tray;

#[cfg(target_os = "linux")]
mod tray_ksni;
#[cfg(target_os = "linux")]
pub(crate) use tray_ksni::Tray;

// Figma is the source of truth for the tray icon layers
// <https://www.figma.com/design/THvQQ1QxKlsk47H9DZ2bhN/Core-Library?node-id=1250-772&t=nHBOzOnSY5Ol4asV-0>
const LOGO_BASE: &[u8] = include_bytes!("../../icons/tray/Logo.png");
const LOGO_GREY_BASE: &[u8] = include_bytes!("../../icons/tray/Logo grey.png");
const BUSY_LAYER: &[u8] = include_bytes!("../../icons/tray/Busy layer.png");
const SIGNED_OUT_LAYER: &[u8] = include_bytes!("../../icons/tray/Signed out layer.png");
const UPDATE_READY_LAYER: &[u8] = include_bytes!("../../icons/tray/Update ready layer.png");

const QUIT_TEXT_SIGNED_OUT: &str = "Quit Firezone";

const NO_ACTIVITY: &str = "No activity";
const GATEWAY_CONNECTED: &str = "Gateway connected";
const ALL_GATEWAYS_OFFLINE: &str = "All Gateways offline";

const ENABLED_SYMBOL: &str = "<->";
const DISABLED_SYMBOL: &str = "—";

const ADD_FAVORITE: &str = "Add to favorites";
const REMOVE_FAVORITE: &str = "Remove from favorites";
const FAVORITE_RESOURCES: &str = "Favorite Resources";
const RESOURCES: &str = "Resources";
const OTHER_RESOURCES: &str = "Other Resources";
const DEVICES: &str = "Devices";

/// Maximum number of connected devices listed inline in the Devices submenu.
///
/// Anything beyond this is summarized as "And N more devices…".
const MAX_DEVICES_INLINE: usize = 20;
const SIGN_OUT: &str = "Sign out";
const DISCONNECT_AND_QUIT: &str = "Disconnect and quit Firezone";
const DISABLE: &str = "Disable this resource";
const ENABLE: &str = "Enable this resource";

const TOOLTIP: &str = "Firezone";

/// Composes the tray icon's PNG layers into a single RGBA image.
///
/// Shared by both tray backends.
pub(crate) fn compose_icon(that: &Icon) -> Image {
    let layers = match that.base {
        IconBase::Busy => &[LOGO_GREY_BASE, BUSY_LAYER][..],
        IconBase::SignedIn => &[LOGO_BASE][..],
        IconBase::SignedOut => &[LOGO_GREY_BASE, SIGNED_OUT_LAYER][..],
    }
    .iter()
    .copied()
    .chain(that.update_ready.then_some(UPDATE_READY_LAYER));
    compositor::compose(layers).expect("PNG decoding should always succeed for baked-in PNGs")
}

/// Maps an [`AppState`] to the tray [`Icon`] that represents it.
pub(crate) fn icon_from_state(state: &AppState) -> Icon {
    let base = match &state.connlib {
        ConnlibState::Loading
        | ConnlibState::Quitting
        | ConnlibState::WaitingForBrowser
        | ConnlibState::WaitingForPortal
        | ConnlibState::WaitingForTunnel => IconBase::Busy,
        ConnlibState::SignedOut => IconBase::SignedOut,
        ConnlibState::SignedIn { .. } => IconBase::SignedIn,
    };
    Icon {
        base,
        update_ready: state.release.is_some(),
    }
}

pub struct AppState {
    pub connlib: ConnlibState,
    pub release: Option<Release>,
    pub hide_admin_portal_menu_item: bool,
    pub support_url: Option<Url>,
}

impl Default for AppState {
    fn default() -> AppState {
        AppState {
            connlib: ConnlibState::Loading,
            release: None,
            hide_admin_portal_menu_item: false,
            support_url: None,
        }
    }
}

impl AppState {
    pub fn into_menu(self) -> Menu {
        let quit_text = match &self.connlib {
            ConnlibState::Loading
            | ConnlibState::Quitting
            | ConnlibState::SignedOut
            | ConnlibState::WaitingForBrowser
            | ConnlibState::WaitingForPortal
            | ConnlibState::WaitingForTunnel => QUIT_TEXT_SIGNED_OUT,
            ConnlibState::SignedIn(_) => DISCONNECT_AND_QUIT,
        };
        let menu = match self.connlib {
            ConnlibState::Loading => Menu::default().disabled("Loading..."),
            ConnlibState::Quitting => Menu::default().disabled("Quitting..."),
            ConnlibState::SignedIn(x) => signed_in(&x),
            ConnlibState::SignedOut => Menu::default().item(Event::SignIn, "Sign In"),
            ConnlibState::WaitingForBrowser => signing_in("Waiting for browser..."),
            ConnlibState::WaitingForPortal => signing_in("Connecting to Firezone Portal..."),
            ConnlibState::WaitingForTunnel => signing_in("Raising tunnel..."),
        };
        menu.add_bottom_section(
            self.release,
            quit_text,
            !self.hide_admin_portal_menu_item,
            self.support_url,
        )
    }
}

pub enum ConnlibState {
    Loading,
    Quitting,
    SignedIn(SignedIn),
    SignedOut,
    WaitingForBrowser,
    WaitingForPortal,
    WaitingForTunnel,
}

pub struct SignedIn {
    pub actor_name: String,
    pub favorite_resources: HashSet<ResourceId>,
    pub resources: Vec<ResourceView>,
    pub connected_devices: Vec<ConnectedDeviceView>,
    pub internet_resource_enabled: Option<bool>,
}

impl SignedIn {
    fn is_favorite(&self, resource: &ResourceId) -> bool {
        self.favorite_resources.contains(resource)
    }

    fn add_favorite_toggle(&self, submenu: &mut Menu, resource: ResourceId) {
        if self.is_favorite(&resource) {
            submenu.add_item(item(Event::RemoveFavorite(resource), REMOVE_FAVORITE).checked(true));
        } else {
            submenu.add_item(item(Event::AddFavorite(resource), ADD_FAVORITE).checked(false));
        }
    }

    /// Builds the submenu that has the resource address, name, desc,
    /// sites online, etc.
    fn resource_submenu(&self, res: &ResourceView) -> Menu {
        let mut submenu = Menu::default().resource_description(res);

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
            let (status, icon) = match res.status() {
                ResourceStatus::Unknown => (NO_ACTIVITY, MenuItemIcon::Grey),
                ResourceStatus::Online => (GATEWAY_CONNECTED, MenuItemIcon::Green),
                ResourceStatus::Offline => (ALL_GATEWAYS_OFFLINE, MenuItemIcon::Red),
            };

            submenu
                .separator()
                .disabled("Site")
                .copyable(&site.name) // Hope this is okay - The code is simpler if every enabled item sends an `Event` on click
                .copyable_with_icon(status, icon)
        } else {
            submenu
        }
    }

    fn is_internet_resource_enabled(&self) -> bool {
        self.internet_resource_enabled.unwrap_or_default()
    }
}

#[derive(Clone, PartialEq)]
pub struct Icon {
    pub base: IconBase,
    pub update_ready: bool,
}

/// Generic icon for unusual terminating cases like if the Tunnel service stops running
pub(crate) fn icon_terminating() -> Icon {
    Icon {
        base: IconBase::SignedOut,
        update_ready: false,
    }
}

#[derive(Clone, PartialEq)]
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

fn signed_in(signed_in: &SignedIn) -> Menu {
    let SignedIn {
        actor_name,
        favorite_resources,
        resources, // Make sure these are presented in the order we receive them
        connected_devices,
        internet_resource_enabled,
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
        for res in resources {
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

    if !connected_devices.is_empty() {
        let label = format!("{DEVICES} ({})", connected_devices.len());
        menu = menu
            .separator()
            .add_submenu(label, devices_submenu(connected_devices));
    }

    menu
}

fn device_label(device: &ConnectedDeviceView) -> String {
    device.tunneled_ipv4.to_string()
}

fn devices_submenu(connected_devices: &[ConnectedDeviceView]) -> Menu {
    let mut menu = Menu::default();
    let visible = connected_devices.len().min(MAX_DEVICES_INLINE);
    for device in &connected_devices[..visible] {
        menu = menu.add_submenu(device_label(device), device_submenu(device));
    }

    let hidden = connected_devices.len() - visible;
    if hidden > 0 {
        let label = if hidden == 1 {
            "And 1 more device…".to_string()
        } else {
            format!("And {hidden} more devices…")
        };
        menu = menu.separator().disabled(label);
    }
    menu
}

fn device_submenu(device: &ConnectedDeviceView) -> Menu {
    let mut menu = Menu::default().disabled("Device");

    menu = menu
        .separator()
        .disabled("Tunnel IPv4")
        .copyable(&device.tunneled_ipv4.to_string())
        .separator()
        .disabled("Client ID")
        .copyable(&device.id.to_string());

    if !device.pools.is_empty() {
        let label = if device.pools.len() == 1 {
            "Pool"
        } else {
            "Pools"
        };
        menu = menu.separator().disabled(label);
        for name in &device.pools {
            menu = menu.copyable(name);
        }
    }

    menu
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
    pub(crate) fn add_bottom_section(
        mut self,
        release: Option<Release>,
        quit_text: &str,
        show_admin_portal_url: bool,
        support_url: Option<Url>,
    ) -> Self {
        self = self.separator();
        if let Some(release) = release {
            self = self.item(
                Event::Url(release.download_url),
                format!("Download Firezone {}...", release.version),
            )
        }

        let mut item = self.item(Event::ShowWindow(Window::About), "About Firezone");

        if show_admin_portal_url {
            item = item.item(Event::AdminPortal, "Admin Portal...");
        }

        item.add_submenu(
            "Help",
            Menu::default()
                .item(
                    Event::Url(utm_url("https://www.firezone.dev/kb")),
                    "Documentation...",
                )
                .item(
                    Event::Url(
                        support_url.unwrap_or_else(|| utm_url("https://www.firezone.dev/support")),
                    ),
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

    use builder::INTERNET_RESOURCE_DESCRIPTION;

    impl Menu {
        fn checkable<E: Into<Option<Event>>, S: Into<String>>(
            mut self,
            id: E,
            title: S,
            checked: bool,
        ) -> Self {
            self.add_item(item(id, title).checked(checked));
            self
        }
    }

    fn signed_in(
        resources: Vec<ResourceView>,
        favorite_resources: HashSet<ResourceId>,
        internet_resource_enabled: Option<bool>,
    ) -> AppState {
        AppState {
            connlib: ConnlibState::SignedIn(SignedIn {
                actor_name: "Jane Doe".into(),
                favorite_resources,
                resources,
                connected_devices: Vec::new(),
                internet_resource_enabled,
            }),
            release: None,
            hide_admin_portal_menu_item: false,
            support_url: None,
        }
    }

    fn resources() -> Vec<ResourceView> {
        let s = r#"[
            {
                "id": "73037362-715d-4a83-a749-f18eadd970e6",
                "type": "cidr",
                "name": "172.172.0.0/16",
                "address": "172.172.0.0/16",
                "address_description": "cidr resource",
                "sites": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
                "status": "Unknown"
            },
            {
                "id": "03000143-e25e-45c7-aafb-144990e57dcd",
                "type": "dns",
                "name": "MyCorp GitLab",
                "address": "gitlab.mycorp.com",
                "address_description": "https://gitlab.mycorp.com",
                "sites": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
                "status": "Online"
            },
            {
                "id": "1106047c-cd5d-4151-b679-96b93da7383b",
                "type": "internet",
                "name": "Internet Resource",
                "address": "All internet addresses",
                "sites": [{"name": "test", "id": "eb94482a-94f4-47cb-8127-14fb3afa5516"}],
                "status": "Offline"
            }
        ]"#;

        serde_json::from_str(s).unwrap()
    }

    #[test]
    fn can_remove_admin_portal_link() {
        let actual = AppState {
            hide_admin_portal_menu_item: true,
            ..Default::default()
        }
        .into_menu();

        let expected = Menu::default()
            .disabled("Loading...")
            .separator()
            .item(Event::ShowWindow(Window::About), "About Firezone")
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
            .item(Event::Quit, QUIT_TEXT_SIGNED_OUT);

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual).unwrap()
        );
    }

    #[test]
    fn can_change_support_url() {
        let actual = AppState {
            support_url: Some("https://example.com".parse().unwrap()),
            ..Default::default()
        }
        .into_menu();

        let expected = Menu::default()
            .disabled("Loading...")
            .separator()
            .item(Event::ShowWindow(Window::About), "About Firezone")
            .item(Event::AdminPortal, "Admin Portal...")
            .add_submenu(
                "Help",
                Menu::default()
                    .item(
                        Event::Url(utm_url("https://www.firezone.dev/kb")),
                        "Documentation...",
                    )
                    .item(
                        Event::Url("https://example.com".parse().unwrap()),
                        "Support...",
                    ),
            )
            .item(Event::ShowWindow(Window::Settings), "Settings")
            .separator()
            .item(Event::Quit, QUIT_TEXT_SIGNED_OUT);

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual).unwrap()
        );
    }

    #[test]
    fn no_resources_no_favorites() {
        let actual = signed_in(vec![], HashSet::default(), None).into_menu();

        let expected = Menu::default()
            .disabled("Signed in as Jane Doe")
            .item(Event::SignOut, SIGN_OUT)
            .separator()
            .disabled(RESOURCES)
            .add_bottom_section(None, DISCONNECT_AND_QUIT, true, None); // Skip testing the bottom section, it's simple

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual).unwrap()
        );
    }

    #[test]
    fn no_resources_invalid_favorite() {
        let actual =
            signed_in(vec![], HashSet::from([ResourceId::from_u128(42)]), None).into_menu();

        let expected = Menu::default()
            .disabled("Signed in as Jane Doe")
            .item(Event::SignOut, SIGN_OUT)
            .separator()
            .disabled(RESOURCES)
            .add_bottom_section(None, DISCONNECT_AND_QUIT, true, None); // Skip testing the bottom section, it's simple

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual).unwrap()
        );
    }

    #[test]
    fn some_resources_no_favorites() {
        let actual = signed_in(resources(), HashSet::default(), None).into_menu();

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
                    .checkable(
                        Event::AddFavorite(
                            ResourceId::from_str("73037362-715d-4a83-a749-f18eadd970e6").unwrap(),
                        ),
                        ADD_FAVORITE,
                        false,
                    )
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable_with_icon(NO_ACTIVITY, MenuItemIcon::Grey),
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
                    .checkable(
                        Event::AddFavorite(
                            ResourceId::from_str("03000143-e25e-45c7-aafb-144990e57dcd").unwrap(),
                        ),
                        ADD_FAVORITE,
                        false,
                    )
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable_with_icon(GATEWAY_CONNECTED, MenuItemIcon::Green),
            )
            .add_submenu(
                "— Internet Resource",
                Menu::default()
                    .disabled(INTERNET_RESOURCE_DESCRIPTION)
                    .separator()
                    .item(Event::EnableInternetResource, ENABLE)
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable_with_icon(ALL_GATEWAYS_OFFLINE, MenuItemIcon::Red),
            )
            .add_bottom_section(None, DISCONNECT_AND_QUIT, true, None); // Skip testing the bottom section, it's simple

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual).unwrap(),
        );
    }

    #[test]
    fn some_resources_one_favorite() -> Result<()> {
        let actual = signed_in(
            resources(),
            HashSet::from([ResourceId::from_str(
                "03000143-e25e-45c7-aafb-144990e57dcd",
            )?]),
            None,
        )
        .into_menu();

        let expected = Menu::default()
            .disabled("Signed in as Jane Doe")
            .item(Event::SignOut, SIGN_OUT)
            .separator()
            .disabled(FAVORITE_RESOURCES)
            .add_submenu(
                "MyCorp GitLab",
                Menu::default()
                    .item(
                        Event::Url("https://gitlab.mycorp.com".parse()?),
                        "<https://gitlab.mycorp.com>",
                    )
                    .separator()
                    .disabled("Resource")
                    .copyable("MyCorp GitLab")
                    .copyable("gitlab.mycorp.com")
                    .checkable(
                        Event::RemoveFavorite(ResourceId::from_str(
                            "03000143-e25e-45c7-aafb-144990e57dcd",
                        )?),
                        REMOVE_FAVORITE,
                        true,
                    )
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable_with_icon(GATEWAY_CONNECTED, MenuItemIcon::Green),
            )
            .add_submenu(
                "— Internet Resource",
                Menu::default()
                    .disabled(INTERNET_RESOURCE_DESCRIPTION)
                    .separator()
                    .item(Event::EnableInternetResource, ENABLE)
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable_with_icon(ALL_GATEWAYS_OFFLINE, MenuItemIcon::Red),
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
                        .checkable(
                            Event::AddFavorite(ResourceId::from_str(
                                "73037362-715d-4a83-a749-f18eadd970e6",
                            )?),
                            ADD_FAVORITE,
                            false,
                        )
                        .separator()
                        .disabled("Site")
                        .copyable("test")
                        .copyable_with_icon(NO_ACTIVITY, MenuItemIcon::Grey),
                ),
            )
            .add_bottom_section(None, DISCONNECT_AND_QUIT, true, None); // Skip testing the bottom section, it's simple

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual)?
        );

        Ok(())
    }

    #[test]
    fn some_resources_invalid_favorite() -> Result<()> {
        let actual = signed_in(
            resources(),
            HashSet::from([ResourceId::from_str(
                "00000000-0000-0000-0000-000000000000",
            )?]),
            None,
        )
        .into_menu();

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
                    .checkable(
                        Event::AddFavorite(ResourceId::from_str(
                            "73037362-715d-4a83-a749-f18eadd970e6",
                        )?),
                        ADD_FAVORITE,
                        false,
                    )
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable_with_icon(NO_ACTIVITY, MenuItemIcon::Grey),
            )
            .add_submenu(
                "MyCorp GitLab",
                Menu::default()
                    .item(
                        Event::Url("https://gitlab.mycorp.com".parse()?),
                        "<https://gitlab.mycorp.com>",
                    )
                    .separator()
                    .disabled("Resource")
                    .copyable("MyCorp GitLab")
                    .copyable("gitlab.mycorp.com")
                    .checkable(
                        Event::AddFavorite(ResourceId::from_str(
                            "03000143-e25e-45c7-aafb-144990e57dcd",
                        )?),
                        ADD_FAVORITE,
                        false,
                    )
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable_with_icon(GATEWAY_CONNECTED, MenuItemIcon::Green),
            )
            .add_submenu(
                "— Internet Resource",
                Menu::default()
                    .disabled(INTERNET_RESOURCE_DESCRIPTION)
                    .separator()
                    .item(Event::EnableInternetResource, ENABLE)
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable_with_icon(ALL_GATEWAYS_OFFLINE, MenuItemIcon::Red),
            )
            .add_bottom_section(None, DISCONNECT_AND_QUIT, true, None); // Skip testing the bottom section, it's simple

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual)?,
        );

        Ok(())
    }

    #[test]
    fn devices_submenu_lists_connected_devices_with_pool_labels() {
        use connlib_model::ClientId;
        use std::net::Ipv4Addr;
        let alpha = ClientId::from_u128(0x1111_1111_1111_1111_1111_1111_1111_1111);
        let beta = ClientId::from_u128(0x2222_2222_2222_2222_2222_2222_2222_2222);
        let alpha_ip = Ipv4Addr::new(100, 64, 0, 1);
        let beta_ip = Ipv4Addr::new(100, 64, 0, 2);
        let connected_devices = vec![
            ConnectedDeviceView {
                id: alpha,
                tunneled_ipv4: alpha_ip,
                pools: vec!["Engineering Pool".into()],
            },
            ConnectedDeviceView {
                id: beta,
                tunneled_ipv4: beta_ip,
                pools: vec!["Engineering Pool".into(), "QA Pool".into()],
            },
        ];

        let actual = devices_submenu(&connected_devices);

        let expected = Menu::default()
            .add_submenu(
                alpha_ip.to_string(),
                Menu::default()
                    .disabled("Device")
                    .separator()
                    .disabled("Tunnel IPv4")
                    .copyable(&alpha_ip.to_string())
                    .separator()
                    .disabled("Client ID")
                    .copyable(&alpha.to_string())
                    .separator()
                    .disabled("Pool")
                    .copyable("Engineering Pool"),
            )
            .add_submenu(
                beta_ip.to_string(),
                Menu::default()
                    .disabled("Device")
                    .separator()
                    .disabled("Tunnel IPv4")
                    .copyable(&beta_ip.to_string())
                    .separator()
                    .disabled("Client ID")
                    .copyable(&beta.to_string())
                    .separator()
                    .disabled("Pools")
                    .copyable("Engineering Pool")
                    .copyable("QA Pool"),
            );

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual).unwrap()
        );
    }

    #[test]
    fn devices_submenu_truncates_beyond_inline_limit() {
        use connlib_model::ClientId;
        use std::net::Ipv4Addr;
        let connected_devices: Vec<ConnectedDeviceView> = (0..MAX_DEVICES_INLINE + 3)
            .map(|i| ConnectedDeviceView {
                id: ClientId::from_u128(0x1111_1111_1111_1111_1111_1111_1111_1111 + i as u128),
                tunneled_ipv4: Ipv4Addr::new(100, 64, 0, i as u8),
                pools: vec!["Engineering Pool".into()],
            })
            .collect();

        let actual = devices_submenu(&connected_devices);

        let mut expected = Menu::default();
        for device in &connected_devices[..MAX_DEVICES_INLINE] {
            let ip = device.tunneled_ipv4.to_string();
            expected = expected.add_submenu(
                ip.clone(),
                Menu::default()
                    .disabled("Device")
                    .separator()
                    .disabled("Tunnel IPv4")
                    .copyable(&ip)
                    .separator()
                    .disabled("Client ID")
                    .copyable(&device.id.to_string())
                    .separator()
                    .disabled("Pool")
                    .copyable(&device.pools[0]),
            );
        }
        expected = expected.separator().disabled("And 3 more devices…");

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual).unwrap()
        );
    }
}

//! Code for the system tray AKA notification area
//!
//! This manages the icon, menu, and tooltip.
//!
//! "Notification Area" is Microsoft's official name instead of "System tray":
//! <https://learn.microsoft.com/en-us/windows/win32/shell/notification-area?redirectedfrom=MSDN#notifications-and-the-notification-area>

use compositor::Image;
use connlib_model::{ConnectedDeviceView, ResourceId, ResourceView};
use std::collections::HashSet;
use tunnel_proto::dns::DEVICE_DOMAIN;
use url::Url;

use crate::{updates::Release, view::description_link};

pub use builder::{Entry, Event, Item, Menu, Window};
use builder::{copyable, item};

mod builder;
mod compositor;

// The tray is drawn by a platform-native backend:
//
// - **Windows / macOS**: Tauri's built-in tray (the `tray-icon` feature).
// - **Linux**: `ksni`, a pure-Rust StatusNotifierItem implementation that
//   speaks the DBusMenu protocol directly.
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

const ENABLED_SYMBOL: &str = "<->";
const DISABLED_SYMBOL: &str = "—";

const FAVORITE_RESOURCES: &str = "Favorite Resources";
const RESOURCES: &str = "Resources";
const INTERNET_RESOURCE_DESCRIPTION: &str = "All network traffic";
const NO_CONNECTED_DEVICES: &str = "No connected devices";

/// Maximum number of connected devices listed inline in a device pool's submenu.
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
        let bottom_section = match &self.connlib {
            ConnlibState::Loading
            | ConnlibState::Quitting
            | ConnlibState::SignedOut
            | ConnlibState::WaitingForBrowser
            | ConnlibState::WaitingForPortal
            | ConnlibState::WaitingForTunnel => BottomSection::SignedOut,
            ConnlibState::SignedIn(_) => BottomSection::SignedIn,
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
            bottom_section,
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
    pub internet_resource_enabled: Option<bool>,
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
        internet_resource_enabled,
    } = signed_in;

    let internet_resource_enabled = internet_resource_enabled.unwrap_or_default();

    let mut menu = Menu::default()
        .disabled(session_heading(actor_name))
        .item(Event::SignOut, SIGN_OUT);

    tracing::debug!(
        resource_count = resources.len(),
        "Building signed-in tray menu"
    );
    let mut favorites = Menu::default();
    if resources
        .iter()
        .any(|res| favorite_resources.contains(&res.id()))
    {
        favorites = favorites.disabled(FAVORITE_RESOURCES);
    }

    for res in resources {
        let is_favorite = favorite_resources.contains(&res.id());

        favorites = match res {
            ResourceView::Internet(internet) => favorites.add_submenu(
                append_status(&internet.name, internet_resource_enabled),
                internet_resource_submenu(internet_resource_enabled),
            ),
            ResourceView::Dns(dns) if is_favorite => favorites.add_submenu(
                &dns.name,
                resource_submenu(&dns.name, dns.address_description.as_deref(), &dns.address),
            ),
            ResourceView::Cidr(cidr) if is_favorite => favorites.add_submenu(
                &cidr.name,
                resource_submenu(
                    &cidr.name,
                    cidr.address_description.as_deref(),
                    &cidr.address.to_string(),
                ),
            ),
            ResourceView::DevicePool(pool) if is_favorite => {
                favorites.add_submenu(&pool.name, devices_submenu(&pool.devices))
            }
            ResourceView::Dns(_) | ResourceView::Cidr(_) | ResourceView::DevicePool(_) => favorites,
        };
    }

    if !favorites.entries.is_empty() {
        menu.add_separator();
        menu.entries.extend(favorites.entries);
    }

    menu
}

fn internet_resource_submenu(enabled: bool) -> Menu {
    let menu = Menu::default()
        .disabled(INTERNET_RESOURCE_DESCRIPTION)
        .separator();

    if enabled {
        menu.item(Event::DisableInternetResource, DISABLE)
    } else {
        menu.item(Event::EnableInternetResource, ENABLE)
    }
}

fn resource_submenu(name: &str, description: Option<&str>, address: &str) -> Menu {
    let mut menu = Menu::default().copyable(name);

    if let Some(description) = description.filter(|description| !description.is_empty()) {
        menu.add_item(description_item(description));
    }

    menu.copyable(address)
}

fn description_item(description: &str) -> Item {
    let Some(url) = description_link(description) else {
        return copyable(description);
    };

    item(Event::Url(url), format!("<{description}>"))
}

fn devices_submenu(connected_devices: &[ConnectedDeviceView]) -> Menu {
    if connected_devices.is_empty() {
        return Menu::default().disabled(NO_CONNECTED_DEVICES);
    }

    let mut menu = Menu::default();
    let visible = connected_devices.len().min(MAX_DEVICES_INLINE);
    for device in &connected_devices[..visible] {
        menu = menu.copyable(&format!("{}.{DEVICE_DOMAIN}", device.slug));
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

fn session_heading(actor_name: &str) -> String {
    if actor_name.is_empty() {
        "Signed in".to_owned()
    } else {
        format!("Signed in as {actor_name}")
    }
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

/// Which session the bottom section of the menu is for.
#[derive(Clone, Copy)]
pub(crate) enum BottomSection {
    SignedIn,
    SignedOut,
}

impl Menu {
    /// Appends things that always show, like About, Settings, Help, Quit, etc.
    pub(crate) fn add_bottom_section(
        mut self,
        release: Option<Release>,
        section: BottomSection,
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

        let quit_text = match section {
            BottomSection::SignedIn => {
                self = self.item(Event::ShowWindow(Window::Resources), RESOURCES);

                DISCONNECT_AND_QUIT
            }
            BottomSection::SignedOut => QUIT_TEXT_SIGNED_OUT,
        };

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
            .item(Event::ShowWindow(Window::Resources), RESOURCES)
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
                        Event::Url(utm_url("https://www.firezone.dev/support")),
                        "Support...",
                    ),
            )
            .item(Event::ShowWindow(Window::Settings), "Settings")
            .separator()
            .item(Event::Quit, DISCONNECT_AND_QUIT);

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual).unwrap()
        );
    }

    #[test]
    fn new_release_is_offered_above_resources() {
        let release = Release {
            download_url: "https://www.firezone.dev/dl".parse().unwrap(),
            version: "1.6.0".parse().unwrap(),
        };

        let actual = AppState {
            release: Some(release.clone()),
            ..signed_in(vec![], HashSet::default(), None)
        }
        .into_menu();

        assert_eq!(
            actual.entries[3..5],
            [
                Entry::Item(item(
                    Event::Url(release.download_url),
                    "Download Firezone 1.6.0..."
                )),
                Entry::Item(item(Event::ShowWindow(Window::Resources), RESOURCES)),
            ]
        );
    }

    #[test]
    fn no_resources_invalid_favorite() {
        let actual =
            signed_in(vec![], HashSet::from([ResourceId::from_u128(42)]), None).into_menu();

        let expected = Menu::default()
            .disabled("Signed in as Jane Doe")
            .item(Event::SignOut, SIGN_OUT)
            .add_bottom_section(None, BottomSection::SignedIn, true, None); // Skip testing the bottom section, it's simple

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
            .add_submenu(
                "— Internet Resource",
                Menu::default()
                    .disabled(INTERNET_RESOURCE_DESCRIPTION)
                    .separator()
                    .item(Event::EnableInternetResource, ENABLE),
            )
            .add_bottom_section(None, BottomSection::SignedIn, true, None); // Skip testing the bottom section, it's simple

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
                    .copyable("MyCorp GitLab")
                    .item(
                        Event::Url("https://gitlab.mycorp.com".parse()?),
                        "<https://gitlab.mycorp.com>",
                    )
                    .copyable("gitlab.mycorp.com"),
            )
            .add_submenu(
                "— Internet Resource",
                Menu::default()
                    .disabled(INTERNET_RESOURCE_DESCRIPTION)
                    .separator()
                    .item(Event::EnableInternetResource, ENABLE),
            )
            .add_bottom_section(None, BottomSection::SignedIn, true, None); // Skip testing the bottom section, it's simple

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual)?
        );

        Ok(())
    }

    #[test]
    fn description_that_is_not_a_url_is_copyable() -> Result<()> {
        let actual = signed_in(
            resources(),
            HashSet::from([ResourceId::from_str(
                "73037362-715d-4a83-a749-f18eadd970e6",
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
                "172.172.0.0/16",
                Menu::default()
                    .copyable("172.172.0.0/16")
                    .copyable("cidr resource")
                    .copyable("172.172.0.0/16"),
            )
            .add_submenu(
                format!("{DISABLED_SYMBOL} Internet Resource"),
                Menu::default()
                    .disabled(INTERNET_RESOURCE_DESCRIPTION)
                    .separator()
                    .item(Event::EnableInternetResource, ENABLE),
            )
            .add_bottom_section(None, BottomSection::SignedIn, true, None); // Skip testing the bottom section, it's simple

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual)?
        );

        Ok(())
    }

    #[test]
    fn missing_description_is_omitted() {
        use connlib_model::DnsResourceView;
        let resource = ResourceView::Dns(DnsResourceView {
            id: ResourceId::from_u128(1),
            address: "git.example.com".into(),
            name: "Git server".into(),
            address_description: None,
            sites: vec![],
            status: connlib_model::ResourceStatus::Unknown,
        });

        let actual = signed_in(
            vec![resource],
            HashSet::from([ResourceId::from_u128(1)]),
            None,
        )
        .into_menu();

        let expected = Menu::default()
            .disabled("Signed in as Jane Doe")
            .item(Event::SignOut, SIGN_OUT)
            .separator()
            .disabled(FAVORITE_RESOURCES)
            .add_submenu(
                "Git server",
                Menu::default()
                    .copyable("Git server")
                    .copyable("git.example.com"),
            )
            .add_bottom_section(None, BottomSection::SignedIn, true, None); // Skip testing the bottom section, it's simple

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual).unwrap()
        );
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
            .add_submenu(
                "— Internet Resource",
                Menu::default()
                    .disabled(INTERNET_RESOURCE_DESCRIPTION)
                    .separator()
                    .item(Event::EnableInternetResource, ENABLE),
            )
            .add_bottom_section(None, BottomSection::SignedIn, true, None); // Skip testing the bottom section, it's simple

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual)?,
        );

        Ok(())
    }

    #[test]
    fn device_pools_list_their_connected_devices() {
        use connlib_model::{ClientId, DevicePoolResourceView};
        use std::net::{Ipv4Addr, Ipv6Addr};
        let alpha = ClientId::from_u128(0x1111_1111_1111_1111_1111_1111_1111_1111);
        let alpha_ip = Ipv4Addr::new(100, 64, 0, 1);
        let alpha_ipv6 = Ipv6Addr::from([0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 1]);
        let resources = vec![
            ResourceView::DevicePool(DevicePoolResourceView {
                id: ResourceId::from_u128(1),
                name: "Engineering Pool".into(),
                devices: vec![ConnectedDeviceView {
                    id: alpha,
                    name: "Alpha".into(),
                    slug: "alpha".into(),
                    tun_ipv4: alpha_ip,
                    tun_ipv6: alpha_ipv6,
                }],
            }),
            ResourceView::DevicePool(DevicePoolResourceView {
                id: ResourceId::from_u128(2),
                name: "QA Pool".into(),
                devices: vec![],
            }),
        ];

        let favorites = HashSet::from([ResourceId::from_u128(1), ResourceId::from_u128(2)]);

        let actual = signed_in(resources, favorites, None).into_menu();

        let expected = Menu::default()
            .disabled("Signed in as Jane Doe")
            .item(Event::SignOut, SIGN_OUT)
            .separator()
            .disabled(FAVORITE_RESOURCES)
            .add_submenu(
                "Engineering Pool",
                Menu::default().copyable("alpha.firezone.network"),
            )
            .add_submenu("QA Pool", Menu::default().disabled(NO_CONNECTED_DEVICES))
            .add_bottom_section(None, BottomSection::SignedIn, true, None); // Skip testing the bottom section, it's simple

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
        use std::net::{Ipv4Addr, Ipv6Addr};
        let connected_devices: Vec<ConnectedDeviceView> = (0..MAX_DEVICES_INLINE + 3)
            .map(|i| ConnectedDeviceView {
                id: ClientId::from_u128(0x1111_1111_1111_1111_1111_1111_1111_1111 + i as u128),
                name: format!("Device {i}"),
                slug: format!("device-{i}"),
                tun_ipv4: Ipv4Addr::new(100, 64, 0, i as u8),
                tun_ipv6: Ipv6Addr::from([0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, i as u16]),
            })
            .collect();

        let actual = devices_submenu(&connected_devices);

        let mut expected = Menu::default();
        for device in &connected_devices[..MAX_DEVICES_INLINE] {
            expected = expected.copyable(&format!("{}.firezone.network", device.slug));
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

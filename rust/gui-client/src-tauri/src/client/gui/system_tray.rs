//! Code for the system tray AKA notification area
//!
//! This manages the icon, menu, and tooltip.
//!
//! "Notification Area" is Microsoft's official name instead of "System tray":
//! <https://learn.microsoft.com/en-us/windows/win32/shell/notification-area?redirectedfrom=MSDN#notifications-and-the-notification-area>

use anyhow::Result;
use connlib_shared::{
    callbacks::{ResourceDescription, Status},
    messages::ResourceId,
};
use std::collections::HashSet;
use tauri::{SystemTray, SystemTrayHandle};

mod builder;

pub(crate) use builder::{item, Event, Menu, Window};

// Figma is the source of truth for the tray icons
// <https://www.figma.com/design/THvQQ1QxKlsk47H9DZ2bhN/Core-Library?node-id=1250-772&t=OGFabKWPx7PRUZmq-0>
const BUSY_ICON: &[u8] = include_bytes!("../../../icons/tray/Busy.png");
const SIGNED_IN_ICON: &[u8] = include_bytes!("../../../icons/tray/Signed in.png");
const SIGNED_OUT_ICON: &[u8] = include_bytes!("../../../icons/tray/Signed out.png");
const TOOLTIP: &str = "Firezone";
const QUIT_TEXT_SIGNED_OUT: &str = "Quit Firezone";

const NO_ACTIVITY: &str = "[-] No activity";
const GATEWAY_CONNECTED: &str = "[O] Gateway connected";
const ALL_GATEWAYS_OFFLINE: &str = "[X] All Gateways offline";

const ADD_FAVORITE: &str = "Add to favorites";
const REMOVE_FAVORITE: &str = "Remove from favorites";
const FAVORITE_RESOURCES: &str = "Favorite Resources";
const RESOURCES: &str = "Resources";
const OTHER_RESOURCES: &str = "Other Resources";
const SIGN_OUT: &str = "Sign out";
const DISCONNECT_AND_QUIT: &str = "Disconnect and quit Firezone";
const DISABLE: &str = "Disable this resource";
const ENABLE: &str = "Enable this resource";

pub(crate) const INTERNET_RESOURCE_DESCRIPTION: &str = "All internet traffic";

pub(crate) fn loading() -> SystemTray {
    SystemTray::new()
        .with_icon(tauri::Icon::Raw(BUSY_ICON.into()))
        .with_menu(AppState::Loading.build())
        .with_tooltip(TOOLTIP)
}

pub(crate) struct Tray {
    handle: SystemTrayHandle,
    last_icon_set: Icon,
}

pub(crate) enum AppState<'a> {
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
    pub(crate) disabled_resources: &'a HashSet<ResourceId>,
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

        if !res.is_internet_resource() {
            self.add_favorite_toggle(&mut submenu, res.id());
        }

        if res.can_be_disabled() {
            submenu.add_separator();
            if self.is_enabled(res) {
                submenu.add_item(item(Event::DisableResource(res.id()), DISABLE));
            } else {
                submenu.add_item(item(Event::EnableResource(res.id()), ENABLE));
            }
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
            submenu.separator()
        }
    }

    fn is_enabled(&self, res: &ResourceDescription) -> bool {
        !self.disabled_resources.contains(&res.id())
    }
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

    pub(crate) fn update(&mut self, state: AppState) -> Result<()> {
        let new_icon = match &state {
            AppState::Loading | AppState::WaitingForBrowser | AppState::WaitingForConnlib => {
                Icon::Busy
            }
            AppState::SignedOut => Icon::SignedOut,
            AppState::SignedIn { .. } => Icon::SignedIn,
        };

        self.handle.set_tooltip(TOOLTIP)?;
        self.handle.set_menu(state.build())?;
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

impl<'a> AppState<'a> {
    fn build(self) -> tauri::SystemTrayMenu {
        self.into_menu().build()
    }

    fn into_menu(self) -> Menu {
        match self {
            Self::Loading => Menu::default().disabled("Loading..."),
            Self::SignedOut => Menu::default()
                .item(Event::SignIn, "Sign In")
                .add_bottom_section(QUIT_TEXT_SIGNED_OUT),
            Self::WaitingForBrowser => signing_in("Waiting for browser..."),
            Self::WaitingForConnlib => signing_in("Signing In..."),
            Self::SignedIn(x) => signed_in(&x),
        }
    }
}

fn signed_in(signed_in: &SignedIn) -> Menu {
    let SignedIn {
        actor_name,
        favorite_resources,
        resources, // Make sure these are presented in the order we receive them
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
            menu = menu.add_submenu(res.name(), signed_in.resource_submenu(res));
        }
    } else {
        // No favorites, show every Resource normally, just like before
        // the favoriting feature was created
        // Always show Resources in the original order
        menu = menu.disabled(RESOURCES);
        for res in *resources {
            menu = menu.add_submenu(res.name(), signed_in.resource_submenu(res));
        }
    }

    if has_any_favorites {
        let mut submenu = Menu::default();
        // Always show Resources in the original order
        for res in resources
            .iter()
            .filter(|res| !favorite_resources.contains(&res.id()) || !res.is_internet_resource())
        {
            submenu = submenu.add_submenu(res.name(), signed_in.resource_submenu(res));
        }
        menu = menu.separator().add_submenu(OTHER_RESOURCES, submenu);
    }

    menu.add_bottom_section(DISCONNECT_AND_QUIT)
}

fn signing_in(waiting_message: &str) -> Menu {
    Menu::default()
        .disabled(waiting_message)
        .item(Event::CancelSignIn, "Cancel sign-in")
        .add_bottom_section(QUIT_TEXT_SIGNED_OUT)
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
        disabled_resources: &'a HashSet<ResourceId>,
    ) -> AppState<'a> {
        AppState::SignedIn(SignedIn {
            actor_name: "Jane Doe",
            favorite_resources,
            resources,
            disabled_resources,
        })
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
                "name": "🌐 Internet Resource",
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
            .add_bottom_section(DISCONNECT_AND_QUIT); // Skip testing the bottom section, it's simple

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
            .add_bottom_section(DISCONNECT_AND_QUIT); // Skip testing the bottom section, it's simple

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
                    .copyable("")
                    .separator()
                    .disabled("Resource")
                    .copyable("Internet Resource")
                    .copyable("")
                    .item(
                        Event::AddFavorite(
                            ResourceId::from_str("1106047c-cd5d-4151-b679-96b93da7383b").unwrap(),
                        ),
                        ADD_FAVORITE,
                    )
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable(ALL_GATEWAYS_OFFLINE),
            )
            .add_bottom_section(DISCONNECT_AND_QUIT); // Skip testing the bottom section, it's simple
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
            .separator()
            .add_submenu(
                OTHER_RESOURCES,
                Menu::default()
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
                        "Internet Resource",
                        Menu::default()
                            .copyable("")
                            .separator()
                            .disabled("Resource")
                            .copyable("Internet Resource")
                            .copyable("")
                            .item(
                                Event::AddFavorite(ResourceId::from_str(
                                    "1106047c-cd5d-4151-b679-96b93da7383b",
                                )?),
                                ADD_FAVORITE,
                            )
                            .separator()
                            .disabled("Site")
                            .copyable("test")
                            .copyable(ALL_GATEWAYS_OFFLINE),
                    ),
            )
            .add_bottom_section(DISCONNECT_AND_QUIT); // Skip testing the bottom section, it's simple

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
                "🌐 Internet Resource",
                Menu::default()
                    .copyable("")
                    .separator()
                    .disabled("Resource")
                    .copyable("🌐 Internet Resource")
                    .copyable("")
                    .item(
                        Event::AddFavorite(ResourceId::from_str(
                            "1106047c-cd5d-4151-b679-96b93da7383b",
                        )?),
                        ADD_FAVORITE,
                    )
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable(ALL_GATEWAYS_OFFLINE),
            )
            .add_bottom_section(DISCONNECT_AND_QUIT); // Skip testing the bottom section, it's simple

        assert_eq!(
            actual,
            expected,
            "{}",
            serde_json::to_string_pretty(&actual).unwrap(),
        );

        Ok(())
    }
}

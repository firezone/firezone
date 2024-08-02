//! Code for the system tray AKA notification area
//!
//! This manages the icon, menu, and tooltip.
//!
//! "Notification Area" is Microsoft's official name instead of "System tray":
//! <https://learn.microsoft.com/en-us/windows/win32/shell/notification-area?redirectedfrom=MSDN#notifications-and-the-notification-area>

use anyhow::Result;
use connlib_client_shared::callbacks::{ResourceDescription, Status};
use tauri::{SystemTray, SystemTrayHandle};
use url::Url;

mod builder;

pub(crate) use builder::{copyable, item, Event, Item, Menu, Window};

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

const RESOURCES: &str = "Resources";
const SIGN_OUT: &str = "Sign out";
const DISCONNECT_AND_QUIT: &str = "Disconnect and quit Firezone";

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
    pub(crate) resources: &'a [ResourceDescription],
}

impl<'a> SignedIn<'a> {
    /// Builds the submenu that has the resource address, name, desc,
    /// sites online, etc.
    fn resource_submenu(&self, res: &ResourceDescription) -> Menu {
        let submenu = Menu::default().add_item(resource_header(res));

        let submenu = submenu
            .separator()
            .disabled("Resource")
            .copyable(res.name())
            .copyable(res.pastable().as_ref());

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
}

fn resource_header(res: &ResourceDescription) -> Item {
    let Some(address_description) = res.address_description() else {
        return copyable(&res.pastable());
    };

    if address_description.is_empty() {
        return copyable(&res.pastable());
    }

    let Ok(url) = Url::parse(address_description) else {
        return copyable(address_description);
    };

    item(Event::Url(url), format!("<{address_description}>"))
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
        resources, // Make sure these are presented in the order we receive them
    } = signed_in;

    let mut menu = Menu::default()
        .disabled(format!("Signed in as {actor_name}"))
        .item(Event::SignOut, SIGN_OUT)
        .separator();

    tracing::debug!(
        resource_count = resources.len(),
        "Building signed-in tray menu"
    );

    menu = menu.disabled(RESOURCES);
    // Always show Resources in the original order
    for res in *resources {
        menu = menu.add_submenu(res.name(), signed_in.resource_submenu(res));
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
                "disableable": false
            },
            {
                "id": "03000143-e25e-45c7-aafb-144990e57dcd",
                "type": "dns",
                "name": "gitlab.mycorp.com",
                "address": "gitlab.mycorp.com",
                "address_description": "dns resource",
                "sites": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
                "status": "Online",
                "disableable": false
            },
            {
                "id": "1106047c-cd5d-4151-b679-96b93da7383b",
                "type": "internet",
                "name": "internet",
                "address": "0.0.0.0/0",
                "address_description": "The whole entire Internet",
                "sites": [{"name": "test", "id": "eb94482a-94f4-47cb-8127-14fb3afa5516"}],
                "status": "Offline",
                "disableable": false
            }
        ]"#;

        serde_json::from_str(s).unwrap()
    }

    #[test]
    fn no_resources() {
        let resources = vec![];
        let input = AppState::SignedIn(SignedIn {
            actor_name: "Jane Doe",
            resources: &resources,
        });
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
    fn dns_resource_with_url() {
        let s = r#"[
            {
                "id": "f716012d-5a0d-4008-86c2-1d37dd3c9915",
                "type": "dns",
                "name": "Example",
                "address": "example.com",
                "address_description": "https://example.com",
                "sites": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
                "status": "Online",
                "disableable": false
            }
        ]"#;
        let resources: Vec<_> = serde_json::from_str(s).unwrap();
        let input = AppState::SignedIn(SignedIn {
            actor_name: "Jane Doe",
            resources: &resources,
        });
        let actual = input.into_menu();
        let expected = Menu::default()
            .disabled("Signed in as Jane Doe")
            .item(Event::SignOut, SIGN_OUT)
            .separator()
            .disabled(RESOURCES)
            .add_submenu(
                "Example",
                Menu::default()
                    .item(
                        Event::Url("https://example.com".parse().unwrap()),
                        "<https://example.com>",
                    )
                    .separator()
                    .disabled("Resource")
                    .copyable("Example")
                    .copyable("example.com")
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable(GATEWAY_CONNECTED),
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
    fn some_resources() {
        let resources = resources();
        let input = AppState::SignedIn(SignedIn {
            actor_name: "Jane Doe",
            resources: &resources,
        });
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
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable(NO_ACTIVITY),
            )
            .add_submenu(
                "gitlab.mycorp.com",
                Menu::default()
                    .copyable("dns resource")
                    .separator()
                    .disabled("Resource")
                    .copyable("gitlab.mycorp.com")
                    .copyable("gitlab.mycorp.com")
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable(GATEWAY_CONNECTED),
            )
            .add_submenu(
                "Internet",
                Menu::default()
                    .copyable("")
                    .separator()
                    .disabled("Resource")
                    .copyable("Internet")
                    .copyable("")
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
}

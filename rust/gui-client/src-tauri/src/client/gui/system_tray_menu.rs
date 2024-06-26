//! Code for the Windows notification area
//!
//! "Notification Area" is Microsoft's official name instead of "System tray":
//! <https://learn.microsoft.com/en-us/windows/win32/shell/notification-area?redirectedfrom=MSDN#notifications-and-the-notification-area>

use connlib_client_shared::callbacks::{ResourceDescription, Status};
use serde::{Deserialize, Serialize};
use tauri::{CustomMenuItem, SystemTrayMenu, SystemTrayMenuItem, SystemTraySubmenu};
use url::Url;

#[derive(Debug, Deserialize, PartialEq, Serialize)]
pub(crate) enum Event {
    AdminPortal,
    CancelSignIn,
    Copy(String),
    Reconnect,
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

pub(crate) fn loading() -> SystemTrayMenu {
    SystemTrayMenu::new().disabled("Loading...")
}

pub(crate) fn signed_in(user_name: &str, resources: &[ResourceDescription]) -> SystemTrayMenu {
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

pub(crate) fn signing_in(waiting_message: &str) -> SystemTrayMenu {
    SystemTrayMenu::new()
        .disabled(waiting_message)
        .item(Event::CancelSignIn, "Cancel sign-in")
        .add_bottom_section(QUIT_TEXT_SIGNED_OUT)
}

pub(crate) fn signed_out() -> SystemTrayMenu {
    SystemTrayMenu::new()
        .item(Event::SignIn, "Sign In")
        .add_bottom_section(QUIT_TEXT_SIGNED_OUT)
}

pub(crate) fn debug() -> SystemTrayMenu {
    let mut menu = SystemTrayMenu::new()
        .disabled("Debug tray menu")
        .item(None, "Fake sign out button")
        .separator()
        .disabled("Resources");

    let submenu = SystemTrayMenu::new().copyable("Fake submenu");
    menu = menu.add_submenu(SystemTraySubmenu::new("Fake resource 1", submenu));

    let submenu = SystemTrayMenu::new()
        .copyable("Fake Copyable")
        .item(None, "Fake description")
        .separator()
        .disabled("Resource")
        .copyable("Fake name")
        .copyable("Fake pastable")
        .separator()
        .disabled("Site")
        .item(None, "Fake name")
        .item(None, "[-] No activity");
    menu = menu.add_submenu(SystemTraySubmenu::new("Fake resource 2", submenu));

    let submenu = SystemTrayMenu::new()
        .copyable("Fake Copyable")
        .item(None, "Fake description")
        .separator()
        .disabled("Resource")
        .copyable("Fake name")
        .copyable("Fake pastable")
        .separator()
        .disabled("Site")
        .item(None, "Fake name")
        .item(None, "⭕🟢🟥 Fake status");
    menu = menu.add_submenu(SystemTraySubmenu::new("Fake resource 3", submenu));

    let submenu = SystemTrayMenu::new().copyable("Fake Copyable ⭕");
    menu = menu.add_submenu(SystemTraySubmenu::new("Fake resource 4", submenu));

    let submenu = SystemTrayMenu::new().copyable("Fake Copyable 🟢");
    menu = menu.add_submenu(SystemTraySubmenu::new("Fake resource 5", submenu));

    let submenu = SystemTrayMenu::new().copyable("Fake Copyable 🟥");
    menu = menu.add_submenu(SystemTraySubmenu::new("Fake resource 6", submenu));

    menu
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
            .item(Event::Reconnect, "Reconnect")
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

//! Code for the Windows notification area
//!
//! "Notification Area" is Microsoft's official name instead of "System tray":
//! <https://learn.microsoft.com/en-us/windows/win32/shell/notification-area?redirectedfrom=MSDN#notifications-and-the-notification-area>

use connlib_client_shared::callbacks::ResourceDescription;
use std::str::FromStr;
use tauri::{CustomMenuItem, SystemTrayMenu, SystemTrayMenuItem, SystemTraySubmenu};

#[derive(Debug, PartialEq)]
pub(crate) enum Event {
    CancelSignIn,
    Resource { id: String },
    SignIn,
    SignOut,
    ShowWindow(Window),
    Quit,
}

#[derive(Debug, PartialEq)]
pub(crate) enum Window {
    About,
    Settings,
}

#[derive(thiserror::Error, Debug)]
pub(crate) enum Error {
    #[error("the system tray menu item ID is not valid")]
    InvalidId,
}

const ABOUT_KEY: &str = "/about";
const SETTINGS_KEY: &str = "/settings";
const QUIT_KEY: &str = "/quit";
const QUIT_ACCELERATOR: &str = "Ctrl+Q";

impl FromStr for Event {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Error> {
        Ok(match s {
            ABOUT_KEY => Self::ShowWindow(Window::About),
            "/cancel_sign_in" => Self::CancelSignIn,
            SETTINGS_KEY => Self::ShowWindow(Window::Settings),
            "/sign_in" => Self::SignIn,
            "/sign_out" => Self::SignOut,
            QUIT_KEY => Self::Quit,
            s => {
                let id = s.strip_prefix("/resource/").ok_or(Error::InvalidId)?;
                Self::Resource { id: id.to_string() }
            }
        })
    }
}

pub(crate) fn signed_in(user_name: &str, resources: &[ResourceDescription]) -> SystemTrayMenu {
    let mut menu = SystemTrayMenu::new()
        .add_item(
            CustomMenuItem::new("".to_string(), format!("Signed in as {user_name}")).disabled(),
        )
        .add_item(CustomMenuItem::new("/sign_out".to_string(), "Sign out"))
        .add_native_item(SystemTrayMenuItem::Separator)
        .add_item(CustomMenuItem::new("".to_string(), "Resources").disabled());

    for res in resources {
        let id = res.id();
        let submenu = SystemTrayMenu::new().add_item(CustomMenuItem::new(
            format!("/resource/{id}"),
            res.pastable(),
        ));
        menu = menu.add_submenu(SystemTraySubmenu::new(res.name(), submenu));
    }

    menu = menu
        .add_native_item(SystemTrayMenuItem::Separator)
        .add_item(about())
        .add_item(settings())
        .add_item(
            CustomMenuItem::new(QUIT_KEY.to_string(), "Disconnect and quit Firezone")
                .accelerator(QUIT_ACCELERATOR),
        );

    menu
}

pub(crate) fn signing_in(waiting_message: &str) -> SystemTrayMenu {
    SystemTrayMenu::new()
        .add_item(CustomMenuItem::new("".to_string(), waiting_message).disabled())
        .add_item(CustomMenuItem::new(
            "/cancel_sign_in".to_string(),
            "Cancel sign-in",
        ))
        .add_native_item(SystemTrayMenuItem::Separator)
        .add_item(about())
        .add_item(settings())
        .add_item(quit())
}

pub(crate) fn signed_out() -> SystemTrayMenu {
    let debug_submenu = SystemTrayMenu::new().add_item(CustomMenuItem::new("", "line 1\nline 2"));

    SystemTrayMenu::new()
        .add_submenu(SystemTraySubmenu::new("line 1\nline 2", debug_submenu))
        .add_item(CustomMenuItem::new("/sign_in".to_string(), "Sign In"))
        .add_native_item(SystemTrayMenuItem::Separator)
        .add_item(about())
        .add_item(settings())
        .add_item(quit())
}

fn about() -> CustomMenuItem {
    CustomMenuItem::new(ABOUT_KEY.to_string(), "About Firezone")
}

fn settings() -> CustomMenuItem {
    CustomMenuItem::new(SETTINGS_KEY.to_string(), "Settings")
}

fn quit() -> CustomMenuItem {
    CustomMenuItem::new(QUIT_KEY.to_string(), "Quit Firezone").accelerator(QUIT_ACCELERATOR)
}

#[cfg(test)]
mod tests {
    use super::{Event, Window};
    use std::str::FromStr;

    #[test]
    fn systray_parse() {
        assert_eq!(
            Event::from_str(super::ABOUT_KEY).unwrap(),
            Event::ShowWindow(Window::About)
        );
        assert_eq!(
            Event::from_str("/resource/1234").unwrap(),
            Event::Resource {
                id: "1234".to_string()
            }
        );
        assert_eq!(
            Event::from_str("/resource/quit").unwrap(),
            Event::Resource {
                id: "quit".to_string()
            }
        );
        assert_eq!(Event::from_str("/sign_out").unwrap(), Event::SignOut);
        assert_eq!(Event::from_str(super::QUIT_KEY).unwrap(), Event::Quit);

        assert!(Event::from_str("/unknown").is_err());
    }
}

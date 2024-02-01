use connlib_client_shared::ResourceDescription;
use std::str::FromStr;
use tauri::{CustomMenuItem, SystemTrayMenu, SystemTrayMenuItem, SystemTraySubmenu};

#[derive(Debug, PartialEq)]
pub(crate) enum Event {
    CancelSignIn,
    Resource { id: String },
    SignIn,
    SignOut,
    ToggleWindow(Window),
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

impl FromStr for Event {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Error> {
        Ok(match s {
            "/about" => Self::ToggleWindow(Window::About),
            "/cancel_sign_in" => Self::CancelSignIn,
            "/settings" => Self::ToggleWindow(Window::Settings),
            "/sign_in" => Self::SignIn,
            "/sign_out" => Self::SignOut,
            "/quit" => Self::Quit,
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
        .add_item(CustomMenuItem::new("/about".to_string(), "About"))
        .add_item(CustomMenuItem::new("/settings".to_string(), "Settings"))
        .add_item(
            CustomMenuItem::new("/quit".to_string(), "Disconnect and quit Firezone")
                .accelerator("Ctrl+Q"),
        );

    menu
}

pub(crate) fn signing_in() -> SystemTrayMenu {
    SystemTrayMenu::new()
        .add_item(CustomMenuItem::new("".to_string(), "Signing In...").disabled())
        .add_item(CustomMenuItem::new(
            "/cancel_sign_in".to_string(),
            "Cancel sign-in",
        ))
        .add_native_item(SystemTrayMenuItem::Separator)
        .add_item(CustomMenuItem::new("/about".to_string(), "About"))
        .add_item(CustomMenuItem::new("/settings".to_string(), "Settings"))
        .add_item(CustomMenuItem::new("/quit".to_string(), "Quit Firezone").accelerator("Ctrl+Q"))
}

pub(crate) fn signed_out() -> SystemTrayMenu {
    SystemTrayMenu::new()
        .add_item(CustomMenuItem::new("/sign_in".to_string(), "Sign In"))
        .add_native_item(SystemTrayMenuItem::Separator)
        .add_item(CustomMenuItem::new("/about".to_string(), "About"))
        .add_item(CustomMenuItem::new("/settings".to_string(), "Settings"))
        .add_item(CustomMenuItem::new("/quit".to_string(), "Quit Firezone").accelerator("Ctrl+Q"))
}

#[cfg(test)]
mod tests {
    use super::{Event, Window};
    use std::str::FromStr;

    #[test]
    fn systray_parse() {
        assert_eq!(
            Event::from_str("/about").unwrap(),
            Event::ToggleWindow(Window::About)
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
        assert_eq!(Event::from_str("/quit").unwrap(), Event::Quit);

        assert!(Event::from_str("/unknown").is_err());
    }
}

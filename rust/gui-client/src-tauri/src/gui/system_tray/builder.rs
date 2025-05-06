//! An abstraction over Tauri's system tray menu structs, that implements `PartialEq` for unit testing

use connlib_model::{ResourceId, ResourceView};
use serde::{Deserialize, Serialize};
use url::Url;

pub const INTERNET_RESOURCE_DESCRIPTION: &str = "All network traffic";

/// A menu that can either be assigned to the system tray directly or used as a submenu in another menu.
///
/// Equivalent to `tauri::menu::Menu` or `tauri::menu::Submenu`
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Menu {
    pub entries: Vec<Entry>,
}

/// Something that can be shown in a menu, including text items, separators, and submenus
#[derive(Clone, Debug, PartialEq, Serialize)]
pub enum Entry {
    Item(Item),
    Separator,
    Submenu { title: String, inner: Menu },
}

/// Something that shows text and may be clickable
///
/// Equivalent to `tauri::CustomMenuItem`
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Item {
    /// An event to send to the app when the item is clicked.
    ///
    /// If `None`, then the item is disabled and greyed out.
    pub event: Option<Event>,
    /// The text displayed to the user
    pub title: String,
    /// `None` means not checkable, `Some` is the checked state
    pub checked: Option<bool>,
}

/// Events that the menu can send to the app
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub enum Event {
    /// Marks this Resource as favorite
    AddFavorite(ResourceId),
    /// Opens the admin portal in the default web browser
    AdminPortal,
    /// Cancels any ongoing sign-in flow
    CancelSignIn,
    /// Copies this string to the desktop clipboard
    Copy(String),
    /// Marks this Resource as non-favorite
    RemoveFavorite(ResourceId),
    /// If a Portal connection has failed, try again immediately
    RetryPortalConnection,
    /// Starts the sign-in flow
    SignIn,
    /// Signs the user out, without quitting the app
    SignOut,
    /// Opens the About or Settings window
    ShowWindow(Window),
    /// Opens an arbitrary URL in the default web browser
    ///
    /// TODO: If we used the `ResourceId` here we could avoid any problems with
    /// serializing and deserializing user-controlled URLs.
    Url(Url),
    /// Quits the app, without signing the user out
    Quit,
    /// The internet resource was enabled
    EnableInternetResource,
    /// The internet resource was disabled
    DisableInternetResource,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub enum Window {
    About,
    Settings,
}

fn resource_header(res: &ResourceView) -> Item {
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

impl Menu {
    pub(crate) fn add_separator(&mut self) {
        self.entries.push(Entry::Separator);
    }

    pub(crate) fn add_item(&mut self, item: Item) {
        self.entries.push(Entry::Item(item));
    }

    pub(crate) fn add_submenu<S: Into<String>>(mut self, title: S, inner: Menu) -> Self {
        self.entries.push(Entry::Submenu {
            inner,
            title: title.into(),
        });
        self
    }

    /// Appends a menu item that copies its title when clicked
    pub(crate) fn copyable(mut self, s: &str) -> Self {
        self.add_item(copyable(s));
        self
    }

    /// Appends a disabled item with no accelerator or event
    pub(crate) fn disabled<S: Into<String>>(mut self, title: S) -> Self {
        self.add_item(item(None, title).disabled());
        self
    }

    /// Appends a generic menu item
    pub(crate) fn item<E: Into<Option<Event>>, S: Into<String>>(mut self, id: E, title: S) -> Self {
        self.add_item(item(id, title));
        self
    }

    /// Appends a separator
    pub(crate) fn separator(mut self) -> Self {
        self.add_separator();
        self
    }

    fn internet_resource(self) -> Self {
        self.disabled(INTERNET_RESOURCE_DESCRIPTION)
    }

    fn resource_body(self, resource: &ResourceView) -> Self {
        self.separator()
            .disabled("Resource")
            .copyable(resource.name())
            .copyable(resource.pastable().as_ref())
    }

    pub(crate) fn resource_description(mut self, resource: &ResourceView) -> Self {
        if resource.is_internet_resource() {
            self.internet_resource()
        } else {
            self.add_item(resource_header(resource));
            self.resource_body(resource)
        }
    }
}

impl Item {
    fn disabled(mut self) -> Self {
        self.event = None;
        self
    }

    pub(crate) fn checked(mut self, b: bool) -> Self {
        self.checked = Some(b);
        self
    }
}

/// Creates a menu item that copies its title when clicked
pub(crate) fn copyable(s: &str) -> Item {
    item(Event::Copy(s.to_string()), s)
}

/// Creates a generic menu item with one of our events attached
pub(crate) fn item<E: Into<Option<Event>>, S: Into<String>>(event: E, title: S) -> Item {
    Item {
        event: event.into(),
        title: title.into(),
        checked: None,
    }
}

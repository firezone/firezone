//! An abstraction over Tauri's system tray menu structs, that implements `PartialEq` for unit testing

use connlib_model::{ResourceId, ResourceView};
use serde::{Deserialize, Serialize};
use std::borrow::Cow;
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
    /// An optional icon shown to the left of the title.
    ///
    /// Mirrors the status icons the macOS client shows in its tray menu.
    pub icon: Option<Icon>,
}

/// A colored dot shown next to a menu item.
///
/// Named by color rather than meaning so it can be reused. Currently it
/// mirrors the native status images the macOS client uses for Site status in
/// its tray menu (`NSImage.statusAvailableName` and friends); Tauri has no
/// cross-platform "native" status icons, so we ship our own equivalents.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub enum Icon {
    Green,
    Red,
    Grey,
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

/// The single detail line shown for a Resource: its description if present,
/// otherwise its address. Returns `None` when that value is empty or identical
/// to the `name` already shown by the parent menu item, so nothing is repeated.
///
/// A description that parses as a URL becomes a clickable link; anything else is
/// shown greyed-out, since the address is copied via the explicit "Copy address"
/// action instead.
pub(crate) fn resource_detail(res: &ResourceView) -> Option<Item> {
    let detail = match res.address_description() {
        Some(description) if !description.is_empty() => Cow::from(description),
        _ => res.pastable(),
    };

    if detail.is_empty() || &*detail == res.name() {
        return None;
    }

    let detail = match Url::parse(&detail) {
        Ok(url) => item(Event::Url(url), format!("<{detail}>")),
        Err(_) => item(None, detail.into_owned()),
    };

    Some(detail)
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

    /// Appends a menu item that copies its title when clicked and shows `icon`
    /// to the left of the text.
    pub(crate) fn copyable_with_icon(mut self, s: &str, icon: Icon) -> Self {
        self.add_item(copyable(s).icon(icon));
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

    pub(crate) fn icon(mut self, icon: Icon) -> Self {
        self.icon = Some(icon);
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
        icon: None,
    }
}

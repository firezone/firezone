//! Code for the system tray AKA notification area
//!
//! This manages the icon, menu, and tooltip.
//!
//! "Notification Area" is Microsoft's official name instead of "System tray":
//! <https://learn.microsoft.com/en-us/windows/win32/shell/notification-area?redirectedfrom=MSDN#notifications-and-the-notification-area>

use crate::updates::Release;
use anyhow::{Context as _, Result};
use compositor::Image;
use connlib_model::{ResourceId, ResourceStatus, ResourceView};
use std::collections::HashSet;
use tauri::AppHandle;
use url::Url;

use builder::item;
pub use builder::{Entry, Event, Item, Menu, Window};

mod builder;
mod compositor;

type IsMenuItem = dyn tauri::menu::IsMenuItem<tauri::Wry>;
type TauriMenu = tauri::menu::Menu<tauri::Wry>;
type TauriSubmenu = tauri::menu::Submenu<tauri::Wry>;

// Figma is the source of truth for the tray icon layers
// <https://www.figma.com/design/THvQQ1QxKlsk47H9DZ2bhN/Core-Library?node-id=1250-772&t=nHBOzOnSY5Ol4asV-0>
const LOGO_BASE: &[u8] = include_bytes!("../../icons/tray/Logo.png");
const LOGO_GREY_BASE: &[u8] = include_bytes!("../../icons/tray/Logo grey.png");
const BUSY_LAYER: &[u8] = include_bytes!("../../icons/tray/Busy layer.png");
const SIGNED_OUT_LAYER: &[u8] = include_bytes!("../../icons/tray/Signed out layer.png");
const UPDATE_READY_LAYER: &[u8] = include_bytes!("../../icons/tray/Update ready layer.png");

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

const TOOLTIP: &str = "Firezone";

pub(crate) struct Tray {
    app: AppHandle,
    handle: tauri::tray::TrayIcon,
    last_icon_set: Icon,
    last_menu_set: Option<Menu>,
}

fn icon_to_tauri_icon(that: &Icon) -> tauri::image::Image<'static> {
    let layers = match that.base {
        IconBase::Busy => &[LOGO_GREY_BASE, BUSY_LAYER][..],
        IconBase::SignedIn => &[LOGO_BASE][..],
        IconBase::SignedOut => &[LOGO_GREY_BASE, SIGNED_OUT_LAYER][..],
    }
    .iter()
    .copied()
    .chain(that.update_ready.then_some(UPDATE_READY_LAYER));
    let composed =
        compositor::compose(layers).expect("PNG decoding should always succeed for baked-in PNGs");
    image_to_tauri_icon(composed)
}

fn image_to_tauri_icon(val: Image) -> tauri::image::Image<'static> {
    tauri::image::Image::new_owned(val.rgba, val.width, val.height)
}

impl Tray {
    pub(crate) fn new(
        app: AppHandle,
        on_event: impl Fn(&AppHandle, Event) + Send + Sync + 'static,
    ) -> Result<Self> {
        let tray = tauri::tray::TrayIconBuilder::new()
            .icon(icon_to_tauri_icon(&Icon::default()))
            .menu(&build_app_state(&app, &AppState::default().into_menu())?)
            .on_menu_event(move |app, event| {
                let id = &event.id.0;
                tracing::debug!(?id, "SystemTrayEvent::MenuItemClick");
                let event = match serde_json::from_str::<Event>(id) {
                    Ok(x) => x,
                    Err(e) => {
                        tracing::error!("{e}");
                        return;
                    }
                };

                on_event(app, event);
            })
            .tooltip("Firezone")
            .build(&app)
            .context("Cannot build Tauri tray icon")?;

        Ok(Self {
            app,
            handle: tray,
            last_icon_set: Default::default(),
            last_menu_set: None,
        })
    }

    pub(crate) fn update(&mut self, state: AppState) {
        let base = match &state.connlib {
            ConnlibState::Loading
            | ConnlibState::Quitting
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

        let menu = state.into_menu();
        let menu_clone = menu.clone();
        let app = self.app.clone();
        let handle = self.handle.clone();

        if Some(&menu) == self.last_menu_set.as_ref() {
            tracing::debug!("Skipping redundant menu update");
        } else {
            self.run_on_main_thread(move || {
                logging::unwrap_or_debug!(
                    update(handle, &app, &menu),
                    "Error while updating tray menu: {}"
                );
            });
        }
        self.set_icon(new_icon);
        self.last_menu_set = Some(menu_clone);
    }

    // Only needed for the stress test
    // Otherwise it would be inlined
    pub(crate) fn set_icon(&mut self, icon: Icon) {
        if icon == self.last_icon_set {
            return;
        }

        // Don't call `set_icon` too often. On Linux it writes a PNG to `/run/user/$UID/tao/tray-icon-*.png` every single time.
        // <https://github.com/tauri-apps/tao/blob/tao-v0.16.7/src/platform_impl/linux/system_tray.rs#L119>
        // Yes, even if you use `Icon::File` and tell Tauri that the icon is already
        // on disk.
        let handle = self.handle.clone();
        self.last_icon_set = icon.clone();
        self.run_on_main_thread(move || {
            let result = handle
                .set_icon(Some(icon_to_tauri_icon(&icon)))
                .context("Failed to set tray icon");

            logging::unwrap_or_debug!(result, "{}");
        });
    }

    fn run_on_main_thread(&self, f: impl FnOnce() + Send + 'static) {
        let result = self
            .app
            .run_on_main_thread(f)
            .context("Failed to run closure on main thread");

        logging::unwrap_or_debug!(result, "{}");
    }
}

fn update(handle: tauri::tray::TrayIcon, app: &AppHandle, menu: &Menu) -> Result<()> {
    let menu = build_app_state(app, menu).context("Failed to build tray menu")?;

    handle
        .set_tooltip(Some(TOOLTIP))
        .context("Failed to set tooltip")?;
    handle
        .set_menu(Some(menu))
        .context("Failed to set tray menu")?;

    Ok(())
}

fn build_app_state(app: &AppHandle, menu: &Menu) -> Result<TauriMenu> {
    build_menu(app, menu)
}

/// Builds this abstract `Menu` into a real menu that we can use in Tauri.
///
/// This recurses but we never go deeper than 3 or 4 levels so it's fine.
///
/// Note that Menus and Submenus are different in Tauri. Using a Submenu as a Menu
/// may crash on Windows. <https://github.com/tauri-apps/tauri/issues/11363>
fn build_menu(app: &AppHandle, that: &Menu) -> Result<TauriMenu> {
    let mut menu = tauri::menu::MenuBuilder::new(app);
    for entry in &that.entries {
        menu = menu.item(&*build_entry(app, entry)?);
    }
    Ok(menu.build()?)
}

fn build_submenu(app: &AppHandle, title: &str, that: &Menu) -> Result<TauriSubmenu> {
    let mut menu = tauri::menu::SubmenuBuilder::new(app, title);
    for entry in &that.entries {
        menu = menu.item(&*build_entry(app, entry)?);
    }
    Ok(menu.build()?)
}

fn build_entry(app: &AppHandle, entry: &Entry) -> Result<Box<IsMenuItem>> {
    let entry = match entry {
        Entry::Item(item) => build_item(app, item)?,
        Entry::Separator => Box::new(tauri::menu::PredefinedMenuItem::separator(app)?),
        Entry::Submenu { title, inner } => Box::new(build_submenu(app, title, inner)?),
    };
    Ok(entry)
}

fn build_item(app: &AppHandle, item: &Item) -> Result<Box<IsMenuItem>> {
    let item: Box<IsMenuItem> = if let Some(checked) = item.checked {
        let mut tauri_item = tauri::menu::CheckMenuItemBuilder::new(&item.title).checked(checked);
        if let Some(event) = &item.event {
            tauri_item = tauri_item.id(serde_json::to_string(event)?);
        } else {
            tauri_item = tauri_item.enabled(false);
        }
        Box::new(tauri_item.build(app)?)
    } else {
        let mut tauri_item = tauri::menu::MenuItemBuilder::new(&item.title);
        if let Some(event) = &item.event {
            tauri_item = tauri_item.id(serde_json::to_string(event)?);
        } else {
            tauri_item = tauri_item.enabled(false);
        }
        Box::new(tauri_item.build(app)?)
    };
    Ok(item)
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
            // Emojis may be causing an issue on some Ubuntu desktop environments.
            let status = match res.status() {
                ResourceStatus::Unknown => NO_ACTIVITY,
                ResourceStatus::Online => GATEWAY_CONNECTED,
                ResourceStatus::Offline => ALL_GATEWAYS_OFFLINE,
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
                    .copyable(GATEWAY_CONNECTED),
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
                    .copyable(ALL_GATEWAYS_OFFLINE),
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
                    .copyable(GATEWAY_CONNECTED),
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
                        .copyable(NO_ACTIVITY),
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
                    .copyable(NO_ACTIVITY),
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
                    .copyable(GATEWAY_CONNECTED),
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
                    .copyable(ALL_GATEWAYS_OFFLINE),
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
}

//! Demo mode that replaces the real `Controller`.
//!
//! Spawned in place of the real `Controller` when `firezone-gui-client debug
//! fake-controller` is run. Builds a hardcoded `AppState::SignedIn` with
//! sample resources and connected device peers, then listens for tray events:
//! favorite toggles re-render the menu live, and "Settings"/"About" open and
//! populate the UI with fake view-models so every page can be
//! eyeballed without a portal, auth, or tunnel. Other clicks (Sign Out,
//! Internet toggle, etc.) are no-ops in fake mode — there's no real backend.
//! `Event::Quit` breaks the loop so the demo can be torn down by the tray
//! menu, `--quit-after`, or `smoke-test`.
//!
//! Lives behind a debug subcommand (not behind `cfg(debug_assertions)`) so it
//! can be exercised against release builds when needed.
use std::collections::HashSet;

use anyhow::Result;
use connlib_model::{
    CidrResourceView, ClientId, ConnectedDeviceView, DnsResourceView, InternetResourceView,
    ResourceId, ResourceStatus, ResourceView, Site, SiteId,
};
use ip_network::IpNetwork;
use tokio::sync::mpsc;

use crate::controller::{ControllerRequest, GuiIntegration as _};
use crate::gui::TauriIntegration;
use crate::gui::system_tray::{AppState, ConnlibState, Event, SignedIn, Window};
use crate::logging::FileCount;
use crate::settings::{AdvancedSettings, GeneralSettings, MdmSettings};
use crate::view::SessionViewModel;

/// Drives a hardcoded fake `AppState::SignedIn` onto the tray and re-renders
/// in response to favorite-toggle clicks; opens and populates the UI
/// windows in response to "Settings"/"About" and the frontend's `UpdateState`.
pub(crate) async fn run(
    mut integration: TauriIntegration,
    mut ctlr_rx: mpsc::Receiver<ControllerRequest>,
) -> Result<()> {
    let mut favorites: HashSet<ResourceId> = HashSet::new();
    integration.set_tray_menu(build_state(&favorites));

    tracing::info!("fake-controller demo started; listening for tray events");
    while let Some(req) = ctlr_rx.recv().await {
        #[allow(
            clippy::wildcard_enum_match_arm,
            reason = "fake-controller only acts on favorite toggles, window-opening, UpdateState, and Quit; everything else is a no-op"
        )]
        match req {
            ControllerRequest::SystemTrayMenu(Event::AddFavorite(id)) => {
                favorites.insert(id);
                tracing::info!(%id, "favorited resource");
            }
            ControllerRequest::SystemTrayMenu(Event::RemoveFavorite(id)) => {
                favorites.remove(&id);
                tracing::info!(%id, "unfavorited resource");
            }
            ControllerRequest::SystemTrayMenu(Event::ShowWindow(window)) => {
                show_window(&integration, window);
                continue;
            }
            ControllerRequest::UpdateState => {
                if let Err(error) = push_fake_state(&integration) {
                    tracing::error!("fake-controller failed to push state: {error:#}");
                }
                continue;
            }
            ControllerRequest::SystemTrayMenu(Event::Quit) => {
                tracing::info!("Quit requested; shutting down fake-controller");
                break;
            }
            other => {
                tracing::debug!(%other, "fake-controller ignoring event");
                continue;
            }
        }
        integration.set_tray_menu(build_state(&favorites));
    }
    Ok(())
}

fn build_state(favorites: &HashSet<ResourceId>) -> AppState {
    AppState {
        connlib: ConnlibState::SignedIn(SignedIn {
            actor_name: "Demo User".into(),
            favorite_resources: favorites.clone(),
            resources: fake_resources(),
            connected_devices: fake_connected_devices(),
            internet_resource_enabled: Some(true),
        }),
        release: None,
        hide_admin_portal_menu_item: true,
        support_url: None,
    }
}

fn fake_resources() -> Vec<ResourceView> {
    let site = Site {
        id: SiteId::from_u128(0xDEAD_BEEF),
        name: "Demo Site".into(),
    };
    vec![
        // Internet resource sorts first in connlib (`ResourceView`'s `Ord`
        // impl in connlib_model::view), so the fixture mirrors that order.
        ResourceView::Internet(InternetResourceView {
            id: ResourceId::from_u128(0x103),
            name: "Internet Resource".into(),
            sites: vec![site.clone()],
            status: ResourceStatus::Online,
        }),
        ResourceView::Cidr(CidrResourceView {
            id: ResourceId::from_u128(0x101),
            address: "10.0.0.0/16"
                .parse::<IpNetwork>()
                .expect("hardcoded CIDR is valid"),
            name: "Office network".into(),
            address_description: Some("CIDR resource".into()),
            sites: vec![site.clone()],
            status: ResourceStatus::Online,
        }),
        ResourceView::Dns(DnsResourceView {
            id: ResourceId::from_u128(0x102),
            address: "gitlab.demo.example".into(),
            name: "Demo GitLab".into(),
            address_description: Some("https://gitlab.demo.example".into()),
            sites: vec![site.clone()],
            status: ResourceStatus::Online,
        }),
        ResourceView::Cidr(CidrResourceView {
            id: ResourceId::from_u128(0x104),
            address: "192.168.50.0/24"
                .parse::<IpNetwork>()
                .expect("hardcoded CIDR is valid"),
            name: "Lab network (offline)".into(),
            address_description: Some("Gateway offline".into()),
            sites: vec![site.clone()],
            status: ResourceStatus::Offline,
        }),
        ResourceView::Dns(DnsResourceView {
            id: ResourceId::from_u128(0x105),
            address: "wiki.demo.example".into(),
            name: "Demo Wiki (unknown)".into(),
            address_description: Some("Gateway state unknown".into()),
            sites: vec![site],
            status: ResourceStatus::Unknown,
        }),
    ]
}

fn fake_connected_devices() -> Vec<ConnectedDeviceView> {
    const POOL_PATTERNS: &[&[&str]] = &[
        &["Engineering Pool"],
        &["Engineering Pool", "QA Pool"],
        &[],
        &["QA Pool"],
        &["Sales Pool"],
    ];
    (0..22u128)
        .map(|i| ConnectedDeviceView {
            id: ClientId::from_u128(i + 1),
            pools: POOL_PATTERNS[(i as usize) % POOL_PATTERNS.len()]
                .iter()
                .map(|s| (*s).to_string())
                .collect(),
        })
        .collect()
}

/// Opens the requested window, mirroring the real `Controller`'s `ShowWindow`
/// handling but with fake settings fixtures.
fn show_window(integration: &TauriIntegration, window: Window) {
    let result = match window {
        Window::About => integration.show_about_page(),
        Window::Settings => integration.show_settings_page(
            fake_mdm_settings(),
            fake_general_settings(),
            AdvancedSettings::default(),
        ),
    };
    if let Err(error) = result {
        tracing::error!("fake-controller failed to open window: {error:#}");
    }
}

/// Emits the fake session, settings, and log count the frontend requests on
/// mount (`UpdateState`), so every page renders populated.
fn push_fake_state(integration: &TauriIntegration) -> Result<()> {
    integration.notify_session_changed(&fake_session())?;
    integration.notify_settings_changed(
        fake_mdm_settings(),
        fake_general_settings(),
        AdvancedSettings::default(),
    )?;
    integration.notify_logs_recounted(&fake_file_count())?;

    Ok(())
}

fn fake_session() -> SessionViewModel {
    SessionViewModel::SignedIn {
        account_slug: "demo-co".into(),
        actor_name: "Demo User".into(),
    }
}

fn fake_general_settings() -> GeneralSettings {
    GeneralSettings {
        start_minimized: true,
        start_on_login: Some(true),
        account_slug: Some("demo-co".into()),
        ..Default::default()
    }
}

/// Marks `account_slug` MDM-managed so the settings UI's locked-field rendering
/// (the `*_is_managed` flags) gets exercised in the demo.
fn fake_mdm_settings() -> MdmSettings {
    MdmSettings {
        account_slug: Some("demo-co".into()),
        ..Default::default()
    }
}

fn fake_file_count() -> FileCount {
    FileCount {
        files: 12,
        bytes: 3 * 1024 * 1024,
    }
}

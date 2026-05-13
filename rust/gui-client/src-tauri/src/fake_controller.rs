//! Demo mode that replaces the real `Controller`.
//!
//! Spawned in place of the real `Controller` when `firezone-gui-client debug
//! fake-controller` is run. Builds a hardcoded `AppState::SignedIn` with
//! sample resources and connected device peers, then listens for tray events
//! so favorite toggles re-render the menu live. Other clicks (Sign Out,
//! Internet toggle, etc.) are no-ops in fake mode — there's no real backend.
//! `Event::Quit` breaks the loop so the demo can be torn down by the tray
//! menu, `--quit-after`, or `smoke-test`.
//!
//! Lives behind a debug subcommand (not behind `cfg(debug_assertions)`) so it
//! can be exercised against release builds when needed.
use std::collections::HashSet;
use std::net::Ipv4Addr;

use anyhow::Result;
use connlib_model::{
    CidrResourceView, ClientId, ConnectedDeviceView, DnsResourceView, InternetResourceView,
    ResourceId, ResourceStatus, ResourceView, Site, SiteId,
};
use ip_network::IpNetwork;
use tokio::sync::mpsc;

use crate::controller::{ControllerRequest, GuiIntegration as _};
use crate::gui::TauriIntegration;
use crate::gui::system_tray::{AppState, ConnlibState, Event, SignedIn};

/// Drives a hardcoded fake `AppState::SignedIn` onto the tray and re-renders
/// in response to favorite-toggle clicks.
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
            reason = "fake-controller intentionally only acts on favorite toggles and Quit; everything else is a no-op"
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
        &["QA Pool"],
        &["Sales Pool"],
    ];
    (0..22u128)
        .map(|i| ConnectedDeviceView {
            id: ClientId::from_u128(i + 1),
            tunneled_ipv4: Some(Ipv4Addr::new(100, 96, 0, (i as u8) + 1)),
            pools: POOL_PATTERNS[(i as usize) % POOL_PATTERNS.len()]
                .iter()
                .map(|name| (*name).to_string())
                .collect(),
        })
        .collect()
}

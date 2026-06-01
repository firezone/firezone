//! Debug-only, in-process mock of the Tunnel service.
//!
//! When enabled (GUI `--mock-tunnel`), [`crate::ipc::connect`] for [`crate::ipc::SocketId::Tunnel`]
//! hands the real `Controller` an in-memory `tokio::io::duplex` channel instead of a real
//! socket, and [`serve`] plays the Tunnel service on the other end. It speaks the same
//! `ClientMsg`/`ServerMsg` protocol over the same JSON codec, but never touches connlib, the
//! portal, DNS or a TUN device — so the real controller / IPC / UI can be exercised offline in
//! a single unprivileged process (no root, no separate process, no socket file).

use crate::{
    ipc,
    service::{ClientMsg, ServerMsg},
    settings::{AdvancedSettings, MdmSettings},
};
use anyhow::Result;
use connlib_model::{
    CidrResourceView, ClientId, ConnectedDeviceView, DnsResourceView, InternetResourceView,
    ResourceId, ResourceList, ResourceStatus, ResourceView, Site, SiteId,
};
use futures::{SinkExt as _, StreamExt as _};
use ip_network::IpNetwork;
use std::{
    net::Ipv4Addr,
    sync::atomic::{AtomicBool, Ordering},
};
use tokio::io::DuplexStream;
use tokio_util::codec::{FramedRead, FramedWrite};

/// Whether the GUI should mock the Tunnel service in-process instead of connecting to the real
/// one. Set once at startup via `--mock-tunnel`. Debug builds only.
static ENABLED: AtomicBool = AtomicBool::new(false);

/// Set [`ENABLED`].
///
/// Call once at process startup, before the controller starts.
pub fn enable() {
    ENABLED.store(true, Ordering::Relaxed);
}

pub(crate) fn enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

/// Build the client end of an in-memory IPC channel and spawn the mock Tunnel service on the
/// other end.
///
/// Returns the boxed client stream; [`crate::ipc::connect`] frames it with the usual codec, so
/// the `Controller` is none the wiser.
pub(crate) fn spawn() -> ipc::ClientStream {
    let (client_io, server_io) = tokio::io::duplex(64 * 1024);

    tokio::spawn(async move {
        if let Err(e) = serve(server_io).await {
            tracing::debug!("Mock Tunnel service stopped: {e:#}");
        }
    });

    Box::new(client_io)
}

/// Plays the Tunnel service over `server_io`, responding to the controller's `ClientMsg`s with
/// the same `ServerMsg` sequence a real, successful session would produce — minus connlib, the
/// portal, DNS and the TUN device.
async fn serve(server_io: DuplexStream) -> Result<()> {
    let (rx, tx) = tokio::io::split(server_io);
    let mut ipc_rx = FramedRead::new(rx, ipc::Decoder::<ClientMsg>::default());
    let mut ipc_tx = FramedWrite::new(tx, ipc::Encoder::<ServerMsg>::default());

    // The controller blocks on `Hello` before doing anything else, so it must come first.
    ipc_tx
        .send(&ServerMsg::Hello {
            firezone_id: "00000000-0000-0000-0000-000000000000".to_owned(),
            advanced_settings: AdvancedSettings::default(),
            mdm_settings: MdmSettings::default(),
        })
        .await?;

    while let Some(msg) = ipc_rx.next().await {
        match msg? {
            ClientMsg::Connect { .. } => {
                ipc_tx.send(&ServerMsg::ConnectResult(Ok(()))).await?;
                ipc_tx
                    .send(&ServerMsg::OnUpdateResources(mock_resource_list()))
                    .await?;
            }
            ClientMsg::Disconnect => {
                ipc_tx.send(&ServerMsg::DisconnectedGracefully).await?;
            }
            ClientMsg::ClearLogs => {
                ipc_tx.send(&ServerMsg::ClearedLogs(Ok(()))).await?;
            }
            ClientMsg::ApplyAdvancedSettings(settings) => {
                ipc_tx
                    .send(&ServerMsg::AdvancedSettingsApplied(Ok(settings)))
                    .await?;
            }
            // The real service has no reply for these either.
            ClientMsg::SetInternetResourceState(_) | ClientMsg::StartTelemetry { .. } => {}
            ClientMsg::Panic => panic!("Explicit panic"),
        }
    }

    Ok(())
}

/// Canned resources + connected devices served in mock mode: 5 resources (Internet, two CIDR
/// incl. one Offline, two DNS incl. one Unknown) and 22 connected devices with rotating pool
/// membership, so every tray rendering branch is exercised.
fn mock_resource_list() -> ResourceList {
    let site = Site {
        id: SiteId::from_u128(0xDEAD_BEEF),
        name: "Demo Site".into(),
    };
    let resources = vec![
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
    ];

    const POOL_PATTERNS: &[&[&str]] = &[
        &["Engineering Pool"],
        &["Engineering Pool", "QA Pool"],
        &["QA Pool"],
        &["Sales Pool"],
    ];
    let connected_devices = (0..22u128)
        .map(|i| ConnectedDeviceView {
            id: ClientId::from_u128(i + 1),
            tunneled_ipv4: Ipv4Addr::new(100, 96, 0, (i as u8) + 1),
            pools: POOL_PATTERNS[(i as usize) % POOL_PATTERNS.len()]
                .iter()
                .map(|name| (*name).to_string())
                .collect(),
        })
        .collect();

    ResourceList {
        resources,
        connected_devices,
    }
}

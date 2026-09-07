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
use client_shared::ConnectedAs;
use connlib_model::{
    CidrResourceView, ConnectedDeviceView, DnsResourceView, InternetResourceView, ResourceList,
    ResourceStatus, ResourceView, Site,
};
use futures::{SinkExt as _, StreamExt as _};
use std::{
    fmt::Debug,
    str::FromStr,
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
            x509_certificate: Ok(None),
        })
        .await?;

    while let Some(msg) = ipc_rx.next().await {
        match msg? {
            ClientMsg::Connect { .. } => {
                ipc_tx.send(&ServerMsg::ConnectResult(Ok(()))).await?;
                ipc_tx
                    .send(&ServerMsg::ConnectedToPortal(ConnectedAs {
                        account_slug: "example-corp".to_owned(),
                        actor_name: "Jane Doe".to_owned(),
                    }))
                    .await?;
                ipc_tx
                    .send(&ServerMsg::OnUpdateResources(mock_resource_list()))
                    .await?;
            }
            ClientMsg::ReloadX509 => {
                ipc_tx.send(&ServerMsg::X509Certificate(Ok(None))).await?;
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

/// Canned resources + connected devices served in mock mode.
///
/// Mirrors the Apple client's "connected" mock scenario
/// (`swift/apple/FirezoneKit/Sources/FirezoneKit/Mocks/Scenarios/connected.json`) so that
/// screenshots of every client show the same data.
fn mock_resource_list() -> ResourceList {
    let internet = site("1a4f0f4e-8f3f-4a2e-9b6d-3c5e7a1b2d40", "Internet");
    let sydney = site("917e9354-26b3-4704-867c-f84c8688d269", "Sydney Office");
    let production = site("003a5a77-6813-4c21-bd91-94f39efb04c0", "Production Cloud");
    let lab = site("0a93828b-6145-409d-ab6e-92a481ed7b1f", "Hardware Lab");

    let resources = vec![
        ResourceView::Internet(InternetResourceView {
            id: parse("425233f2-a1cb-4b7d-84f3-850367fa122a"),
            name: "Internet Resource".into(),
            sites: vec![internet],
            status: ResourceStatus::Online,
        }),
        ResourceView::Dns(DnsResourceView {
            id: parse("0854dca1-2c5b-468a-be85-0eec2f02a211"),
            address: "wiki.example.com".into(),
            name: "Engineering wiki".into(),
            address_description: Some("https://wiki.example.com".into()),
            sites: vec![sydney.clone()],
            status: ResourceStatus::Online,
        }),
        ResourceView::Dns(DnsResourceView {
            id: parse("92da16a4-0eb2-45c2-b882-8573aad73921"),
            address: "git.example.com".into(),
            name: "Git server".into(),
            address_description: None,
            sites: vec![production.clone()],
            status: ResourceStatus::Unknown,
        }),
        ResourceView::Dns(DnsResourceView {
            id: parse("ed3778b9-dd41-4312-b616-028b0bbaff1c"),
            address: "*.svc.example.com".into(),
            name: "Internal services".into(),
            address_description: None,
            sites: vec![production.clone()],
            status: ResourceStatus::Unknown,
        }),
        ResourceView::Cidr(CidrResourceView {
            id: parse("be575d17-b0b3-40c9-ac34-e1ec3064d75a"),
            address: parse("192.0.2.0/24"),
            name: "Office network".into(),
            address_description: None,
            sites: vec![sydney],
            status: ResourceStatus::Online,
        }),
        ResourceView::Cidr(CidrResourceView {
            id: parse("8900accd-e39d-4705-ac7c-2189c59b4a1c"),
            address: parse("198.51.100.0/24"),
            name: "Production VPC".into(),
            address_description: None,
            sites: vec![production],
            status: ResourceStatus::Unknown,
        }),
        ResourceView::Cidr(CidrResourceView {
            id: parse("6b15c815-cefc-4128-8ab0-d9d6a526bbc7"),
            address: parse("203.0.113.0/24"),
            name: "Lab test bench".into(),
            address_description: None,
            sites: vec![lab],
            status: ResourceStatus::Offline,
        }),
    ];

    const LAB: &str = "Lab hardware";
    const STORAGE: &str = "Shared storage";
    const BUILD: &str = "Build farm";

    #[rustfmt::skip]
    let connected_devices = [
        ("a21c9663-4d0e-4f4a-a8fa-48790b1e5cef", "bench-controller-01", "100.64.3.18", "fd00:2021:1111::12", &[LAB, STORAGE][..]),
        ("47e9e79b-e4eb-4444-af14-ec24c6a2afc2", "build-runner-02", "100.64.7.41", "fd00:2021:1111::29", &[BUILD]),
        ("db8221d1-0277-4f05-b0a8-22b32a5a9a46", "build-runner-03", "100.64.7.42", "fd00:2021:1111::2a", &[BUILD]),
        ("f0442658-4fca-4f53-9323-161fa389a659", "build-runner-04", "100.64.7.43", "fd00:2021:1111::2b", &[BUILD]),
        ("7392a499-c8f0-4f24-aba0-2f6a00fe3bc0", "build-runner-05", "100.64.7.44", "fd00:2021:1111::2c", &[BUILD]),
        ("62f5c6e4-46f5-418a-82ff-7d0e612b29a6", "build-runner-06", "100.64.7.45", "fd00:2021:1111::2d", &[BUILD]),
        ("c951f7eb-6fa7-428b-aecf-10b654ecccf7", "design-nas", "100.64.11.5", "fd00:2021:1111::1f5", &[STORAGE]),
        ("4a6f80e6-5322-4202-a1ac-1e897aa826a5", "lab-probe-01", "100.64.19.87", "fd00:2021:1111::3c2", &[LAB]),
        ("99fd7f50-02aa-4ebd-aac3-b9b914c4aebb", "lab-probe-02", "100.64.19.88", "fd00:2021:1111::3c3", &[LAB]),
        ("3683defa-c0c5-453b-8d06-22fe7f422f05", "media-encoder-01", "100.64.11.6", "fd00:2021:1111::1f6", &[STORAGE]),
        ("cef0ac7a-c103-4e1a-b937-485d6fc8f00c", "render-node-01", "100.64.7.46", "fd00:2021:1111::2e", &[BUILD, STORAGE]),
        ("ef39322d-65e2-4dea-af50-6fd4c61a72a6", "sensor-hub-01", "100.64.19.89", "fd00:2021:1111::3c4", &[LAB]),
        ("487f8ebe-4b83-4239-8cb9-40d298fe8561", "sensor-hub-02", "100.64.19.90", "fd00:2021:1111::3c5", &[LAB]),
        ("e8dc5d0d-93ac-4e1b-9532-866dda67ce5b", "vision-rig-01", "100.64.19.86", "fd00:2021:1111::3c1", &[LAB]),
        ("46b198aa-fcf6-4640-bb23-b20879c52958", "vision-rig-02", "100.64.19.91", "fd00:2021:1111::3c6", &[LAB]),
    ]
    .into_iter()
    .map(
        |(id, name, tun_ipv4, tun_ipv6, pools)| ConnectedDeviceView {
            id: parse(id),
            name: name.to_owned(),
            tun_ipv4: parse(tun_ipv4),
            tun_ipv6: parse(tun_ipv6),
            pools: pools.iter().map(|pool| (*pool).to_owned()).collect(),
        },
    )
    .collect();

    ResourceList {
        resources,
        connected_devices,
    }
}

fn site(id: &str, name: &str) -> Site {
    Site {
        id: parse(id),
        name: name.to_owned(),
    }
}

/// Parses a hardcoded literal.
///
/// # Panics
///
/// If the literal does not parse, which is a bug in the fixture.
fn parse<T>(literal: &str) -> T
where
    T: FromStr,
    T::Err: Debug,
{
    literal
        .parse()
        .expect("hardcoded mock literal should be valid")
}

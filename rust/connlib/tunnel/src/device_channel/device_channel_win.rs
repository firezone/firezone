use crate::device_channel::Packet;
use crate::Device;
use crate::DnsFallbackStrategy;
use connlib_shared::{messages::Interface, Callbacks, Result};
use ip_network::IpNetwork;
use std::{
    str::FromStr,
    sync::Arc,
    task::{ready, Context, Poll},
};
use tokio::sync::mpsc;

// TODO: Make sure this gets dropped gracefully on disconnect
pub(crate) struct IfaceConfig {
    _adapter: Arc<wintun::Adapter>,
    _recv_thread: std::thread::JoinHandle<()>,
    _session: Arc<wintun::Session>,
}

pub(crate) struct DeviceIo {
    // TODO: Get rid of this mutex. It's a hack to deal with `poll_read` taking a `&self` instead of `&mut self`
    packet_rx: std::sync::Mutex<mpsc::Receiver<Vec<u8>>>,
    session: Arc<wintun::Session>,
}

impl DeviceIo {
    pub fn poll_read(&self, out: &mut [u8], cx: &mut Context<'_>) -> Poll<std::io::Result<usize>> {
        let mut packet_rx = self.packet_rx.try_lock().unwrap();

        let pkt = ready!(packet_rx.poll_recv(cx));

        match pkt {
            Some(pkt) => {
                out[0..pkt.len()].copy_from_slice(&pkt);
                tracing::debug!("tx {} B, {}", pkt.len(), explain_packet(&pkt));
                Poll::Ready(Ok(pkt.len()))
            }
            None => {
                tracing::error!("error receiving packet from mpsc channel");
                Poll::Ready(Err(std::io::ErrorKind::Other.into()))
            }
        }
    }

    pub fn write(&self, packet: Packet<'_>) -> std::io::Result<usize> {
        // All outgoing packets are successfully written to the void
        let bytes = match packet {
            Packet::Ipv4(msg) => msg,
            Packet::Ipv6(msg) => msg,
        };
        tracing::debug!("rx {} B, {}", bytes.len(), explain_packet(&bytes));
        let mut pkt = self
            .session
            .allocate_send_packet(bytes.len().try_into().unwrap())
            .unwrap();
        pkt.bytes_mut().copy_from_slice(&bytes);
        self.session.send_packet(pkt);
        Ok(bytes.len())
    }
}

const BOGUS_MTU: usize = 1_500;

impl IfaceConfig {
    pub(crate) fn mtu(&self) -> usize {
        BOGUS_MTU
    }

    pub(crate) async fn refresh_mtu(&self) -> Result<usize> {
        Ok(BOGUS_MTU)
    }

    pub(crate) async fn add_route(
        &self,
        route: IpNetwork,
        _: &impl Callbacks,
    ) -> Result<Option<Device>> {
        tracing::debug!("add_route {route}");

        Ok(None)
    }
}

const TUNNEL_UUID: &str = "e9245bc1-b8c1-44ca-ab1d-c6aad4f13b9c";

pub(crate) async fn create_iface(
    config: &Interface,
    _: &impl Callbacks,
    _: DnsFallbackStrategy,
) -> Result<Device> {
    tracing::debug!("create_iface {}", config.ipv4);

    let wintun = unsafe { wintun::load_from_path("./wintun.dll") }?;
    let uuid = uuid::Uuid::from_str(TUNNEL_UUID)?;
    let adapter =
        match wintun::Adapter::create(&wintun, "Firezone", "Firezone VPN", Some(uuid.as_u128())) {
            Ok(x) => x,
            Err(e) => {
                tracing::error!(
                    "wintun::Adapter::create failed, probably need admin powers: {}",
                    e
                );
                return Err(e.into());
            }
        };

    adapter.set_address(config.ipv4)?;

    let session = Arc::new(adapter.start_session(wintun::MAX_RING_CAPACITY)?);

    let (packet_tx, packet_rx) = mpsc::channel(5);

    let recv_thread = start_recv_thread(packet_tx, Arc::clone(&session));
    let packet_rx = std::sync::Mutex::new(packet_rx);

    Ok(Device {
        config: IfaceConfig {
            _adapter: adapter,
            _recv_thread: recv_thread,
            _session: Arc::clone(&session),
        },
        io: DeviceIo {
            packet_rx,
            session: Arc::clone(&session),
        },
    })
}

fn start_recv_thread(
    packet_tx: mpsc::Sender<Vec<u8>>,
    session: Arc<wintun::Session>,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        while let Ok(pkt) = session.receive_blocking() {
            // TODO: Don't allocate here if we can help it
            packet_tx.blocking_send(pkt.bytes().to_vec()).unwrap();
        }
        tracing::debug!("recv_task exiting gracefully");
    })
}

// TODO: Remove before prod
fn explain_packet(pkt: &[u8]) -> String {
    let proto = match pkt[9] {
        1 => "ICMP",
        6 => "TCP",
        17 => "UDP",
        132 => "SCTP",
        _ => "Unknown",
    };

    let src = &pkt[12..16];
    let dst = &pkt[16..20];

    format!("proto {proto} src {src:?} dst {dst:?}")
}

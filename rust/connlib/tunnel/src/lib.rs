//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.
use crate::device_channel::Device;
use boringtun::x25519::{PublicKey, StaticSecret};
use connlib_shared::messages::SecretKey;
use connlib_shared::Result;
use connlib_shared::{CallbackErrorFacade, Callbacks};
use either::Either;
use futures_util::task::AtomicWaker;
use ip_network::IpNetwork;
use parking_lot::Mutex;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::task::{Context, Poll};
use std::{fmt, io};
use tokio::io::ReadBuf;
use tokio::net::UdpSocket;

pub use control_protocol::Request;

mod bounded_queue;
mod control_protocol;
mod device_channel;
mod dns;
mod index;
mod ip_packet;

pub mod client;
mod connection;
pub mod gateway;
mod rate_limiter;
mod shared_utils; // TODO: Not good, get rid of this somehow :)

const MAX_UDP_SIZE: usize = (1 << 16) - 1;
const DNS_QUERIES_QUEUE_SIZE: usize = 100;

// Note: the windows dns fallback strategy might change when implementing, however we prefer
// splitdns to trying to obtain the default server.
#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "linux",
    target_os = "windows"
))]
impl Default for DnsFallbackStrategy {
    fn default() -> DnsFallbackStrategy {
        Self::SystemResolver
    }
}

#[cfg(target_os = "android")]
impl Default for DnsFallbackStrategy {
    fn default() -> DnsFallbackStrategy {
        Self::UpstreamResolver
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DnsFallbackStrategy {
    UpstreamResolver,
    SystemResolver,
}

impl DnsFallbackStrategy {
    fn is_upstream(&self) -> bool {
        self == &DnsFallbackStrategy::UpstreamResolver
    }
}

impl fmt::Display for DnsFallbackStrategy {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DnsFallbackStrategy::UpstreamResolver => write!(f, "upstream_resolver"),
            DnsFallbackStrategy::SystemResolver => write!(f, "system_resolver"),
        }
    }
}

pub(crate) fn get_v4(ip: IpAddr) -> Option<Ipv4Addr> {
    match ip {
        IpAddr::V4(v4) => Some(v4),
        IpAddr::V6(_) => None,
    }
}

pub(crate) fn get_v6(ip: IpAddr) -> Option<Ipv6Addr> {
    match ip {
        IpAddr::V4(_) => None,
        IpAddr::V6(v6) => Some(v6),
    }
}

/// Represent's the tunnel actual peer's config
/// Obtained from connlib_shared's Peert
#[derive(Clone)]
pub struct PeerConfig {
    pub(crate) public_key: PublicKey,
    pub(crate) ips: Vec<IpNetwork>,
    pub(crate) preshared_key: SecretKey,
}

impl From<connlib_shared::messages::Peer> for PeerConfig {
    fn from(value: connlib_shared::messages::Peer) -> Self {
        Self {
            public_key: value.public_key.0.into(),
            ips: vec![value.ipv4.into(), value.ipv6.into()],
            preshared_key: value.preshared_key,
        }
    }
}

/// Tunnel is a wireguard state machine that uses webrtc's ICE channels instead of UDP sockets to communicate between peers.
pub struct Tunnel<CB: Callbacks, TRoleState> {
    callbacks: CallbackErrorFacade<CB>,

    /// State that differs per role, i.e. clients vs gateways.
    role_state: Mutex<TRoleState>,

    ip4_socket: UdpSocket,
    ip6_socket: UdpSocket,

    device: Mutex<Option<Device>>,
    read_buf: Mutex<Box<[u8; MAX_UDP_SIZE]>>,
    no_device_waker: AtomicWaker,
}

impl<CB> Tunnel<CB, client::State>
where
    CB: Callbacks + 'static,
{
    pub fn client(private_key: StaticSecret, callbacks: CB) -> Result<Self> {
        Self::new(client::State::new(private_key), callbacks)
    }

    pub async fn next_event(&self) -> Result<client::Event> {
        std::future::poll_fn(|cx| self.poll_next_event(cx)).await
    }

    fn poll_next_event(&self, cx: &mut Context<'_>) -> Poll<Result<client::Event>> {
        let mut role_state = self.role_state.lock();
        let mut device_guard = self.device.lock();
        let mut read_guard = self.read_buf.lock();
        let mut read_buf = ReadBuf::new(read_guard.as_mut_slice());

        loop {
            read_buf.clear();

            let Some(device) = device_guard.as_mut() else {
                self.no_device_waker.register(cx.waker());
                return Poll::Pending;
            };

            match device.poll_read(read_buf.initialized_mut(), cx)? {
                Poll::Ready(Some(packet)) => match role_state.handle_device_input(packet) {
                    Some(Either::Left(packet)) => {
                        device.write(packet).expect("TODO");
                        continue;
                    }
                    Some(Either::Right((dest, packet))) => {
                        self.try_send_to(packet, dest)?;
                        continue;
                    }
                    None => {}
                },
                Poll::Ready(None) => continue,
                Poll::Pending => {}
            }

            if let Poll::Ready(from) = self.ip4_socket.poll_recv_from(cx, &mut read_buf)? {
                let Some(packet) = role_state.handle_socket_input(from, read_buf.filled()) else {
                    continue;
                };

                device.write(packet)?;

                continue;
            }

            if let Poll::Ready(from) = self.ip6_socket.poll_recv_from(cx, &mut read_buf)? {
                let Some(packet) = role_state.handle_socket_input(from, read_buf.filled()) else {
                    continue;
                };

                device.write(packet)?;

                continue;
            }

            match role_state.poll_next_event(cx) {
                Poll::Ready(Either::Left(event)) => {
                    return Poll::Ready(Ok(event));
                }
                Poll::Ready(Either::Right(transmit)) => {
                    self.try_send_to(&transmit.payload, transmit.dst)?;
                    continue;
                }
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }
}

impl<CB> Tunnel<CB, gateway::State>
where
    CB: Callbacks + 'static,
{
    pub fn gateway(tunnel_private_key: StaticSecret, callbacks: CB) -> Result<Self> {
        Self::new(gateway::State::new(tunnel_private_key), callbacks)
    }

    // TODO: De-duplicate with client.
    pub fn poll_next_event(&self, cx: &mut Context<'_>) -> Poll<Result<gateway::Event>> {
        let mut role_state = self.role_state.lock();
        let mut device_guard = self.device.lock();
        let mut read_guard = self.read_buf.lock();
        let mut read_buf = ReadBuf::new(read_guard.as_mut_slice());

        loop {
            read_buf.clear();

            let Some(device) = device_guard.as_mut() else {
                self.no_device_waker.register(cx.waker());
                return Poll::Pending;
            };

            match device.poll_read(read_buf.initialized_mut(), cx)? {
                Poll::Ready(Some(packet)) => match role_state.handle_device_input(packet) {
                    Some(Either::Left(packet)) => {
                        device.write(packet).expect("TODO");
                        continue;
                    }
                    Some(Either::Right((dest, packet))) => {
                        self.try_send_to(packet, dest)?;
                        continue;
                    }
                    None => {}
                },
                Poll::Ready(None) => continue,
                Poll::Pending => {}
            }

            if let Poll::Ready(from) = self.ip4_socket.poll_recv_from(cx, &mut read_buf)? {
                let Some(packet) = role_state.handle_socket_input(from, read_buf.filled()) else {
                    continue;
                };

                device.write(packet)?;

                continue;
            }

            if let Poll::Ready(from) = self.ip6_socket.poll_recv_from(cx, &mut read_buf)? {
                let Some(packet) = role_state.handle_socket_input(from, read_buf.filled()) else {
                    continue;
                };

                device.write(packet)?;

                continue;
            }

            match role_state.poll_next_event(cx) {
                Poll::Ready(Either::Left(event)) => {
                    return Poll::Ready(Ok(event));
                }
                Poll::Ready(Either::Right(transmit)) => {
                    self.try_send_to(&transmit.payload, transmit.dst)?;
                    continue;
                }
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }
}

impl<CB, TRoleState> Tunnel<CB, TRoleState>
where
    CB: Callbacks + 'static,
{
    /// Creates a new tunnel.
    #[tracing::instrument(level = "trace", skip(role_state, callbacks))]
    pub fn new(role_state: TRoleState, callbacks: CB) -> Result<Self> {
        Ok(Self {
            device: Default::default(),
            read_buf: Mutex::new(Box::new([0u8; MAX_UDP_SIZE])),
            callbacks: CallbackErrorFacade(callbacks),
            role_state: Mutex::new(role_state),
            ip4_socket: UdpSocket::from_std(make_wildcard_socket(socket2::Domain::IPV4, 9999)?)?,
            ip6_socket: UdpSocket::from_std(make_wildcard_socket(socket2::Domain::IPV6, 9999)?)?,
            no_device_waker: Default::default(),
        })
    }

    pub fn callbacks(&self) -> &CallbackErrorFacade<CB> {
        &self.callbacks
    }

    #[tracing::instrument(level = "trace", skip(self, packet), fields(num_bytes = %packet.len()))]
    fn try_send_to(&self, packet: &[u8], dest: SocketAddr) -> io::Result<()> {
        let socket = match dest {
            SocketAddr::V4(_) => &self.ip4_socket,
            SocketAddr::V6(_) => &self.ip6_socket,
        };

        let sent = match socket.try_send_to(packet, dest) {
            Ok(sent) => sent,
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                tracing::debug!("Socket busy, dropping packet");
                return Ok(());
            }
            Err(e) => return Err(e),
        };

        tracing::debug!("Sent packet");

        debug_assert_eq!(sent, packet.len());

        Ok(())
    }
}

pub(crate) struct Transmit {
    pub dst: SocketAddr,
    pub payload: Vec<u8>,
}

impl fmt::Debug for Transmit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Transmit")
            .field("dst", &self.dst)
            .field("payload_len", &self.payload.len())
            .finish()
    }
}

impl From<firezone_relay::client::Transmit> for Transmit {
    fn from(value: firezone_relay::client::Transmit) -> Self {
        Self {
            dst: value.dst,
            payload: value.payload,
        }
    }
}

/// Creates an [std::net::UdpSocket] via the [socket2] library that is configured for our needs.
///
/// Most importantly, this sets the `IPV6_V6ONLY` flag to ensure we disallow IP4-mapped IPv6 addresses and can bind to IP4 and IP6 addresses on the same port.
fn make_wildcard_socket(domain: socket2::Domain, port: u16) -> io::Result<std::net::UdpSocket> {
    use socket2::*;

    let address = match domain {
        Domain::IPV4 => IpAddr::from(Ipv4Addr::UNSPECIFIED),
        Domain::IPV6 => IpAddr::from(Ipv6Addr::UNSPECIFIED),
        _ => return Err(io::ErrorKind::InvalidInput.into()),
    };

    let socket = Socket::new(domain, Type::DGRAM, Some(Protocol::UDP))?;
    if domain == Domain::IPV6 {
        socket.set_only_v6(true)?;
    }

    socket.set_nonblocking(true)?;
    socket.bind(&SockAddr::from(SocketAddr::new(address, port)))?;

    Ok(socket.into())
}

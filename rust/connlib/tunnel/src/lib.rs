//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.
use crate::ip_packet::MutableIpPacket;
use arc_swap::ArcSwapOption;
use boringtun::{
    noise::rate_limiter::RateLimiter,
    x25519::{PublicKey, StaticSecret},
};
use bytes::Bytes;
use connlib_shared::error::ConnlibError;
use connlib_shared::messages::SecretKey;
use connlib_shared::Result;
use connlib_shared::{messages::Key, CallbackErrorFacade, Callbacks, Error};
use futures_util::task::AtomicWaker;
use hickory_resolver::proto::rr::RecordType;
use index::IndexLfsr;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use ip_packet::IpPacket;
use parking_lot::Mutex;
use peer::{PacketTransform, Peer};
use pnet_packet::Packet;
use std::collections::VecDeque;
use std::hash::Hash;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::task::{ready, Context, Poll};
use std::{collections::HashMap, fmt, net::IpAddr, sync::Arc, time::Duration};
use tokio::time::Interval;
use tokio::time::MissedTickBehavior;
use webrtc::{
    api::{
        interceptor_registry::register_default_interceptors, media_engine::MediaEngine,
        setting_engine::SettingEngine, APIBuilder, API,
    },
    ice_transport::RTCIceTransport,
    interceptor::registry::Registry,
};

use crate::device_channel::Device;
pub use control_protocol::Request;

mod bounded_queue;
mod control_protocol;
mod device_channel;
mod dns;
mod index;
mod ip_packet;
mod peer;
mod peer_handler;

pub mod client;
pub mod gateway;

const MAX_UDP_SIZE: usize = (1 << 16) - 1;
const DNS_QUERIES_QUEUE_SIZE: usize = 100;
// Why do we need such big channel? I have not the slightless idea
// but if we make it smaller things get quite slower.
// Since eventually we will have a UDP socket with try_send
// I don't think there's a point to having this.
const PEER_QUEUE_SIZE: usize = 1_000;

/// For how long we will attempt to gather ICE candidates before aborting.
///
/// Chosen arbitrarily.
/// Very likely, the actual WebRTC connection will timeout before this.
/// This timeout is just here to eventually clean-up tasks if they are somehow broken.
const ICE_GATHERING_TIMEOUT_SECONDS: u64 = 5 * 60;

/// How many concurrent ICE gathering attempts we are allow.
///
/// Chosen arbitrarily,
const MAX_CONCURRENT_ICE_GATHERING: usize = 100;

// Note: Taken from boringtun
const HANDSHAKE_RATE_LIMIT: u64 = 100;

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
/// Obtained from connlib_shared's Peer
#[derive(Clone)]
pub struct PeerConfig {
    pub(crate) persistent_keepalive: Option<u16>,
    pub(crate) public_key: PublicKey,
    pub(crate) ips: Vec<IpNetwork>,
    pub(crate) preshared_key: SecretKey,
}

impl From<connlib_shared::messages::Peer> for PeerConfig {
    fn from(value: connlib_shared::messages::Peer) -> Self {
        Self {
            persistent_keepalive: value.persistent_keepalive,
            public_key: value.public_key.0.into(),
            ips: vec![value.ipv4.into(), value.ipv6.into()],
            preshared_key: value.preshared_key,
        }
    }
}

/// Tunnel is a wireguard state machine that uses webrtc's ICE channels instead of UDP sockets to communicate between peers.
pub struct Tunnel<CB: Callbacks, TRoleState: RoleState> {
    next_index: Mutex<IndexLfsr>,
    rate_limiter: Arc<RateLimiter>,
    private_key: StaticSecret,
    public_key: PublicKey,
    peer_connections: Mutex<HashMap<TRoleState::Id, Arc<RTCIceTransport>>>,
    webrtc_api: API,
    callbacks: CallbackErrorFacade<CB>,

    /// State that differs per role, i.e. clients vs gateways.
    role_state: Mutex<TRoleState>,

    rate_limit_reset_interval: Mutex<Interval>,
    peer_refresh_interval: Mutex<Interval>,
    mtu_refresh_interval: Mutex<Interval>,

    peers_to_stop: Mutex<VecDeque<TRoleState::Id>>,

    device: Arc<ArcSwapOption<Device>>,
    read_buf: Mutex<Box<[u8; MAX_UDP_SIZE]>>,
    write_buf: Mutex<Box<[u8; MAX_UDP_SIZE]>>,
    no_device_waker: AtomicWaker,
}

impl<CB> Tunnel<CB, client::State>
where
    CB: Callbacks + 'static,
{
    pub async fn next_event(&self) -> Result<client::Event> {
        std::future::poll_fn(|cx| loop {
            {
                let guard = self.device.load();

                if let Some(device) = guard.as_ref() {
                    match self.poll_device(device, cx) {
                        Poll::Ready(Ok(Some(event))) => return Poll::Ready(Ok(event)),
                        Poll::Ready(Ok(None)) => {
                            tracing::info!("Device stopped");
                            self.device.store(None);
                            continue;
                        }
                        Poll::Ready(Err(e)) => {
                            self.device.store(None); // Ensure we don't poll a failed device again.
                            return Poll::Ready(Err(e));
                        }
                        Poll::Pending => {}
                    }
                } else {
                    self.no_device_waker.register(cx.waker());
                }
            }

            match self.poll_next_event_common(cx) {
                Poll::Ready(event) => return Poll::Ready(Ok(event)),
                Poll::Pending => {}
            }

            return Poll::Pending;
        })
        .await
    }

    pub(crate) fn poll_device(
        &self,
        device: &Device,
        cx: &mut Context<'_>,
    ) -> Poll<Result<Option<client::Event>>> {
        loop {
            let mut role_state = self.role_state.lock();

            let mut read_guard = self.read_buf.lock();
            let mut write_guard = self.write_buf.lock();
            let read_buf = read_guard.as_mut_slice();
            let write_buf = write_guard.as_mut_slice();

            let Some(packet) = ready!(device.poll_read(read_buf, cx))? else {
                return Poll::Ready(Ok(None));
            };

            tracing::trace!(target: "wire", action = "read", from = "device", dest = %packet.destination());

            let dns_strategy = role_state.dns_strategy;
            let packet = match role_state.handle_dns(packet, dns_strategy) {
                Ok(Some(response)) => {
                    device.write(response)?;
                    continue;
                }
                Ok(None) => continue,
                Err(non_dns_packet) => non_dns_packet,
            };

            let dest = packet.destination();

            let Some(peer) = peer_by_ip(&role_state.peers_by_ip, dest) else {
                role_state.on_connection_intent_ip(dest);
                continue;
            };

            self.encapsulate(write_buf, packet, peer);

            continue;
        }
    }
}

impl<CB> Tunnel<CB, gateway::State>
where
    CB: Callbacks + 'static,
{
    pub fn poll_next_event(&self, cx: &mut Context<'_>) -> Poll<Result<gateway::Event>> {
        let mut read_guard = self.read_buf.lock();
        let mut write_guard = self.write_buf.lock();

        let read_buf = read_guard.as_mut_slice();
        let write_buf = write_guard.as_mut_slice();

        loop {
            {
                let device = self.device.load();

                match device.as_ref().map(|d| d.poll_read(read_buf, cx)) {
                    Some(Poll::Ready(Ok(Some(packet)))) => {
                        let dest = packet.destination();

                        let role_state = self.role_state.lock();
                        let Some(peer) = peer_by_ip(&role_state.peers_by_ip, dest) else {
                            continue;
                        };

                        self.encapsulate(write_buf, packet, peer);

                        continue;
                    }
                    Some(Poll::Ready(Ok(None))) => {
                        tracing::info!("Device stopped");
                        self.device.store(None);
                    }
                    Some(Poll::Ready(Err(e))) => return Poll::Ready(Err(ConnlibError::Io(e))),
                    Some(Poll::Pending) => {
                        // device not ready for reading, moving on ..
                    }
                    None => {
                        self.no_device_waker.register(cx.waker());
                    }
                }
            }

            match self.poll_next_event_common(cx) {
                Poll::Ready(e) => return Poll::Ready(Ok(e)),
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }
}

pub struct ConnectedPeer<TId, TTransform> {
    inner: Arc<Peer<TId, TTransform>>,
    channel: tokio::sync::mpsc::Sender<Bytes>,
}

impl<TId, TTranform> Clone for ConnectedPeer<TId, TTranform> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
            channel: self.channel.clone(),
        }
    }
}

#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct TunnelStats<TId> {
    public_key: String,
    peer_connections: Vec<TId>,
}

impl<CB, TRoleState> Tunnel<CB, TRoleState>
where
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    pub fn stats(&self) -> TunnelStats<TRoleState::Id> {
        let peer_connections = self.peer_connections.lock().keys().cloned().collect();

        TunnelStats {
            public_key: Key::from(self.public_key).to_string(),
            peer_connections,
        }
    }

    fn poll_next_event_common(&self, cx: &mut Context<'_>) -> Poll<TRoleState::Event> {
        loop {
            if let Some(conn_id) = self.peers_to_stop.lock().pop_front() {
                self.role_state.lock().remove_peers(conn_id);

                if let Some(conn) = self.peer_connections.lock().remove(&conn_id) {
                    tokio::spawn({
                        let callbacks = self.callbacks.clone();
                        async move {
                            if let Err(e) = conn.stop().await {
                                tracing::warn!(%conn_id, error = ?e, "Can't close peer");
                                let _ = callbacks.on_error(&e.into());
                            }
                        }
                    });
                }
            }

            if self
                .rate_limit_reset_interval
                .lock()
                .poll_tick(cx)
                .is_ready()
            {
                self.rate_limiter.reset_count();
                continue;
            }

            if self.peer_refresh_interval.lock().poll_tick(cx).is_ready() {
                let mut peers_to_stop = self.role_state.lock().refresh_peers();
                self.peers_to_stop.lock().append(&mut peers_to_stop);

                continue;
            }

            if self.mtu_refresh_interval.lock().poll_tick(cx).is_ready() {
                let Some(device) = self.device.load().clone() else {
                    tracing::debug!("Device temporarily not available");
                    continue;
                };

                if let Err(e) = device.refresh_mtu() {
                    tracing::error!(error = ?e, "refresh_mtu");
                    let _ = self.callbacks.on_error(&e);
                }
            }

            if let Poll::Ready(event) = self.role_state.lock().poll_next_event(cx) {
                return Poll::Ready(event);
            }

            return Poll::Pending;
        }
    }

    fn encapsulate<TTransform: PacketTransform>(
        &self,
        write_buf: &mut [u8],
        packet: MutableIpPacket,
        peer: &ConnectedPeer<TRoleState::Id, TTransform>,
    ) {
        let peer_id = peer.inner.conn_id;

        match peer.inner.encapsulate(packet, write_buf) {
            Ok(None) => {}
            Ok(Some(b)) => {
                tracing::trace!(target: "wire", action = "writing", to = "peer");
                if peer.channel.try_send(b).is_err() {
                    tracing::warn!(target: "wire", action = "dropped", to = "peer");
                }
            }
            Err(e) => {
                tracing::error!(err = ?e, "failed to handle packet {e:#}");

                if e.is_fatal_connection_error() {
                    self.peers_to_stop.lock().push_back(peer_id);
                }
            }
        };
    }
}

pub(crate) fn peer_by_ip<Id, TTransform>(
    peers_by_ip: &IpNetworkTable<ConnectedPeer<Id, TTransform>>,
    ip: IpAddr,
) -> Option<&ConnectedPeer<Id, TTransform>> {
    peers_by_ip.longest_match(ip).map(|(_, peer)| peer)
}

#[derive(Debug)]
pub struct DnsQuery<'a> {
    pub name: String,
    pub record_type: RecordType,
    // We could be much more efficient with this field,
    // we only need the header to create the response.
    pub query: IpPacket<'a>,
}

impl<'a> DnsQuery<'a> {
    pub(crate) fn into_owned(self) -> DnsQuery<'static> {
        let Self {
            name,
            record_type,
            query,
        } = self;
        let buf = query.packet().to_vec();
        let query =
            IpPacket::owned(buf).expect("We are constructing the ip packet from an ip packet");

        DnsQuery {
            name,
            record_type,
            query,
        }
    }
}

impl<CB, TRoleState> Tunnel<CB, TRoleState>
where
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    /// Creates a new tunnel.
    ///
    /// # Parameters
    /// - `private_key`: wireguard's private key.
    /// -  `control_signaler`: this is used to send SDP from the tunnel to the control plane.
    #[tracing::instrument(level = "trace", skip(private_key, callbacks))]
    pub async fn new(private_key: StaticSecret, callbacks: CB) -> Result<Self> {
        let public_key = (&private_key).into();
        let rate_limiter = Arc::new(RateLimiter::new(&public_key, HANDSHAKE_RATE_LIMIT));
        let next_index = Default::default();
        let peer_connections = Default::default();
        let device = Default::default();

        // ICE
        let mut media_engine = MediaEngine::default();

        // Register default codecs (TODO: We need this?)
        media_engine.register_default_codecs()?;
        let mut registry = Registry::new();
        registry = register_default_interceptors(registry, &mut media_engine)?;
        let mut setting_engine = SettingEngine::default();
        setting_engine.set_interface_filter(Box::new(|name| !name.contains("tun")));

        let webrtc_api = APIBuilder::new()
            .with_media_engine(media_engine)
            .with_interceptor_registry(registry)
            .with_setting_engine(setting_engine)
            .build();

        Ok(Self {
            rate_limiter,
            private_key,
            peer_connections,
            public_key,
            next_index,
            webrtc_api,
            device,
            read_buf: Mutex::new(Box::new([0u8; MAX_UDP_SIZE])),
            write_buf: Mutex::new(Box::new([0u8; MAX_UDP_SIZE])),
            callbacks: CallbackErrorFacade(callbacks),
            role_state: Default::default(),
            rate_limit_reset_interval: Mutex::new(rate_limit_reset_interval()),
            peer_refresh_interval: Mutex::new(peer_refresh_interval()),
            mtu_refresh_interval: Mutex::new(mtu_refresh_interval()),
            peers_to_stop: Default::default(),
            no_device_waker: Default::default(),
        })
    }

    fn next_index(&self) -> u32 {
        self.next_index.lock().next()
    }

    pub fn callbacks(&self) -> &CallbackErrorFacade<CB> {
        &self.callbacks
    }
}

/// Constructs the interval for resetting the rate limit count.
///
/// As per documentation on [`RateLimiter::reset_count`], this is configured to run every second.
fn rate_limit_reset_interval() -> Interval {
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    interval.set_missed_tick_behavior(MissedTickBehavior::Delay);

    interval
}

/// Constructs the interval for "refreshing" peers.
///
/// On each tick, we remove expired peers from our map, update wireguard timers and send packets, if any.
fn peer_refresh_interval() -> Interval {
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    interval.set_missed_tick_behavior(MissedTickBehavior::Delay);

    interval
}

/// Constructs the interval for refreshing the MTU of our TUN device.
fn mtu_refresh_interval() -> Interval {
    let mut interval = tokio::time::interval(Duration::from_secs(30));
    interval.set_missed_tick_behavior(MissedTickBehavior::Delay);

    interval
}

/// Dedicated trait for abstracting over the different ICE states.
///
/// By design, this trait does not allow any operations apart from advancing via [`RoleState::poll_next_event`].
/// The state should only be modified when the concrete type is known, e.g. [`State`] or [`State`].
pub trait RoleState: Default + Send + 'static {
    type Id: fmt::Debug + fmt::Display + Eq + Hash + Copy + Unpin + Send + Sync + 'static;
    type Event;

    fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Self::Event>;
    fn remove_peers(&mut self, conn_id: Self::Id);
    fn refresh_peers(&mut self) -> VecDeque<Self::Id>;
}

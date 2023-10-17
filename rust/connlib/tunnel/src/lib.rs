//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.
use boringtun::{
    noise::{errors::WireGuardError, rate_limiter::RateLimiter, TunnResult},
    x25519::{PublicKey, StaticSecret},
};
use bytes::Bytes;

use connlib_shared::{messages::Key, CallbackErrorFacade, Callbacks, Error};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use serde::{Deserialize, Serialize};

use itertools::Itertools;
use parking_lot::{Mutex, RwLock};
use peer::{Peer, PeerStats};
use resource_table::ResourceTable;
use tokio::{task::AbortHandle, time::MissedTickBehavior};
use webrtc::{
    api::{
        interceptor_registry::register_default_interceptors, media_engine::MediaEngine,
        setting_engine::SettingEngine, APIBuilder, API,
    },
    interceptor::registry::Registry,
    peer_connection::RTCPeerConnection,
};

use std::task::{Context, Poll};
use std::{collections::HashMap, fmt, io, net::IpAddr, sync::Arc, time::Duration};
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;

use connlib_shared::{
    messages::{ClientId, GatewayId, ResourceDescription, ResourceId},
    Result,
};

use device_channel::{DeviceIo, IfaceConfig};

pub use client::ClientState;
pub use control_protocol::Request;
pub use gateway::GatewayState;
pub use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;

use crate::ip_packet::MutableIpPacket;
use connlib_shared::messages::SecretKey;
use index::IndexLfsr;

mod client;
mod control_protocol;
mod device_channel;
mod dns;
mod gateway;
mod iface_handler;
mod index;
mod ip_packet;
mod peer;
mod peer_handler;
mod resource_sender;
mod resource_table;
mod tokio_util;

const MAX_UDP_SIZE: usize = (1 << 16) - 1;
const RESET_PACKET_COUNT_INTERVAL: Duration = Duration::from_secs(1);
const REFRESH_PEERS_TIMERS_INTERVAL: Duration = Duration::from_secs(1);
const REFRESH_MTU_INTERVAL: Duration = Duration::from_secs(30);
/// For how long we will attempt to gather ICE candidates before aborting.
///
/// Chosen arbitrarily.
/// Very likely, the actual WebRTC connection will timeout before this.
/// This timeout is just here to eventually clean-up tasks if they are somehow broken.
const ICE_GATHERING_TIMEOUT_SECONDS: u64 = 5 * 60;

/// How many concurrent ICE gathering attempts we are allow.
///
/// Chosen arbitrarily.
const MAX_CONCURRENT_ICE_GATHERING: usize = 100;

// Note: Taken from boringtun
const HANDSHAKE_RATE_LIMIT: u64 = 100;

#[derive(Hash, Debug, Deserialize, Serialize, Clone, Copy, PartialEq, Eq)]
pub enum ConnId {
    Gateway(GatewayId),
    Client(ClientId),
    Resource(ResourceId),
}

impl From<GatewayId> for ConnId {
    fn from(id: GatewayId) -> Self {
        Self::Gateway(id)
    }
}

impl From<ClientId> for ConnId {
    fn from(id: ClientId) -> Self {
        Self::Client(id)
    }
}

impl From<ResourceId> for ConnId {
    fn from(id: ResourceId) -> Self {
        Self::Resource(id)
    }
}

impl fmt::Display for ConnId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConnId::Gateway(inner) => fmt::Display::fmt(inner, f),
            ConnId::Client(inner) => fmt::Display::fmt(inner, f),
            ConnId::Resource(inner) => fmt::Display::fmt(inner, f),
        }
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
#[derive(Clone)]
struct Device {
    config: Arc<IfaceConfig>,
    io: DeviceIo,

    buf: Box<[u8; MAX_UDP_SIZE]>,
}

impl Device {
    async fn read(&mut self) -> io::Result<Option<MutableIpPacket<'_>>> {
        let res = self.io.read(&mut self.buf[..self.config.mtu()]).await?;
        tracing::trace!(target: "wire", action = "read", bytes = res, from = "iface");

        if res == 0 {
            return Ok(None);
        }

        Ok(Some(
            MutableIpPacket::new(&mut self.buf[..res]).ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "received bytes are not an IP packet",
                )
            })?,
        ))
    }
}

// TODO: We should use newtypes for each kind of Id
/// Tunnel is a wireguard state machine that uses webrtc's ICE channels instead of UDP sockets
/// to communicate between peers.
pub struct Tunnel<CB: Callbacks, TRoleState> {
    next_index: Mutex<IndexLfsr>,
    // We use a tokio Mutex here since this is only read/write during config so there's no relevant performance impact
    device: tokio::sync::RwLock<Option<Device>>,
    rate_limiter: Arc<RateLimiter>,
    private_key: StaticSecret,
    public_key: PublicKey,
    peers_by_ip: RwLock<IpNetworkTable<Arc<Peer>>>,
    peer_connections: Mutex<HashMap<ConnId, Arc<RTCPeerConnection>>>,
    webrtc_api: API,
    callbacks: CallbackErrorFacade<CB>,
    iface_handler_abort: Mutex<Option<AbortHandle>>,

    /// State that differs per role, i.e. clients vs gateways.
    role_state: Mutex<TRoleState>,
}

// TODO: For now we only use these fields with debug
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct TunnelStats {
    public_key: String,
    peers_by_ip: HashMap<IpNetwork, PeerStats>,
    peer_connections: Vec<ConnId>,
}

impl<CB, TRoleState> Tunnel<CB, TRoleState>
where
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    pub fn stats(&self) -> TunnelStats {
        let peers_by_ip = self
            .peers_by_ip
            .read()
            .iter()
            .map(|(ip, peer)| (ip, peer.stats()))
            .collect();
        let peer_connections = self.peer_connections.lock().keys().cloned().collect();

        TunnelStats {
            public_key: Key::from(self.public_key).to_string(),
            peers_by_ip,
            peer_connections,
        }
    }

    pub async fn next_event(&self) -> Event<TRoleState::Id> {
        std::future::poll_fn(|cx| self.poll_next_event(cx)).await
    }

    pub fn poll_next_event(&self, cx: &mut Context<'_>) -> Poll<Event<TRoleState::Id>> {
        self.role_state.lock().poll_next_event(cx)
    }
}

pub(crate) fn peer_by_ip(peers_by_ip: &IpNetworkTable<Arc<Peer>>, ip: IpAddr) -> Option<Arc<Peer>> {
    peers_by_ip.longest_match(ip).map(|(_, peer)| peer).cloned()
}

pub enum Event<TId> {
    SignalIceCandidate {
        conn_id: TId,
        candidate: RTCIceCandidateInit,
    },
    ConnectionIntent {
        resource: ResourceDescription,
        connected_gateway_ids: Vec<GatewayId>,
        reference: usize,
    },
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
        let peers_by_ip = RwLock::new(IpNetworkTable::new());
        let next_index = Default::default();
        let peer_connections = Default::default();
        let resources: Arc<RwLock<ResourceTable<ResourceDescription>>> = Default::default();
        let device = Default::default();
        let iface_handler_abort = Default::default();

        // ICE
        let mut media_engine = MediaEngine::default();

        // Register default codecs (TODO: We need this?)
        media_engine.register_default_codecs()?;
        let mut registry = Registry::new();
        registry = register_default_interceptors(registry, &mut media_engine)?;
        let mut setting_engine = SettingEngine::default();
        setting_engine.detach_data_channels();
        setting_engine.set_ip_filter(Box::new({
            let resources = Arc::clone(&resources);
            move |ip| !resources.read().values().any(|res_ip| res_ip.contains(ip))
        }));

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
            peers_by_ip,
            next_index,
            webrtc_api,
            device,
            callbacks: CallbackErrorFacade(callbacks),
            iface_handler_abort,
            role_state: Default::default(),
        })
    }

    #[tracing::instrument(level = "trace", skip(self))]
    async fn stop_peer(&self, index: u32, conn_id: ConnId) {
        self.peers_by_ip.write().retain(|_, p| p.index != index);
        let conn = self.peer_connections.lock().remove(&conn_id);
        if let Some(conn) = conn {
            if let Err(e) = conn.close().await {
                tracing::warn!(error = ?e, "Can't close peer");
                let _ = self.callbacks().on_error(&e.into());
            }
        }
    }

    async fn peer_refresh(&self, peer: &Peer, dst_buf: &mut [u8; MAX_UDP_SIZE]) {
        let update_timers_result = peer.update_timers(&mut dst_buf[..]);

        match update_timers_result {
            TunnResult::Done => {}
            TunnResult::Err(WireGuardError::ConnectionExpired)
            | TunnResult::Err(WireGuardError::NoCurrentSession) => {
                self.stop_peer(peer.index, peer.conn_id).await;
                let _ = peer.shutdown().await;
            }
            TunnResult::Err(e) => tracing::error!(error = ?e, "timer_error"),
            TunnResult::WriteToNetwork(packet) => {
                let bytes = Bytes::copy_from_slice(packet);
                peer.send_infallible(bytes, &self.callbacks).await
            }

            _ => panic!("Unexpected result from update_timers"),
        };
    }

    fn start_rate_limiter_refresh_timer(self: &Arc<Self>) {
        let rate_limiter = self.rate_limiter.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(RESET_PACKET_COUNT_INTERVAL);
            interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
            loop {
                rate_limiter.reset_count();
                interval.tick().await;
            }
        });
    }

    fn start_peers_refresh_timer(self: &Arc<Self>) {
        let tunnel = self.clone();

        tokio::spawn(async move {
            let mut interval = tokio::time::interval(REFRESH_PEERS_TIMERS_INTERVAL);
            interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
            let mut dst_buf = [0u8; MAX_UDP_SIZE];

            loop {
                remove_expired_peers(
                    &mut tunnel.peers_by_ip.write(),
                    &mut tunnel.peer_connections.lock(),
                );

                let peers: Vec<_> = tunnel
                    .peers_by_ip
                    .read()
                    .iter()
                    .map(|p| p.1)
                    .unique_by(|p| p.index)
                    .cloned()
                    .collect();

                for peer in peers {
                    tunnel.peer_refresh(&peer, &mut dst_buf).await;
                }

                interval.tick().await;
            }
        });
    }

    async fn start_refresh_mtu_timer(self: &Arc<Self>) -> Result<()> {
        let dev = self.clone();
        let callbacks = self.callbacks().clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(REFRESH_MTU_INTERVAL);
            interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
            loop {
                interval.tick().await;

                let Some(device) = dev.device.read().await.clone() else {
                    let err = Error::ControlProtocolError;
                    tracing::error!(?err, "get_iface_config");
                    let _ = callbacks.0.on_error(&err);
                    continue;
                };
                if let Err(e) = device.config.refresh_mtu().await {
                    tracing::error!(error = ?e, "refresh_mtu");
                    let _ = callbacks.0.on_error(&e);
                }
            }
        });

        Ok(())
    }

    async fn start_timers(self: &Arc<Self>) -> Result<()> {
        self.start_refresh_mtu_timer().await?;
        self.start_rate_limiter_refresh_timer();
        self.start_peers_refresh_timer();
        Ok(())
    }

    fn next_index(&self) -> u32 {
        self.next_index.lock().next()
    }

    pub fn callbacks(&self) -> &CallbackErrorFacade<CB> {
        &self.callbacks
    }
}

fn remove_expired_peers(
    peers_by_ip: &mut IpNetworkTable<Arc<Peer>>,
    peer_connections: &mut HashMap<ConnId, Arc<RTCPeerConnection>>,
) {
    for (_, peer) in peers_by_ip.iter() {
        peer.expire_resources();
        if peer.is_emptied() {
            tracing::trace!(index = peer.index, "peer_expired");
            let conn = peer_connections.remove(&peer.conn_id);
            let p = peer.clone();

            // We are holding a Mutex, particularly a write one, we don't want to make a blocking call
            tokio::spawn(async move {
                let _ = p.shutdown().await;
                if let Some(conn) = conn {
                    // TODO: it seems that even closing the stream there are messages to the relay
                    // see where they come from.
                    let _ = conn.close().await;
                }
            });
        }
    }

    peers_by_ip.retain(|_, p| !p.is_emptied());
}

/// Dedicated trait for abstracting over the different ICE states.
///
/// By design, this trait does not allow any operations apart from advancing via [`RoleState::poll_next_event`].
/// The state should only be modified when the concrete type is known, e.g. [`ClientState`] or [`GatewayState`].
pub trait RoleState: Default + Send + 'static {
    type Id: fmt::Debug;

    fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Event<Self::Id>>;
}

//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.
use boringtun::{
    noise::{
        errors::WireGuardError, handshake::parse_handshake_anon, rate_limiter::RateLimiter, Packet,
        Tunn, TunnResult,
    },
    x25519::{PublicKey, StaticSecret},
};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use libs_common::{Callbacks, Error, DNS_SENTINEL};

use async_trait::async_trait;
use bytes::Bytes;
use itertools::Itertools;
use parking_lot::{Mutex, RwLock};
use peer::Peer;
use resource_table::ResourceTable;
use tokio::time::MissedTickBehavior;
use webrtc::{
    api::{
        interceptor_registry::register_default_interceptors, media_engine::MediaEngine,
        setting_engine::SettingEngine, APIBuilder, API,
    },
    interceptor::registry::Registry,
    peer_connection::RTCPeerConnection,
};

use std::{
    collections::{HashMap, HashSet},
    net::IpAddr,
    sync::Arc,
    time::Duration,
};

use libs_common::{
    messages::{Id, Interface as InterfaceConfig, ResourceDescription},
    CallbackErrorFacade, Result,
};

use device_channel::{create_iface, DeviceChannel};
use tun::IfaceConfig;

pub use control_protocol::Request;
pub use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;

use index::{check_packet_index, IndexLfsr};

use crate::ip_packet::MutableIpPacket;

mod control_protocol;
mod dns;
mod index;
mod ip_packet;
mod peer;
mod resource_sender;
mod resource_table;

// TODO: For now all tunnel implementations are the same
// will divide when we start introducing differences.
#[cfg(target_os = "windows")]
#[path = "tun_win.rs"]
mod tun;

#[cfg(any(target_os = "macos", target_os = "ios"))]
#[path = "tun_darwin.rs"]
mod tun;

#[cfg(target_os = "linux")]
#[path = "tun_linux.rs"]
mod tun;

// TODO: Android and linux are nearly identical; use a common tunnel module?
#[cfg(target_os = "android")]
#[path = "tun_android.rs"]
mod tun;

#[cfg(target_family = "unix")]
#[path = "device_channel_unix.rs"]
mod device_channel;

#[cfg(target_family = "windows")]
#[path = "device_channel_win.rs"]
mod device_channel;

const RESET_PACKET_COUNT_INTERVAL: Duration = Duration::from_secs(1);
const REFRESH_PEERS_TIMERS_INTERVAL: Duration = Duration::from_secs(1);

// Note: Taken from boringtun
const HANDSHAKE_RATE_LIMIT: u64 = 100;
const MAX_UDP_SIZE: usize = (1 << 16) - 1;

/// Represent's the tunnel actual peer's config
/// Obtained from libs_common's Peer
#[derive(Clone)]
pub struct PeerConfig {
    pub(crate) persistent_keepalive: Option<u16>,
    pub(crate) public_key: PublicKey,
    pub(crate) ips: Vec<IpNetwork>,
    pub(crate) preshared_key: StaticSecret,
}

impl From<libs_common::messages::Peer> for PeerConfig {
    fn from(value: libs_common::messages::Peer) -> Self {
        Self {
            persistent_keepalive: value.persistent_keepalive,
            public_key: value.public_key.0.into(),
            ips: vec![value.ipv4.into(), value.ipv6.into()],
            preshared_key: value.preshared_key.0.into(),
        }
    }
}

/// Trait used for out-going signals to control plane that are **required** to be made from inside the tunnel.
///
/// Generally, we try to return from the functions here rather than using this callback.
#[async_trait]
pub trait ControlSignal {
    /// Signals to the control plane an intent to initiate a connection to the given resource.
    ///
    /// Used when a packet is found to a resource we have no connection stablished but is within the list of resources available for the client.
    async fn signal_connection_to(
        &self,
        resource: &ResourceDescription,
        connected_gateway_ids: Vec<Id>,
    ) -> Result<()>;
}

// TODO: We should use newtypes for each kind of Id
/// Tunnel is a wireguard state machine that uses webrtc's ICE channels instead of UDP sockets
/// to communicate between peers.
pub struct Tunnel<C: ControlSignal, CB: Callbacks> {
    next_index: Mutex<IndexLfsr>,
    // We use a tokio's mutex here since it makes things easier and we only need it
    // during init, so the performance hit is neglibile
    iface_config: tokio::sync::Mutex<Option<IfaceConfig>>,
    device_channel: RwLock<Option<Arc<DeviceChannel>>>,
    rate_limiter: Arc<RateLimiter>,
    private_key: StaticSecret,
    public_key: PublicKey,
    peers_by_ip: RwLock<IpNetworkTable<Arc<Peer>>>,
    peer_connections: Mutex<HashMap<Id, Arc<RTCPeerConnection>>>,
    awaiting_connection: Mutex<HashSet<Id>>,
    gateway_awaiting_connection: Mutex<HashMap<Id, Vec<IpNetwork>>>,
    resources_gateways: Mutex<HashMap<Id, Id>>,
    webrtc_api: API,
    resources: RwLock<ResourceTable<ResourceDescription>>,
    control_signaler: C,
    gateway_public_keys: Mutex<HashMap<Id, PublicKey>>,
    callbacks: CallbackErrorFacade<CB>,
}

impl<C, CB> Tunnel<C, CB>
where
    C: ControlSignal + Send + Sync + 'static,
    CB: Callbacks + 'static,
{
    /// Creates a new tunnel.
    ///
    /// # Parameters
    /// - `private_key`: wireguard's private key.
    /// -  `control_signaler`: this is used to send SDP from the tunnel to the control plane.
    #[tracing::instrument(level = "trace", skip(private_key, control_signaler, callbacks))]
    pub async fn new(
        private_key: StaticSecret,
        control_signaler: C,
        callbacks: CB,
    ) -> Result<Self> {
        let public_key = (&private_key).into();
        let rate_limiter = Arc::new(RateLimiter::new(&public_key, HANDSHAKE_RATE_LIMIT));
        let peers_by_ip = RwLock::new(IpNetworkTable::new());
        let next_index = Default::default();
        let peer_connections = Default::default();
        let resources = Default::default();
        let awaiting_connection = Default::default();
        let gateway_public_keys = Default::default();
        let resources_gateways = Default::default();
        let gateway_awaiting_connection = Default::default();
        let iface_config = Default::default();
        let device_channel = Default::default();

        // ICE
        let mut media_engine = MediaEngine::default();

        // Register default codecs (TODO: We need this?)
        media_engine.register_default_codecs()?;
        let mut registry = Registry::new();
        registry = register_default_interceptors(registry, &mut media_engine)?;
        let mut setting_engine = SettingEngine::default();
        setting_engine.detach_data_channels();
        // TODO: Enable UDPMultiplex (had some problems before)

        let webrtc_api = APIBuilder::new()
            .with_media_engine(media_engine)
            .with_interceptor_registry(registry)
            .with_setting_engine(setting_engine)
            .build();

        Ok(Self {
            gateway_public_keys,
            rate_limiter,
            private_key,
            peer_connections,
            public_key,
            peers_by_ip,
            next_index,
            webrtc_api,
            resources,
            iface_config,
            device_channel,
            awaiting_connection,
            gateway_awaiting_connection,
            control_signaler,
            resources_gateways,
            callbacks: CallbackErrorFacade(callbacks),
        })
    }

    /// Adds a the given resource to the tunnel.
    ///
    /// Once added, when a packet for the resource is intercepted a new data channel will be created
    /// and packets will be wrapped with wireguard and sent through it.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn add_resource(&self, resource_description: ResourceDescription) -> Result<()> {
        {
            let Some(ref mut iface_config) = *self.iface_config.lock().await else {
                tracing::error!("Received resource add before initialization.");
                return Err(Error::ControlProtocolError)
            };
            for ip in resource_description.ips() {
                iface_config.add_route(ip, self.callbacks()).await?;
            }
        }
        let resource_list = {
            let mut resources = self.resources.write();
            resources.insert(resource_description);
            resources.resource_list()
        };
        self.callbacks.on_update_resources(resource_list)?;
        Ok(())
    }

    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_interface(self: &Arc<Self>, config: &InterfaceConfig) -> Result<()> {
        let (mut iface_config, device_channel) = create_iface(config, self.callbacks()).await?;
        iface_config
            .add_route(DNS_SENTINEL.into(), self.callbacks())
            .await?;

        let device_channel = Arc::new(device_channel);
        *self.device_channel.write() = Some(device_channel.clone());
        *self.iface_config.lock().await = Some(iface_config);
        self.start_timers();
        self.start_iface_handler(device_channel);

        self.callbacks.on_tunnel_ready()?;

        tracing::trace!("Started background loops");

        Ok(())
    }

    async fn stop_peer(&self, index: u32, conn_id: Id) {
        self.peers_by_ip.write().retain(|_, p| p.index != index);
        let conn = self.peer_connections.lock().remove(&conn_id);
        if let Some(conn) = conn {
            if let Err(e) = conn.close().await {
                tracing::error!("Problem while trying to close channel: {e:?}");
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
            TunnResult::Err(e) => tracing::error!(message = "Timer error", error = ?e),
            TunnResult::WriteToNetwork(packet) => {
                peer.send_infallible(packet, &self.callbacks).await
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

    fn remove_expired_peers(self: &Arc<Self>) {
        let mut peers_by_ip = self.peers_by_ip.write();

        for (_, peer) in peers_by_ip.iter() {
            peer.expire_resources();
            if peer.is_emptied() {
                tracing::trace!("Peer connection with index {} expired", peer.index);
                let conn = self.peer_connections.lock().remove(&peer.conn_id);
                let p = peer.clone();
                // We are holding a Mutex, specially a write one, we don't want to make a blocking call
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

    fn start_peers_refresh_timer(self: &Arc<Self>) {
        let tunnel = self.clone();

        tokio::spawn(async move {
            let mut interval = tokio::time::interval(REFRESH_PEERS_TIMERS_INTERVAL);
            interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
            let mut dst_buf = [0u8; MAX_UDP_SIZE];

            loop {
                tunnel.remove_expired_peers();

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

    fn start_timers(self: &Arc<Self>) {
        self.start_rate_limiter_refresh_timer();
        self.start_peers_refresh_timer();
    }

    fn is_wireguard_packet_ok(&self, parsed_packet: &Packet, peer: &Peer) -> bool {
        match &parsed_packet {
            Packet::HandshakeInit(p) => {
                parse_handshake_anon(&self.private_key, &self.public_key, p).is_ok()
            }
            Packet::HandshakeResponse(p) => check_packet_index(p.receiver_idx, peer.index),
            Packet::PacketCookieReply(p) => check_packet_index(p.receiver_idx, peer.index),
            Packet::PacketData(p) => check_packet_index(p.receiver_idx, peer.index),
        }
    }

    fn start_peer_handler(self: &Arc<Self>, peer: Arc<Peer>) -> Result<()> {
        let Some(device_channel) = self.device_channel.read().clone() else { return Err(Error::NoIface); };
        let tunnel = Arc::clone(self);
        tokio::spawn(async move {
            let mut src_buf = [0u8; MAX_UDP_SIZE];
            let mut dst_buf = [0u8; MAX_UDP_SIZE];
            while let Ok(size) = peer.channel.read(&mut src_buf[..]).await {
                // TODO: Double check that this can only happen on closed channel
                // I think it's possible to transmit a 0-byte message through the channel
                // but we would never use that.
                // We should keep track of an open/closed channel ourselves if we wanted to do it properly then.
                if size == 0 {
                    break;
                }

                tracing::trace!(action = "read", bytes = size, from = "peer");

                // The rate limiter initially checks mac1 and mac2, and optionally asks to send a cookie
                let parsed_packet = match tunnel.rate_limiter.verify_packet(
                    // TODO: Some(addr.ip()) webrtc doesn't expose easily the underlying data channel remote ip
                    // so for now we don't use it. but we need it for rate limiter although we probably not need it since the data channel
                    // will only be established to authenticated peers, so the portal could already prevent being ddos'd
                    // but maybe in that cased we can drop this rate_limiter all together and just use decapsulate
                    None,
                    &src_buf[..size],
                    &mut dst_buf,
                ) {
                    Ok(packet) => packet,
                    Err(TunnResult::WriteToNetwork(cookie)) => {
                        peer.send_infallible(cookie, &tunnel.callbacks).await;
                        continue;
                    }
                    Err(TunnResult::Err(e)) => {
                        tracing::error!(message = "Wireguard error", error = ?e);
                        let _ = tunnel.callbacks().on_error(&e.into());
                        continue;
                    }
                    Err(_) => {
                        tracing::error!("Developer error: wireguard returned an unexpected error");
                        continue;
                    }
                };

                if !tunnel.is_wireguard_packet_ok(&parsed_packet, &peer) {
                    tracing::error!("Wireguard packet failed verification");
                    continue;
                }

                let decapsulate_result = peer.tunnel.lock().decapsulate(
                    // TODO: See comment above
                    None,
                    &src_buf[..size],
                    &mut dst_buf[..],
                );

                // We found a peer, use it to decapsulate the message+
                let mut flush = false;
                match decapsulate_result {
                    TunnResult::Done => {}
                    TunnResult::Err(e) => {
                        tracing::error!(message = "Error decapsulating packet", error = ?e);
                        let _ = tunnel.callbacks().on_error(&e.into());
                        continue;
                    }
                    TunnResult::WriteToNetwork(packet) => {
                        flush = true;
                        peer.send_infallible(packet, &tunnel.callbacks).await;
                    }
                    TunnResult::WriteToTunnelV4(packet, addr) => {
                        tunnel
                            .send_to_resource(&device_channel, &peer, addr.into(), packet)
                            .await;
                    }
                    TunnResult::WriteToTunnelV6(packet, addr) => {
                        tunnel
                            .send_to_resource(&device_channel, &peer, addr.into(), packet)
                            .await;
                    }
                };

                if flush {
                    // Flush pending queue
                    while let TunnResult::WriteToNetwork(packet) = {
                        let res = peer.tunnel.lock().decapsulate(None, &[], &mut dst_buf[..]);
                        res
                    } {
                        peer.send_infallible(packet, &tunnel.callbacks).await;
                    }
                }
            }
        });

        Ok(())
    }

    async fn write4_device_infallible(&self, device_channel: &DeviceChannel, packet: &[u8]) {
        if let Err(e) = device_channel.write4(packet).await {
            let _ = self.callbacks.on_error(&e.into());
        }
    }

    async fn write6_device_infallible(&self, device_channel: &DeviceChannel, packet: &[u8]) {
        if let Err(e) = device_channel.write6(packet).await {
            let _ = self.callbacks.on_error(&e.into());
        }
    }

    fn get_resource(&self, buff: &[u8]) -> Option<ResourceDescription> {
        let addr = Tunn::dst_address(buff)?;
        let resources = self.resources.read();
        match addr {
            IpAddr::V4(ipv4) => resources.get_by_ip(ipv4).cloned(),
            IpAddr::V6(ipv6) => resources.get_by_ip(ipv6).cloned(),
        }
    }

    fn start_iface_handler(self: &Arc<Self>, device_channel: Arc<DeviceChannel>) {
        let dev = self.clone();
        tokio::spawn(async move {
            loop {
                let mut src = [0u8; MAX_UDP_SIZE];
                let mut dst = [0u8; MAX_UDP_SIZE];
                let res = {
                    // TODO: We should check here if what we read is a whole packet
                    // there's no docs on tun device on when a whole packet is read, is it \n or another thing?
                    // found some comments saying that a single read syscall represents a single packet but no docs on that
                    // See https://stackoverflow.com/questions/18461365/how-to-read-packet-by-packet-from-linux-tun-tap
                    match device_channel.mtu().await {
                        // XXX: Do we need to fetch the mtu every time? In most clients it'll
                        // be hardcoded to 1280, and if not, it'll only change before packets start
                        // to flow.
                        Ok(mtu) => match device_channel.read(&mut src[..mtu]).await {
                            Ok(res) => res,
                            Err(err) => {
                                tracing::error!(message = "Couldn't read packet from interface", error = ?err);
                                let _ = dev.callbacks.on_error(&err.into());
                                continue;
                            }
                        },
                        Err(err) => {
                            tracing::error!(message = "Couldn't obtain iface mtu", error = ?err);
                            let _ = dev.callbacks.on_error(&err);
                            continue;
                        }
                    }
                };

                tracing::trace!(action = "reading", bytes = res, from = "iface");

                if let Some(r) = dev.check_for_dns(&src[..res]) {
                    match r {
                        dns::SendPacket::Ipv4(r) => {
                            dev.write4_device_infallible(&device_channel, &r[..]).await
                        }
                        dns::SendPacket::Ipv6(r) => {
                            dev.write6_device_infallible(&device_channel, &r[..]).await
                        }
                    }
                    continue;
                }

                let dst_addr = match Tunn::dst_address(&src[..res]) {
                    Some(addr) => addr,
                    None => continue,
                };

                let (encapsulate_result, channel, peer_index, conn_id) = {
                    match dev.peers_by_ip.read().longest_match(dst_addr).map(|p| p.1) {
                        Some(peer) => {
                            let Some(mut packet) = MutableIpPacket::new(&mut src[..res]) else  {
                                    tracing::error!("Developer error: we should never see a packet through the tunnel wire that isn't ip");
                                    continue;
                                };
                            if let Some(resource) =
                                peer.get_translation(packet.to_immutable().source())
                            {
                                let ResourceDescription::Dns(resource) = resource else {
                                    tracing::error!("Developer error: only dns resources should have a resource_address");
                                    continue;
                                };

                                match &mut packet {
                                    MutableIpPacket::MutableIpv4Packet(ref mut p) => {
                                        p.set_source(resource.ipv4)
                                    }
                                    MutableIpPacket::MutableIpv6Packet(ref mut p) => {
                                        p.set_source(resource.ipv6)
                                    }
                                }

                                packet.update_checksum();
                            }
                            (
                                peer.tunnel.lock().encapsulate(&src[..res], &mut dst[..]),
                                peer.channel.clone(),
                                peer.index,
                                peer.conn_id,
                            )
                        }
                        None => {
                            // We can buffer requests here but will drop them for now and let the upper layer reliability protocol handle this
                            if let Some(resource) = dev.get_resource(&src[..res]) {
                                // We have awaiting connection to prevent a race condition where
                                // create_peer_connection hasn't added the thing to peer_connections
                                // and we are finding another packet to the same address (otherwise we would just use peer_connections here)
                                let mut awaiting_connection = dev.awaiting_connection.lock();
                                let id = resource.id();
                                if !awaiting_connection.contains(&id) {
                                    tracing::trace!(
                                        message = "Found new intent to send packets to resource",
                                        resource_ip = %dst_addr
                                    );

                                    awaiting_connection.insert(id);
                                    let dev = Arc::clone(&dev);

                                    let mut connected_gateway_ids: Vec<_> = dev
                                        .gateway_awaiting_connection
                                        .lock()
                                        .clone()
                                        .into_keys()
                                        .collect();
                                    connected_gateway_ids.extend(
                                        dev.resources_gateways.lock().values().collect::<Vec<_>>(),
                                    );
                                    tracing::trace!(
                                        message = "Currently connected gateways", gateways = ?connected_gateway_ids
                                    );
                                    tokio::spawn(async move {
                                        if let Err(e) = dev
                                            .control_signaler
                                            .signal_connection_to(&resource, connected_gateway_ids)
                                            .await
                                        {
                                            // Not a deadlock because this is a different task
                                            dev.awaiting_connection.lock().remove(&id);
                                            tracing::error!(message = "couldn't start protocol for new connection to resource", error = ?e);
                                            let _ = dev.callbacks.on_error(&e);
                                        }
                                    });
                                }
                            }
                            continue;
                        }
                    }
                };

                match encapsulate_result {
                    TunnResult::Done => {}
                    TunnResult::Err(WireGuardError::ConnectionExpired)
                    | TunnResult::Err(WireGuardError::NoCurrentSession) => {
                        dev.stop_peer(peer_index, conn_id).await
                    }

                    TunnResult::Err(e) => {
                        tracing::error!(message = "Encapsulate error for resource", resource_address = %dst_addr, error = ?e);
                        let _ = dev.callbacks.on_error(&e.into());
                    }
                    TunnResult::WriteToNetwork(packet) => {
                        tracing::trace!(action = "writing", from = "iface", to = %dst_addr);
                        if let Err(e) = channel.write(&Bytes::copy_from_slice(packet)).await {
                            tracing::error!("Couldn't write packet to channel: {e}");
                            if matches!(
                                e,
                                webrtc::data::Error::ErrStreamClosed
                                    | webrtc::data::Error::Sctp(
                                        webrtc::sctp::Error::ErrStreamClosed
                                    )
                            ) {
                                dev.stop_peer(peer_index, conn_id).await;
                            }
                            let _ = dev.callbacks.on_error(&e.into());
                            return;
                        }
                    }
                    _ => panic!("Unexpected result from encapsulate"),
                };
            }
        });
    }

    fn next_index(&self) -> u32 {
        self.next_index.lock().next()
    }

    pub fn callbacks(&self) -> &CallbackErrorFacade<CB> {
        &self.callbacks
    }
}

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
use libs_common::{
    error_type::ErrorType::{Fatal, Recoverable},
    Callbacks,
};

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
    Result,
};

use device_channel::{create_iface, DeviceChannel};
use tun::IfaceConfig;

pub use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;

use index::{check_packet_index, IndexLfsr};

mod control_protocol;
mod index;
mod peer;
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

#[cfg(target_os = "android")]
#[path = "tun_android.rs"]
mod tun;

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "linux",
    target_os = "android"
))]
#[path = "device_channel_unix.rs"]
mod device_channel;

#[cfg(target_os = "windows")]
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
    async fn signal_connection_to(&self, resource: &ResourceDescription) -> Result<()>;
}

/// Tunnel is a wireguard state machine that uses webrtc's ICE channels instead of UDP sockets
/// to communicate between peers.
pub struct Tunnel<C: ControlSignal, CB: Callbacks> {
    next_index: Mutex<IndexLfsr>,
    // We use a tokio's mutex here since it makes things easier and we only need it
    // during init, so the performance hit is neglibile
    iface_config: tokio::sync::Mutex<IfaceConfig>,
    device_channel: Arc<DeviceChannel>,
    rate_limiter: Arc<RateLimiter>,
    private_key: StaticSecret,
    public_key: PublicKey,
    peers_by_ip: RwLock<IpNetworkTable<Arc<Peer>>>,
    peer_connections: Mutex<HashMap<Id, Arc<RTCPeerConnection>>>,
    awaiting_connection: Mutex<HashSet<Id>>,
    webrtc_api: API,
    resources: RwLock<ResourceTable>,
    control_signaler: C,
    gateway_public_keys: Mutex<HashMap<Id, PublicKey>>,
    callbacks: CB,
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
        let (iface_config, device_channel) = create_iface().await?;
        let iface_config = tokio::sync::Mutex::new(iface_config);
        let device_channel = Arc::new(device_channel);
        let peer_connections = Default::default();
        let resources = Default::default();
        let awaiting_connection = Default::default();
        let gateway_public_keys = Default::default();

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
            iface_config,
            device_channel,
            resources,
            awaiting_connection,
            control_signaler,
            callbacks,
        })
    }

    /// Adds a the given resource to the tunnel.
    ///
    /// Once added, when a packet for the resource is intercepted a new data channel will be created
    /// and packets will be wrapped with wireguard and sent through it.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn add_resource(&self, resource_description: ResourceDescription) {
        {
            let mut iface_config = self.iface_config.lock().await;
            for ip in resource_description.ips() {
                if let Err(err) = iface_config.add_route(&ip).await {
                    self.callbacks.on_error(&err, Fatal);
                }
            }
        }
        self.resources.write().insert(resource_description);
    }

    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_interface(self: &Arc<Self>, config: &InterfaceConfig) -> Result<()> {
        {
            let mut iface_config = self.iface_config.lock().await;
            iface_config
                .set_iface_config(config)
                .await
                .expect("Couldn't initiate interface");
            iface_config
                .up()
                .await
                .expect("Couldn't initiate interface");
        }

        self.start_timers();
        self.start_iface_handler();

        tracing::trace!("Started background loops");

        Ok(())
    }

    async fn peer_refresh(&self, peer: &Peer, dst_buf: &mut [u8; MAX_UDP_SIZE]) {
        let update_timers_result = peer.update_timers(&mut dst_buf[..]);

        match update_timers_result {
            TunnResult::Done => {}
            TunnResult::Err(WireGuardError::ConnectionExpired) => {
                tracing::error!("Connection expired");
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

    fn start_peers_refresh_timer(self: &Arc<Self>) {
        let tunnel = self.clone();

        tokio::spawn(async move {
            let mut interval = tokio::time::interval(REFRESH_PEERS_TIMERS_INTERVAL);
            interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
            let mut dst_buf = [0u8; MAX_UDP_SIZE];

            loop {
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

    fn start_peer_handler(self: &Arc<Self>, peer: Arc<Peer>) {
        let tunnel = Arc::clone(self);
        tokio::spawn(async move {
            let mut src_buf = [0u8; MAX_UDP_SIZE];
            let mut dst_buf = [0u8; MAX_UDP_SIZE];
            // Loop while we have packets on the anonymous connection
            while let Ok(size) = peer.channel.read(&mut src_buf[..]).await {
                tracing::trace!("read {size} bytes from peer");
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
                    Err(_) => continue,
                };

                if !tunnel.is_wireguard_packet_ok(&parsed_packet, &peer) {
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
                    TunnResult::Err(_) => continue,
                    TunnResult::WriteToNetwork(packet) => {
                        flush = true;
                        peer.send_infallible(packet, &tunnel.callbacks).await;
                    }
                    TunnResult::WriteToTunnelV4(packet, addr) => {
                        if peer.is_allowed(addr) {
                            tracing::trace!("Writing received peer packet to iface");
                            tunnel.write4_device_infallible(packet).await;
                        }
                    }
                    TunnResult::WriteToTunnelV6(packet, addr) => {
                        if peer.is_allowed(addr) {
                            tracing::trace!("Writing received peer packet to iface");
                            tunnel.write6_device_infallible(packet).await;
                        }
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
    }

    async fn write4_device_infallible(&self, packet: &[u8]) {
        if let Err(e) = self.device_channel.write4(packet).await {
            self.callbacks.on_error(&e.into(), Recoverable);
        }
    }

    async fn write6_device_infallible(&self, packet: &[u8]) {
        if let Err(e) = self.device_channel.write6(packet).await {
            self.callbacks.on_error(&e.into(), Recoverable);
        }
    }

    fn get_resource(&self, buff: &[u8]) -> Option<ResourceDescription> {
        // TODO: Check if DNS packet, in that case parse and get dns
        let addr = Tunn::dst_address(buff)?;
        let resources = self.resources.read();
        match addr {
            IpAddr::V4(ipv4) => resources.get_by_ip(ipv4).cloned(),
            IpAddr::V6(ipv6) => resources.get_by_ip(ipv6).cloned(),
        }
    }

    fn start_iface_handler(self: &Arc<Self>) {
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
                    match dev.device_channel.mtu().await {
                        Ok(mtu) => match dev.device_channel.read(&mut src[..mtu]).await {
                            Ok(res) => res,
                            Err(err) => {
                                tracing::error!("Couldn't read packet from interface: {err}");
                                dev.callbacks.on_error(&err.into(), Recoverable);
                                continue;
                            }
                        },
                        Err(err) => {
                            tracing::error!("Couldn't obtain iface mtu: {err}");
                            dev.callbacks.on_error(&err, Recoverable);
                            continue;
                        }
                    }
                };

                let dst_addr = match Tunn::dst_address(&src[..res]) {
                    Some(addr) => addr,
                    None => continue,
                };

                let (encapsulate_result, channel) = {
                    let peers_by_ip = dev.peers_by_ip.read();
                    match peers_by_ip.longest_match(dst_addr).map(|p| p.1) {
                        Some(peer) => (
                            peer.tunnel.lock().encapsulate(&src[..res], &mut dst[..]),
                            peer.channel.clone(),
                        ),
                        None => {
                            // We can buffer requests here but will drop them for now and let the upper layer reliability protocol handle this
                            if let Some(resource) = dev.get_resource(&src[..res]) {
                                // We have awaiting connection to prevent a race condition where
                                // create_peer_connection hasn't added the thing to peer_connections
                                // and we are finding another packet to the same address (otherwise we would just use peer_connections here)
                                let mut awaiting_connection = dev.awaiting_connection.lock();
                                let id = resource.id();
                                if !awaiting_connection.contains(&id) {
                                    tracing::trace!("Found new intent to send packets to resource with resource-ip: {dst_addr}, initializing connection...");

                                    awaiting_connection.insert(id);
                                    let dev = Arc::clone(&dev);

                                    tokio::spawn(async move {
                                        if let Err(e) = dev
                                            .control_signaler
                                            .signal_connection_to(&resource)
                                            .await
                                        {
                                            // Not a deadlock because this is a different task
                                            dev.awaiting_connection.lock().remove(&id);
                                            tracing::error!("couldn't start protocol for new connection to resource: {e}");
                                            dev.callbacks.on_error(&e, Recoverable);
                                        }
                                    });
                                }
                            }
                            continue;
                        }
                    }
                };

                match encapsulate_result {
                    TunnResult::Done => {
                        tracing::trace!(
                            "tunnel for resource corresponding to {dst_addr} was finalized"
                        );
                    }
                    TunnResult::Err(e) => {
                        tracing::error!(message = "Encapsulate error for resource corresponding to {dst_addr}", error = ?e);
                        dev.callbacks.on_error(&e.into(), Recoverable);
                    }
                    TunnResult::WriteToNetwork(packet) => {
                        tracing::trace!("writing iface packet to peer: {dst_addr}");
                        if let Err(e) = channel.write(&Bytes::copy_from_slice(packet)).await {
                            tracing::error!("Couldn't write packet to channel: {e}");
                            dev.callbacks.on_error(&e.into(), Recoverable);
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

    pub fn callbacks(&self) -> &CB {
        &self.callbacks
    }
}

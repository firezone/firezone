use crate::ip_packet::MutableIpPacket;
use crate::{device_channel, Transmit, MAX_UDP_SIZE};
use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use chrono::{DateTime, Utc};
use connlib_shared::error::ConnlibError;
use connlib_shared::messages::{Key, ResourceDescription, ResourceId, SecretKey};
use either::Either;
use firezone_relay::client::ChannelBinding;
use futures_util::future::BoxFuture;
use futures_util::FutureExt;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use pnet_packet::Packet;
use rand_core::OsRng;
use std::borrow::Cow;
use std::collections::{HashMap, VecDeque};
use std::net::{IpAddr, SocketAddr, ToSocketAddrs};
use std::task::{Context, Poll, Waker};
use std::time::Instant;
use str0m::ice::{IceAgent, IceAgentEvent, IceCreds};
use str0m::net::{DatagramRecv, Protocol, Receive};
use str0m::{Candidate, CandidateKind};

/// A connection to another peer.
///
/// Through the use of ICE, [`Connection`] will initially attempt to hole-punch a direct connection and fall back to using one or more TURN servers.
/// This struct itself doesn't actually perform any IO but it does have internal timers so it is not strictly SANS-IO.
pub(crate) struct Connection<T> {
    ice_agent: IceAgent,
    agent_timeout: BoxFuture<'static, Instant>,
    state: T,

    /// The STUN servers we've been configured to use.
    stun_servers: Vec<SocketAddr>,

    /// The STUN servers we've been configured to use.
    turn_servers: Vec<SocketAddr>,

    /// The local address of our socket.
    local: SocketAddr,

    waker: Option<Waker>,
}

/// Initial state of every [`Connection`] on the client.
///
/// Clients always generate the shared key to be used for the WG tunnel and then request a connection to the gateway.
pub(crate) struct WantsRemoteCredentials {
    preshared_key: SecretKey,
}

/// State of a connection after the initial handshake.
///
/// During this phase, the peers exchange ICE candidates and perform connectivity testing.
pub(crate) struct Connecting {
    remote: PublicKey,
    preshared_key: SecretKey,

    /// The channels we've created on the relay as part of the ICE process.
    ///
    /// In order for a TURN candidate to be selected, the remote needs to be able to send us a STUN binding request (and we need to respond to it).
    /// For such a request to be relayed to us, we need to bind a channel on the remote for each discovered socket of the remote peer (i.e. every address that they _may_ send data from).
    ///
    /// Once an ICE candidate has been selected, we can either
    /// - drop all of them in case we managed to hole-punch
    /// - only carry forward the channel binding for the selected address
    channel_bindings: Vec<ChannelBinding>,

    /// Temporarily buffered events that will be returned from [`Connection::<Connecting>::poll`].
    pending_events: VecDeque<ConnectingEvent>,
}

/// State of a direct connection from a client to a gateway.
pub(crate) struct DirectClientToGateway {
    _src: SocketAddr,
    dst: SocketAddr,
    tunnel: Tunn,
    allowed_ips: IpNetworkTable<()>,
    buffered_transmits: VecDeque<crate::Transmit>,
}

/// State of a direct connection from a gateway to a client.
pub(crate) struct DirectGatewayToClient {
    _src: SocketAddr,
    dst: SocketAddr,
    tunnel: Tunn,

    // allowed_resources: ResourceTable<(ResourceDescription, DateTime<Utc>)>, // TODO: Shutdown connection if this is empty?
    translated_resource_addresses: HashMap<IpAddr, ResourceId>,

    buffered_transmits: VecDeque<crate::Transmit>,
}

impl Connection<WantsRemoteCredentials> {
    pub fn new_client_to_gateway(
        local: SocketAddr,
        stun_servers: Vec<SocketAddr>,
        turn_servers: Vec<SocketAddr>,
    ) -> Self {
        let mut ice_agent = IceAgent::new();
        ice_agent.set_controlling(true);
        add_local_host_candidate(&mut ice_agent, local);

        Self {
            ice_agent,
            agent_timeout: agent_timeout(Instant::now()).boxed(),
            state: WantsRemoteCredentials {
                preshared_key: SecretKey::new(Key(StaticSecret::random_from_rng(OsRng).to_bytes())),
            },
            stun_servers,
            turn_servers,
            local,
            waker: None,
        }
    }

    pub fn preshared_key(&self) -> SecretKey {
        self.state.preshared_key.clone()
    }

    pub fn with_remote_credentials(
        self,
        remote: PublicKey,
        gateway_credentials: IceCreds,
    ) -> Connection<Connecting> {
        let mut ice_agent = self.ice_agent;
        ice_agent.set_remote_credentials(gateway_credentials);

        tracing::info!("Transitioning connection to `Connecting`");

        Connection {
            ice_agent,
            agent_timeout: self.agent_timeout,
            state: Connecting {
                remote,
                preshared_key: self.state.preshared_key,
                channel_bindings: vec![],
                pending_events: Default::default(),
            },
            stun_servers: self.stun_servers,
            turn_servers: self.turn_servers,
            local: self.local,
            waker: self.waker,
        }
    }
}

impl Connection<Connecting> {
    pub fn new_gateway_to_client(
        preshared_key: SecretKey,
        remote: PublicKey,
        client_credentials: IceCreds,
        local: SocketAddr,
        stun_servers: Vec<SocketAddr>,
        turn_servers: Vec<SocketAddr>,
    ) -> Self {
        let mut ice_agent = IceAgent::new();
        ice_agent.set_controlling(false);
        ice_agent.set_remote_credentials(client_credentials);
        add_local_host_candidate(&mut ice_agent, local);

        Self {
            ice_agent,
            agent_timeout: agent_timeout(Instant::now()).boxed(),
            state: Connecting {
                preshared_key,
                remote,
                channel_bindings: vec![], // TODO: I think gateways should never bind channels, lets have the clients do that.
                pending_events: Default::default(),
            },
            stun_servers,
            turn_servers,
            local,
            waker: None,
        }
    }

    /// Handle an incoming packet from the given address.
    ///
    /// Whilst we are in [`Connecting`], the only traffic we care about are STUN binding requests which need to be handled by the [`IceAgent`].
    /// These can come from one of two sources:
    ///
    /// - Via a channel binding in case the remote is testing connectivity of one of our relay candidates.
    /// - Directly to our socket for server and host reflexive candidates.
    pub fn handle_input(&mut self, from: SocketAddr, packet: &[u8]) -> bool {
        if !self.accepts(from, packet) {
            return false;
        }

        // First, see if the packet is from one of our channels.
        for channel in self.state.channel_bindings.iter_mut() {
            let Some(payload) = channel.decapsulate(from, packet) else {
                continue;
            };

            let peer = channel.peer();
            return self.ice_agent_handle_packet(peer, payload);
        }

        // Second, the traffic could be a STUN binding request directly from the remote.
        self.ice_agent_handle_packet(from, packet)
    }

    pub fn add_binding(&mut self, relay: SocketAddr, binding: ChannelBinding) {
        if !self.stun_servers.contains(&relay) {
            return;
        }

        self.state.channel_bindings.push(binding);
    }

    pub fn into_established_client_to_gateway(
        self,
        src: SocketAddr,
        dst: SocketAddr,
        make_tunn: impl FnOnce(SecretKey, PublicKey) -> Tunn,
    ) -> Connection<DirectClientToGateway> {
        tracing::info!("Transitioning connection to `DirectClientToGateway`");

        let selected_candidate = self
            .ice_agent
            .local_candidates()
            .iter()
            .find(|c| c.addr() == src)
            .expect("candidate must exist");

        match selected_candidate.kind() {
            CandidateKind::ServerReflexive | CandidateKind::Host => Connection {
                ice_agent: self.ice_agent,
                agent_timeout: self.agent_timeout,
                state: DirectClientToGateway {
                    _src: src,
                    dst,
                    tunnel: make_tunn(self.state.preshared_key, self.state.remote),
                    allowed_ips: Default::default(),
                    buffered_transmits: Default::default(),
                },
                stun_servers: self.stun_servers,
                turn_servers: self.turn_servers,
                local: self.local,
                waker: self.waker,
            },
            CandidateKind::PeerReflexive => unreachable!(),
            CandidateKind::Relayed => todo!(),
        }
    }

    pub fn into_established_gateway_to_client(
        self,
        src: SocketAddr,
        dst: SocketAddr,
        make_tunn: impl FnOnce(SecretKey, PublicKey) -> Tunn,
    ) -> Connection<DirectGatewayToClient> {
        tracing::info!("Transitioning connection to `DirectGatewayToClient`");

        let selected_candidate = self
            .ice_agent
            .local_candidates()
            .iter()
            .find(|c| c.addr() == src)
            .expect("candidate must exist");

        match selected_candidate.kind() {
            CandidateKind::ServerReflexive | CandidateKind::Host => Connection {
                ice_agent: self.ice_agent,
                agent_timeout: self.agent_timeout,
                state: DirectGatewayToClient {
                    _src: src,
                    dst,
                    tunnel: make_tunn(self.state.preshared_key, self.state.remote),
                    buffered_transmits: Default::default(),
                    translated_resource_addresses: Default::default(),
                },
                stun_servers: self.stun_servers,
                turn_servers: self.turn_servers,
                local: self.local,
                waker: self.waker,
            },
            CandidateKind::PeerReflexive => unreachable!(),
            CandidateKind::Relayed => todo!(),
        }
    }

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<ConnectingEvent> {
        loop {
            if let Some(event) = self.state.pending_events.pop_front() {
                return Poll::Ready(event);
            }

            if let Some(transmit) = self.ice_agent.poll_transmit() {
                // TODO: Do we need to handle `transmit.source`?
                return Poll::Ready(ConnectingEvent::Transmit(Transmit {
                    dst: transmit.destination,
                    payload: transmit.contents.to_vec(),
                }));
            }

            match self.ice_agent.poll_event() {
                Some(IceAgentEvent::IceConnectionStateChange(new_state)) => {
                    tracing::debug!(?new_state);
                    continue;
                }
                Some(IceAgentEvent::DiscoveredRecv { source, .. }) => {
                    self.state
                        .pending_events
                        .extend(self.stun_servers.iter().copied().map(|relay| {
                            ConnectingEvent::WantChannelToPeer {
                                peer: source,
                                relay,
                            }
                        }));
                    continue;
                }
                Some(IceAgentEvent::NominatedSend {
                    source,
                    destination,
                    ..
                }) => {
                    return Poll::Ready(ConnectingEvent::Connection {
                        src: source,
                        dst: destination,
                    });
                }
                Some(IceAgentEvent::IceRestart(_)) => {}
                None => {}
            }

            if let Poll::Ready(timeout) = self.agent_timeout.poll_unpin(cx) {
                self.ice_agent.handle_timeout(timeout);
                self.agent_timeout = agent_timeout(timeout).boxed();
                continue;
            }

            self.waker = Some(cx.waker().clone());
            return Poll::Pending;
        }
    }

    /// Checks whether this connection will accept the provided packet from the given address.
    fn accepts(&self, from: SocketAddr, _: &[u8]) -> bool {
        let from_remote = self
            .ice_agent
            .remote_candidates()
            .iter()
            .any(|c| c.addr() == from);
        let stun_response = self.stun_servers.contains(&from);
        let turn_response = self.turn_servers.contains(&from);

        from_remote || stun_response || turn_response
    }

    fn ice_agent_handle_packet(&mut self, peer: SocketAddr, packet: &[u8]) -> bool {
        let Ok(DatagramRecv::Stun(stun)) = DatagramRecv::try_from(packet) else {
            tracing::warn!(%peer, "Received non-STUN message");
            return false;
        };

        if !self.ice_agent.accepts_message(&stun) {
            return false;
        }

        self.ice_agent.handle_receive(
            Instant::now(),
            Receive {
                proto: Protocol::Udp,
                source: peer,
                destination: self.local,
                contents: DatagramRecv::Stun(stun),
            },
        );

        if let Some(waker) = self.waker.take() {
            waker.wake();
        }

        true
    }
}

impl Connection<DirectClientToGateway> {
    /// Checks whether this connection will accept the provided packet from the given address.
    pub fn accepts(&self, from: SocketAddr, _: &[u8]) -> bool {
        from == self.state.dst
    }

    pub fn add_allowed_ip(&mut self, ip: IpNetwork) {
        self.state.allowed_ips.insert(ip, ());
    }

    /// Decapsulate an incoming packet.
    pub fn decapsulate<'b>(
        &mut self,
        from: SocketAddr,
        packet: &[u8],
        buf: &'b mut [u8],
    ) -> Result<Option<device_channel::Packet<'b>>, ConnlibError> {
        debug_assert_eq!(from, self.state.dst);

        match decapsulate(from, &mut self.state.tunnel, packet, buf)? {
            Either::Left(transmits) => {
                self.state.buffered_transmits.extend(transmits);
                Ok(None)
            }
            Either::Right((packet, addr)) => Ok(self.tunnel_to_device(packet, addr)),
        }
    }

    /// Encapsulates an outgoing packet.
    pub fn encapsulate<'b>(
        &mut self,
        packet: &[u8],
        buf: &'b mut [u8],
    ) -> Result<Option<(SocketAddr, &'b [u8])>, ConnlibError> {
        let packet = match self.state.tunnel.encapsulate(packet, buf) {
            TunnResult::Done => return Ok(None),
            TunnResult::Err(e) => return Err(e.into()),
            TunnResult::WriteToNetwork(b) => b,
            _ => panic!("Unexpected result from `encapsulate`"),
        };

        tracing::debug!(gateway_addr = %self.state.dst, "Encapsulated packet to resource");

        // Because this is a direct connection, we can just directly send it to the `dst` that we initially discovered.
        Ok(Some((self.state.dst, packet)))
    }

    pub fn poll_transmit(&mut self) -> Option<crate::Transmit> {
        self.state.buffered_transmits.pop_front()
    }

    pub fn update_timers(&mut self) {
        update_timers(
            &mut self.state.tunnel,
            self.state.dst,
            &mut self.state.buffered_transmits,
        )
    }

    /// Maps a WG-decapsulated packet coming in from the network to a [`device_channel::Packet`], essentially sending it to the user-space application.
    fn tunnel_to_device<'a>(
        &self,
        packet: &'a mut [u8],
        addr: impl Into<IpAddr>,
    ) -> Option<device_channel::Packet<'a>> {
        let addr = addr.into();
        let is_allowed = self.state.allowed_ips.longest_match(addr).is_some();

        if !is_allowed {
            tracing::warn!(%addr, "Received packet from peer with an not-allowed ip");

            return None;
        }

        tracing::debug!(peer = %addr, "Forwarding packet from peer to device");

        match addr {
            IpAddr::V4(_) => Some(device_channel::Packet::Ipv4(Cow::Borrowed(packet))),
            IpAddr::V6(_) => Some(device_channel::Packet::Ipv6(Cow::Borrowed(packet))),
        }
    }
}

impl Connection<DirectGatewayToClient> {
    /// Checks whether this connection will accept the provided packet from the given address.
    pub fn accepts(&self, from: SocketAddr, _: &[u8]) -> bool {
        from == self.state.dst
    }

    pub fn allow_access(&mut self, resource: ResourceDescription, expires_at: DateTime<Utc>) {
        // self.state.allowed_resources.insert((resource, expires_at));
    }

    /// Decapsulate an incoming packet.
    pub fn decapsulate<'b>(
        &mut self,
        from: SocketAddr,
        packet: &[u8],
        buf: &'b mut [u8],
    ) -> Result<Option<device_channel::Packet<'b>>, ConnlibError> {
        debug_assert_eq!(from, self.state.dst);

        match decapsulate(from, &mut self.state.tunnel, packet, buf)? {
            Either::Left(transmits) => {
                self.state.buffered_transmits.extend(transmits);
                Ok(None)
            }
            Either::Right((packet, addr)) => Ok(self.tunnel_to_device(packet, addr)),
        }
    }

    /// Encapsulates an outgoing packet.
    pub fn encapsulate<'b>(
        &mut self,
        packet: &mut [u8],
        buf: &'b mut [u8],
    ) -> Result<Option<(SocketAddr, &'b [u8])>, ConnlibError> {
        let mut packet = MutableIpPacket::new(packet).expect("TODO");

        if let Some(resource) = self.get_translation(packet.to_immutable().source()) {
            let ResourceDescription::Dns(resource) = resource else {
                tracing::error!(
                    "Control protocol error: only dns resources should have a resource_address"
                );
                return Err(ConnlibError::ControlProtocolError);
            };

            // TODO
            // match packet {
            //     MutableIpPacket::MutableIpv4Packet(ref mut p) => p.set_source(resource.ipv4),
            //     MutableIpPacket::MutableIpv6Packet(ref mut p) => p.set_source(resource.ipv6),
            // }

            packet.update_checksum();
        }

        let packet = match self.state.tunnel.encapsulate(packet.packet(), buf) {
            TunnResult::Done => return Ok(None),
            TunnResult::Err(e) => return Err(e.into()),
            TunnResult::WriteToNetwork(b) => b,
            _ => panic!("Unexpected result from `encapsulate`"),
        };

        // Because this is a direct connection, we can just directly send it to the `dst` that we initially discovered.
        Ok(Some((self.state.dst, packet)))
    }

    pub fn poll_transmit(&mut self) -> Option<crate::Transmit> {
        self.state.buffered_transmits.pop_front()
    }

    pub fn update_timers(&mut self) {
        update_timers(
            &mut self.state.tunnel,
            self.state.dst,
            &mut self.state.buffered_transmits,
        )
    }

    pub fn expire_resources(&mut self) {
        // let expire_resources = self
        //     .state
        //     .allowed_resources
        //     .values()
        //     .filter(|(_, e)| e <= &Utc::now())
        //     .cloned()
        //     .collect::<Vec<_>>();
        // {
        //     for r in expire_resources {
        //         self.state.allowed_resources.cleanup_resource(&r);
        //         self.state
        //             .translated_resource_addresses
        //             .retain(|_, &mut i| r.0.id() != i);
        //     }
        // }
    }

    /// Maps a WG-decapsulated packet coming in from the network to a [`device_channel::Packet`], essentially sending it to the user-space application.
    fn tunnel_to_device<'a>(
        &mut self,
        packet: &'a mut [u8],
        client: impl Into<IpAddr>,
    ) -> Option<device_channel::Packet<'a>> {
        let client = client.into();
        let resource = Tunn::dst_address(packet)?;

        // let (resource_desc, _) = self.state.allowed_resources.get_by_ip(resource)?;

        // let Ok((resource, _dst_port)) = get_resource_addr_and_port(
        //     &mut self.state.translated_resource_addresses,
        //     resource_desc,
        //     &client,
        //     &resource,
        // ) else {
        //     return None;
        // };
        // update_packet(packet, resource);
        //
        // tracing::debug!(%client, %resource, "Forwarding packet from peer to device");
        //
        // match client {
        //     IpAddr::V4(_) => Some(device_channel::Packet::Ipv4(Cow::Borrowed(packet))),
        //     IpAddr::V6(_) => Some(device_channel::Packet::Ipv6(Cow::Borrowed(packet))),
        // }

        None
    }

    fn get_translation(&self, ip: IpAddr) -> Option<ResourceDescription> {
        let id = self.state.translated_resource_addresses.get(&ip)?;
        // let (desc, _) = self.state.allowed_resources.get_by_id(id)?;

        // Some(desc.clone())

        None
    }
}

/// Decapsulate an incoming packet using the provided [`Tunn`].
///
/// ## Implementation note regarding allocations
///
/// In almost all cases, [`Tunn::decapsulate`] will return [`TunnResult::WriteToTunnelV4`] or [`TunnResult::WriteToTunnelV6`].
/// In case there isn't an activate session when calling [`Tunn::`**en**`capsulate`](Tunn::encapsulate), the packet is queued for later.
/// It may then be returned when calling [`Tunn::decapsulate`] as [`TunnResult::WriteToNetwork`] (together with certain WG control messages).
///
/// Consequently, the code branch of handling [`TunnResult::WriteToNetwork`] after [`Tunn::decapsulate`] is rare enough that we deem it okay to allocate the packets.
/// As per the API docs of [`Tunn::decapsulate`], we MUST call [`Tunn::decapsulate`] until it returns [`TunnResult::Done`].
///
/// It is much easier for the upper layers built on top of to handle all packets that need to be sent in one go rather than calling this function repeatedly.
#[allow(clippy::type_complexity)]
fn decapsulate<'b>(
    sender: SocketAddr,
    tunnel: &mut Tunn,
    packet: &[u8],
    buf: &'b mut [u8],
) -> Result<Either<Vec<crate::Transmit>, (&'b mut [u8], IpAddr)>, ConnlibError> {
    match tunnel.decapsulate(None, packet, buf) {
        TunnResult::Done => Ok(Either::Left(vec![])),
        TunnResult::Err(e) => Err(e.into()),
        TunnResult::WriteToTunnelV4(packet, addr) => Ok(Either::Right((packet, addr.into()))),
        TunnResult::WriteToTunnelV6(packet, addr) => Ok(Either::Right((packet, addr.into()))),
        TunnResult::WriteToNetwork(bytes) => {
            let mut transmits = vec![crate::Transmit {
                dst: sender,
                payload: bytes.to_vec(),
            }];

            let mut buf = Box::new([0u8; MAX_UDP_SIZE]);

            while let TunnResult::WriteToNetwork(packet) =
                tunnel.decapsulate(None, &[], buf.as_mut_slice())
            {
                transmits.push(crate::Transmit {
                    dst: sender,
                    payload: packet.to_vec(),
                })
            }

            Ok(Either::Left(transmits))
        }
    }
}

fn get_resource_addr_and_port(
    translated_resource_addresses: &mut HashMap<IpAddr, ResourceId>,
    resource: &ResourceDescription,
    addr: &IpAddr,
    dst: &IpAddr,
) -> Result<(IpAddr, Option<u16>), ConnlibError> {
    match resource {
        ResourceDescription::Dns(r) => {
            let mut address = r.address.split(':');
            let Some(dst_addr) = address.next() else {
                tracing::error!("invalid DNS name for resource: {}", r.address);
                return Err(ConnlibError::InvalidResource);
            };
            let Ok(mut dst_addr) = (dst_addr, 0).to_socket_addrs() else {
                tracing::warn!(%addr, "Couldn't resolve name");
                return Err(ConnlibError::InvalidResource);
            };
            let Some(dst_addr) = dst_addr.find_map(|d| get_matching_version_ip(addr, &d.ip()))
            else {
                tracing::warn!(%addr, "Couldn't resolve name addr");
                return Err(ConnlibError::InvalidResource);
            };
            translated_resource_addresses.insert(dst_addr, r.id);
            Ok((
                dst_addr,
                address
                    .next()
                    .map(str::parse::<u16>)
                    .and_then(std::result::Result::ok),
            ))
        }
        ResourceDescription::Cidr(r) => {
            if r.address.contains(*dst) {
                Ok((
                    get_matching_version_ip(addr, dst).ok_or(ConnlibError::InvalidResource)?,
                    None,
                ))
            } else {
                tracing::warn!(
                    "client tried to hijack the tunnel for range outside what it's allowed."
                );
                Err(ConnlibError::InvalidSource)
            }
        }
    }
}

#[inline(always)]
fn update_packet(packet: &mut [u8], dst_addr: IpAddr) {
    let Some(mut pkt) = MutableIpPacket::new(packet) else {
        return;
    };
    pkt.set_dst(dst_addr);
    pkt.update_checksum();
}

fn get_matching_version_ip(addr: &IpAddr, ip: &IpAddr) -> Option<IpAddr> {
    ((addr.is_ipv4() && ip.is_ipv4()) || (addr.is_ipv6() && ip.is_ipv6())).then_some(*ip)
}

fn update_timers(tunn: &mut Tunn, dst: SocketAddr, queue: &mut VecDeque<crate::Transmit>) {
    /// [`boringtun`] requires us to pass buffers in where it can construct its packets.
    ///
    /// When updating the timers, the largest packet that we may have to send is `148` bytes as per `HANDSHAKE_INIT_SZ` constant in [`boringtun`].
    const MAX_SCRATCH_SPACE: usize = 148;

    let mut buf = [0u8; MAX_SCRATCH_SPACE];

    match tunn.update_timers(&mut buf) {
        TunnResult::Done => {}
        TunnResult::Err(e) => {
            // TODO: Handle this error. I think it can only be an expired connection so we should return a very specific error to the caller to make this easy to handle!
            panic!("{e:?}")
        }
        TunnResult::WriteToNetwork(b) => queue.push_back(crate::Transmit {
            dst,
            payload: b.to_vec(),
        }),
        _ => panic!("Unexpected result from update_timers"),
    };
}

impl<T> Connection<T> {
    pub fn add_remote_candidate(&mut self, candidate: Candidate) {
        tracing::trace!(%candidate, "Received remote candidate");

        self.ice_agent.add_remote_candidate(candidate);
    }

    pub fn add_local_candidate(&mut self, server: SocketAddr, candidate: Candidate) -> bool {
        if !self.stun_servers.contains(&server) && !self.turn_servers.contains(&server) {
            return false;
        }

        self.ice_agent.add_local_candidate(candidate)
    }

    pub fn ice_credentials(&self) -> IceCreds {
        self.ice_agent.local_credentials().clone()
    }
}

#[derive(Debug)]
pub(crate) enum ConnectingEvent {
    WantChannelToPeer { relay: SocketAddr, peer: SocketAddr },
    Connection { src: SocketAddr, dst: SocketAddr },
    Transmit(Transmit),
}

async fn agent_timeout(deadline: Instant) -> Instant {
    tokio::time::sleep_until(deadline.into()).await;

    deadline
}

fn add_local_host_candidate(ice_agent: &mut IceAgent, local: SocketAddr) {
    match Candidate::host(local, Protocol::Udp) {
        Ok(c) => {
            let is_new = ice_agent.add_local_candidate(c);
            debug_assert!(is_new, "host candidate should always be new")
        }
        Err(e) => {
            tracing::warn!(%local, "Failed to add local socket address as host candidate: {e}")
        }
    }
}

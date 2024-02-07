use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::PublicKey;
use boringtun::{noise::rate_limiter::RateLimiter, x25519::StaticSecret};
use core::{fmt, slice};
use pnet_packet::ipv4::MutableIpv4Packet;
use pnet_packet::ipv6::MutableIpv6Packet;
use pnet_packet::Packet;
use rand::random;
use secrecy::{ExposeSecret, Secret};
use std::hash::Hash;
use std::marker::PhantomData;
use std::time::{Duration, Instant};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    net::SocketAddr,
    sync::Arc,
};
use str0m::ice::{IceAgent, IceAgentEvent, IceCreds, StunMessage, StunPacket};
use str0m::net::Protocol;
use str0m::{Candidate, CandidateKind, IceConnectionState};

use crate::allocation::{Allocation, Socket};
use crate::index::IndexLfsr;
use crate::info::ConnectionInfo;
use crate::stun_binding::StunBinding;
use crate::utils::earliest;
use crate::{IpPacket, MutableIpPacket};
use boringtun::noise::errors::WireGuardError;
use std::borrow::Cow;
use std::iter;
use stun_codec::rfc5389::attributes::{Realm, Username};

// Note: Taken from boringtun
const HANDSHAKE_RATE_LIMIT: u64 = 100;

/// How often wireguard will send a keep-alive packet.
pub(crate) const WIREGUARD_KEEP_ALIVE: u16 = 5;

const MAX_UDP_SIZE: usize = (1 << 16) - 1;

/// Manages a set of wireguard connections for a server.
pub type ServerNode<TId> = Node<Server, TId>;
/// Manages a set of wireguard connections for a client.
pub type ClientNode<TId> = Node<Client, TId>;

pub enum Server {}
pub enum Client {}

/// A node within a `snownet` network maintains connections to several other nodes.
pub struct Node<T, TId> {
    private_key: StaticSecret,
    index: IndexLfsr,
    rate_limiter: Arc<RateLimiter>,
    host_candidates: HashSet<Candidate>,
    buffered_transmits: VecDeque<Transmit<'static>>,

    next_rate_limiter_reset: Option<Instant>,

    bindings: HashMap<SocketAddr, StunBinding>,
    allocations: HashMap<SocketAddr, Allocation>,

    connections: Connections<TId>,
    pending_events: VecDeque<Event<TId>>,

    last_now: Instant,

    buffer: Box<[u8; MAX_UDP_SIZE]>,

    marker: PhantomData<T>,
}

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("Unknown interface")]
    UnknownInterface,
    #[error("Failed to decapsulate: {0:?}")] // TODO: Upstream an std::error::Error impl
    Decapsulate(boringtun::noise::errors::WireGuardError),
    #[error("Failed to encapsulate: {0:?}")]
    Encapsulate(boringtun::noise::errors::WireGuardError),
    #[error("Unmatched packet")]
    UnmatchedPacket,
    #[error("Not connected")]
    NotConnected,
    #[error("Invalid local address: {0}")]
    BadLocalAddress(#[from] str0m::error::IceError),
}

impl<T, TId> Node<T, TId>
where
    TId: Eq + Hash + Copy + fmt::Display,
{
    pub fn new(private_key: StaticSecret, now: Instant) -> Self {
        let public_key = &(&private_key).into();
        Self {
            private_key,
            marker: Default::default(),
            index: IndexLfsr::default(),
            rate_limiter: Arc::new(RateLimiter::new(public_key, HANDSHAKE_RATE_LIMIT)),
            host_candidates: HashSet::default(),
            buffered_transmits: VecDeque::default(),
            next_rate_limiter_reset: None,
            pending_events: VecDeque::default(),
            buffer: Box::new([0u8; MAX_UDP_SIZE]),
            bindings: HashMap::default(),
            allocations: HashMap::default(),
            last_now: now,
            connections: Default::default(),
        }
    }

    /// Lazily retrieve stats of all connections.
    pub fn stats(&self) -> impl Iterator<Item = (TId, ConnectionInfo)> + '_ {
        self.connections.stats(self.last_now)
    }

    /// Add an address as a `host` candidate.
    ///
    /// For most network topologies, [`snownet`](crate) will automatically discover host candidates via the traffic to the configured STUN and TURN servers.
    /// However, in topologies like the one below, we cannot discover that there is a more optimal link between BACKEND and DB.
    /// For those situations, users need to manually add the address of the direct link in order for [`snownet`](crate) to establish a connection.
    ///
    /// ```text
    ///        ┌──────┐          ┌──────┐
    ///        │ STUN ├─┐      ┌─┤ TURN │
    ///        └──────┘ │      │ └──────┘
    ///                 │      │
    ///               ┌─┴──────┴─┐
    ///      ┌────────┤   WAN    ├───────┐
    ///      │        └──────────┘       │
    /// ┌────┴─────┐                  ┌──┴───┐
    /// │    FW    │                  │  FW  │
    /// └────┬─────┘                  └──┬───┘
    ///      │            ┌──┐           │
    ///  ┌───┴─────┐      │  │         ┌─┴──┐
    ///  │ BACKEND ├──────┤FW├─────────┤ DB │
    ///  └─────────┘      │  │         └────┘
    ///                   └──┘
    /// ```
    pub fn add_local_host_candidate(&mut self, address: SocketAddr) -> Result<(), Error> {
        self.add_local_as_host_candidate(address)?;

        Ok(())
    }

    pub fn add_remote_candidate(&mut self, id: TId, candidate: String) {
        let candidate = match Candidate::from_sdp_string(&candidate) {
            Ok(c) => c,
            Err(e) => {
                tracing::debug!("Failed to parse candidate: {e}");
                return;
            }
        };

        if let Some(agent) = self.connections.agent_mut(id) {
            agent.add_remote_candidate(candidate.clone());
        }

        // Each remote candidate might be source of traffic: Bind a channel for each.
        if let Some(conn) = self.connections.get_established_mut(&id) {
            for relay in &conn.turn_servers {
                let Some(allocation) = self.allocations.get_mut(relay) else {
                    continue;
                };

                allocation.bind_channel(candidate.addr(), self.last_now);
            }
        }
    }

    /// Decapsulate an incoming packet.
    ///
    /// # Returns
    ///
    /// - `Ok(None)` if the packet was handled internally, for example, a response from a TURN server.
    /// - `Ok(Some)` if the packet was an encrypted wireguard packet from a peer.
    ///   The `Option` contains the connection on which the packet was decrypted.
    pub fn decapsulate<'s>(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
        buffer: &'s mut [u8],
    ) -> Result<Option<(TId, MutableIpPacket<'s>)>, Error> {
        self.add_local_as_host_candidate(local)?;

        // First, check if a `StunBinding` wants the packet
        if let Some(binding) = self.bindings.get_mut(&from) {
            if binding.handle_input(from, local, packet, now) {
                return Ok(None);
            }
        }

        // Next, check if an `Allocation` wants the packet
        if let Some(allocation) = self.allocations.get_mut(&from) {
            if allocation.handle_input(from, local, packet, now) {
                return Ok(None);
            };
        }

        // Next, the packet could be a channel-data message, unwrap if that is the case.
        let (from, packet, relay_socket) = self
            .allocations
            .get_mut(&from)
            .and_then(|a| {
                let (from, packet, socket) = a.decapsulate(from, packet, now)?;

                Some((from, packet, Some(socket)))
            })
            .unwrap_or((from, packet, None));

        // Next: If we can parse the message as a STUN message, cycle through all agents to check which one it is for.
        if let Ok(message) = StunMessage::parse(packet) {
            for (_, agent) in self.connections.agents_mut() {
                if agent.accepts_message(&message) {
                    agent.handle_packet(
                        now,
                        StunPacket {
                            proto: Protocol::Udp,
                            source: from,
                            destination: relay_socket.map(|s| s.address()).unwrap_or(local),
                            message,
                        },
                    );
                    return Ok(None);
                }
            }
        }

        for (id, conn) in self.connections.iter_established_mut() {
            if !conn.accepts(from) {
                continue;
            }

            return match conn.tunnel.decapsulate(None, packet, buffer) {
                TunnResult::Done => Ok(None),
                TunnResult::Err(e) => Err(Error::Decapsulate(e)),

                // For WriteToTunnel{V4,V6}, boringtun returns the source IP of the packet that was tunneled to us.
                // I am guessing this was done for convenience reasons.
                // In our API, we parse the packets directly as an IpPacket.
                // Thus, the caller can query whatever data they'd like, not just the source IP so we don't return it in addition.
                TunnResult::WriteToTunnelV4(packet, ip) => {
                    conn.set_remote_from_wg_activity(local, from, relay_socket);

                    let ipv4_packet =
                        MutableIpv4Packet::new(packet).expect("boringtun verifies validity");
                    debug_assert_eq!(ipv4_packet.get_source(), ip);

                    Ok(Some((id, ipv4_packet.into())))
                }
                TunnResult::WriteToTunnelV6(packet, ip) => {
                    conn.set_remote_from_wg_activity(local, from, relay_socket);

                    let ipv6_packet =
                        MutableIpv6Packet::new(packet).expect("boringtun verifies validity");
                    debug_assert_eq!(ipv6_packet.get_source(), ip);

                    Ok(Some((id, ipv6_packet.into())))
                }

                // During normal operation, i.e. when the tunnel is active, decapsulating a packet straight yields the decrypted packet.
                // However, in case `Tunn` has buffered packets, they may be returned here instead.
                // This should be fairly rare which is why we just allocate these and return them from `poll_transmit` instead.
                // Overall, this results in a much nicer API for our caller and should not affect performance.
                TunnResult::WriteToNetwork(bytes) => {
                    conn.set_remote_from_wg_activity(local, from, relay_socket);

                    self.buffered_transmits.extend(conn.encapsulate(
                        bytes,
                        &mut self.allocations,
                        now,
                    ));

                    while let TunnResult::WriteToNetwork(packet) =
                        conn.tunnel
                            .decapsulate(None, &[], self.buffer.as_mut_slice())
                    {
                        self.buffered_transmits.extend(conn.encapsulate(
                            packet,
                            &mut self.allocations,
                            now,
                        ));
                    }

                    Ok(None)
                }
            };
        }

        Err(Error::UnmatchedPacket)
    }

    /// Encapsulate an outgoing IP packet.
    ///
    /// Wireguard is an IP tunnel, so we "enforce" that only IP packets are sent through it.
    /// We say "enforce" an [`IpPacket`] can be created from an (almost) arbitrary byte buffer at virtually no cost.
    /// Nevertheless, using [`IpPacket`] in our API has good documentation value.
    pub fn encapsulate<'s>(
        &'s mut self,
        connection: TId,
        packet: IpPacket<'_>,
    ) -> Result<Option<Transmit<'s>>, Error> {
        let conn = self
            .connections
            .get_established_mut(&connection)
            .ok_or(Error::NotConnected)?;

        let (header, payload) = self.buffer.as_mut().split_at_mut(4);

        let packet_len = match conn.tunnel.encapsulate(packet.packet(), payload) {
            TunnResult::Done => return Ok(None),
            TunnResult::Err(e) => return Err(Error::Encapsulate(e)),
            TunnResult::WriteToNetwork(packet) => packet.len(),
            TunnResult::WriteToTunnelV4(_, _) | TunnResult::WriteToTunnelV6(_, _) => {
                unreachable!("never returned from encapsulate")
            }
        };

        let packet = &payload[..packet_len];

        match conn.peer_socket.ok_or(Error::NotConnected)? {
            PeerSocket::Direct {
                dest: remote,
                source,
            } => Ok(Some(Transmit {
                src: Some(source),
                dst: remote,
                payload: Cow::Borrowed(packet),
            })),
            PeerSocket::Relay { relay, dest: peer } => {
                let Some(allocation) = self.allocations.get_mut(&relay) else {
                    tracing::warn!(%relay, "No allocation");
                    return Ok(None);
                };
                let Some(total_length) =
                    allocation.encode_to_slice(peer, packet, header, self.last_now)
                else {
                    tracing::warn!(%peer, "No channel");
                    return Ok(None);
                };

                // Safety: We split the slice before, but the borrow-checker doesn't allow us to re-borrow `self.buffer`.
                // Safety: `total_length` < `buffer.len()` because it is returned from `Tunn::encapsulate`.
                let channel_data_packet =
                    unsafe { slice::from_raw_parts(header.as_ptr(), total_length) };

                Ok(Some(Transmit {
                    src: None,
                    dst: relay,
                    payload: Cow::Borrowed(channel_data_packet),
                }))
            }
        }
    }

    /// Returns a pending [`Event`] from the pool.
    pub fn poll_event(&mut self) -> Option<Event<TId>> {
        let binding_events = self.bindings.iter_mut().flat_map(|(server, binding)| {
            iter::from_fn(|| binding.poll_event().map(|e| (*server, e)))
        });
        let allocation_events = self
            .allocations
            .iter_mut()
            .flat_map(|(server, allocation)| {
                iter::from_fn(|| allocation.poll_event().map(|e| (*server, e)))
            });

        for (server, event) in binding_events.chain(allocation_events) {
            match event {
                CandidateEvent::New(candidate) => {
                    add_candidates(
                        server,
                        candidate,
                        &mut self.connections,
                        &mut self.pending_events,
                    );
                }
            }
        }

        let mut failed_connections = vec![];

        for (id, conn) in self.connections.iter_established_mut() {
            while let Some(event) = conn.agent.poll_event() {
                match event {
                    IceAgentEvent::DiscoveredRecv { source, .. } => {
                        conn.possible_sockets.insert(source);
                    }
                    IceAgentEvent::IceConnectionStateChange(IceConnectionState::Disconnected) => {
                        failed_connections.push(id);
                    }
                    IceAgentEvent::NominatedSend {
                        destination,
                        source,
                        ..
                    } => {
                        let candidate = conn
                            .agent
                            .local_candidates()
                            .iter()
                            .find(|c| c.addr() == source)
                            .expect("to only nominate existing candidates");

                        let remote_socket = match candidate.kind() {
                            CandidateKind::Relayed => {
                                let relay =
                                    self.allocations.iter().find_map(|(relay, allocation)| {
                                        allocation.has_socket(source).then_some(*relay)
                                    });

                                let Some(relay) = relay else {
                                    debug_assert!(
                                        false,
                                        "Should only nominate candidates from known relays"
                                    );
                                    continue;
                                };

                                PeerSocket::Relay {
                                    relay,
                                    dest: destination,
                                }
                            }
                            CandidateKind::ServerReflexive | CandidateKind::Host => {
                                PeerSocket::Direct {
                                    dest: destination,
                                    source,
                                }
                            }
                            CandidateKind::PeerReflexive => {
                                unreachable!("local candidate is never `PeerReflexive`")
                            }
                        };

                        if conn.peer_socket != Some(remote_socket) {
                            tracing::debug!(old = ?conn.peer_socket, new = ?remote_socket, "Updating remote socket");
                            conn.peer_socket = Some(remote_socket);
                            return Some(Event::ConnectionEstablished(id));
                        }
                    }
                    _ => {}
                }
            }
        }

        for conn in failed_connections {
            self.connections.established.remove(&conn);
            self.pending_events.push_back(Event::ConnectionFailed(conn));
        }

        self.pending_events.pop_front()
    }

    /// Returns, when [`Node::handle_timeout`] should be called next.
    ///
    /// This function only takes `&mut self` because it caches certain computations internally.
    /// The returned timestamp will **not** change unless other state is modified.
    pub fn poll_timeout(&mut self) -> Option<Instant> {
        let mut connection_timeout = None;

        for (_, c) in self.connections.iter_established_mut() {
            connection_timeout = earliest(connection_timeout, c.poll_timeout());
        }
        for b in self.bindings.values_mut() {
            connection_timeout = earliest(connection_timeout, b.poll_timeout());
        }
        for a in self.allocations.values_mut() {
            connection_timeout = earliest(connection_timeout, a.poll_timeout());
        }

        earliest(connection_timeout, self.next_rate_limiter_reset)
    }

    /// Advances time within the [`Node`].
    ///
    /// This advances time within the ICE agent, updates timers within all wireguard connections as well as resets wireguard's rate limiter (if necessary).
    pub fn handle_timeout(&mut self, now: Instant) {
        self.last_now = now;

        let mut expired_connections = vec![];

        for (id, c) in self.connections.iter_established_mut() {
            match c.handle_timeout(now, &mut self.allocations) {
                Ok(Some(transmit)) => {
                    self.buffered_transmits.push_back(transmit);
                }
                Err(WireGuardError::ConnectionExpired) => {
                    expired_connections.push(id);
                }
                Err(e) => {
                    tracing::warn!(%id, ?e);
                }
                _ => {}
            };
        }

        for conn in expired_connections {
            self.connections.established.remove(&conn);
            self.pending_events.push_back(Event::ConnectionFailed(conn))
        }

        for binding in self.bindings.values_mut() {
            binding.handle_timeout(now);
        }

        for allocation in self.allocations.values_mut() {
            allocation.handle_timeout(now);
        }

        let next_reset = *self.next_rate_limiter_reset.get_or_insert(now);

        if now >= next_reset {
            self.rate_limiter.reset_count();
            self.next_rate_limiter_reset = Some(now + Duration::from_secs(1));
        }

        let stale_connections = self
            .connections
            .initial
            .iter()
            .filter_map(|(id, conn)| {
                (now.duration_since(conn.created_at) >= Duration::from_secs(10)).then_some(*id)
            })
            .collect::<Vec<_>>();

        for conn in stale_connections {
            self.connections.initial.remove(&conn);
            self.pending_events.push_back(Event::ConnectionFailed(conn));
        }
    }

    /// Returns buffered data that needs to be sent on the socket.
    pub fn poll_transmit(&mut self) -> Option<Transmit<'static>> {
        for (_, conn) in self.connections.iter_established_mut() {
            if let Some(transmit) = conn.poll_transmit(&mut self.allocations, self.last_now) {
                return Some(transmit);
            }
        }

        for binding in self.bindings.values_mut() {
            if let Some(transmit) = binding.poll_transmit() {
                return Some(transmit);
            }
        }

        for allocation in self.allocations.values_mut() {
            if let Some(transmit) = allocation.poll_transmit() {
                return Some(transmit);
            }
        }

        self.buffered_transmits.pop_front()
    }

    fn init_connection(
        &mut self,
        mut agent: IceAgent,
        remote: PublicKey,
        key: [u8; 32],
        allowed_stun_servers: HashSet<SocketAddr>,
        allowed_turn_servers: HashSet<SocketAddr>,
    ) -> Connection {
        agent.handle_timeout(self.last_now);

        Connection {
            agent,
            tunnel: Tunn::new(
                self.private_key.clone(),
                remote,
                Some(key),
                Some(WIREGUARD_KEEP_ALIVE),
                self.index.next(),
                Some(self.rate_limiter.clone()),
            ),
            stun_servers: allowed_stun_servers,
            turn_servers: allowed_turn_servers,
            next_timer_update: self.last_now,
            peer_socket: None,
            possible_sockets: HashSet::default(),
            last_seen: None,
        }
    }

    /// Attempt to add the `local` address as a host candidate.
    ///
    /// Receiving traffic on a certain interface means we at least have a connection to a relay via this interface.
    /// Thus, it is also a viable interface to attempt a connection to a gateway.
    fn add_local_as_host_candidate(&mut self, local: SocketAddr) -> Result<(), Error> {
        let host_candidate = Candidate::host(local, Protocol::Udp)?;

        let is_new = self.host_candidates.insert(host_candidate.clone());

        if !is_new {
            return Ok(());
        }

        for (conn, agent) in self.connections.agents_mut() {
            add_local_candidate(
                conn,
                agent,
                host_candidate.clone(),
                &mut self.pending_events,
            );
        }

        Ok(())
    }
}

impl<TId> Node<Client, TId>
where
    TId: Eq + Hash + Copy + fmt::Display,
{
    /// Create a new connection indexed by the given ID.
    ///
    /// Out of all configured STUN and TURN servers, the connection will only use the ones provided here.
    /// The returned [`Offer`] must be passed to the remote via a signalling channel.
    pub fn new_connection(
        &mut self,
        id: TId,
        allowed_stun_servers: HashSet<SocketAddr>,
        allowed_turn_servers: HashSet<(SocketAddr, String, String, String)>,
    ) -> Offer {
        if self.connections.initial.remove(&id).is_some() {
            tracing::info!(%id, "Replacing existing initial connection");
        };

        if self.connections.established.remove(&id).is_some() {
            tracing::info!(%id, "Replacing existing established connection");
        };

        self.upsert_stun_servers(&allowed_stun_servers);
        self.upsert_turn_servers(&allowed_turn_servers);

        let allowed_turn_servers = allowed_turn_servers
            .iter()
            .map(|(server, _, _, _)| server)
            .copied()
            .collect();

        let mut agent = IceAgent::new();
        agent.set_controlling(true);

        self.seed_agent_with_local_candidates(
            id,
            &mut agent,
            &allowed_stun_servers,
            &allowed_turn_servers,
        );

        let session_key = Secret::new(random());
        let ice_creds = agent.local_credentials();

        let params = Offer {
            session_key: session_key.clone(),
            credentials: Credentials {
                username: ice_creds.ufrag.clone(),
                password: ice_creds.pass.clone(),
            },
        };

        let existing = self.connections.initial.insert(
            id,
            InitialConnection {
                agent,
                session_key,
                stun_servers: allowed_stun_servers,
                turn_servers: allowed_turn_servers,
                created_at: self.last_now,
            },
        );

        debug_assert!(existing.is_none());

        params
    }

    /// Accept an [`Answer`] from the remote for a connection previously created via [`Node::new_connection`].
    pub fn accept_answer(&mut self, id: TId, remote: PublicKey, answer: Answer) {
        let Some(initial) = self.connections.initial.remove(&id) else {
            debug_assert!(false, "No initial connection to accept answer for");
            return;
        };

        let mut agent = initial.agent;
        agent.set_remote_credentials(IceCreds {
            ufrag: answer.credentials.username,
            pass: answer.credentials.password,
        });

        let connection = self.init_connection(
            agent,
            remote,
            *initial.session_key.expose_secret(),
            initial.stun_servers,
            initial.turn_servers,
        );

        let existing = self.connections.established.insert(id, connection);

        debug_assert!(existing.is_none());
    }
}

impl<TId> Node<Server, TId>
where
    TId: Eq + Hash + Copy + fmt::Display,
{
    /// Accept a new connection indexed by the given ID.
    ///
    /// Out of all configured STUN and TURN servers, the connection will only use the ones provided here.
    /// The returned [`Answer`] must be passed to the remote via a signalling channel.
    pub fn accept_connection(
        &mut self,
        id: TId,
        offer: Offer,
        remote: PublicKey,
        allowed_stun_servers: HashSet<SocketAddr>,
        allowed_turn_servers: HashSet<(SocketAddr, String, String, String)>,
    ) -> Answer {
        debug_assert!(
            !self.connections.initial.contains_key(&id),
            "server to not use `initial_connections`"
        );

        if self.connections.established.remove(&id).is_some() {
            tracing::info!(%id, "Replacing existing established connection");
        };

        self.upsert_stun_servers(&allowed_stun_servers);
        self.upsert_turn_servers(&allowed_turn_servers);

        let allowed_turn_servers = allowed_turn_servers
            .iter()
            .map(|(server, _, _, _)| server)
            .copied()
            .collect();

        let mut agent = IceAgent::new();
        agent.set_controlling(false);
        agent.set_remote_credentials(IceCreds {
            ufrag: offer.credentials.username,
            pass: offer.credentials.password,
        });
        let answer = Answer {
            credentials: Credentials {
                username: agent.local_credentials().ufrag.clone(),
                password: agent.local_credentials().pass.clone(),
            },
        };

        self.seed_agent_with_local_candidates(
            id,
            &mut agent,
            &allowed_stun_servers,
            &allowed_turn_servers,
        );

        let connection = self.init_connection(
            agent,
            remote,
            *offer.session_key.expose_secret(),
            allowed_stun_servers,
            allowed_turn_servers,
        );
        let existing = self.connections.established.insert(id, connection);

        debug_assert!(existing.is_none());

        answer
    }
}

impl<T, TId> Node<T, TId>
where
    TId: Eq + Hash + Copy + fmt::Display,
{
    fn upsert_stun_servers(&mut self, servers: &HashSet<SocketAddr>) {
        for server in servers {
            if !self.bindings.contains_key(server) {
                tracing::debug!(address = %server, "Adding new STUN server");

                self.bindings
                    .insert(*server, StunBinding::new(*server, self.last_now));
            }
        }
    }

    fn upsert_turn_servers(&mut self, servers: &HashSet<(SocketAddr, String, String, String)>) {
        for (server, username, password, realm) in servers {
            let Ok(username) = Username::new(username.to_owned()) else {
                tracing::debug!(%username, "Invalid TURN username");
                continue;
            };
            let Ok(realm) = Realm::new(realm.to_owned()) else {
                tracing::debug!(%realm, "Invalid TURN realm");
                continue;
            };

            if !self.allocations.contains_key(server) {
                tracing::debug!(address = %server, "Adding new TURN server");

                self.allocations.insert(
                    *server,
                    Allocation::new(*server, username, password.clone(), realm, self.last_now),
                );
            }
        }
    }

    fn seed_agent_with_local_candidates(
        &mut self,
        connection: TId,
        agent: &mut IceAgent,
        allowed_stun_servers: &HashSet<SocketAddr>,
        allowed_turn_servers: &HashSet<SocketAddr>,
    ) {
        for candidate in self.host_candidates.iter().cloned() {
            add_local_candidate(connection, agent, candidate, &mut self.pending_events);
        }

        for candidate in self.bindings.iter().filter_map(|(server, binding)| {
            let candidate = allowed_stun_servers
                .contains(server)
                .then(|| binding.candidate())??;

            Some(candidate)
        }) {
            add_local_candidate(
                connection,
                agent,
                candidate.clone(),
                &mut self.pending_events,
            );
        }

        for candidate in self
            .allocations
            .iter()
            .flat_map(|(server, allocation)| {
                allowed_turn_servers
                    .contains(server)
                    .then(|| allocation.current_candidates())
            })
            .flatten()
        {
            add_local_candidate(
                connection,
                agent,
                candidate.clone(),
                &mut self.pending_events,
            );
        }
    }
}

struct Connections<TId> {
    initial: HashMap<TId, InitialConnection>,
    established: HashMap<TId, Connection>,
}

impl<TId> Default for Connections<TId> {
    fn default() -> Self {
        Self {
            initial: Default::default(),
            established: Default::default(),
        }
    }
}

impl<TId> Connections<TId>
where
    TId: Eq + Hash + Copy,
{
    fn stats(&self, now: Instant) -> impl Iterator<Item = (TId, ConnectionInfo)> + '_ {
        self.established.iter().map(move |(id, c)| {
            (
                *id,
                ConnectionInfo {
                    last_seen: c.last_seen,
                    generated_at: now,
                },
            )
        })
    }

    fn agent_mut(&mut self, id: TId) -> Option<&mut IceAgent> {
        let maybe_initial_connection = self.initial.get_mut(&id).map(|i| &mut i.agent);
        let maybe_established_connection = self.established.get_mut(&id).map(|c| &mut c.agent);

        maybe_initial_connection.or(maybe_established_connection)
    }

    fn agents_mut(&mut self) -> impl Iterator<Item = (TId, &mut IceAgent)> {
        let initial_agents = self.initial.iter_mut().map(|(id, c)| (*id, &mut c.agent));
        let negotiated_agents = self
            .established
            .iter_mut()
            .map(|(id, c)| (*id, &mut c.agent));

        initial_agents.chain(negotiated_agents)
    }

    fn get_established_mut(&mut self, id: &TId) -> Option<&mut Connection> {
        self.established.get_mut(id)
    }

    fn iter_established_mut(&mut self) -> impl Iterator<Item = (TId, &mut Connection)> {
        self.established.iter_mut().map(|(id, conn)| (*id, conn))
    }
}

/// Wraps the message as a channel data message via the relay, iff:
///
/// - `relay` is in fact a relay
/// - We have an allocation on the relay
/// - There is a channel bound to the provided peer
fn encode_as_channel_data(
    relay: SocketAddr,
    dest: SocketAddr,
    contents: &[u8],
    allocations: &mut HashMap<SocketAddr, Allocation>,
    now: Instant,
) -> Result<Transmit<'static>, EncodeError> {
    let allocation = allocations
        .get_mut(&relay)
        .ok_or(EncodeError::NoAllocation)?;
    let payload = allocation
        .encode_to_vec(dest, contents, now)
        .ok_or(EncodeError::NoChannel)?;

    Ok(Transmit {
        src: None,
        dst: relay,
        payload: Cow::Owned(payload),
    })
}

#[derive(Debug)]
enum EncodeError {
    NoAllocation,
    NoChannel,
}

fn add_candidates<TId>(
    server: SocketAddr,
    candidate: Candidate,
    connections: &mut Connections<TId>,
    pending_events: &mut VecDeque<Event<TId>>,
) where
    TId: Copy + fmt::Display,
{
    let initial_connections = connections
        .initial
        .iter_mut()
        .map(|(id, c)| (*id, &c.stun_servers, &c.turn_servers, &mut c.agent));
    let established_connections = connections
        .established
        .iter_mut()
        .map(|(id, c)| (*id, &c.stun_servers, &c.turn_servers, &mut c.agent));

    for (id, allowed_stun, allowed_turn, agent) in
        initial_connections.chain(established_connections)
    {
        match candidate.kind() {
            CandidateKind::ServerReflexive => {
                if (!allowed_stun.contains(&server)) && (!allowed_turn.contains(&server)) {
                    tracing::debug!(%id, %server, ?allowed_stun, ?allowed_turn, "Not adding srflx candidate");
                    continue;
                }
            }
            CandidateKind::Relayed => {
                if !allowed_turn.contains(&server) {
                    tracing::debug!(%id, %server, ?allowed_turn, "Not adding relay candidate");

                    continue;
                }
            }
            CandidateKind::PeerReflexive | CandidateKind::Host => continue,
        }

        add_local_candidate(id, agent, candidate.clone(), pending_events);
    }
}

fn add_local_candidate<TId>(
    id: TId,
    agent: &mut IceAgent,
    candidate: Candidate,
    pending_events: &mut VecDeque<Event<TId>>,
) {
    let is_new = agent.add_local_candidate(candidate.clone());

    if is_new {
        pending_events.push_back(Event::SignalIceCandidate {
            connection: id,
            candidate: candidate.to_sdp_string(),
        })
    }
}

pub struct Offer {
    /// The Wireguard session key for a connection.
    pub session_key: Secret<[u8; 32]>,
    pub credentials: Credentials,
}

pub struct Answer {
    pub credentials: Credentials,
}

pub struct Credentials {
    /// The ICE username (ufrag).
    pub username: String,
    /// The ICE password.
    pub password: String,
}

#[derive(Debug, PartialEq)]
pub enum Event<TId> {
    /// Signal the ICE candidate to the remote via the signalling channel.
    ///
    /// Candidates are in SDP format although this may change and should be considered an implementation detail of the application.
    SignalIceCandidate {
        connection: TId,
        candidate: String,
    },
    ConnectionEstablished(TId),

    /// We failed to establish a connection.
    ///
    /// All state associated with the connection has been cleared.
    ConnectionFailed(TId),
}

#[derive(Debug)]
pub struct Transmit<'a> {
    /// The local interface from which this packet should be sent.
    ///
    /// If `None`, it can be sent from any interface.
    /// Typically, this will be `None` for any message that needs to be sent to a relay.
    ///
    /// For all direct communication with another peer, this will be set and must be honored.
    pub src: Option<SocketAddr>,
    /// The remote the packet should be sent to.
    pub dst: SocketAddr,
    /// The data that should be sent.
    pub payload: Cow<'a, [u8]>,
}

impl<'a> Transmit<'a> {
    pub fn into_owned(self) -> Transmit<'static> {
        Transmit {
            src: self.src,
            dst: self.dst,
            payload: Cow::Owned(self.payload.into_owned()),
        }
    }
}

#[derive(Debug, PartialEq)]
pub(crate) enum CandidateEvent {
    New(Candidate),
}

struct InitialConnection {
    agent: IceAgent,
    session_key: Secret<[u8; 32]>,
    stun_servers: HashSet<SocketAddr>,
    turn_servers: HashSet<SocketAddr>,

    created_at: Instant,
}

struct Connection {
    agent: IceAgent,

    tunnel: Tunn,
    next_timer_update: Instant,

    last_seen: Option<Instant>,

    // When this is `Some`, we are connected.
    peer_socket: Option<PeerSocket>,
    // Socket addresses from which we might receive data (even before we are connected).
    possible_sockets: HashSet<SocketAddr>,

    stun_servers: HashSet<SocketAddr>,
    turn_servers: HashSet<SocketAddr>,
}

/// The socket of the peer we are connected to.
#[derive(Debug, PartialEq, Clone, Copy)]
enum PeerSocket {
    Direct {
        source: SocketAddr,
        dest: SocketAddr,
    },
    Relay {
        relay: SocketAddr,
        dest: SocketAddr,
    },
}

impl Connection {
    /// Checks if we want to accept a packet from a certain address.
    ///
    /// Whilst we establish connections, we may see traffic from a certain address, prior to the negotiation being fully complete.
    /// We already want to accept that traffic and not throw it away.
    fn accepts(&self, addr: SocketAddr) -> bool {
        let from_connected_remote = self.peer_socket.is_some_and(|r| match r {
            PeerSocket::Direct { dest, .. } => dest == addr,
            PeerSocket::Relay { dest, .. } => dest == addr,
        });
        let from_possible_remote = self.possible_sockets.contains(&addr);

        from_connected_remote || from_possible_remote
    }

    fn set_remote_from_wg_activity(
        &mut self,
        local: SocketAddr,
        dest: SocketAddr,
        relay_socket: Option<Socket>,
    ) {
        let remote_socket = match relay_socket {
            Some(relay_socket) => PeerSocket::Relay {
                relay: relay_socket.server(),
                dest,
            },
            None => PeerSocket::Direct {
                source: local,
                dest,
            },
        };

        if self.peer_socket != Some(remote_socket) {
            tracing::debug!(old = ?self.peer_socket, new = ?remote_socket, "Updating remote socket from WG activity");
            self.peer_socket = Some(remote_socket);
        }
    }

    fn poll_timeout(&mut self) -> Option<Instant> {
        let agent_timeout = self.agent.poll_timeout();
        let next_wg_timer = Some(self.next_timer_update);

        earliest(agent_timeout, next_wg_timer)
    }

    fn poll_transmit(
        &mut self,
        allocations: &mut HashMap<SocketAddr, Allocation>,
        now: Instant,
    ) -> Option<Transmit<'static>> {
        loop {
            let transmit = self.agent.poll_transmit()?;
            let source = transmit.source;
            let dst = transmit.destination;
            let packet = transmit.contents;

            // Check if `str0m` wants us to send from a "remote" socket, i.e. one that we allocated with a relay.
            let allocation = allocations
                .iter_mut()
                .find(|(_, allocation)| allocation.has_socket(source));

            let Some((relay, allocation)) = allocation else {
                // `source` did not match any of our allocated sockets, must be a local one then!
                return Some(Transmit {
                    src: Some(source),
                    dst,
                    payload: Cow::Owned(packet.into()),
                });
            };

            // Payload should be sent from a "remote socket", let's wrap it in a channel data message!
            let Some(channel_data) = allocation.encode_to_vec(dst, &packet, now) else {
                // Unlikely edge-case, drop the packet and continue.
                tracing::debug!(%relay, peer = %dst, "Dropping packet because allocation does not offer a channel to peer");
                continue;
            };

            return Some(Transmit {
                src: None,
                dst: *relay,
                payload: Cow::Owned(channel_data),
            });
        }
    }

    fn handle_timeout(
        &mut self,
        now: Instant,
        allocations: &mut HashMap<SocketAddr, Allocation>,
    ) -> Result<Option<Transmit<'static>>, WireGuardError> {
        self.agent.handle_timeout(now);

        // TODO: `boringtun` is impure because it calls `Instant::now`.
        self.last_seen = self
            .tunnel
            .time_since_last_received()
            .and_then(|d| now.checked_sub(d));

        if now >= self.next_timer_update {
            self.next_timer_update = now + Duration::from_secs(1);

            // Don't update wireguard timers until we are connected.
            if self.peer_socket.is_none() {
                return Ok(None);
            }

            /// [`boringtun`] requires us to pass buffers in where it can construct its packets.
            ///
            /// When updating the timers, the largest packet that we may have to send is `148` bytes as per `HANDSHAKE_INIT_SZ` constant in [`boringtun`].
            const MAX_SCRATCH_SPACE: usize = 148;

            let mut buf = [0u8; MAX_SCRATCH_SPACE];

            match self.tunnel.update_timers(&mut buf) {
                TunnResult::Done => {}
                TunnResult::Err(e) => return Err(e),
                TunnResult::WriteToNetwork(b) => {
                    let Some(transmit) = self.encapsulate(b, allocations, now) else {
                        return Ok(None);
                    };

                    return Ok(Some(transmit.into_owned()));
                }
                _ => panic!("Unexpected result from update_timers"),
            };
        }

        Ok(None)
    }

    fn encapsulate(
        &self,
        message: &[u8],
        allocations: &mut HashMap<SocketAddr, Allocation>,
        now: Instant,
    ) -> Option<Transmit<'static>> {
        match self.peer_socket? {
            PeerSocket::Direct {
                dest: remote,
                source,
            } => Some(Transmit {
                src: Some(source),
                dst: remote,
                payload: Cow::Owned(message.into()),
            }),
            PeerSocket::Relay { relay, dest: peer } => {
                encode_as_channel_data(relay, peer, message, allocations, now).ok()
            }
        }
    }
}

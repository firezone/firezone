use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::PublicKey;
use boringtun::{noise::rate_limiter::RateLimiter, x25519::StaticSecret};
use core::fmt;
use pnet_packet::ipv4::Ipv4Packet;
use pnet_packet::ipv6::Ipv6Packet;
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
use str0m::{Candidate, IceConnectionState};

use crate::index::IndexLfsr;
use crate::stun_binding::StunBinding;
use crate::IpPacket;

// Note: Taken from boringtun
const HANDSHAKE_RATE_LIMIT: u64 = 100;

const MAX_UDP_SIZE: usize = (1 << 16) - 1;

/// Manages a set of wireguard connections for a server.
pub type ServerConnectionPool<TId> = ConnectionPool<Server, TId>;
/// Manages a set of wireguard connections for a client.
pub type ClientConnectionPool<TId> = ConnectionPool<Client, TId>;

pub enum Server {}
pub enum Client {}

pub struct ConnectionPool<T, TId> {
    private_key: StaticSecret,
    index: IndexLfsr,
    rate_limiter: Arc<RateLimiter>,
    local_interfaces: HashSet<SocketAddr>,
    buffered_transmits: VecDeque<Transmit>,

    next_rate_limiter_reset: Option<Instant>,

    stun_servers: HashMap<SocketAddr, StunBinding>,

    initial_connections: HashMap<TId, InitialConnection>,
    negotiated_connections: HashMap<TId, Connection>,
    pending_events: VecDeque<Event<TId>>,

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
}

impl<T, TId> ConnectionPool<T, TId>
where
    TId: Eq + Hash + Copy + fmt::Display,
{
    pub fn new(private_key: StaticSecret) -> Self {
        let public_key = &(&private_key).into();
        Self {
            private_key,
            marker: Default::default(),
            index: IndexLfsr::default(),
            rate_limiter: Arc::new(RateLimiter::new(public_key, HANDSHAKE_RATE_LIMIT)),
            local_interfaces: HashSet::default(),
            buffered_transmits: VecDeque::default(),
            next_rate_limiter_reset: None,
            negotiated_connections: HashMap::default(),
            pending_events: VecDeque::default(),
            initial_connections: HashMap::default(),
            buffer: Box::new([0u8; MAX_UDP_SIZE]),
            stun_servers: HashMap::default(),
        }
    }

    pub fn add_local_interface(&mut self, local_addr: SocketAddr) {
        self.local_interfaces.insert(local_addr);

        // TODO: Add host candidate to all existing connections here.
    }

    pub fn add_remote_candidate(&mut self, id: TId, candidate: String) {
        let candidate = match Candidate::from_sdp_string(&candidate) {
            Ok(c) => c,
            Err(e) => {
                tracing::debug!("Failed to parse candidate: {e}");
                return;
            }
        };

        if let Some(agent) = self.agent_mut(id) {
            agent.add_remote_candidate(candidate);
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
    ) -> Result<Option<(TId, IpPacket<'s>)>, Error> {
        if !self.local_interfaces.contains(&local) {
            return Err(Error::UnknownInterface);
        }

        // First, check if a `StunBinding` wants the packet
        if let Some(binding) = self.stun_servers.get_mut(&from) {
            if binding.handle_input(from, packet, now) {
                // If it handled the packet, drain its events to ensure we update the candidates of all connections.
                drain_binding_events(
                    from,
                    binding,
                    &mut self.initial_connections,
                    &mut self.negotiated_connections,
                    &mut self.pending_events,
                );
                return Ok(None);
            }
        }

        // Next: If we can parse the message as a STUN message, cycle through all agents to check which one it is for.
        if let Ok(message) = StunMessage::parse(packet) {
            for (_, conn) in self.initial_connections.iter_mut() {
                // TODO: `accepts_message` cannot demultiplexing multiple connections until https://github.com/algesten/str0m/pull/418 is merged.
                if conn.agent.accepts_message(&message) {
                    conn.agent.handle_packet(
                        now,
                        StunPacket {
                            proto: Protocol::Udp,
                            source: from,
                            destination: local,
                            message,
                        },
                    );
                    return Ok(None);
                }
            }

            for (_, conn) in self.negotiated_connections.iter_mut() {
                // Would the ICE agent of this connection like to handle the packet?
                if conn.agent.accepts_message(&message) {
                    conn.agent.handle_packet(
                        now,
                        StunPacket {
                            proto: Protocol::Udp,
                            source: from,
                            destination: local,
                            message,
                        },
                    );
                    return Ok(None);
                }
            }
        }

        for (id, conn) in self.negotiated_connections.iter_mut() {
            if !conn.accepts(from) {
                continue;
            }

            // TODO: I think eventually, here is where we'd unwrap a channel data message.

            return match conn.tunnel.decapsulate(None, packet, buffer) {
                TunnResult::Done => Ok(None),
                TunnResult::Err(e) => Err(Error::Decapsulate(e)),

                // For WriteToTunnel{V4,V6}, boringtun returns the source IP of the packet that was tunneled to us.
                // I am guessing this was done for convenience reasons.
                // In our API, we parse the packets directly as an IpPacket.
                // Thus, the caller can query whatever data they'd like, not just the source IP so we don't return it in addition.
                TunnResult::WriteToTunnelV4(packet, ip) => {
                    conn.set_remote_from_wg_activity(from);

                    let ipv4_packet = Ipv4Packet::new(packet).expect("boringtun verifies validity");
                    debug_assert_eq!(ipv4_packet.get_source(), ip);

                    Ok(Some((*id, ipv4_packet.into())))
                }
                TunnResult::WriteToTunnelV6(packet, ip) => {
                    conn.set_remote_from_wg_activity(from);

                    let ipv6_packet = Ipv6Packet::new(packet).expect("boringtun verifies validity");
                    debug_assert_eq!(ipv6_packet.get_source(), ip);

                    Ok(Some((*id, ipv6_packet.into())))
                }

                // During normal operation, i.e. when the tunnel is active, decapsulating a packet straight yields the decrypted packet.
                // However, in case `Tunn` has buffered packets, they may be returned here instead.
                // This should be fairly rare which is why we just allocate these and return them from `poll_transmit` instead.
                // Overall, this results in a much nicer API for our caller and should not affect performance.
                TunnResult::WriteToNetwork(bytes) => {
                    conn.set_remote_from_wg_activity(from);

                    self.buffered_transmits.push_back(Transmit {
                        dst: from,
                        payload: bytes.to_vec(),
                    });

                    while let TunnResult::WriteToNetwork(packet) =
                        conn.tunnel
                            .decapsulate(None, &[], self.buffer.as_mut_slice())
                    {
                        self.buffered_transmits.push_back(Transmit {
                            dst: from,
                            payload: packet.to_vec(),
                        });
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
    ) -> Result<Option<(SocketAddr, &'s [u8])>, Error> {
        // TODO: We need to return, which local socket to use to send the data.
        let conn = self
            .negotiated_connections
            .get_mut(&connection)
            .ok_or(Error::NotConnected)?;

        let remote_socket = conn.remote_socket.ok_or(Error::NotConnected)?;

        // TODO: If we are connected via TURN, wrap in data channel message here.

        match conn
            .tunnel
            .encapsulate(packet.packet(), self.buffer.as_mut())
        {
            TunnResult::Done => Ok(None),
            TunnResult::Err(e) => Err(Error::Encapsulate(e)),
            TunnResult::WriteToNetwork(packet) => Ok(Some((remote_socket, packet))),
            TunnResult::WriteToTunnelV4(_, _) | TunnResult::WriteToTunnelV6(_, _) => {
                unreachable!("never returned from encapsulate")
            }
        }
    }

    /// Returns a pending [`Event`] from the pool.
    pub fn poll_event(&mut self) -> Option<Event<TId>> {
        for (id, conn) in self.negotiated_connections.iter_mut() {
            while let Some(event) = conn.agent.poll_event() {
                match event {
                    IceAgentEvent::DiscoveredRecv { source, .. } => {
                        conn.possible_sockets.insert(source);
                        // TODO: Here is where we'd allocate channels.
                    }
                    IceAgentEvent::IceConnectionStateChange(IceConnectionState::Disconnected) => {
                        return Some(Event::ConnectionFailed(*id));
                    }
                    IceAgentEvent::NominatedSend { destination, .. } => match conn.remote_socket {
                        Some(old) if old != destination => {
                            tracing::info!(%id, new = %destination, %old, "Migrating connection to peer");
                            conn.remote_socket = Some(destination);
                        }
                        None => {
                            tracing::info!(%id, %destination, "Connected to peer");
                            conn.remote_socket = Some(destination);

                            return Some(Event::ConnectionEstablished(*id));
                        }
                        _ => {}
                    },
                    _ => {}
                }
            }
        }

        self.pending_events.pop_front()
    }

    /// Returns, when [`ConnectionPool::handle_timeout`] should be called next.
    ///
    /// This function only takes `&mut self` because it caches certain computations internally.
    /// The returned timestamp will **not** change unless other state is modified.
    pub fn poll_timeout(&mut self) -> Option<Instant> {
        let mut connection_timeout = None;

        // TODO: Do we need to poll ice agents of initial connections??

        for c in self.negotiated_connections.values_mut() {
            connection_timeout = earliest(connection_timeout, c.poll_timeout());
        }
        for b in self.stun_servers.values_mut() {
            connection_timeout = earliest(connection_timeout, b.poll_timeout());
        }

        earliest(connection_timeout, self.next_rate_limiter_reset)
    }

    /// Advances time within the [`ConnectionPool`].
    ///
    /// This advances time within the ICE agent, updates timers within all wireguard connections as well as resets wireguard's rate limiter (if necessary).
    pub fn handle_timeout(&mut self, now: Instant) {
        for c in self.negotiated_connections.values_mut() {
            self.buffered_transmits.extend(c.handle_timeout(now));
        }

        for binding in self.stun_servers.values_mut() {
            binding.handle_timeout(now);
        }

        let next_reset = *self.next_rate_limiter_reset.get_or_insert(now);

        if now >= next_reset {
            self.rate_limiter.reset_count();
            self.next_rate_limiter_reset = Some(now + Duration::from_secs(1));
        }
    }

    /// Returns buffered data that needs to be sent on the socket.
    pub fn poll_transmit(&mut self) -> Option<Transmit> {
        for conn in self.initial_connections.values_mut() {
            if let Some(transmit) = conn.agent.poll_transmit() {
                return Some(Transmit {
                    dst: transmit.destination,
                    payload: transmit.contents.into(),
                });
            }
        }

        for binding in self.stun_servers.values_mut() {
            if let Some(transmit) = binding.poll_transmit() {
                return Some(transmit);
            }
        }

        for conn in self.negotiated_connections.values_mut() {
            if let Some(transmit) = conn.agent.poll_transmit() {
                return Some(Transmit {
                    dst: transmit.destination,
                    payload: transmit.contents.into(),
                });
            }
        }

        self.buffered_transmits.pop_front()
    }

    fn agent_mut(&mut self, id: TId) -> Option<&mut IceAgent> {
        let maybe_initial_connection = self.initial_connections.get_mut(&id).map(|i| &mut i.agent);
        let maybe_established_connection = self
            .negotiated_connections
            .get_mut(&id)
            .map(|c| &mut c.agent);

        maybe_initial_connection.or(maybe_established_connection)
    }

    fn upsert_stun_servers(&mut self, servers: &HashSet<SocketAddr>) {
        for server in servers {
            if !self.stun_servers.contains_key(server) {
                tracing::debug!(address = %server, "Adding new STUN server");

                self.stun_servers.insert(*server, StunBinding::new(*server));
            }
        }
    }

    fn seed_agent_with_local_candidates(
        &mut self,
        connection: TId,
        agent: &mut IceAgent,
        allowed_stun_servers: &HashSet<SocketAddr>,
    ) {
        for local in self.local_interfaces.iter().copied() {
            let candidate = match Candidate::host(local, Protocol::Udp) {
                Ok(c) => c,
                Err(e) => {
                    tracing::debug!("Failed to generate host candidate from addr: {e}");
                    continue;
                }
            };

            add_local_candidate(
                connection,
                agent,
                candidate.clone(),
                &mut self.pending_events,
            );
        }

        for candidate in self.stun_servers.iter().filter_map(|(server, binding)| {
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
    }
}

impl<TId> ConnectionPool<Client, TId>
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
        allowed_turn_servers: HashSet<SocketAddr>,
    ) -> Offer {
        self.upsert_stun_servers(&allowed_stun_servers);

        let mut agent = IceAgent::new();
        agent.set_controlling(true);

        self.seed_agent_with_local_candidates(id, &mut agent, &allowed_stun_servers);

        let session_key = Secret::new(random());
        let ice_creds = agent.local_credentials();

        let params = Offer {
            session_key: session_key.clone(),
            credentials: Credentials {
                username: ice_creds.ufrag.clone(),
                password: ice_creds.pass.clone(),
            },
        };

        self.initial_connections.insert(
            id,
            InitialConnection {
                agent,
                session_key,
                stun_servers: allowed_stun_servers,
                turn_servers: allowed_turn_servers,
            },
        );

        params
    }

    /// Accept an [`Answer`] from the remote for a connection previously created via [`ConnectionPool::new_connection`].
    pub fn accept_answer(&mut self, id: TId, remote: PublicKey, answer: Answer) {
        let Some(initial) = self.initial_connections.remove(&id) else {
            return; // TODO: Better error handling
        };

        let mut agent = initial.agent;
        agent.set_remote_credentials(IceCreds {
            ufrag: answer.credentials.username,
            pass: answer.credentials.password,
        });

        self.negotiated_connections.insert(
            id,
            Connection {
                agent,
                tunnel: Tunn::new(
                    self.private_key.clone(),
                    remote,
                    Some(*initial.session_key.expose_secret()),
                    None,
                    self.index.next(),
                    Some(self.rate_limiter.clone()),
                ),
                stun_servers: initial.stun_servers,
                _turn_servers: initial.turn_servers,
                next_timer_update: None,
                remote_socket: None,
                possible_sockets: HashSet::default(),
            },
        );
    }
}

impl<TId> ConnectionPool<Server, TId>
where
    TId: Eq + Hash + Copy + fmt::Display,
{
    pub fn accept_connection(
        &mut self,
        id: TId,
        offer: Offer,
        remote: PublicKey,
        allowed_stun_servers: HashSet<SocketAddr>,
        allowed_turn_servers: HashSet<SocketAddr>,
    ) -> Answer {
        self.upsert_stun_servers(&allowed_stun_servers);

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

        self.seed_agent_with_local_candidates(id, &mut agent, &allowed_stun_servers);

        self.negotiated_connections.insert(
            id,
            Connection {
                agent,
                tunnel: Tunn::new(
                    self.private_key.clone(),
                    remote,
                    Some(*offer.session_key.expose_secret()),
                    None,
                    self.index.next(),
                    Some(self.rate_limiter.clone()),
                ),
                stun_servers: allowed_stun_servers,
                _turn_servers: allowed_turn_servers,
                next_timer_update: None,
                remote_socket: None,
                possible_sockets: HashSet::default(),
            },
        );

        answer
    }
}

fn drain_binding_events<TId>(
    server: SocketAddr,
    binding: &mut StunBinding,
    initial_connections: &mut HashMap<TId, InitialConnection>,
    negotiated_connections: &mut HashMap<TId, Connection>,
    pending_events: &mut VecDeque<Event<TId>>,
) where
    TId: Copy,
{
    while let Some(candidate) = binding.poll_candidate() {
        // TODO: Reduce duplication between initial and negotiated connections
        for (id, c) in initial_connections.iter_mut() {
            if !c.stun_servers.contains(&server) {
                continue;
            }

            add_local_candidate(*id, &mut c.agent, candidate.clone(), pending_events);
        }

        for (id, c) in negotiated_connections.iter_mut() {
            if !c.stun_servers.contains(&server) {
                continue;
            }

            add_local_candidate(*id, &mut c.agent, candidate.clone(), pending_events);
        }
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

pub enum Event<TId> {
    /// Signal the ICE candidate to the remote via the signalling channel.
    ///
    /// Candidates are in SDP format although this may change and should be considered an implementation detail of the application.
    SignalIceCandidate {
        connection: TId,
        candidate: String,
    },
    ConnectionEstablished(TId),

    /// We tested all candidates and failed to establish a connection.
    ///
    /// This condition will not resolve unless more candidates are added or the network conditions change.
    ConnectionFailed(TId),
}

#[derive(Debug)]
pub struct Transmit {
    pub dst: SocketAddr,
    pub payload: Vec<u8>,
}

pub struct InitialConnection {
    agent: IceAgent,
    session_key: Secret<[u8; 32]>,
    stun_servers: HashSet<SocketAddr>,
    turn_servers: HashSet<SocketAddr>,
}

struct Connection {
    agent: IceAgent,

    tunnel: Tunn,
    next_timer_update: Option<Instant>,

    // When this is `Some`, we are connected.
    remote_socket: Option<SocketAddr>,
    // Socket addresses from which we might receive data (even before we are connected).
    possible_sockets: HashSet<SocketAddr>,

    stun_servers: HashSet<SocketAddr>,
    _turn_servers: HashSet<SocketAddr>,
}

impl Connection {
    /// Checks if we want to accept a packet from a certain address.
    ///
    /// Whilst we establish connections, we may see traffic from a certain address, prior to the negotiation being fully complete.
    /// We already want to accept that traffic and not throw it away.
    fn accepts(&self, addr: SocketAddr) -> bool {
        let from_connected_remote = self.remote_socket.is_some_and(|r| r == addr);
        let from_possible_remote = self.possible_sockets.contains(&addr);

        from_connected_remote || from_possible_remote
    }

    fn set_remote_from_wg_activity(&mut self, remote: SocketAddr) {
        match self.remote_socket {
            Some(current) if current != remote => {
                tracing::info!(%current, new = %remote, "Setting new remote socket from WG activity");
                self.remote_socket = Some(remote);
            }
            None => {
                tracing::info!(new = %remote, "Setting remote socket from WG activity");
                self.remote_socket = Some(remote);
            }
            _ => {}
        }
    }

    fn poll_timeout(&mut self) -> Option<Instant> {
        let agent_timeout = self.agent.poll_timeout();
        let next_wg_timer = self.next_timer_update;

        earliest(agent_timeout, next_wg_timer)
    }

    fn handle_timeout(&mut self, now: Instant) -> Option<Transmit> {
        self.agent.handle_timeout(now);

        let remote = self.remote_socket?;
        let next_timer_update = self.next_timer_update?;

        if now >= next_timer_update {
            self.next_timer_update = Some(now + Duration::from_nanos(1));

            /// [`boringtun`] requires us to pass buffers in where it can construct its packets.
            ///
            /// When updating the timers, the largest packet that we may have to send is `148` bytes as per `HANDSHAKE_INIT_SZ` constant in [`boringtun`].
            const MAX_SCRATCH_SPACE: usize = 148;

            let mut buf = [0u8; MAX_SCRATCH_SPACE];

            match self.tunnel.update_timers(&mut buf) {
                TunnResult::Done => {}
                TunnResult::Err(e) => {
                    // TODO: Handle this error. I think it can only be an expired connection so we should return a very specific error to the caller to make this easy to handle!
                    panic!("{e:?}")
                }
                TunnResult::WriteToNetwork(b) => {
                    return Some(Transmit {
                        dst: remote,
                        payload: b.to_vec(),
                    });
                }
                _ => panic!("Unexpected result from update_timers"),
            };
        }

        None
    }
}

fn earliest(left: Option<Instant>, right: Option<Instant>) -> Option<Instant> {
    match (left, right) {
        (None, None) => None,
        (Some(left), Some(right)) => Some(std::cmp::min(left, right)),
        (Some(left), None) => Some(left),
        (None, Some(right)) => Some(right),
    }
}

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
use str0m::ice::{IceAgent, IceAgentEvent, IceCreds};
use str0m::net::{Protocol, Receive};
use str0m::{Candidate, StunMessage};

use crate::index::IndexLfsr;
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

        // TODO: First thing we need to check if the message is from one of our STUN / TURN servers AND it is a STUN message (starts with 0x03)
        // ...
        // ...

        // Next: If we can parse the message as a STUN message, cycle through all agents to check which one it is for.
        if let Ok(stun_message) = StunMessage::parse(packet) {
            for (_, conn) in self.initial_connections.iter_mut() {
                // TODO: I believe `accepts_message` is broken for our usecases. It does not support client-side demultiplexing.
                if conn.agent.accepts_message(&stun_message) {
                    conn.agent.handle_receive(
                        now,
                        Receive {
                            proto: Protocol::Udp,
                            source: from,
                            destination: local,
                            contents: str0m::net::DatagramRecv::Stun(stun_message),
                        },
                    );
                    return Ok(None);
                }
            }

            for (_, conn) in self.negotiated_connections.iter_mut() {
                // Would the ICE agent of this connection like to handle the packet?
                if conn.agent.accepts_message(&stun_message) {
                    conn.agent.handle_receive(
                        now,
                        Receive {
                            proto: Protocol::Udp,
                            source: from,
                            destination: local,
                            contents: str0m::net::DatagramRecv::Stun(stun_message),
                        },
                    );
                    return Ok(None);
                }
            }
        }

        for (id, conn) in self.negotiated_connections.iter_mut() {
            // Is the packet from the remote directly?

            if !conn.accepts(from) {
                continue;
            }

            // TODO: I think eventually, here is where we'd unwrap a channel data message.

            return match conn.tunnel.decapsulate(None, packet, buffer) {
                TunnResult::Done => Ok(None),
                TunnResult::Err(e) => Err(Error::Decapsulate(e)),
                TunnResult::WriteToTunnelV4(packet, ip) => {
                    let ipv4_packet =
                        Ipv4Packet::new(packet).expect("boringtun verifies that it is valid");

                    debug_assert_eq!(ipv4_packet.get_source(), ip);

                    Ok(Some((*id, ipv4_packet.into())))
                }
                TunnResult::WriteToTunnelV6(packet, ip) => {
                    let ipv6_packet =
                        Ipv6Packet::new(packet).expect("boringtun verifies that it is valid");

                    debug_assert_eq!(ipv6_packet.get_source(), ip);

                    Ok(Some((*id, ipv6_packet.into())))
                }
                // TODO: Document why this is okay!
                TunnResult::WriteToNetwork(bytes) => {
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

    pub fn poll_event(&mut self) -> Option<Event<TId>> {
        for (id, conn) in self.negotiated_connections.iter_mut() {
            while let Some(event) = conn.agent.poll_event() {
                match event {
                    IceAgentEvent::DiscoveredRecv { source, .. } => {
                        conn.possible_sockets.insert(source);
                        // TODO: Here is where we'd allocate channels.
                    }
                    IceAgentEvent::IceRestart(_) => {}
                    IceAgentEvent::IceConnectionStateChange(_) => {}
                    IceAgentEvent::NominatedSend { destination, .. } => {
                        let old = conn.remote_socket;

                        conn.remote_socket = Some(destination);

                        match old {
                            Some(old) => {
                                tracing::info!(%id, new = %destination, %old, "Migrating connection to peer")
                            }
                            None => {
                                tracing::info!(%id, %destination, "Connected to peer");
                                return Some(Event::ConnectionEstablished(*id));
                            }
                        }
                    }
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

        earliest(connection_timeout, self.next_rate_limiter_reset)
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        for c in self.negotiated_connections.values_mut() {
            self.buffered_transmits.extend(c.handle_timeout(now));
        }

        let next_reset = *self.next_rate_limiter_reset.get_or_insert(now);

        if now >= next_reset {
            self.rate_limiter.reset_count();
            self.next_rate_limiter_reset = Some(now + Duration::from_secs(1));
        }
    }

    pub fn poll_transmit(&mut self) -> Option<Transmit> {
        for conn in self.initial_connections.values_mut() {
            if let Some(transmit) = conn.agent.poll_transmit() {
                return Some(Transmit {
                    dst: transmit.destination,
                    payload: transmit.contents.into(),
                });
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
}

impl<TId> ConnectionPool<Client, TId>
where
    TId: Eq + Hash + Copy,
{
    /// Create a new connection indexed by the given ID.
    ///
    /// Out of all configured STUN and TURN servers, the connection will only use the ones provided here.
    /// The returned [`Offer`] must be passed to the remote via a signalling channel.
    pub fn new_connection(
        &mut self,
        id: TId,
        allowed_stun_servers: Vec<SocketAddr>,
        allowed_turn_servers: Vec<SocketAddr>,
    ) -> Offer {
        let mut agent = IceAgent::new();
        agent.set_controlling(true);

        for local in self.local_interfaces.iter().copied() {
            let candidate = match Candidate::host(local, Protocol::Udp) {
                Ok(c) => c,
                Err(e) => {
                    tracing::debug!("Failed to generate host candidate from addr: {e}");
                    continue;
                }
            };

            if agent.add_local_candidate(candidate.clone()) {
                self.pending_events.push_back(Event::SignalIceCandidate {
                    connection: id,
                    candidate: candidate.to_sdp_string(),
                });
            }
        }

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
                _stun_servers: initial.stun_servers,
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
    TId: Eq + Hash + Copy,
{
    pub fn accept_connection(
        &mut self,
        id: TId,
        offer: Offer,
        remote: PublicKey,
        allowed_stun_servers: Vec<SocketAddr>,
        allowed_turn_servers: Vec<SocketAddr>,
    ) -> Answer {
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

        for local in self.local_interfaces.iter().copied() {
            let candidate = match Candidate::host(local, Protocol::Udp) {
                Ok(c) => c,
                Err(e) => {
                    tracing::debug!("Failed to generate host candidate from addr: {e}");
                    continue;
                }
            };

            if agent.add_local_candidate(candidate.clone()) {
                self.pending_events.push_back(Event::SignalIceCandidate {
                    connection: id,
                    candidate: candidate.to_sdp_string(),
                });
            }
        }

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
                _stun_servers: allowed_stun_servers,
                _turn_servers: allowed_turn_servers,
                next_timer_update: None,
                remote_socket: None,
                possible_sockets: HashSet::default(),
            },
        );

        answer
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
}

pub struct Transmit {
    pub dst: SocketAddr,
    pub payload: Vec<u8>,
}

pub struct InitialConnection {
    agent: IceAgent,
    session_key: Secret<[u8; 32]>,
    stun_servers: Vec<SocketAddr>,
    turn_servers: Vec<SocketAddr>,
}

struct Connection {
    agent: IceAgent,

    tunnel: Tunn,
    next_timer_update: Option<Instant>,

    // When this is `Some`, we are connected.
    remote_socket: Option<SocketAddr>,
    // Socket addresses from which we might receive data (even before we are connected).
    possible_sockets: HashSet<SocketAddr>,

    _stun_servers: Vec<SocketAddr>,
    _turn_servers: Vec<SocketAddr>,
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

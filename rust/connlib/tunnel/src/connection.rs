use crate::{Transmit, MAX_UDP_SIZE};
use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use connlib_shared::error::ConnlibError;
use connlib_shared::messages::{Key, SecretKey};
use either::Either;
use firezone_relay::client::ChannelBinding;
use futures_util::future::BoxFuture;
use futures_util::FutureExt;
use rand_core::OsRng;
use std::collections::VecDeque;
use std::net::{IpAddr, SocketAddr};
use std::task::{Context, Poll, Waker};
use std::time::Instant;
use str0m::ice::{IceAgent, IceAgentEvent, IceCreds};
use str0m::net::{DatagramRecv, Protocol, Receive};
use str0m::Candidate;

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

    /// The TURN servers we've been configured to use.
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

// TOOD: Find a better name.
pub(crate) struct Active {
    tunnel: Tunn,

    channel_bindings: Vec<ChannelBinding>,

    /// Temporarily buffered events that will be returned from [`Connection::<Connecting>::poll`].
    pending_events: VecDeque<Event>,

    buffered_transmits: VecDeque<crate::Transmit>,

    // When this is `Some`, we are connected.
    remote_socket: Option<SocketAddr>,
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
        make_tunn: impl FnOnce(SecretKey, PublicKey) -> Tunn,
    ) -> Connection<Active> {
        let mut ice_agent = self.ice_agent;
        ice_agent.set_remote_credentials(gateway_credentials);

        tracing::info!("Transitioning connection to `Connecting`");

        Connection {
            ice_agent,
            agent_timeout: self.agent_timeout,
            state: Active {
                tunnel: make_tunn(self.state.preshared_key, remote),
                channel_bindings: vec![],
                pending_events: Default::default(),
                buffered_transmits: VecDeque::default(),
                remote_socket: None,
            },
            stun_servers: self.stun_servers,
            turn_servers: self.turn_servers,
            local: self.local,
            waker: self.waker,
        }
    }
}

impl Connection<Active> {
    pub fn new_gateway_to_client(
        tunnel: Tunn,
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
            state: Active {
                tunnel,
                channel_bindings: vec![], // TODO: I think gateways should never bind channels, lets have the clients do that.
                pending_events: Default::default(),
                buffered_transmits: VecDeque::default(),
                remote_socket: None,
            },
            stun_servers,
            turn_servers,
            local,
            waker: None,
        }
    }

    pub fn is_connected(&self) -> bool {
        self.state.remote_socket.is_some()
    }

    /// Decapsulate an incoming packet.
    pub fn decapsulate<'b>(
        &mut self,
        from: SocketAddr,
        packet: &[u8],
        buf: &'b mut [u8],
    ) -> Result<Option<(&'b [u8], IpAddr)>, ConnlibError> {
        // debug_assert_eq!(from, self.state.dst);

        if self.ice_agent_handle_packet(from, packet) {
            return Ok(None); // TODO: Consider making this a different return type so we can stop processing on the outside.
        }

        // TODO: Handle channels

        match decapsulate(from, &mut self.state.tunnel, packet, buf)? {
            Either::Left(transmits) => {
                self.state.buffered_transmits.extend(transmits);
                Ok(None)
            }
            Either::Right((packet, addr)) => Ok(Some((packet, addr))),
        }
    }

    /// Encapsulates an outgoing packet.
    pub fn encapsulate<'b>(
        &mut self,
        packet: &[u8],
        buf: &'b mut [u8],
    ) -> Result<Option<(SocketAddr, &'b [u8])>, ConnlibError> {
        let Some(remote) = self.state.remote_socket else {
            return Err(ConnlibError::Other("not yet connected"));
        };

        let packet = match self.state.tunnel.encapsulate(packet, buf) {
            TunnResult::Done => return Ok(None),
            TunnResult::Err(e) => return Err(e.into()),
            TunnResult::WriteToNetwork(b) => b,
            _ => panic!("Unexpected result from `encapsulate`"),
        };

        tracing::debug!(%remote, "Encapsulated packet");

        // TODO: Wrap data in channel here?

        Ok(Some((remote, packet)))
    }

    pub fn update_timers(&mut self) {
        let Some(remote) = self.state.remote_socket else {
            return;
        };

        update_timers(
            &mut self.state.tunnel,
            remote,
            &mut self.state.buffered_transmits,
        )
    }

    pub fn add_binding(&mut self, relay: SocketAddr, binding: ChannelBinding) {
        if !self.stun_servers.contains(&relay) {
            return;
        }

        tracing::debug!(%relay, peer = %binding.peer(), "Adding channel binding to connection");

        self.state.channel_bindings.push(binding);
    }

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Event> {
        loop {
            if let Some(event) = self.state.pending_events.pop_front() {
                return Poll::Ready(event);
            }

            if let Some(transmit) = self.ice_agent.poll_transmit() {
                // TODO: Do we need to handle `transmit.source`?
                return Poll::Ready(Event::Transmit(Transmit {
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
                        .extend(self.turn_servers.iter().copied().map(|relay| {
                            Event::WantChannelToPeer {
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
                    // TODO: `source` tells us whether or not we are relayed.
                    self.state.remote_socket = Some(destination);
                    continue;
                }
                Some(IceAgentEvent::IceRestart(_)) => {}
                None => {}
            }

            if let Poll::Ready(timeout) = self.agent_timeout.poll_unpin(cx) {
                self.ice_agent.handle_timeout(timeout);

                if let Some(timeout) = self.ice_agent.poll_timeout() {
                    self.agent_timeout = agent_timeout(timeout).boxed();
                }

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
        let direct_traffic = self
            .state
            .remote_socket
            .is_some_and(|remote| remote == from);

        from_remote || stun_response || turn_response || direct_traffic
    }

    fn ice_agent_handle_packet(&mut self, peer: SocketAddr, packet: &[u8]) -> bool {
        let Ok(DatagramRecv::Stun(stun)) = DatagramRecv::try_from(packet) else {
            tracing::warn!(%peer, "Received non-STUN message");
            return false;
        };

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
        self.ice_agent.add_remote_candidate(candidate);

        if let Some(waker) = self.waker.take() {
            waker.wake();
        }
    }

    pub fn add_local_server_candidate(&mut self, server: SocketAddr, candidate: Candidate) -> bool {
        if !self.stun_servers.contains(&server) && !self.turn_servers.contains(&server) {
            return false;
        }

        let is_new = self.ice_agent.add_local_candidate(candidate);

        if let Some(waker) = self.waker.take() {
            waker.wake()
        }

        is_new
    }

    pub fn ice_credentials(&self) -> IceCreds {
        self.ice_agent.local_credentials().clone()
    }
}

#[derive(Debug)]
pub(crate) enum Event {
    WantChannelToPeer { relay: SocketAddr, peer: SocketAddr },
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

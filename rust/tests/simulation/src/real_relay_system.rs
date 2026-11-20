//! The relay simulation's real system: a relay client and a relay.
//!
//! [`Allocation`] and the relay's `Server` are both sans-IO. They sit on the network of the
//! tunnel simulation: each is a [`Host`], and their datagrams travel through
//! [`BufferedTransmits`]. The client exchanges data with the peers of the [`RelayModel`] through
//! the relay, which [`RealRelaySystem::check`] holds against what the model expects.

use std::{
    collections::BTreeSet,
    iter, mem,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::{Duration, Instant, SystemTime},
};

use bufferpool::Bytes;
use connlib_model::IpStack;
use ip_packet::Ecn;
use is::CandidateKind;
use jiff::Timestamp;
use relay_client_proto::{Allocation, Event, channel_data};
use relay_server_proto::{ChannelData, ClientSocket, Command};
use snownet::Transmit;
use stun_codec::rfc5389::attributes::{Nonce, Realm, Username};

use crate::{
    buffered_transmits::BufferedTransmits,
    clock::Clock,
    network::{ExecMutScope, Host, PollTimeout},
    real_relay::RealRelay,
    relay_model::{ModelHost, PEERS, RelayModel},
    relay_transition::{ForeignRequest, Injection, Interference, RelayDatagram, Transition},
    stun,
};

/// When the credentials of the devices expire: 2038-01-01T00:00:00Z, which the simulation never
/// reaches.
const CREDENTIALS_EXPIRE_AT: Duration = Duration::from_secs(2_145_916_800);

/// A client retransmits a request within this time, so a timer this close belongs to an
/// exchange that is still going on.
const RETRANSMISSION: Duration = Duration::from_secs(4);

/// How many new allocations the client gets in a row: each of them gives up while the client and
/// the relay share no address family.
const MAX_ALLOCATIONS: usize = 3;

/// More time than the client needs to give up on a relay that often.
const MAX_SETTLE: Duration = Duration::from_secs(60);

/// How often the client and each peer it is connected to exchange data while time passes.
///
/// A client that sends data this often needs no keep-alives.
const HEARTBEAT: Duration = Duration::from_secs(15);

/// The device that the client's credentials name.
const CLIENT_DEVICE: &str = "client";

/// A device with credentials of its own for the relay that the client uses.
const FOREIGN_DEVICE: &str = "foreign";

/// The client, the relay and the network between them.
pub(crate) struct RealRelaySystem {
    clock: Clock,
    transmits: BufferedTransmits,

    relay: Host<RealRelay>,
    /// How often the relay rebooted. Every boot has a secret of its own.
    relay_boots: u64,
    /// The relay boot that the client's allocation has credentials for.
    allocation_boot: u64,

    client: Host<RealAllocation>,

    /// The data that arrived at the peers.
    at_peers: Vec<Transmit>,
    /// The data that was injected into the relay's channels.
    injected_data: Vec<Vec<u8>>,
    /// How many data messages were sent. Each one carries its number.
    data_messages: u64,
    next_heartbeat: Instant,

    /// What the network still does to the control datagrams of the current transition.
    interference: Interference,
}

/// The relay client: an [`Allocation`], with what it announced and received.
#[derive(Default)]
struct RealAllocation {
    /// Absent once the allocation gave up, until the client gets a new one.
    allocation: Option<Allocation>,
    /// How many allocations the client started; each gets a seed of its own.
    seeds: u64,
    /// The relay addresses the allocation announced and did not invalidate since.
    relay_addresses: BTreeSet<SocketAddr>,
    relay_addresses_changed: bool,
    /// The data that arrived: the peer and the relay address that the allocation attributes
    /// it to, and its payload.
    received: Vec<(SocketAddr, SocketAddr, Vec<u8>)>,
}

impl RealRelaySystem {
    /// Builds the hosts of `model`.
    pub(crate) fn new(model: &RelayModel, start: Instant) -> Self {
        let clock = Clock::new(start, Timestamp::UNIX_EPOCH);

        Self {
            relay: new_relay(&model.relay, 0, clock.now()),
            clock,
            transmits: BufferedTransmits::default(),
            relay_boots: 0,
            allocation_boot: 0,
            client: host(RealAllocation::default(), &model.client, model.client.stack),
            at_peers: Vec::new(),
            injected_data: Vec::new(),
            data_messages: 0,
            next_heartbeat: start,
            interference: Interference::default(),
        }
    }

    pub(crate) fn apply(
        &mut self,
        model: &RelayModel,
        transition: &Transition,
        interference: Interference,
    ) {
        let now = self.clock.now::<Instant>();
        self.interference = interference;

        match transition {
            Transition::Advance { duration } => self.advance(model, *duration),
            Transition::Refresh => {
                self.client
                    .drive(&mut self.transmits, now, |a| a.refresh(now));
            }
            Transition::Roam { stack } => {
                let (ip4, ip6) = model.client.interfaces(*stack);
                let seed = self.client.exec_mut(|c| {
                    c.forget_relay_addresses();
                    c.next_seed()
                });

                self.client.port += 1;
                self.client.update_interface(ip4, ip6);
                self.client
                    .drive(&mut self.transmits, now, |a| a.restart(now, seed));
                self.bind_channels(model);
            }
            Transition::RebootRelay => {
                self.relay_boots += 1;
                self.relay = new_relay(&model.relay, self.relay_boots, self.clock.now());
            }
            Transition::Partition { duration } => {
                self.client.set_offline();
                self.advance(model, *duration);
                self.client
                    .update_interface(self.client.ip4, self.client.ip6);
            }
            Transition::Connect { peer } => {
                self.client
                    .drive(&mut self.transmits, now, |a| a.bind_channel(*peer, now));
            }
            Transition::Disconnect { peer: _ } => {}
            Transition::InjectDatagram(injection) => self.inject(model, injection),
        }
    }

    /// Lets the system settle and checks it against the model.
    pub(crate) fn check(&mut self, model: &RelayModel) {
        self.settle(model);
        self.interference = Interference::default();

        let changed = self
            .client
            .exec_mut(|c| mem::take(&mut c.relay_addresses_changed));
        assert!(
            model.disrupted() || !changed,
            "The client's relay addresses changed although nothing disrupted relaying"
        );

        if model.must_relay() {
            let (ip4, ip6) = model.relay.interfaces(model.relay.stack);

            assert_eq!(
                Vec::from_iter(self.client.inner().relay_addresses.iter().map(|a| a.ip())),
                Vec::from_iter(
                    iter::empty()
                        .chain(ip4.map(IpAddr::from))
                        .chain(ip6.map(IpAddr::from))
                ),
                "The client does not hold one relay address per address family of the relay"
            );
        }

        // Has the client bind the channels that it lacks.
        self.heartbeat(model);
        self.settle(model);

        assert_eq!(
            self.exchange(model),
            BTreeSet::from_iter(
                model
                    .connections
                    .keys()
                    .copied()
                    .filter(|p| model.can_relay(*p))
            ),
            "The client does not relay data to and from every peer it is connected to"
        );
        self.injected_data.clear();
    }

    /// Exchanges data over every connection. The established ones must relay it unless the
    /// network is partitioned.
    fn heartbeat(&mut self, model: &RelayModel) {
        let relayed = self.exchange(model);

        if self.client.is_offline() {
            return;
        }

        for (peer, established) in &model.connections {
            assert!(
                !established || relayed.contains(peer),
                "The established connection to {peer} lost data although nothing disrupted relaying"
            );
        }
    }

    /// Sends data from the client to every peer it is connected to and back, returning the
    /// peers for which both arrived.
    ///
    /// Panics on data that arrives where nobody sent it to.
    fn exchange(&mut self, model: &RelayModel) -> BTreeSet<SocketAddr> {
        let now = self.clock.now::<Instant>();
        let mut to_peers = Vec::new();
        let mut to_client = Vec::new();

        for peer in model.connections.keys().copied() {
            let relay_address = self.client.inner().relay_address_for(peer);

            let data = self.next_data(peer);
            if self.send_to_peer(peer, &data) {
                to_peers.push((relay_address, peer, data));
            }

            let Some(relay_address) = relay_address else {
                continue;
            };
            let data = self.next_data(peer);
            self.transmits.push(
                datagram(Some(peer), relay_address, &data),
                Duration::ZERO,
                now,
            );
            to_client.push((peer, relay_address, data));
        }

        let arrived = now + self.client.latency() + 2 * self.relay.latency();
        self.run(|_| arrived);

        let at_peers = mem::take(&mut self.at_peers)
            .into_iter()
            .map(|t| (t.src, t.dst, t.payload.to_vec()))
            .collect::<Vec<_>>();
        let at_client = self.client.exec_mut(|c| mem::take(&mut c.received));

        for arrival in &at_peers {
            assert!(
                to_peers.contains(arrival) || self.injected_data.contains(&arrival.2),
                "A peer received data that the client did not send to it from its relay address: {arrival:?}"
            );
        }
        for arrival in &at_client {
            assert!(
                to_client.contains(arrival),
                "The client received data that no peer it is connected to sent to its relay address: {arrival:?}"
            );
        }

        to_peers.retain(|sent| at_peers.contains(sent));
        to_client.retain(|sent| at_client.contains(sent));

        to_client
            .into_iter()
            .map(|(peer, _, _)| peer)
            .filter(|peer| to_peers.iter().any(|(_, to, _)| to == peer))
            .collect()
    }

    /// Has the client send data to a peer through the relay, which takes a channel to the peer.
    fn send_to_peer(&mut self, peer: SocketAddr, data: &[u8]) -> bool {
        let now = self.clock.now();
        let mut payload = channel_data::channel_data_packet_buffer(data);
        let encoded = self.client.drive(&mut self.transmits, now, |a| {
            a.encode_channel_data_header(peer, &mut payload, now)
        });
        let Some(Some(encoded)) = encoded else {
            return false;
        };

        self.transmits.push_from(
            datagram(None, encoded.socket, &payload),
            &mut self.client,
            now,
        );

        true
    }

    /// Builds a WireGuard data message that is unlike every other: the relay only relays
    /// WireGuard and STUN.
    fn next_data(&mut self, peer: SocketAddr) -> Vec<u8> {
        self.data_messages += 1;

        let mut message = vec![0u8; 32];
        message[0] = 4;
        message[6..8].copy_from_slice(&peer.port().to_be_bytes());
        message[8..16].copy_from_slice(&self.data_messages.to_be_bytes());

        message
    }

    /// Gives the client a new allocation, with credentials for the running relay.
    fn allocate(&mut self, model: &RelayModel) {
        let now = self.clock.now();

        let (server, username, password, realm) = self.credentials(CLIENT_DEVICE);
        let allocation = Allocation::new(
            server,
            Username::new(username).expect("username is short enough"),
            password,
            Realm::new(realm).expect("realm is short enough"),
            now,
            self.client.exec_mut(RealAllocation::next_seed),
        );

        self.client.exec_mut(|c| {
            c.allocation = Some(allocation);
            c.forget_relay_addresses();
        });
        self.allocation_boot = self.relay_boots;
        self.bind_channels(model);
    }

    /// Has the client bind a channel to every peer it is connected to, as it does whenever
    /// its allocation starts from scratch.
    fn bind_channels(&mut self, model: &RelayModel) {
        let now = self.clock.now();

        self.client.drive(&mut self.transmits, now, |a| {
            for peer in model.connections.keys() {
                a.bind_channel(*peer, now);
            }
        });
    }

    fn inject(&mut self, model: &RelayModel, injection: &Injection) {
        let now = self.clock.now();

        match injection {
            Injection::RelayFromForeign(datagram) => {
                let foreign = model.foreign.socket_for(any_socket(&self.relay).ip());

                self.inject_to_relay(model, foreign, datagram);
            }
            Injection::RelayFromClient(datagram) => {
                let client = [
                    IpAddr::from(Ipv4Addr::UNSPECIFIED),
                    Ipv6Addr::UNSPECIFIED.into(),
                ]
                .into_iter()
                .filter_map(|ip| self.client.sending_socket_for(ip))
                .find(|s| self.relay.sending_socket_for(s.ip()).is_some());
                let Some(client) = client else {
                    return;
                };

                self.inject_to_relay(model, client, datagram);
            }
            Injection::Client(payload) => {
                let dst = any_socket(&self.client);
                let Some(src) = self.relay.sending_socket_for(dst.ip()) else {
                    return;
                };

                self.forge_to_client(datagram(Some(src), dst, payload), now);
            }
            Injection::RelayAddresses => {
                for relay_address in self.client.inner().relay_addresses.clone() {
                    let foreign = model.foreign.socket_for(relay_address.ip());
                    let data = self.next_data(foreign);

                    self.transmits.push(
                        datagram(Some(foreign), relay_address, &data),
                        Duration::ZERO,
                        now,
                    );
                }
            }
        }
    }

    /// Sends the relay a datagram from `src`.
    fn inject_to_relay(&mut self, model: &RelayModel, src: SocketAddr, datagram: &RelayDatagram) {
        let now = self.clock.now();
        let Some(dst) = self.relay.sending_socket_for(src.ip()) else {
            return;
        };
        let payload = match datagram {
            RelayDatagram::Raw(bytes) => Some(bytes.clone()),
            RelayDatagram::Stun(bytes) => stun::round_trip(bytes),
            RelayDatagram::Request(request) => {
                let (_, username, password, _) = self.credentials(FOREIGN_DEVICE);
                let nonce = self.issue_nonce(model.foreign.socket_for(src.ip()));

                stun::request(*request, Some((&username, &password, nonce)))
            }
        };
        let Some(payload) = payload else {
            return;
        };

        // ChannelData is not authenticated: the relay passes on what arrives on a channel
        // from the socket that bound it.
        if let Ok(message) = ChannelData::parse(&payload) {
            self.injected_data.push(message.data().to_vec());
        }

        self.relay
            .receive(self::datagram(Some(src), dst, &payload), now);
    }

    /// Obtains a nonce for `socket` the way a client does: from the relay's answer to a
    /// request without one.
    fn issue_nonce(&mut self, socket: SocketAddr) -> Nonce {
        let (now, now_utc) = (self.clock.now(), self.clock.now());
        let request = stun::request(ForeignRequest::Allocate, None).expect("request is valid");

        let answer = self.relay.exec_mut(|r| {
            r.server
                .handle_client_input(&request, ClientSocket::new(socket), now, now_utc);
            r.server.next_command()
        });
        let Some(Command::SendMessage { payload, .. }) = answer else {
            panic!("The relay does not answer a request without credentials");
        };

        stun::nonce(&payload).expect("a `401` carries a nonce")
    }

    /// The relay's socket and credentials for `device` on the running relay.
    fn credentials(&self, device: &str) -> (snownet::RelaySocket, String, String, String) {
        let relay = self.relay.inner();

        relay.explode(
            device,
            relay.server.auth_secret(),
            relay.server.public_address(),
            SystemTime::UNIX_EPOCH + CREDENTIALS_EXPIRE_AT,
        )
    }

    /// Hands the client a datagram that the relay did not send.
    ///
    /// ChannelData is not authenticated, so whatever the client takes for a peer's data does
    /// not count as received.
    fn forge_to_client(&mut self, forged: Transmit, now: Instant) {
        let received = self.client.inner().received.len();

        self.client.handle_input(&mut self.transmits, forged, now);
        self.client.exec_mut(|c| c.received.truncate(received));
    }

    /// Lets the client and the relay finish what they are doing, and gives the client a new
    /// allocation whenever it has none for the running relay.
    ///
    /// Time only passes for the network and for retransmissions; everything else waits for
    /// `advance`.
    fn settle(&mut self, model: &RelayModel) {
        let deadline = self.clock.now::<Instant>() + MAX_SETTLE;
        let mut allocations = 0;

        loop {
            self.run(|now| {
                assert!(now <= deadline, "The client and the relay do not settle");

                now + RETRANSMISSION
            });

            let lacks_allocation = self.client.inner().allocation.is_none()
                || self.allocation_boot != self.relay_boots;
            if !lacks_allocation || allocations == MAX_ALLOCATIONS {
                return;
            }

            allocations += 1;
            self.allocate(model);
        }
    }

    /// Lets time pass, stopping at everything that is due on the way and for a heartbeat
    /// every [`HEARTBEAT`].
    fn advance(&mut self, model: &RelayModel, duration: Duration) {
        let target = self.clock.now::<Instant>() + duration;

        while self.next_heartbeat <= target {
            let next_heartbeat = self.next_heartbeat;

            self.run(|_| next_heartbeat);
            self.clock.skip_to(next_heartbeat);
            self.heartbeat(model);
            self.next_heartbeat = self.clock.now::<Instant>() + HEARTBEAT;
        }

        self.run(|_| target);
        self.clock.skip_to(target);
    }

    /// Steps the hosts and the network through everything that is due until the horizon, which
    /// may move with the clock.
    fn run(&mut self, horizon: impl Fn(Instant) -> Instant) {
        loop {
            let now = self.clock.now::<Instant>();

            while let Some(transmit) = self.transmits.pop(now) {
                self.dispatch(transmit, now);
            }
            self.client.step(&mut self.transmits, now);
            self.relay.step(&mut self.transmits, now, self.clock.now());

            let next = iter::empty()
                .chain(self.transmits.next_transmit())
                .chain(self.client.poll_timeout())
                .chain(self.relay.poll_timeout())
                .min();
            let Some(next) = next.filter(|next| *next <= horizon(now)) else {
                return;
            };

            assert!(
                next > now,
                "The client or the relay keeps a timer that is due after handling timeouts"
            );
            self.clock.skip_to(next);
        }
    }

    /// Routes a datagram by its destination, losing and forging the control datagrams that the
    /// current transition asks for.
    fn dispatch(&mut self, transmit: Transmit, now: Instant) {
        let src = transmit
            .src
            .expect("datagrams on the network have a source");
        let dst = transmit.dst;
        let is_control = matches!(transmit.payload.first(), Some(0..=3));

        if PEERS.contains(&dst) {
            self.at_peers.push(transmit);
            return;
        }

        if self.relay.ip4.map(IpAddr::from) == Some(dst.ip())
            || self.relay.ip6.map(IpAddr::from) == Some(dst.ip())
        {
            if is_control
                && self.client.sending_socket_for(src.ip()) == Some(src)
                && self.interference.lose_to_relay > 0
            {
                self.interference.lose_to_relay -= 1;
                return;
            }

            self.relay.receive(transmit, now);
            return;
        }

        // Answers to foreign sockets, to sockets the client left and to a client that is offline
        // go nowhere.
        if self.client.sending_socket_for(dst.ip()) != Some(dst) || self.client.is_offline() {
            return;
        }

        if is_control && self.interference.lose_to_client > 0 {
            self.interference.lose_to_client -= 1;
            return;
        }

        let forgery = self.interference.forge_to_client.take_if(|_| is_control);
        if let Some(forged) = forgery.and_then(|f| f.apply_to(&transmit.payload)) {
            self.forge_to_client(datagram(Some(src), dst, &forged), now);
        }

        self.client.receive(transmit, now);
    }
}

impl Host<RealAllocation> {
    /// Steps the client with what is due at `now`.
    fn step(&mut self, transmits: &mut BufferedTransmits, now: Instant) {
        while let Some(transmit) = self.poll_inbox(now) {
            self.handle_input(transmits, transmit, now);
        }

        if self
            .exec_mut(|c| c.poll_timeout())
            .is_some_and(|t| t <= now)
        {
            self.drive(transmits, now, |a| a.handle_timeout(now));
        }
    }

    fn handle_input(
        &mut self,
        transmits: &mut BufferedTransmits,
        transmit: Transmit,
        now: Instant,
    ) {
        let Some(from) = transmit.src else {
            return;
        };

        match transmit.payload.first() {
            Some(0..=3) => {
                let Ok(Ok(message)) = relay_client_proto::decode(&transmit.payload) else {
                    return;
                };

                self.drive(transmits, now, |a| {
                    a.handle_input(from, transmit.dst, message, now)
                });
            }
            Some(64..=79) => {
                let Ok(packet) = channel_data::decode(&transmit.payload) else {
                    return;
                };
                let data = packet.payload().to_vec();
                let decapsulated = self.drive(transmits, now, |a| a.decapsulate(from, packet, now));
                let Some(Some((peer, socket))) = decapsulated else {
                    return;
                };

                self.exec_mut(|c| c.received.push((peer, socket.address(), data)));
            }
            _ => {}
        }
    }

    /// Lets the allocation act, then handles its events and puts what it wants to send onto
    /// the network.
    fn drive<R>(
        &mut self,
        transmits: &mut BufferedTransmits,
        now: Instant,
        act: impl FnOnce(&mut Allocation) -> R,
    ) -> Option<R> {
        let (result, sent) = self.exec_mut(|c| (c.allocation.as_mut().map(act), c.drain()));

        for transmit in sent {
            transmits.push_from(transmit, self, now);
        }

        result
    }
}

impl RealAllocation {
    /// Handles the allocation's events, frees it once it gave up and returns what it wants to
    /// send.
    fn drain(&mut self) -> Vec<Transmit> {
        let Some(allocation) = &mut self.allocation else {
            return Vec::new();
        };

        while let Some(event) = allocation.poll_event() {
            let (candidate, is_new) = match event {
                Event::New(candidate) => (candidate, true),
                Event::Invalid(candidate) => (candidate, false),
            };
            if candidate.kind() != CandidateKind::Relayed {
                continue;
            }

            self.relay_addresses_changed = true;
            match is_new {
                true => self.relay_addresses.insert(candidate.addr()),
                false => self.relay_addresses.remove(&candidate.addr()),
            };
        }

        let transmits = iter::from_fn(|| allocation.poll_transmit())
            .map(|t| datagram(None, t.dst, &t.payload))
            .collect();

        if let Some(reason) = allocation.can_be_freed() {
            tracing::debug!(%reason, "Client gives up on the relay");

            self.allocation = None;
            self.forget_relay_addresses();
        }

        transmits
    }

    /// The relay address that data to and from `peer` passes through.
    fn relay_address_for(&self, peer: SocketAddr) -> Option<SocketAddr> {
        self.relay_addresses
            .iter()
            .copied()
            .find(|a| a.is_ipv4() == peer.is_ipv4())
    }

    fn next_seed(&mut self) -> [u8; 32] {
        self.seeds += 1;

        let mut seed = [0u8; 32];
        seed[..8].copy_from_slice(&self.seeds.to_be_bytes());

        seed
    }

    fn forget_relay_addresses(&mut self) {
        self.relay_addresses_changed |= !self.relay_addresses.is_empty();
        self.relay_addresses.clear();
    }
}

impl PollTimeout for RealAllocation {
    fn poll_timeout(&mut self) -> Option<Instant> {
        self.allocation.as_ref()?.poll_timeout()
    }
}

impl ExecMutScope for RealAllocation {
    type Guard = ();

    fn enter(&self) -> Self::Guard {}
}

fn new_relay(model: &ModelHost, boot: u64, now_utc: SystemTime) -> Host<RealRelay> {
    let (ip4, ip6) = model.interfaces(model.stack);

    host(RealRelay::new(boot, ip4, ip6, now_utc), model, model.stack)
}

/// A host that is reachable from everywhere, with the addresses of `stack`.
fn host<T>(inner: T, model: &ModelHost, stack: IpStack) -> Host<T> {
    let (ip4, ip6) = model.interfaces(stack);
    let mut host = Host::new(inner, model.latency, model.port);
    host.update_interface(ip4, ip6);

    host
}

fn any_socket<T>(host: &Host<T>) -> SocketAddr {
    host.sending_socket_for(Ipv4Addr::UNSPECIFIED)
        .or(host.sending_socket_for(Ipv6Addr::UNSPECIFIED))
        .expect("a host has an address")
}

fn datagram(src: Option<SocketAddr>, dst: SocketAddr, payload: &[u8]) -> Transmit {
    Transmit {
        src,
        dst,
        payload: Bytes::copied_from(payload),
        ecn: Ecn::NonEct,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::relay_generator::RelayGenerator;

    #[test]
    fn client_relays_data_on_a_working_network() {
        let model = RelayGenerator::new(&[]).model();
        let mut system = RealRelaySystem::new(&model, Instant::now());

        system.check(&model);

        assert_eq!(system.client.inner().relay_addresses.len(), 2);
    }
}

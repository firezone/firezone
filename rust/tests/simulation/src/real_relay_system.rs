//! The relay simulation's real system: a relay client and a relay.
//!
//! [`Allocation`] and the relay's `Server` are both sans-IO. They sit on the network of the
//! tunnel simulation: each is a [`Host`], and their datagrams travel through
//! [`BufferedTransmits`]. Each [`Transition`] runs until the two have settled. The [`RelayModel`]
//! then says whether relaying must work, which [`RealRelaySystem::probe`] checks end to end, and
//! whether the transition was allowed to interrupt it.

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
use relay_server_proto::ChannelData;
use snownet::Transmit;
use stun_codec::rfc5389::attributes::{Realm, Username};

use crate::{
    buffered_transmits::BufferedTransmits,
    clock::Clock,
    network::{ExecMutScope, Host, PollTimeout},
    real_relay::RealRelay,
    relay_model::{ModelHost, RelayModel},
    relay_transition::{BitFlips, Crafting, Interference, Target, Template, Transition},
    stun,
};

/// When the client's credentials expire: 2038-01-01T00:00:00Z, which the simulation never
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

/// The device that the client's credentials name.
const CLIENT_DEVICE: &str = "client";

/// A WireGuard keepalive, which is a data message with an empty payload: the relay only relays
/// WireGuard and STUN.
const WIREGUARD_KEEPALIVE: [u8; 32] = {
    let mut message = [0u8; 32];
    message[0] = 4;
    message
};

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
    last_from_client: Option<Transmit>,
    /// What the network still does to the current transition's control datagrams.
    interference: Interference,

    /// Whether the network lost a control datagram during the current transition.
    pub(crate) lost_datagram: bool,
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
    /// The peers whose data arrived, each with the relay address it arrived on.
    received: Vec<(SocketAddr, SocketAddr)>,
}

impl RealRelaySystem {
    /// Builds the hosts of `model` and gives the client an allocation.
    pub(crate) fn new(model: &RelayModel, start: Instant) -> Self {
        let clock = Clock::new(start, Timestamp::UNIX_EPOCH);

        let mut system = Self {
            relay: new_relay(&model.relay, 0, clock.now()),
            clock,
            transmits: BufferedTransmits::default(),
            relay_boots: 0,
            allocation_boot: 0,
            client: host(RealAllocation::default(), &model.client, model.client.stack),
            at_peers: Vec::new(),
            last_from_client: None,
            interference: Interference::default(),
            lost_datagram: false,
        };
        system.settle(model);

        system
    }

    pub(crate) fn apply(
        &mut self,
        model: &RelayModel,
        transition: &Transition,
        interference: Interference,
    ) {
        let now = self.clock.now::<Instant>();
        self.interference = interference;
        self.lost_datagram = false;
        self.client.exec_mut(|c| c.relay_addresses_changed = false);
        let mut from_client = None;

        match transition {
            Transition::Advance { duration } => self.advance(model, *duration),
            Transition::Refresh => self.client.exec_mut(|c| {
                if let Some(allocation) = &mut c.allocation {
                    allocation.refresh(now);
                }
            }),
            Transition::Roam { stack } => {
                let (ip4, ip6) = model.client.interfaces(*stack);

                self.client.port += 1;
                self.client.update_interface(ip4, ip6);
                self.client.exec_mut(|c| c.restart(now));
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
            Transition::Inject { target, flips } => match target {
                Target::RelayFromForeign(crafting) => {
                    self.inject_to_relay(model, false, *crafting, flips);
                }
                Target::RelayFromClient(crafting) => {
                    from_client = self.inject_to_relay(model, true, *crafting, flips);
                }
                Target::Client => self.inject_to_client(flips),
            },
        }

        self.settle(model);
        self.interference = Interference::default();

        // ChannelData is not authenticated: the relay passes on what arrives from the client's
        // socket on a channel the client bound.
        if let Some(message) = from_client
            .as_deref()
            .and_then(|p| ChannelData::parse(p).ok())
        {
            self.at_peers.retain(|t| message.data() != &t.payload[..]);
        }

        assert!(
            self.at_peers.is_empty(),
            "The relay passed on data that the client did not send"
        );
    }

    /// Checks the settled system against what the model expects of the last transition.
    pub(crate) fn check(&mut self, model: &RelayModel, may_interrupt: bool) {
        assert!(
            may_interrupt || !self.client.inner().relay_addresses_changed,
            "The client's relay addresses changed in a transition that must not interrupt relaying"
        );

        if model.must_relay() {
            self.probe(model);
        }
    }

    /// Sends data between a peer and the client through every relay address the client announced.
    fn probe(&mut self, model: &RelayModel) {
        let addresses = self.client.inner().relay_addresses.clone();
        assert!(
            !addresses.is_empty(),
            "The client holds no relay address although relaying must work"
        );

        for address in addresses {
            let peer = model.peer.socket_for(address.ip());

            // The first attempt binds a channel to the peer if there is none.
            if !self.send_to_peer(peer) {
                self.settle(model);
                assert!(
                    self.send_to_peer(peer),
                    "The client has no channel to send a peer data over"
                );
            }
            self.deliver(model);
            let relayed = mem::take(&mut self.at_peers)
                .into_iter()
                .map(|t| (t.src, t.dst, t.payload.to_vec()))
                .collect::<Vec<_>>();
            assert_eq!(
                relayed,
                vec![(Some(address), peer, WIREGUARD_KEEPALIVE.to_vec())],
                "The relay does not pass the client's data on to the peer from the relay address"
            );

            let now = self.clock.now();
            self.client.exec_mut(|c| c.received.clear());
            self.transmits.push(
                datagram(Some(peer), address, &WIREGUARD_KEEPALIVE),
                model.peer.latency,
                now,
            );
            self.deliver(model);
            assert_eq!(
                self.client.inner().received,
                vec![(peer, address)],
                "The client does not attribute a peer's data to the peer and the relay address"
            );
        }
    }

    /// Has the client send data to a peer through the relay, which takes a channel to the peer.
    fn send_to_peer(&mut self, peer: SocketAddr) -> bool {
        let now = self.clock.now();
        let mut payload = channel_data::channel_data_packet_buffer(&WIREGUARD_KEEPALIVE);
        let encoded = self.client.exec_mut(|c| {
            c.allocation
                .as_mut()?
                .encode_channel_data_header(peer, &mut payload, now)
        });
        let Some(encoded) = encoded else {
            return false;
        };

        self.transmits.push_from(
            datagram(None, encoded.socket, &payload),
            &mut self.client,
            now,
        );

        true
    }

    /// Gives the client a new allocation, with credentials for the running relay.
    fn allocate(&mut self) {
        let now = self.clock.now();

        let relay = self.relay.inner();
        let (server, username, password, realm) = relay.explode(
            CLIENT_DEVICE,
            relay.server.auth_secret(),
            relay.server.public_address(),
            SystemTime::UNIX_EPOCH + CREDENTIALS_EXPIRE_AT,
        );
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
    }

    /// Sends the relay a datagram made from the bit flips, returning what it sent.
    fn inject_to_relay(
        &mut self,
        model: &RelayModel,
        from_client: bool,
        crafting: Crafting,
        flips: &BitFlips,
    ) -> Option<Vec<u8>> {
        let now = self.clock.now();
        let template = self
            .last_from_client
            .clone()
            .filter(|_| crafting.template == Template::LastFromClient);
        let src = match from_client {
            true => template
                .as_ref()
                .and_then(|t| t.src)
                .filter(|s| self.client.sending_socket_for(s.ip()) == Some(*s))
                .unwrap_or_else(|| any_socket(&self.client)),
            false => model.foreign.socket_for(any_socket(&self.relay).ip()),
        };
        let dst = self.relay.sending_socket_for(src.ip())?;
        let mut payload = flips.apply_to(
            template
                .as_ref()
                .map(|t| &t.payload[..])
                .unwrap_or_default(),
        );

        if crafting.parse {
            payload = stun::round_trip(&payload)?;
        }

        self.relay.receive(datagram(Some(src), dst, &payload), now);

        Some(payload)
    }

    fn inject_to_client(&mut self, flips: &BitFlips) {
        let dst = any_socket(&self.client);
        let Some(src) = self.relay.sending_socket_for(dst.ip()) else {
            return;
        };

        self.client
            .receive(datagram(Some(src), dst, &flips.mask), self.clock.now());
    }

    /// Lets the client and the relay finish what they are doing, and gives the client a new
    /// allocation whenever it has none for the running relay.
    ///
    /// Time only passes for the network and for retransmissions; refreshes and keep-alives wait
    /// for `advance`.
    fn settle(&mut self, model: &RelayModel) {
        let deadline = self.clock.now::<Instant>() + MAX_SETTLE;
        let mut allocations = 0;

        loop {
            self.run(model, |now| {
                assert!(now <= deadline, "The client and the relay do not settle");

                now + RETRANSMISSION
            });

            let lacks_allocation = self.client.inner().allocation.is_none()
                || self.allocation_boot != self.relay_boots;
            if !lacks_allocation || allocations == MAX_ALLOCATIONS {
                return;
            }

            allocations += 1;
            self.allocate();
        }
    }

    /// Lets time pass, stopping at everything that is due on the way.
    fn advance(&mut self, model: &RelayModel, duration: Duration) {
        let target = self.clock.now::<Instant>() + duration;

        self.run(model, |_| target);
        self.clock.skip_to(target);
    }

    /// Runs for as long as a datagram takes from the client through the relay to a peer and back.
    fn deliver(&mut self, model: &RelayModel) {
        let round_trip =
            2 * (self.client.latency() + 2 * self.relay.latency()) + model.peer.latency;
        let arrived = self.clock.now::<Instant>() + round_trip;

        self.run(model, |_| arrived);
    }

    /// Steps the hosts and the network through everything that is due until the horizon, which
    /// may move with the clock.
    fn run(&mut self, model: &RelayModel, horizon: impl Fn(Instant) -> Instant) {
        loop {
            let now = self.clock.now::<Instant>();

            while let Some(transmit) = self.transmits.pop(now) {
                self.dispatch(model, transmit, now);
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
    fn dispatch(&mut self, model: &RelayModel, transmit: Transmit, now: Instant) {
        let src = transmit
            .src
            .expect("datagrams on the network have a source");
        let dst = transmit.dst;
        let is_control = matches!(transmit.payload.first(), Some(0..=3));

        if self.relay.ip4.map(IpAddr::from) == Some(dst.ip())
            || self.relay.ip6.map(IpAddr::from) == Some(dst.ip())
        {
            if is_control && self.client.sending_socket_for(src.ip()) == Some(src) {
                self.last_from_client = Some(transmit.clone());

                if mem::take(&mut self.interference.lose_to_relay) {
                    self.lost_datagram = true;
                    return;
                }
            }

            self.relay.receive(transmit, now);
            return;
        }

        if dst == model.peer.socket_for(dst.ip()) {
            self.at_peers.push(transmit);
            return;
        }

        // Answers to foreign sockets, to sockets the client left and to a client that is offline
        // go nowhere.
        if self.client.sending_socket_for(dst.ip()) != Some(dst) || self.client.is_offline() {
            return;
        }

        if is_control {
            if mem::take(&mut self.interference.lose_to_client) {
                self.lost_datagram = true;
                return;
            }

            if let Some(flips) = self.interference.forge_to_client.take() {
                let forged = datagram(Some(src), dst, &flips.apply_to(&transmit.payload));
                self.client.exec_mut(|c| c.handle_input(forged, now));
            }
        }

        self.client.receive(transmit, now);
    }
}

impl Host<RealAllocation> {
    /// Steps the client with what is due at `now` and puts what it sent onto the network.
    fn step(&mut self, transmits: &mut BufferedTransmits, now: Instant) {
        while let Some(transmit) = self.poll_inbox(now) {
            self.exec_mut(|c| c.handle_input(transmit, now));
        }

        for transmit in self.exec_mut(|c| c.handle_timeout(now)) {
            transmits.push_from(transmit, self, now);
        }
    }
}

impl RealAllocation {
    fn handle_input(&mut self, transmit: Transmit, now: Instant) {
        let (Some(allocation), Some(from)) = (&mut self.allocation, transmit.src) else {
            return;
        };

        match transmit.payload.first() {
            Some(0..=3) => {
                if let Ok(Ok(message)) = relay_client_proto::decode(&transmit.payload) {
                    allocation.handle_input(from, transmit.dst, message, now);
                }
            }
            Some(64..=79) => {
                if let Ok(packet) = channel_data::decode(&transmit.payload)
                    && let Some((peer, socket)) = allocation.decapsulate(from, packet, now)
                {
                    self.received.push((peer, socket.address()));
                }
            }
            _ => {}
        }
    }

    /// Handles the allocation's timeouts and events, and frees it once it gave up.
    fn handle_timeout(&mut self, now: Instant) -> Vec<Transmit> {
        let Some(allocation) = &mut self.allocation else {
            return Vec::new();
        };

        allocation.handle_timeout(now);

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

    fn restart(&mut self, now: Instant) {
        let seed = self.next_seed();

        if let Some(allocation) = &mut self.allocation {
            allocation.restart(now, seed);
            self.forget_relay_addresses();
        }
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

        assert_eq!(system.client.inner().relay_addresses.len(), 2);
        system.probe(&model);
    }
}

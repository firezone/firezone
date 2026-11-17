//! The relay simulation's real system: a relay client and a relay, with a portal that hands the
//! client the relay and its credentials.
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
use chrono::DateTime;
use connlib_model::IpStack;
use ip_packet::Ecn;
use is::CandidateKind;
use relay_client_proto::{Allocation, Event, channel_data};
use snownet::Transmit;
use stun_codec::rfc5389::{
    attributes::{Realm, Username},
    methods::BINDING,
};

use crate::{
    buffered_transmits::BufferedTransmits,
    clock::Clock,
    network::{EdgeConfig, ExecMutScope, Host, PollTimeout},
    real_relay::RealRelay,
    relay_model::{Environment, ModelHost, Observed, RelayModel},
    relay_transition::{Crafting, Garbage, Interference, Target, Transition},
    stun,
};

/// How long the credentials are valid that the portal issues.
const CREDENTIAL_LIFETIME: Duration = Duration::from_secs(60 * 60);

/// A client retransmits a request within this time, so a timer this close belongs to an
/// exchange that is still going on.
const RETRANSMISSION: Duration = Duration::from_secs(4);

/// How often the portal hands the relay back to a client that keeps giving up on it.
const MAX_HANDOVERS: usize = 3;

/// More time than the client needs to give up on a relay that often.
const MAX_SETTLE: Duration = Duration::from_secs(60);

/// How long it takes at most until a client and a relay that went out of sync agree again.
///
/// The client notices a lost allocation at its next refresh; a channel that the relay bound
/// without the client knowing is in the way until its binding is gone.
const RESYNC: Duration = Duration::from_secs(16 * 60);

/// A WireGuard keepalive, which is a data message with an empty payload: the relay only relays
/// WireGuard and STUN.
const WIREGUARD_KEEPALIVE: [u8; 32] = {
    let mut message = [0u8; 32];
    message[0] = 4;
    message
};

/// The client, the relay, the portal and the network between them.
pub(crate) struct RealRelaySystem {
    clock: Clock,
    transmits: BufferedTransmits,

    relay: Host<RealRelay>,
    /// How often the relay rebooted. Every boot has a secret of its own, so it is a different
    /// relay to the portal.
    relay_boots: u64,

    portal_reachable: bool,
    /// The credentials that the portal last issued.
    credentials: Option<Credentials>,

    client: Host<RealAllocation>,

    /// The data that arrived at the peers.
    at_peers: Vec<Transmit>,
    last_from_client: Option<Transmit>,
    /// What the network still does to the current transition's control datagrams.
    interference: Interference,

    /// What happened during the current transition.
    pub(crate) observed: Observed,
}

/// The relay client: an [`Allocation`] driven the way `snownet` drives it.
#[derive(Default)]
struct RealAllocation {
    /// Absent while the client has given up on the relay and the portal did not hand it back.
    allocation: Option<Allocation>,
    /// How many allocations the client started; each gets a seed of its own.
    seeds: u64,
    /// The relay addresses the allocation announced and did not invalidate since.
    relay_addresses: BTreeSet<SocketAddr>,
    relay_addresses_changed: bool,
    /// The peers whose data arrived, each with the relay address it arrived on.
    received: Vec<(SocketAddr, SocketAddr)>,
}

struct Credentials {
    /// The boot of the relay that they are for.
    relay_boot: u64,
    expire_at: SystemTime,
}

impl RealRelaySystem {
    /// Builds the hosts of `model` and lets the portal hand the client the relay.
    pub(crate) fn new(model: &RelayModel, start: Instant) -> Self {
        let clock = Clock::new(start, DateTime::UNIX_EPOCH);

        let mut system = Self {
            relay: new_relay(&model.relay, 0, clock.now()),
            clock,
            transmits: BufferedTransmits::default(),
            relay_boots: 0,
            portal_reachable: true,
            credentials: None,
            client: host(RealAllocation::default(), &model.client, model.client.stack),
            at_peers: Vec::new(),
            last_from_client: None,
            interference: Interference::default(),
            observed: Observed::default(),
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
        self.observed = Observed::default();
        self.client.exec_mut(|c| c.relay_addresses_changed = false);

        match transition {
            Transition::Advance { duration } => self.advance(model, *duration),
            Transition::RotateCredentials => {
                if self.portal_reachable && self.client.inner().allocation.is_some() {
                    self.connect(model);
                }
            }
            Transition::Refresh => {
                if self.portal_reachable {
                    self.client.exec_mut(|c| {
                        if let Some(allocation) = &mut c.allocation {
                            allocation.refresh(now);
                        }
                    });
                }
            }
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
            Transition::PortalOutage => self.portal_reachable = false,
            Transition::PortalRecovers => self.portal_reachable = true,
            Transition::Garbage { target, datagram } => match target {
                Target::RelayFromForeign(crafting) => {
                    self.garbage_to_relay(model, false, *crafting, datagram)
                }
                Target::RelayFromClient(crafting) => {
                    self.garbage_to_relay(model, true, *crafting, datagram);
                    self.advance(model, RESYNC);
                    // The relay may pass on what comes from the client's socket.
                    self.at_peers.clear();
                }
                Target::Client => self.garbage_to_client(datagram),
            },
        }

        self.settle(model);
        self.interference = Interference::default();

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

        if model.must_relay(self.environment()) {
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

    pub(crate) fn environment(&self) -> Environment {
        let now = self.clock.now::<SystemTime>();

        Environment {
            relay_reachable: (self.client.ip4.is_some() && self.relay.ip4.is_some())
                || (self.client.ip6.is_some() && self.relay.ip6.is_some()),
            portal_reachable: self.portal_reachable,
            credentials_valid: self
                .credentials
                .as_ref()
                .is_some_and(|c| c.relay_boot == self.relay_boots && now <= c.expire_at),
        }
    }

    /// The portal hands the client the relay with fresh credentials; the client starts over.
    fn connect(&mut self, model: &RelayModel) {
        let now = self.clock.now();
        let lifetime_ends = (self.clock.now::<SystemTime>() + CREDENTIAL_LIFETIME)
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("the clock starts at the UNIX epoch");
        // Whole seconds, because that is what a username carries.
        let expire_at = SystemTime::UNIX_EPOCH + Duration::from_secs(lifetime_ends.as_secs());

        let relay = self.relay.inner();
        let (server, username, password, realm) = relay.explode(
            model.client.device,
            relay.server.auth_secret(),
            relay.server.public_address(),
            expire_at,
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
        self.credentials = Some(Credentials {
            relay_boot: self.relay_boots,
            expire_at,
        });
    }

    fn garbage_to_relay(
        &mut self,
        model: &RelayModel,
        from_client: bool,
        crafting: Crafting,
        garbage: &Garbage,
    ) {
        let now = self.clock.now();
        let template = self.last_from_client.clone().filter(|_| crafting.mutate);
        let (src, device) = match from_client {
            true => {
                let src = template
                    .as_ref()
                    .and_then(|t| t.src)
                    .filter(|s| self.client.sending_socket_for(s.ip()) == Some(*s))
                    .unwrap_or_else(|| any_socket(&self.client));

                (src, model.client.device)
            }
            false => (
                model.foreign.socket_for(any_socket(&self.relay).ip()),
                model.foreign.device,
            ),
        };
        let Some(dst) = self.relay.sending_socket_for(src.ip()) else {
            return;
        };
        let mut payload = garbage.apply_to(
            template
                .as_ref()
                .map(|t| &t.payload[..])
                .unwrap_or_default(),
        );

        if crafting.parse {
            let now_utc = self.clock.now();
            let nonce = crafting
                .authenticate
                .then(|| self.relay.exec_mut(|r| r.issue_nonce(src, now, now_utc)));
            let Some(repaired) =
                stun::repair(&payload, nonce.as_ref(), device, &self.relay.inner().server)
            else {
                return;
            };

            payload = repaired;
        }

        self.relay.receive(datagram(Some(src), dst, &payload), now);
    }

    fn garbage_to_client(&mut self, garbage: &Garbage) {
        let dst = any_socket(&self.client);
        let Some(src) = self.relay.sending_socket_for(dst.ip()) else {
            return;
        };

        self.client
            .receive(datagram(Some(src), dst, &garbage.bytes), self.clock.now());
    }

    /// Lets the client and the relay finish what they are doing, and the portal react to it.
    ///
    /// Time only passes for the network and for retransmissions; refreshes and keep-alives wait
    /// for `advance`.
    fn settle(&mut self, model: &RelayModel) {
        let deadline = self.clock.now::<Instant>() + MAX_SETTLE;
        let mut handovers = 0;

        loop {
            self.run(model, |now| {
                assert!(now <= deadline, "The client and the relay do not settle");

                now + RETRANSMISSION
            });

            let credentials_valid = self.environment().credentials_valid;
            self.observed.credentials_lapsed |= !credentials_valid;

            let lacks_relay = self.client.inner().allocation.is_none() || !credentials_valid;
            if !lacks_relay || !self.portal_reachable || handovers == MAX_HANDOVERS {
                return;
            }

            handovers += 1;
            self.connect(model);
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
                    self.observed.lost_datagram = true;
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

        // Answers to foreign sockets and to sockets the client left go nowhere.
        if self.client.sending_socket_for(dst.ip()) != Some(dst)
            || self.client.ingress(src, dst, now).is_err()
        {
            return;
        }

        if is_control {
            if mem::take(&mut self.interference.lose_to_client) {
                self.observed.lost_datagram = true;
                return;
            }

            if let Some(garbage) = self.interference.forge_to_client.take() {
                self.observed.forged_binding |= relay_client_proto::decode(&transmit.payload)
                    .is_ok_and(|message| message.is_ok_and(|m| m.method() == BINDING));

                let forged = datagram(Some(src), dst, &garbage.apply_to(&transmit.payload));
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

    /// Runs the allocation the way `snownet` does: handle timeouts, drain events, free it once
    /// it gave up.
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
    let mut host = Host::new(
        inner,
        model.latency,
        model.port,
        EdgeConfig::Open,
        Ipv4Addr::UNSPECIFIED,
    );
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

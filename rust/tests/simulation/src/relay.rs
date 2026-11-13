//! A relay client and a relay, with a portal that hands the client the relay and its credentials.
//!
//! [`Allocation`] and the relay's `Server` are both sans-IO. They sit on the network of the
//! tunnel simulation: each is a [`Host`], and their datagrams travel through
//! [`BufferedTransmits`]. Each [`Transition`] runs until the two have settled. The [`Reference`]
//! then says whether relaying must work, which [`World::probe`] checks end to end, and whether
//! the transition was allowed to interrupt it.

use std::{
    collections::BTreeSet,
    iter, mem,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::{Duration, Instant, SystemTime},
};

use bufferpool::Bytes;
use chrono::DateTime;
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
    flux_capacitor::FluxCapacitor,
    relay_reference::{Environment, Observed, Reference},
    relay_transition::{Garbage, Loss, Target, Transition},
    sim_net::{EdgeConfig, ExecMutScope, Host, PollTimeout},
    sim_relay::SimRelay,
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

/// How long a host takes to send a datagram, and again to receive one.
const LATENCY: Duration = Duration::from_millis(10);

const RELAY_IP4: Ipv4Addr = Ipv4Addr::new(198, 51, 100, 1);
const RELAY_IP6: Ipv6Addr = Ipv6Addr::new(0x2001, 0xdb8, 1, 0, 0, 0, 0, 1);
const RELAY_PORT: u16 = 3478;

const CLIENT_IP4: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 10);
const CLIENT_IP6: Ipv6Addr = Ipv6Addr::new(0x2001, 0xdb8, 2, 0, 0, 0, 0, 10);
const CLIENT_PORT: u16 = 50000;
const CLIENT_DEVICE: &str = "client";

const FOREIGN_IP4: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 200);
const FOREIGN_IP6: Ipv6Addr = Ipv6Addr::new(0x2001, 0xdb8, 2, 0, 0, 0, 0, 200);
const FOREIGN_PORT: u16 = 7000;
const FOREIGN_DEVICE: &str = "foreign";

const PEER_IP4: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10)), 40000);
const PEER_IP6: SocketAddr = SocketAddr::new(
    IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 3, 0, 0, 0, 0, 10)),
    40000,
);

/// The smallest WireGuard data message: the relay only relays WireGuard and STUN.
const PAYLOAD: [u8; 32] = {
    let mut payload = [0u8; 32];
    payload[0] = 4;
    payload
};

/// The client, the relay, the portal and the network between them.
pub(crate) struct World {
    clock: FluxCapacitor,
    transmits: BufferedTransmits,

    relay: Host<SimRelay>,
    /// How often the relay rebooted. Every boot has a secret of its own, so it is a different
    /// relay to the portal.
    relay_boots: u64,

    portal_reachable: bool,
    /// The credentials that the portal last issued.
    credentials: Option<Credentials>,

    client: Host<Client>,
    roams: u16,
    seeds: u64,

    /// The data that arrived at the peers.
    at_peers: Vec<Transmit>,
    last_from_client: Option<Transmit>,
    /// What the current transition still loses.
    loss: Loss,
    /// Flips these bits in a copy of the relay's next control datagram and delivers it first.
    forgery: Option<Garbage>,

    /// What happened during the current transition.
    pub(crate) observed: Observed,
}

#[derive(Default)]
struct Client {
    /// Absent while the client has given up on the relay and the portal did not hand it back.
    allocation: Option<Allocation>,
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

impl World {
    pub(crate) fn new(
        relay_stack: (bool, bool),
        client_stack: (bool, bool),
        start: Instant,
    ) -> Self {
        let clock = FluxCapacitor::new(start, DateTime::UNIX_EPOCH);
        let (ip4, ip6) = interfaces(client_stack, CLIENT_IP4, CLIENT_IP6);

        Self {
            relay: new_relay(relay_stack, 0, clock.now()),
            clock,
            transmits: BufferedTransmits::default(),
            relay_boots: 0,
            portal_reachable: true,
            credentials: None,
            client: host(Client::default(), CLIENT_PORT, ip4, ip6),
            roams: 0,
            seeds: 0,
            at_peers: Vec::new(),
            last_from_client: None,
            loss: Loss::default(),
            forgery: None,
            observed: Observed::default(),
        }
    }

    pub(crate) fn apply(&mut self, transition: &Transition, loss: Loss) {
        let now = self.clock.now::<Instant>();
        self.loss = loss;
        self.observed = Observed::default();
        self.client.exec_mut(|c| c.relay_addresses_changed = false);

        match transition {
            Transition::Advance { duration } => self.advance(*duration),
            Transition::RotateCredentials => {
                if self.portal_reachable && self.client.inner().allocation.is_some() {
                    self.connect();
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
            Transition::Roam { v4, v6 } => {
                self.roams += 1;
                self.seeds += 1;
                let (ip4, ip6) = interfaces((*v4, *v6), CLIENT_IP4, CLIENT_IP6);
                let seed = seed(self.seeds);

                self.client.port = CLIENT_PORT + self.roams;
                self.client.update_interface(ip4, ip6);
                self.client.exec_mut(|c| c.restart(now, seed));
            }
            Transition::RebootRelay => {
                self.relay_boots += 1;
                self.relay = new_relay(
                    (self.relay.ip4.is_some(), self.relay.ip6.is_some()),
                    self.relay_boots,
                    self.clock.now(),
                );
            }
            Transition::Partition { duration } => {
                self.client.set_offline();
                self.advance(*duration);
                self.client
                    .update_interface(self.client.ip4, self.client.ip6);
            }
            Transition::PortalOutage => self.portal_reachable = false,
            Transition::PortalRecovers => self.portal_reachable = true,
            Transition::Garbage {
                target,
                parse,
                authenticate,
                datagram,
            } => match target {
                Target::RelayFromForeign => {
                    self.garbage_to_relay(false, *parse, *authenticate, datagram)
                }
                Target::RelayFromClient => {
                    self.garbage_to_relay(true, *parse, *authenticate, datagram);
                    self.advance(RESYNC);
                    // The relay may pass on what comes from the client's socket.
                    self.at_peers.clear();
                }
                Target::Client => self.garbage_to_client(datagram),
            },
        }

        self.settle();

        assert!(
            self.at_peers.is_empty(),
            "The relay passed on data that the client did not send"
        );
    }

    /// Checks the settled world against what the reference expects of the last transition.
    pub(crate) fn check(&mut self, reference: &Reference, may_interrupt: bool) {
        assert!(
            may_interrupt || !self.client.inner().relay_addresses_changed,
            "The client's relay addresses changed in a transition that must not interrupt relaying"
        );

        if reference.must_relay(self.environment()) {
            self.probe();
        }
    }

    /// Sends data between a peer and the client through every relay address the client announced.
    fn probe(&mut self) {
        let addresses = self.client.inner().relay_addresses.clone();
        assert!(
            !addresses.is_empty(),
            "The client holds no relay address although relaying must work"
        );

        for address in addresses {
            let peer = match address {
                SocketAddr::V4(_) => PEER_IP4,
                SocketAddr::V6(_) => PEER_IP6,
            };

            // The first attempt binds a channel to the peer if there is none.
            if !self.send_to_peer(peer) {
                self.settle();
                assert!(
                    self.send_to_peer(peer),
                    "The client has no channel to send a peer data over"
                );
            }
            self.deliver();
            let relayed = mem::take(&mut self.at_peers)
                .into_iter()
                .map(|t| (t.src, t.dst, t.payload.to_vec()))
                .collect::<Vec<_>>();
            assert_eq!(
                relayed,
                vec![(Some(address), peer, PAYLOAD.to_vec())],
                "The relay does not pass the client's data on to the peer from the relay address"
            );

            let now = self.clock.now();
            self.client.exec_mut(|c| c.received.clear());
            self.transmits
                .push(datagram(Some(peer), address, &PAYLOAD), LATENCY, now);
            self.deliver();
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
        let mut payload = channel_data::channel_data_packet_buffer(&PAYLOAD);
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
    fn connect(&mut self) {
        let now = self.clock.now();
        let lifetime_ends = (self.clock.now::<SystemTime>() + CREDENTIAL_LIFETIME)
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("the clock starts at the UNIX epoch");
        // Whole seconds, because that is what a username carries.
        let expire_at = SystemTime::UNIX_EPOCH + Duration::from_secs(lifetime_ends.as_secs());

        let relay = self.relay.inner();
        let (server, username, password, realm) = relay.explode(
            CLIENT_DEVICE,
            relay.sut.auth_secret(),
            relay.sut.public_address(),
            expire_at,
        );
        self.seeds += 1;
        let allocation = Allocation::new(
            server,
            Username::new(username).expect("username is short enough"),
            password,
            Realm::new(realm).expect("realm is short enough"),
            now,
            seed(self.seeds),
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
        from_client: bool,
        parse: bool,
        authenticate: bool,
        garbage: &Garbage,
    ) {
        let now = self.clock.now();
        let template = self.last_from_client.clone().filter(|_| garbage.mutate);
        let (src, device) = match from_client {
            true => {
                let src = template
                    .as_ref()
                    .and_then(|t| t.src)
                    .filter(|s| self.client.sending_socket_for(s.ip()) == Some(*s))
                    .unwrap_or_else(|| any_socket(&self.client));

                (src, CLIENT_DEVICE)
            }
            false if self.relay.ip4.is_some() => (
                SocketAddr::new(FOREIGN_IP4.into(), FOREIGN_PORT),
                FOREIGN_DEVICE,
            ),
            false => (
                SocketAddr::new(FOREIGN_IP6.into(), FOREIGN_PORT),
                FOREIGN_DEVICE,
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

        if parse {
            let now_utc = self.clock.now();
            let nonce =
                authenticate.then(|| self.relay.exec_mut(|r| r.issue_nonce(src, now, now_utc)));
            let Some(repaired) =
                stun::repair(&payload, nonce.as_ref(), device, &self.relay.inner().sut)
            else {
                return;
            };

            payload = repaired;
        }

        self.relay.receive(datagram(Some(src), dst, &payload), now);
    }

    fn garbage_to_client(&mut self, garbage: &Garbage) {
        if garbage.mutate {
            self.forgery = Some(garbage.clone());
            return;
        }

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
    pub(crate) fn settle(&mut self) {
        let deadline = self.clock.now::<Instant>() + MAX_SETTLE;
        let mut handovers = 0;

        loop {
            self.run(|now| {
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
            self.connect();
        }
    }

    /// Lets time pass, stopping at everything that is due on the way.
    fn advance(&mut self, duration: Duration) {
        let target = self.clock.now::<Instant>() + duration;

        self.run(|_| target);
        self.clock.skip_to(target);
    }

    /// Runs for as long as a datagram takes from the client to a peer or back.
    fn deliver(&mut self) {
        let arrived = self.clock.now::<Instant>() + 4 * LATENCY;

        self.run(|_| arrived);
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

        if self.relay.ip4.map(IpAddr::from) == Some(dst.ip())
            || self.relay.ip6.map(IpAddr::from) == Some(dst.ip())
        {
            if is_control && self.client.sending_socket_for(src.ip()) == Some(src) {
                self.last_from_client = Some(transmit.clone());

                if mem::take(&mut self.loss.to_relay) {
                    self.observed.lost_datagram = true;
                    return;
                }
            }

            self.relay.receive(transmit, now);
            return;
        }

        if dst == PEER_IP4 || dst == PEER_IP6 {
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
            if mem::take(&mut self.loss.to_client) {
                self.observed.lost_datagram = true;
                return;
            }

            if let Some(garbage) = self.forgery.take() {
                self.observed.forged_binding |= relay_client_proto::decode(&transmit.payload)
                    .is_ok_and(|message| message.is_ok_and(|m| m.method() == BINDING));

                let forged = datagram(Some(src), dst, &garbage.apply_to(&transmit.payload));
                self.client.exec_mut(|c| c.handle_input(forged, now));
            }
        }

        self.client.receive(transmit, now);
    }
}

impl Host<Client> {
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

impl Client {
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

    fn restart(&mut self, now: Instant, seed: [u8; 32]) {
        if let Some(allocation) = &mut self.allocation {
            allocation.restart(now, seed);
            self.forget_relay_addresses();
        }
    }

    fn forget_relay_addresses(&mut self) {
        self.relay_addresses_changed |= !self.relay_addresses.is_empty();
        self.relay_addresses.clear();
    }
}

impl PollTimeout for Client {
    fn poll_timeout(&mut self) -> Option<Instant> {
        self.allocation.as_ref()?.poll_timeout()
    }
}

impl ExecMutScope for Client {
    type Guard = ();

    fn enter(&self) -> Self::Guard {}
}

fn new_relay(stack: (bool, bool), boot: u64, now_utc: SystemTime) -> Host<SimRelay> {
    let (ip4, ip6) = interfaces(stack, RELAY_IP4, RELAY_IP6);

    host(SimRelay::new(boot, ip4, ip6, now_utc), RELAY_PORT, ip4, ip6)
}

/// A host that is reachable from everywhere.
fn host<T>(inner: T, port: u16, ip4: Option<Ipv4Addr>, ip6: Option<Ipv6Addr>) -> Host<T> {
    let mut host = Host::new(
        inner,
        LATENCY,
        port,
        EdgeConfig::Open,
        Ipv4Addr::UNSPECIFIED,
    );
    host.update_interface(ip4, ip6);

    host
}

/// Uses both address families if neither is asked for.
fn interfaces(
    (v4, v6): (bool, bool),
    ip4: Ipv4Addr,
    ip6: Ipv6Addr,
) -> (Option<Ipv4Addr>, Option<Ipv6Addr>) {
    let both = !v4 && !v6;

    ((v4 || both).then_some(ip4), (v6 || both).then_some(ip6))
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

fn seed(n: u64) -> [u8; 32] {
    let mut seed = [0u8; 32];
    seed[..8].copy_from_slice(&n.to_be_bytes());

    seed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_relays_data_on_a_working_network() {
        let mut world = World::new((true, true), (true, true), Instant::now());

        world.settle();

        assert_eq!(world.client.inner().relay_addresses.len(), 2);
        world.probe();
    }
}

//! A relay client and a relay, with a portal that hands the client the relay and its credentials.
//!
//! [`Allocation`] and the relay's `Server` are both sans-IO, so the world fits into one struct:
//! the two state machines, a clock and the datagrams in flight between them. Each [`Transition`]
//! runs until the two have settled. The [`Reference`] then says whether relaying must work, which
//! [`World::probe`] checks end to end, and whether the transition was allowed to interrupt it.

use std::{
    collections::{BTreeSet, VecDeque},
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::{Duration, Instant, SystemTime},
};

use arbitrary::Unstructured;
use bufferpool::Bytes;
use ip_packet::Ecn;
use is::CandidateKind;
use relay_client_proto::{Allocation, Event, RelaySocket, channel_data};
use relay_server_proto::{Command, auth};
use snownet::Transmit;
use stun_codec::rfc5389::{
    attributes::{Realm, Username},
    methods::BINDING,
};
use uuid::Uuid;

use crate::{
    relay_garbage as garbage,
    relay_reference::{Environment, Observed, Reference},
    relay_transition::{self as transition, Garbage, Loss, Target, Transition},
    sim_relay::SimRelay,
};

const MAX_TRANSITIONS: usize = 64;

/// How long the credentials are valid that the portal issues.
const CREDENTIAL_LIFETIME: Duration = Duration::from_secs(60 * 60);

/// A client retransmits a request within this time, so a timer this close belongs to an
/// exchange that is still going on.
const RETRANSMISSION: Duration = Duration::from_secs(4);

/// How often the portal hands the relay back to a client that keeps giving up on it.
const MAX_HANDOVERS: usize = 3;

/// More time than the client needs to give up on a relay that often.
const MAX_SETTLE: Duration = Duration::from_secs(60);

/// More datagrams than the client and the relay ever exchange without a timer firing.
const MAX_DATAGRAMS_PER_INSTANT: usize = 1000;

/// How long it takes at most until a client and a relay that went out of sync agree again.
///
/// The client notices a lost allocation at its next refresh; a channel that the relay bound
/// without the client knowing is in the way until its binding is gone.
const RESYNC: Duration = Duration::from_secs(16 * 60);

const RELAY_IP4: Ipv4Addr = Ipv4Addr::new(198, 51, 100, 1);
const RELAY_IP6: Ipv6Addr = Ipv6Addr::new(0x2001, 0xdb8, 1, 0, 0, 0, 0, 1);
const RELAY_PORT: u16 = 3478;

const CLIENT_IP4: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 10);
const CLIENT_IP6: Ipv6Addr = Ipv6Addr::new(0x2001, 0xdb8, 2, 0, 0, 0, 0, 10);
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

pub(crate) fn run(data: &[u8], now: Instant) {
    let mut u = Unstructured::new(data);
    let relay = transition::stack(&mut u);
    let client = transition::stack(&mut u);

    let mut reference = Reference::default();
    let mut world = World::new(relay, client, now);
    world.settle();
    world.check(&reference, true);

    for _ in 0..MAX_TRANSITIONS {
        if u.is_empty() {
            break;
        }

        let (transition, loss) = Transition::arbitrary(&mut u);
        tracing::debug!(?transition, ?loss);

        world.apply(&transition, loss);
        let may_interrupt = reference.apply(&transition, world.environment(), world.observed);
        world.check(&reference, may_interrupt);
    }
}

/// The client, the relay, the portal and the network between them.
struct World {
    start: Instant,
    now: Instant,

    relay: SimRelay,
    relay_sockets: Sockets,
    /// How often the relay rebooted. Every boot has a secret of its own, so it is a different
    /// relay to the portal.
    relay_boots: u64,

    portal_reachable: bool,
    /// The credentials that the portal last issued.
    credentials: Option<Credentials>,

    /// Absent while the client has given up on the relay and the portal did not hand it back.
    client: Option<Client>,
    sockets: Sockets,
    roams: u16,
    seeds: u64,

    to_relay: VecDeque<Datagram>,
    to_client: VecDeque<Datagram>,
    last_from_client: Option<Datagram>,
    partitioned: bool,
    /// What the current transition still loses.
    loss: Loss,
    /// Flips these bits in a copy of the relay's next control datagram and delivers it first.
    forgery: Option<Vec<u8>>,

    /// What happened during the current transition.
    observed: Observed,
    relay_addresses_changed: bool,
}

struct Client {
    allocation: Allocation,
    /// The relay addresses the allocation announced and did not invalidate since.
    relay_addresses: BTreeSet<SocketAddr>,
}

struct Credentials {
    /// The boot of the relay that they are for.
    relay_boot: u64,
    expire_at: Instant,
}

#[derive(Debug, Clone)]
struct Datagram {
    src: SocketAddr,
    dst: SocketAddr,
    payload: Vec<u8>,
}

/// The sockets of the client or the relay, at most one per address family.
#[derive(Debug, Clone, Copy)]
struct Sockets {
    v4: Option<SocketAddr>,
    v6: Option<SocketAddr>,
}

impl World {
    fn new(relay_stack: (bool, bool), client_stack: (bool, bool), start: Instant) -> Self {
        let relay_sockets = Sockets::new(relay_stack, RELAY_IP4, RELAY_IP6, RELAY_PORT);

        Self {
            start,
            now: start,
            relay: new_relay(relay_sockets, 0, utc(Duration::ZERO)),
            relay_sockets,
            relay_boots: 0,
            portal_reachable: true,
            credentials: None,
            client: None,
            sockets: Sockets::new(client_stack, CLIENT_IP4, CLIENT_IP6, 50000),
            roams: 0,
            seeds: 0,
            to_relay: VecDeque::new(),
            to_client: VecDeque::new(),
            last_from_client: None,
            partitioned: false,
            loss: Loss::default(),
            forgery: None,
            observed: Observed::default(),
            relay_addresses_changed: false,
        }
    }

    fn apply(&mut self, transition: &Transition, loss: Loss) {
        self.loss = loss;
        self.observed = Observed::default();
        self.relay_addresses_changed = false;

        match transition {
            Transition::Advance { duration } => self.advance(*duration),
            Transition::RotateCredentials => {
                if self.portal_reachable && self.client.is_some() {
                    self.connect();
                }
            }
            Transition::Refresh => {
                if let Some(client) = self.client.as_mut().filter(|_| self.portal_reachable) {
                    client.allocation.refresh(self.now);
                    self.tick_client();
                }
            }
            Transition::Roam { v4, v6 } => {
                self.roams += 1;
                self.seeds += 1;
                self.sockets = Sockets::new((*v4, *v6), CLIENT_IP4, CLIENT_IP6, 50000 + self.roams);

                if let Some(client) = &mut self.client {
                    client.allocation.restart(self.now, seed(self.seeds));
                    self.relay_addresses_changed |= !client.relay_addresses.is_empty();
                    client.relay_addresses.clear();
                    self.tick_client();
                }
            }
            Transition::RebootRelay => {
                self.relay_boots += 1;
                self.relay = new_relay(
                    self.relay_sockets,
                    self.relay_boots,
                    utc(self.now - self.start),
                );
            }
            Transition::Partition { duration } => {
                self.partitioned = true;
                self.advance(*duration);
                self.partitioned = false;
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
                }
                Target::Client => self.garbage_to_client(datagram),
            },
        }

        self.settle();
    }

    /// Checks the settled world against what the reference expects of the last transition.
    fn check(&mut self, reference: &Reference, may_interrupt: bool) {
        assert!(
            may_interrupt || !self.relay_addresses_changed,
            "The client's relay addresses changed in a transition that must not interrupt relaying"
        );

        if reference.must_relay(self.environment()) {
            self.probe();
        }
    }

    /// Sends data between a peer and the client through every relay address the client announced.
    fn probe(&mut self) {
        let addresses = self
            .client
            .as_ref()
            .map(|c| c.relay_addresses.clone())
            .unwrap_or_default();
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
            let to_peer = self.encode_to_peer(peer).or_else(|| {
                self.settle();
                self.encode_to_peer(peer)
            });
            let relayed = to_peer
                .and_then(|datagram| self.deliver_to_relay(datagram))
                .expect("The client's data does not make it through the relay");
            assert_eq!(
                (relayed.src, relayed.dst, &relayed.payload[..]),
                (Some(address), peer, &PAYLOAD[..]),
                "The relay passed the client's data on to the wrong place"
            );

            let relayed = self
                .deliver_to_relay(Datagram {
                    src: peer,
                    dst: address,
                    payload: PAYLOAD.to_vec(),
                })
                .expect("A peer's data does not make it through the relay");
            let src = relayed.src.expect("the relay sets a source");
            assert!(
                self.sockets.contains(relayed.dst),
                "The relay passed a peer's data on to a socket the client does not have"
            );

            let client = self
                .client
                .as_mut()
                .expect("the client has relay addresses");
            let received = channel_data::decode(&relayed.payload)
                .ok()
                .and_then(|packet| client.allocation.decapsulate(src, packet, self.now))
                .map(|(from, socket)| (from, socket.address()));
            assert_eq!(
                received,
                Some((peer, address)),
                "The client does not attribute a peer's data to the peer and the relay address"
            );
            self.tick_client();
        }
    }

    fn encode_to_peer(&mut self, peer: SocketAddr) -> Option<Datagram> {
        let client = self.client.as_mut()?;
        let mut payload = channel_data::channel_data_packet_buffer(&PAYLOAD);
        let encoded = client
            .allocation
            .encode_channel_data_header(peer, &mut payload, self.now);
        self.tick_client();

        let dst = encoded?.socket;
        let src = self.sockets.of_family(dst)?;

        Some(Datagram { src, dst, payload })
    }

    fn environment(&self) -> Environment {
        Environment {
            relay_reachable: (self.sockets.v4.is_some() && self.relay_sockets.v4.is_some())
                || (self.sockets.v6.is_some() && self.relay_sockets.v6.is_some()),
            portal_reachable: self.portal_reachable,
            credentials_valid: self
                .credentials
                .as_ref()
                .is_some_and(|c| c.relay_boot == self.relay_boots && self.now <= c.expire_at),
        }
    }

    /// The portal hands the client the relay with fresh credentials; the client starts over.
    fn connect(&mut self) {
        let server = match (self.relay_sockets.v4, self.relay_sockets.v6) {
            (Some(SocketAddr::V4(v4)), Some(SocketAddr::V6(v6))) => RelaySocket::from((v4, v6)),
            (v4, v6) => RelaySocket::from(v4.or(v6).expect("the relay has a socket")),
        };
        // Whole seconds, because that is what a username carries.
        let expires_after =
            Duration::from_secs((self.now - self.start + CREDENTIAL_LIFETIME).as_secs());
        let expiry = utc(expires_after)
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("expiry is later than the UNIX epoch")
            .as_secs();
        let username = username(expiry, CLIENT_DEVICE);
        let password = auth::generate_password(self.relay.sut.auth_secret(), &username);
        self.seeds += 1;

        let previous = self.client.replace(Client {
            allocation: Allocation::new(
                server,
                Username::new(username).expect("username is short enough"),
                password,
                Realm::new("firezone".to_owned()).expect("realm is short enough"),
                self.now,
                seed(self.seeds),
            ),
            relay_addresses: BTreeSet::new(),
        });
        self.credentials = Some(Credentials {
            relay_boot: self.relay_boots,
            expire_at: self.start + expires_after,
        });
        self.relay_addresses_changed |= previous.is_some_and(|c| !c.relay_addresses.is_empty());
        self.tick_client();
    }

    fn garbage_to_relay(
        &mut self,
        from_client: bool,
        parse: bool,
        authenticate: bool,
        garbage: &Garbage,
    ) {
        let template = self.last_from_client.clone().filter(|_| garbage.mutate);
        let (src, device) = match from_client {
            true => (
                self.sockets.like(template.as_ref().map(|d| d.src)),
                CLIENT_DEVICE,
            ),
            false if self.relay_sockets.v4.is_some() => (
                SocketAddr::new(FOREIGN_IP4.into(), FOREIGN_PORT),
                FOREIGN_DEVICE,
            ),
            false => (
                SocketAddr::new(FOREIGN_IP6.into(), FOREIGN_PORT),
                FOREIGN_DEVICE,
            ),
        };
        let Some(dst) = self.relay_sockets.of_family(src) else {
            return;
        };
        let mut payload = garbage::mutate(
            template.map(|d| d.payload).as_deref().unwrap_or_default(),
            &garbage.bytes,
        );

        if parse {
            let now_utc = utc(self.now - self.start);
            let nonce = authenticate
                .then(|| garbage::issued_nonce(&mut self.relay.sut, src, self.now, now_utc));
            let Some(repaired) = garbage::repair(&payload, nonce.as_ref(), device, &self.relay.sut)
            else {
                return;
            };

            payload = repaired;
        }

        let relayed = self.deliver_to_relay(Datagram { src, dst, payload });
        assert!(
            from_client || relayed.is_none(),
            "The relay passed on data from a foreign socket"
        );
    }

    fn garbage_to_client(&mut self, garbage: &Garbage) {
        if garbage.mutate {
            self.forgery = Some(garbage.bytes.clone());
            return;
        }

        let dst = self.sockets.like(None);
        let Some(src) = self.relay_sockets.of_family(dst) else {
            return;
        };

        self.deliver_to_client(Datagram {
            src,
            dst,
            payload: garbage.bytes.clone(),
        });
    }

    /// Lets the client and the relay finish what they are doing, and the portal react to it.
    ///
    /// Time only passes for retransmissions; refreshes and keep-alives wait for `advance`.
    fn settle(&mut self) {
        let deadline = self.now + MAX_SETTLE;
        let mut handovers = 0;

        loop {
            self.deliver_all();

            let credentials_valid = self.environment().credentials_valid;
            self.observed.credentials_lapsed |= !credentials_valid;

            let lacks_relay = self.client.is_none() || !credentials_valid;
            if lacks_relay && self.portal_reachable && handovers < MAX_HANDOVERS {
                handovers += 1;
                self.connect();
                continue;
            }

            let Some(timeout) = self
                .client
                .as_ref()
                .and_then(|c| c.allocation.poll_timeout())
                .filter(|t| *t <= self.now + RETRANSMISSION)
            else {
                return;
            };

            self.now = timeout;
            self.tick_relay();
            self.tick_client();

            assert!(
                self.now <= deadline,
                "The client and the relay do not settle"
            );
        }
    }

    /// Lets time pass, stopping at every timer of the client and the relay.
    fn advance(&mut self, duration: Duration) {
        let target = self.now + duration;

        while self.now < target {
            let next_timer = self
                .client
                .as_ref()
                .and_then(|c| c.allocation.poll_timeout())
                .into_iter()
                .chain(self.relay.sut.poll_timeout())
                .min();

            self.now = next_timer.map_or(target, |t| t.min(target)).max(self.now);
            self.tick_relay();
            self.tick_client();
            self.deliver_all();
        }
    }

    fn deliver_all(&mut self) {
        for _ in 0..MAX_DATAGRAMS_PER_INSTANT {
            if let Some(datagram) = self.to_relay.pop_front() {
                self.deliver_to_relay(datagram);
            } else if let Some(datagram) = self.to_client.pop_front() {
                self.deliver_to_client(datagram);
            } else {
                return;
            }
        }

        panic!("The client and the relay keep exchanging datagrams without time passing");
    }

    fn tick_relay(&mut self) {
        if self.relay.sut.poll_timeout().is_some_and(|t| t <= self.now) {
            self.relay.sut.handle_timeout(self.now);
            self.drain_relay();
        }

        assert!(
            self.relay.sut.poll_timeout().is_none_or(|t| t > self.now),
            "The relay keeps a timer that is due after handling timeouts"
        );
    }

    /// Runs the client the way `snownet` does: handle timeouts, drain events, free what gave up.
    fn tick_client(&mut self) {
        let Some(client) = &mut self.client else {
            return;
        };

        client.allocation.handle_timeout(self.now);

        while let Some(event) = client.allocation.poll_event() {
            let (candidate, is_new) = match event {
                Event::New(candidate) => (candidate, true),
                Event::Invalid(candidate) => (candidate, false),
            };
            if candidate.kind() != CandidateKind::Relayed {
                continue;
            }

            self.relay_addresses_changed = true;
            match is_new {
                true => client.relay_addresses.insert(candidate.addr()),
                false => client.relay_addresses.remove(&candidate.addr()),
            };
        }

        let transmits =
            std::iter::from_fn(|| client.allocation.poll_transmit()).collect::<Vec<_>>();
        let gave_up = client.allocation.can_be_freed();
        let timeout = client.allocation.poll_timeout();

        for transmit in transmits {
            self.send_from_client(transmit.dst, transmit.payload.to_vec());
        }

        if let Some(reason) = gave_up {
            tracing::debug!(%reason, "Client gives up on the relay");

            let client = self.client.take().expect("we just had a client");
            self.relay_addresses_changed |= !client.relay_addresses.is_empty();

            return;
        }

        assert!(
            timeout.is_none_or(|t| t > self.now),
            "The client keeps a timer that is due after handling timeouts"
        );
    }

    fn send_from_client(&mut self, dst: SocketAddr, payload: Vec<u8>) {
        // Without a socket of that address family, the datagram never leaves the client.
        let Some(src) = self.sockets.of_family(dst) else {
            return;
        };
        let datagram = Datagram { src, dst, payload };
        self.last_from_client = Some(datagram.clone());

        if self.partitioned {
            return;
        }
        if std::mem::take(&mut self.loss.to_relay) {
            self.observed.lost_datagram = true;
            return;
        }

        self.to_relay.push_back(datagram);
    }

    /// Hands a datagram to the relay, returning the data that the relay passes on because of it.
    fn deliver_to_relay(&mut self, datagram: Datagram) -> Option<Transmit> {
        let relayed = self.relay.receive(
            Transmit {
                src: Some(datagram.src),
                dst: datagram.dst,
                payload: Bytes::copied_from(&datagram.payload),
                ecn: Ecn::NonEct,
            },
            self.now,
            utc(self.now - self.start),
        );
        self.drain_relay();

        relayed
    }

    fn drain_relay(&mut self) {
        while let Some(command) = self.relay.sut.next_command() {
            match command {
                Command::SendMessage { payload, recipient } => {
                    let dst = recipient.into_socket();
                    let src = self
                        .relay_sockets
                        .of_family(dst)
                        .expect("the relay answers from the socket it was reached on");

                    self.send_from_relay(Datagram { src, dst, payload });
                }
                Command::CreateAllocation { port, family } => {
                    self.relay.allocations.insert((family, port));
                }
                Command::FreeAllocation { port, family } => {
                    self.relay.allocations.remove(&(family, port));
                }
                Command::CreateChannelBinding { .. } | Command::DeleteChannelBinding { .. } => {}
            }
        }
    }

    fn send_from_relay(&mut self, datagram: Datagram) {
        // Answers to foreign sockets and to sockets the client left go nowhere.
        if !self.sockets.contains(datagram.dst) || self.partitioned {
            return;
        }
        if std::mem::take(&mut self.loss.to_client) {
            self.observed.lost_datagram = true;
            return;
        }

        if let Some(mask) = self.forgery.take() {
            self.observed.forged_binding |= relay_client_proto::decode(&datagram.payload)
                .is_ok_and(|message| message.is_ok_and(|m| m.method() == BINDING));
            self.to_client.push_back(Datagram {
                payload: garbage::mutate(&datagram.payload, &mask),
                ..datagram.clone()
            });
        }
        self.to_client.push_back(datagram);
    }

    fn deliver_to_client(&mut self, datagram: Datagram) {
        if !self.sockets.contains(datagram.dst) {
            return;
        }
        let Some(client) = &mut self.client else {
            return;
        };

        match datagram.payload.first() {
            Some(0..=3) => {
                if let Ok(Ok(message)) = relay_client_proto::decode(&datagram.payload) {
                    client
                        .allocation
                        .handle_input(datagram.src, datagram.dst, message, self.now);
                }
            }
            Some(64..=79) => {
                if let Ok(packet) = channel_data::decode(&datagram.payload) {
                    client
                        .allocation
                        .decapsulate(datagram.src, packet, self.now);
                }
            }
            _ => {}
        }

        self.tick_client();
    }
}

impl Sockets {
    /// Uses both address families if neither is asked for.
    fn new((v4, v6): (bool, bool), ip4: Ipv4Addr, ip6: Ipv6Addr, port: u16) -> Self {
        let both = !v4 && !v6;

        Self {
            v4: (v4 || both).then_some(SocketAddr::new(ip4.into(), port)),
            v6: (v6 || both).then_some(SocketAddr::new(ip6.into(), port)),
        }
    }

    fn contains(&self, socket: SocketAddr) -> bool {
        self.v4 == Some(socket) || self.v6 == Some(socket)
    }

    /// The socket of the same address family as `other`.
    fn of_family(&self, other: SocketAddr) -> Option<SocketAddr> {
        match other {
            SocketAddr::V4(_) => self.v4,
            SocketAddr::V6(_) => self.v6,
        }
    }

    /// The given socket if it is one of ours, any of ours otherwise.
    fn like(&self, socket: Option<SocketAddr>) -> SocketAddr {
        socket
            .filter(|s| self.contains(*s))
            .or(self.v4)
            .or(self.v6)
            .expect("there is at least one socket")
    }
}

fn new_relay(sockets: Sockets, boot: u64, now_utc: SystemTime) -> SimRelay {
    SimRelay::new(
        boot,
        sockets.v4.map(|_| RELAY_IP4),
        sockets.v6.map(|_| RELAY_IP6),
        now_utc,
    )
}

/// The wall-clock time, `since_start` into the simulation.
///
/// Fixed rather than taken from the system so that credential expiry does not depend on when
/// the simulation runs.
fn utc(since_start: Duration) -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000) + since_start
}

fn seed(n: u64) -> [u8; 32] {
    let mut seed = [0u8; 32];
    seed[..8].copy_from_slice(&n.to_be_bytes());

    seed
}

/// A username of the account that the relay serves.
pub(crate) fn username(expiry: impl fmt::Display, device: &str) -> String {
    let account = auth::hash_account_id(&auth::AccountId::from(Uuid::nil()));

    format!("{expiry}:{account}:{device}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_relays_data_on_a_working_network() {
        let mut world = World::new((true, true), (true, true), Instant::now());

        world.settle();

        let client = world.client.as_ref().unwrap();
        assert_eq!(client.relay_addresses.len(), 2);
        world.probe();
    }
}

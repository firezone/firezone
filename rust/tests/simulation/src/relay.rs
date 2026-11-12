//! A relay client and a relay, talking to each other over an unreliable network.
//!
//! [`Allocation`] and the relay's `Server` are both sans-IO, so the whole world fits into
//! one struct: the two state machines, a clock and the datagrams in flight between them.
//! The input is a list of [`Transition`]s. There is no reference model; every transition
//! instead checks the properties listed on [`World`].

use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::{Duration, Instant, SystemTime},
};

use arbitrary::Unstructured;
use bufferpool::Bytes;
use ip_packet::Ecn;
use is::{Candidate, CandidateKind};
use relay_client_proto::{Allocation, Event, RelaySocket, channel_data};
use relay_server_proto::{AddressFamily, Command, auth};
use snownet::Transmit;
use stun_codec::rfc5389::attributes::{Realm, Username};
use uuid::Uuid;

use crate::{
    relay_garbage as garbage,
    relay_transition::{self as transition, Direction, Garbage, Sender, Transition},
    sim_relay::SimRelay,
};

const MAX_TRANSITIONS: usize = 256;

/// How long a working network gets to bring the client and the relay back in sync.
///
/// The client notices at its next refresh that the relay lost its allocation, which is at most
/// five minutes away.
const CONVERGENCE: Duration = Duration::from_secs(15 * 60);

/// More datagrams than the client and the relay ever exchange without a timer firing.
const MAX_DATAGRAMS_PER_INSTANT: usize = 1000;

/// Longer than an input can make time pass, so the client's credentials never expire.
const CREDENTIAL_LIFETIME: Duration = Duration::from_secs(7 * 24 * 60 * 60);

const RELAY_IP4: Ipv4Addr = Ipv4Addr::new(198, 51, 100, 1);
const RELAY_IP6: Ipv6Addr = Ipv6Addr::new(0x2001, 0xdb8, 1, 0, 0, 0, 0, 1);
const RELAY_PORT: u16 = 3478;

const CLIENT_IP4: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 10);
const CLIENT_IP6: Ipv6Addr = Ipv6Addr::new(0x2001, 0xdb8, 2, 0, 0, 0, 0, 10);
const CLIENT_DEVICE: &str = "client";

const FOREIGN_IP4: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 200);
const FOREIGN_IP6: Ipv6Addr = Ipv6Addr::new(0x2001, 0xdb8, 2, 0, 0, 0, 0, 200);
const FOREIGN_PORT: u16 = 7000;

const PEERS: [SocketAddr; 3] = [
    SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10)), 40000),
    SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 0, 2, 11)), 40001),
    SocketAddr::new(
        IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 3, 0, 0, 0, 0, 10)),
        40000,
    ),
];

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
    let mut world = World::new(relay, client, now);

    for _ in 0..MAX_TRANSITIONS {
        if u.is_empty() {
            break;
        }

        let transition = Transition::arbitrary(&mut u);
        tracing::debug!(?transition);

        world.apply(transition);
    }

    world.converge();
}

/// The client, the relay and everything between them.
///
/// # Properties
///
/// - Neither state machine panics or logs an error.
/// - Handling a timeout leaves no timer at or before the current time, and the client and
///   the relay never exchange datagrams endlessly without time passing.
/// - The candidates the client announces and invalidates are the ones it holds.
/// - The relay passes data only between a client and the allocation of that client.
/// - Nothing a foreign socket sends changes what the relay holds for the client, or reaches
///   the client.
/// - The client ignores what fails the integrity check.
/// - On a working network, the client and the relay end up agreeing on the allocation. The
///   client only gives up on a relay it cannot reach.
struct World {
    start: Instant,
    now: Instant,

    relay: SimRelay,
    relay_sockets: Sockets,
    /// How often the relay rebooted.
    relay_generation: u64,
    /// The client socket that each allocated port was allocated from.
    owners: BTreeMap<u16, SocketAddr>,

    /// Absent once the client gave up its allocation, until the portal announces the relay again.
    client: Option<Client>,
    sockets: Sockets,
    roams: u16,
    seeds: u64,

    to_relay: VecDeque<Datagram>,
    to_client: VecDeque<Datagram>,
    last_from_client: Option<Datagram>,
    last_from_relay: Option<Datagram>,
}

struct Client {
    allocation: Allocation,
    relay_generation: u64,
    username: Username,
    realm: Realm,
    password: String,
    /// The candidates the allocation announced and did not invalidate since.
    announced: Vec<Candidate>,
}

/// What a client shows of itself.
#[derive(Debug, PartialEq)]
struct Observable {
    relay_candidates: Vec<Candidate>,
    other_candidates: Vec<Candidate>,
    timeout: Option<Instant>,
    active_socket: Option<SocketAddr>,
    rtt: Option<Duration>,
    has_credentials: bool,
}

#[derive(Debug, Clone, PartialEq)]
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

        let mut world = Self {
            start,
            now: start,
            relay: new_relay(relay_sockets, 0, utc(Duration::ZERO)),
            relay_sockets,
            relay_generation: 0,
            owners: BTreeMap::new(),
            client: None,
            sockets: Sockets::new(client_stack, CLIENT_IP4, CLIENT_IP6, 50000),
            roams: 0,
            seeds: 0,
            to_relay: VecDeque::new(),
            to_client: VecDeque::new(),
            last_from_client: None,
            last_from_relay: None,
        };
        world.connect();

        world
    }

    fn apply(&mut self, transition: Transition) {
        match transition {
            Transition::Settle => self.settle(),
            Transition::Deliver(Direction::ToRelay) => {
                if let Some(datagram) = self.to_relay.pop_front() {
                    self.deliver_to_relay(datagram);
                }
            }
            Transition::Deliver(Direction::ToClient) => {
                if let Some(datagram) = self.to_client.pop_front() {
                    self.deliver_to_client(datagram);
                }
            }
            Transition::Drop(Direction::ToRelay) => {
                self.to_relay.pop_front();
            }
            Transition::Drop(Direction::ToClient) => {
                self.to_client.pop_front();
            }
            Transition::DropAll => {
                self.to_relay.clear();
                self.to_client.clear();
            }
            Transition::Advance { duration, deliver } => self.advance(duration, deliver),
            Transition::Refresh => {
                if let Some(client) = &mut self.client {
                    client.allocation.refresh(self.now);
                }
                self.tick_client();
            }
            Transition::BindChannel { peer } => {
                if let Some(client) = &mut self.client {
                    client
                        .allocation
                        .bind_channel(PEERS[peer % PEERS.len()], self.now);
                }
                self.tick_client();
            }
            Transition::SendToPeer { peer } => self.send_to_peer(PEERS[peer % PEERS.len()]),
            Transition::PeerSends { peer } => self.peer_sends(PEERS[peer % PEERS.len()]),
            Transition::Roam { v4, v6 } => {
                self.roams += 1;
                self.seeds += 1;
                self.sockets = Sockets::new((v4, v6), CLIENT_IP4, CLIENT_IP6, 50000 + self.roams);

                if let Some(client) = &mut self.client {
                    client.allocation.restart(self.now, seed(self.seeds));
                    client.announced.clear();
                }
                self.tick_client();
            }
            Transition::RebootRelay => {
                self.relay_generation += 1;
                self.relay = new_relay(
                    self.relay_sockets,
                    self.relay_generation,
                    utc(self.now - self.start),
                );
                self.owners.clear();
            }
            Transition::AnnounceRelay => self.announce_relay(),
            Transition::SetRelayCapacity { exhausted } => self.relay.out_of_capacity = exhausted,
            Transition::GarbageToRelay {
                sender,
                parse,
                authenticate,
                datagram,
            } => self.garbage_to_relay(sender, parse, authenticate, datagram),
            Transition::GarbageToClient(datagram) => self.garbage_to_client(datagram),
        }
    }

    /// Gives a working network time and checks where the client and the relay end up.
    fn converge(&mut self) {
        self.relay.out_of_capacity = false;
        self.settle();

        // The second announcement is for a client that gives up during the first round.
        for _ in 0..2 {
            self.announce_relay();
            self.advance(CONVERGENCE, true);
        }

        let Some(client) = &self.client else {
            let is_reachable = (self.sockets.v4.is_some() && self.relay_sockets.v4.is_some())
                || (self.sockets.v6.is_some() && self.relay_sockets.v6.is_some());
            assert!(!is_reachable, "The client gave up on a relay that works");

            return;
        };

        let socket = client
            .allocation
            .active_socket()
            .and_then(|relay| self.sockets.of_family(relay));
        let held_by_client = client
            .allocation
            .current_relay_candidates()
            .map(|c| c.addr())
            .collect::<BTreeSet<_>>();
        let held_by_relay = self
            .relay
            .allocations
            .iter()
            .filter(|(_, port)| self.owners.get(&port.value()) == socket.as_ref())
            .map(|(family, port)| match family {
                AddressFamily::V4 => SocketAddr::new(RELAY_IP4.into(), port.value()),
                AddressFamily::V6 => SocketAddr::new(RELAY_IP6.into(), port.value()),
            })
            .collect::<BTreeSet<_>>();

        assert!(
            !held_by_client.is_empty(),
            "The client neither holds an allocation nor gives it up"
        );
        assert_eq!(
            held_by_client, held_by_relay,
            "The client and the relay disagree on the allocation"
        );
    }

    /// The portal announces the relay; a client that is connected to it does nothing.
    fn announce_relay(&mut self) {
        let is_connected = self
            .client
            .as_ref()
            .is_some_and(|c| c.relay_generation == self.relay_generation);

        if !is_connected {
            self.connect();
        }
    }

    /// The client starts a new allocation with credentials the portal issues for it.
    fn connect(&mut self) {
        let server = match (self.relay_sockets.v4, self.relay_sockets.v6) {
            (Some(SocketAddr::V4(v4)), Some(SocketAddr::V6(v6))) => RelaySocket::from((v4, v6)),
            (v4, v6) => RelaySocket::from(v4.or(v6).expect("the relay has a socket")),
        };
        let expiry = (utc(self.now - self.start) + CREDENTIAL_LIFETIME)
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("expiry is later than the UNIX epoch")
            .as_secs();
        let username = username(expiry, CLIENT_DEVICE);
        let password = auth::generate_password(self.relay.sut.auth_secret(), &username);
        let username = Username::new(username).expect("username is short enough");
        let realm = Realm::new("firezone".to_owned()).expect("realm is short enough");
        self.seeds += 1;

        self.client = Some(Client {
            allocation: Allocation::new(
                server,
                username.clone(),
                password.clone(),
                realm.clone(),
                self.now,
                seed(self.seeds),
            ),
            relay_generation: self.relay_generation,
            username,
            realm,
            password,
            announced: Vec::new(),
        });
        self.tick_client();
    }

    fn send_to_peer(&mut self, peer: SocketAddr) {
        let Some(client) = &mut self.client else {
            return;
        };

        let mut datagram = channel_data::channel_data_packet_buffer(&PAYLOAD);
        let encoded = client
            .allocation
            .encode_channel_data_header(peer, &mut datagram, self.now);

        if let Some(encoded) = encoded {
            self.send_from_client(encoded.socket, datagram);
        }
        self.tick_client();
    }

    fn peer_sends(&mut self, peer: SocketAddr) {
        let Some(client) = &self.client else {
            return;
        };
        let socket = match peer {
            SocketAddr::V4(_) => client.allocation.ip4_socket(),
            SocketAddr::V6(_) => client.allocation.ip6_socket(),
        };
        let Some(socket) = socket else {
            return;
        };

        self.deliver_to_relay(Datagram {
            src: peer,
            dst: socket.address(),
            payload: PAYLOAD.to_vec(),
        });
    }

    fn garbage_to_relay(
        &mut self,
        sender: Sender,
        parse: bool,
        authenticate: bool,
        garbage: Garbage,
    ) {
        let template = self
            .last_from_client
            .as_ref()
            .filter(|_| garbage.mutate_last);
        let src = match sender {
            Sender::Client => self.sockets.like(template.map(|d| d.src)),
            Sender::Foreign if self.relay_sockets.v4.is_some() => {
                SocketAddr::new(FOREIGN_IP4.into(), FOREIGN_PORT)
            }
            Sender::Foreign => SocketAddr::new(FOREIGN_IP6.into(), FOREIGN_PORT),
        };
        let Some(dst) = self.relay_sockets.of_family(src) else {
            return;
        };
        let mut payload = garbage::mutate(
            template.map(|d| d.payload.as_slice()).unwrap_or_default(),
            &garbage.bytes,
        );

        if parse {
            let now_utc = utc(self.now - self.start);
            let nonce = authenticate
                .then(|| garbage::issued_nonce(&mut self.relay.sut, src, self.now, now_utc));
            let Some(repaired) = garbage::repair(&payload, nonce.as_ref(), sender, &self.relay.sut)
            else {
                return;
            };

            payload = repaired;
        }

        self.deliver_to_relay(Datagram { src, dst, payload });
    }

    fn garbage_to_client(&mut self, garbage: Garbage) {
        self.tick_client();

        let Some(client) = &self.client else {
            return;
        };
        let template = self
            .last_from_relay
            .as_ref()
            .filter(|_| garbage.mutate_last);
        let dst = self.sockets.like(template.map(|d| d.dst));
        let Some(src) = self.relay_sockets.of_family(dst) else {
            return;
        };
        let payload = garbage::mutate(
            template.map(|d| d.payload.as_slice()).unwrap_or_default(),
            &garbage.bytes,
        );

        let must_be_ignored = garbage::fails_integrity_check(
            &payload,
            &client.username,
            &client.realm,
            &client.password,
        );
        let before = (Some(client.observable()), self.to_relay.len());

        self.deliver_to_client(Datagram { src, dst, payload });

        if must_be_ignored {
            let after = (
                self.client.as_ref().map(Client::observable),
                self.to_relay.len(),
            );

            assert_eq!(
                before, after,
                "The client reacted to a datagram that fails the integrity check"
            );
        }
    }

    /// Delivers datagrams until none are in flight.
    fn settle(&mut self) {
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

    /// Lets time pass, stopping at every timer of the client and the relay.
    fn advance(&mut self, duration: Duration, deliver: bool) {
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

            if deliver {
                self.settle();
            }
        }
    }

    fn tick_relay(&mut self) {
        if self.relay.sut.poll_timeout().is_some_and(|t| t <= self.now) {
            self.relay.sut.handle_timeout(self.now);
            self.drain_relay(None);
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
        client.drain_events();

        let transmits =
            std::iter::from_fn(|| client.allocation.poll_transmit()).collect::<Vec<_>>();
        for transmit in transmits {
            self.send_from_client(transmit.dst, transmit.payload.to_vec());
        }

        let Some(client) = &mut self.client else {
            return;
        };

        if let Some(reason) = client.allocation.can_be_freed() {
            tracing::debug!(%reason, "Client gives up its allocation");
            self.client = None;

            return;
        }

        assert!(
            client
                .allocation
                .poll_timeout()
                .is_none_or(|t| t > self.now),
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
        self.to_relay.push_back(datagram);
    }

    fn deliver_to_relay(&mut self, datagram: Datagram) {
        let reply = self.relay.receive(
            Transmit {
                src: Some(datagram.src),
                dst: datagram.dst,
                payload: Bytes::copied_from(&datagram.payload),
                ecn: Ecn::NonEct,
            },
            self.now,
            utc(self.now - self.start),
        );
        self.drain_relay(Some(datagram.src));

        let Some(reply) = reply else {
            return;
        };
        let reply_src = reply.src.expect("the relay sets a source");

        if datagram.dst.port() != RELAY_PORT {
            assert_eq!(
                self.owners.get(&datagram.dst.port()),
                Some(&reply.dst),
                "The relay passed data from a peer to a client that does not hold the allocation"
            );
        } else if reply_src.port() != RELAY_PORT {
            assert_eq!(
                self.owners.get(&reply_src.port()),
                Some(&datagram.src),
                "The relay sent a client's data from an allocation that client does not hold"
            );

            return;
        }

        self.queue_to_client(Datagram {
            src: reply_src,
            dst: reply.dst,
            payload: reply.payload.to_vec(),
        });
    }

    /// Carries out what the relay decided on a timeout or on a datagram from `sender`.
    fn drain_relay(&mut self, sender: Option<SocketAddr>) {
        let is_foreign = sender.is_some_and(|s| s.port() == FOREIGN_PORT);

        while let Some(command) = self.relay.sut.next_command() {
            let concerns = match command {
                Command::SendMessage { payload, recipient } => {
                    let dst = recipient.into_socket();
                    let src = self
                        .relay_sockets
                        .of_family(dst)
                        .expect("the relay answers from the socket it was reached on");
                    self.queue_to_client(Datagram { src, dst, payload });

                    dst
                }
                Command::CreateAllocation { port, family } => {
                    let client = sender.expect("the relay only allocates when asked to");
                    let owner = *self.owners.entry(port.value()).or_insert(client);
                    assert_eq!(owner, client, "The relay allocated a port twice");
                    self.relay.allocations.insert((family, port));

                    client
                }
                Command::FreeAllocation { port, family } => {
                    self.relay.allocations.remove(&(family, port));

                    // An allocation on both address families is freed with two commands.
                    let Some(owner) = self.owners.remove(&port.value()) else {
                        continue;
                    };

                    owner
                }
                Command::CreateChannelBinding { client, .. }
                | Command::DeleteChannelBinding { client, .. } => client.into_socket(),
            };

            assert!(
                !(is_foreign && self.sockets.contains(concerns)),
                "A foreign socket changed what the relay holds for the client, or reached the client"
            );
        }
    }

    fn queue_to_client(&mut self, datagram: Datagram) {
        // Answers to foreign sockets and to sockets the client left go nowhere.
        if !self.sockets.contains(datagram.dst) {
            return;
        }

        self.last_from_relay = Some(datagram.clone());
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

impl Client {
    /// Records what the allocation announced and checks it against what it holds.
    fn drain_events(&mut self) {
        while let Some(event) = self.allocation.poll_event() {
            match event {
                Event::New(candidate) => {
                    if !self.announced.contains(&candidate) {
                        self.announced.push(candidate);
                    }
                }
                Event::Invalid(candidate) => {
                    let position = self
                        .announced
                        .iter()
                        .position(|c| c == &candidate)
                        .expect("The client invalidated a candidate it never announced");

                    self.announced.remove(position);
                }
            }
        }

        let observable = self.observable();
        let mut announced_relay_candidates = self
            .announced
            .iter()
            .filter(|c| c.kind() == CandidateKind::Relayed)
            .cloned()
            .collect::<Vec<_>>();
        announced_relay_candidates.sort_by_key(|c| c.addr());

        assert_eq!(
            observable.relay_candidates, announced_relay_candidates,
            "The relay candidates the client holds are not the ones it announced"
        );
        for candidate in observable.other_candidates {
            assert!(
                self.announced.contains(&candidate),
                "The client holds a candidate it never announced: {candidate:?}"
            );
        }
    }

    fn observable(&self) -> Observable {
        let mut relay_candidates = self
            .allocation
            .current_relay_candidates()
            .collect::<Vec<_>>();
        relay_candidates.sort_by_key(|c| c.addr());

        Observable {
            relay_candidates,
            other_candidates: self
                .allocation
                .host_and_server_reflexive_candidates()
                .collect(),
            timeout: self.allocation.poll_timeout(),
            active_socket: self.allocation.active_socket(),
            rtt: self.allocation.rtt(),
            has_credentials: self.allocation.has_credentials(),
        }
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

fn new_relay(sockets: Sockets, generation: u64, now_utc: SystemTime) -> SimRelay {
    SimRelay::new(
        generation,
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
    fn client_allocates_on_a_working_network() {
        let mut world = World::new((true, true), (true, true), Instant::now());

        world.apply(Transition::Settle);

        let client = world.client.as_ref().unwrap();
        assert_eq!(client.allocation.current_relay_candidates().count(), 2);
        world.converge();
    }
}

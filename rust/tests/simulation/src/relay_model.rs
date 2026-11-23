//! The relay simulation's model: what the client is connected to and whether a transition may
//! interrupt relaying.
//!
//! It only knows the transitions and the interference that were asked for, never what the
//! client or the relay made of them.

use std::{
    collections::BTreeMap,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Duration,
};

use connlib_model::IpStack;

use crate::relay_transition::{Interference, Transition};

/// The sockets that the client relays data to, two per address family.
pub(crate) const PEERS: [SocketAddr; 4] = [
    SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10)), 40000),
    SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 0, 2, 11)), 40001),
    SocketAddr::new(
        IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 3, 0, 0, 0, 0, 10)),
        40000,
    ),
    SocketAddr::new(
        IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 3, 0, 0, 0, 0, 11)),
        40001,
    ),
];

/// How many transmissions of a request may get lost: a client sends each one four times, after
/// 0, 1, 2.5 and 4.75 seconds.
const RETRANSMISSION_BUDGET: u8 = 3;

/// The longest partition or sleep that the last transmission of every request outlasts, with the
/// latencies that the hosts may have.
const BRIDGED_PARTITION: Duration = Duration::from_secs(4);

#[derive(Debug)]
pub(crate) struct RelayModel {
    pub(crate) relay: ModelHost,
    pub(crate) client: ModelHost,
    /// A host on the internet that has nothing to do with the client.
    pub(crate) foreign: ModelHost,

    /// The peers that the client is connected to, and whether each connection is established:
    /// it relayed data since relaying was last disrupted.
    pub(crate) connections: BTreeMap<SocketAddr, bool>,

    /// Whether relaying was disrupted since the system last settled.
    disrupted: bool,
    /// How many transmissions a request may have lost since the system last settled.
    lost_transmissions: u8,

    /// How much time the transitions let pass.
    elapsed: Duration,
    /// When the credentials that the client holds expire, on the clock of `elapsed`.
    pub(crate) credentials_expire_at: Duration,
}

/// A host with an address of each family, of which it uses those in `stack`.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ModelHost {
    pub(crate) ip4: Ipv4Addr,
    pub(crate) ip6: Ipv6Addr,
    pub(crate) port: u16,
    pub(crate) stack: IpStack,
    /// How long the host takes to send a datagram, and again to receive one.
    pub(crate) latency: Duration,
}

impl RelayModel {
    pub(crate) fn new(
        relay: ModelHost,
        client: ModelHost,
        foreign: ModelHost,
        credentials_lifetime: Duration,
    ) -> Self {
        Self {
            relay,
            client,
            foreign,
            connections: PEERS.into_iter().map(|peer| (peer, false)).collect(),
            disrupted: true,
            lost_transmissions: 0,
            elapsed: Duration::ZERO,
            credentials_expire_at: expiry(Duration::ZERO, credentials_lifetime),
        }
    }

    /// Whether relaying must work once the system has settled: whenever the client's
    /// credentials are valid and the client and the relay share an address family.
    pub(crate) fn must_relay(&self) -> bool {
        let shares_family = (self.client.stack.supports_ipv4() && self.relay.stack.supports_ipv4())
            || (self.client.stack.supports_ipv6() && self.relay.stack.supports_ipv6());

        shares_family && !self.credentials_expired()
    }

    /// Whether the relay can relay data between the client and `peer`: it needs an address of
    /// the peer's family to send from.
    pub(crate) fn can_relay(&self, peer: SocketAddr) -> bool {
        let reaches_peer = match peer {
            SocketAddr::V4(_) => self.relay.stack.supports_ipv4(),
            SocketAddr::V6(_) => self.relay.stack.supports_ipv6(),
        };

        self.must_relay() && reaches_peer
    }

    /// Whether the client's relay addresses may have changed since the system last settled.
    ///
    /// With expired credentials, they may change at any time.
    pub(crate) fn disrupted(&self) -> bool {
        self.disrupted || self.credentials_expired()
    }

    /// Whether the credentials that the client holds expired: relaying keeps working until the
    /// client or the relay notices.
    pub(crate) fn credentials_expired(&self) -> bool {
        self.credentials_expire_at < self.elapsed
    }

    pub(crate) fn apply(&mut self, transition: &Transition, interference: &Interference) {
        let credentials_were_expired = self.credentials_expired();

        self.lost_transmissions = self
            .lost_transmissions
            .saturating_add(interference.lose_to_relay)
            .saturating_add(interference.lose_to_client);

        match transition {
            Transition::Roam { ip4, ip6 } => {
                self.client.stack = match (ip4, ip6) {
                    (Some(_), Some(_)) => IpStack::Dual,
                    (Some(_), None) => IpStack::Ipv4Only,
                    (None, _) => IpStack::Ipv6Only,
                };
                self.disrupted = true;
            }
            Transition::RebootRelay => self.disrupted = true,
            Transition::Partition { duration } if *duration > BRIDGED_PARTITION => {
                self.elapsed += *duration;
                self.disrupted = true;
            }
            // Costs every request that is in flight all but its last transmission.
            Transition::Partition { duration } => {
                self.elapsed += *duration;
                self.lost_transmissions = self
                    .lost_transmissions
                    .saturating_add(RETRANSMISSION_BUDGET);
            }
            Transition::Sleep { duration } if *duration > BRIDGED_PARTITION => {
                self.elapsed += *duration;
                self.disrupted = true;
            }
            // Costs every request that is in flight all but its last transmission.
            Transition::Sleep { duration } => {
                self.elapsed += *duration;
                self.lost_transmissions = self
                    .lost_transmissions
                    .saturating_add(RETRANSMISSION_BUDGET);
            }
            Transition::Advance { duration } => self.elapsed += *duration,
            Transition::RotateCredentials { lifetime } => {
                self.credentials_expire_at = expiry(self.elapsed, *lifetime);
            }
            Transition::Connect { peer } => {
                self.connections.entry(*peer).or_insert(false);
            }
            Transition::Disconnect { peer } => {
                self.connections.remove(peer);
            }
            Transition::InjectDatagram(_) => {}
        }

        // Expired credentials cost the client its allocation once it or the relay notices.
        self.disrupted |= credentials_were_expired || self.credentials_expired();

        self.disrupted |= self.lost_transmissions > RETRANSMISSION_BUDGET;

        if self.disrupted {
            for established in self.connections.values_mut() {
                *established = false;
            }
        }
    }

    /// Records that the system settled and relays data for every connection it can.
    pub(crate) fn settle(&mut self) {
        for peer in PEERS {
            let can_relay = self.can_relay(peer);

            self.connections
                .entry(peer)
                .and_modify(|established| *established = can_relay);
        }
        self.disrupted = false;
        self.lost_transmissions = 0;
    }
}

/// When credentials issued at `issued_at` for `lifetime` expire: their expiry has a resolution of
/// whole seconds.
fn expiry(issued_at: Duration, lifetime: Duration) -> Duration {
    Duration::from_secs((issued_at + lifetime).as_secs())
}

impl ModelHost {
    /// The host's interfaces if it had the address families of `stack`.
    pub(crate) fn interfaces(&self, stack: IpStack) -> (Option<Ipv4Addr>, Option<Ipv6Addr>) {
        match stack {
            IpStack::Dual => (Some(self.ip4), Some(self.ip6)),
            IpStack::Ipv4Only => (Some(self.ip4), None),
            IpStack::Ipv6Only => (None, Some(self.ip6)),
        }
    }

    /// The host's socket of the address family of `ip`.
    pub(crate) fn socket_for(&self, ip: IpAddr) -> SocketAddr {
        match ip {
            IpAddr::V4(_) => SocketAddr::new(self.ip4.into(), self.port),
            IpAddr::V6(_) => SocketAddr::new(self.ip6.into(), self.port),
        }
    }
}

//! The relay simulation's model: when the client's `Allocation` must relay data, and what may
//! interrupt it.
//!
//! The model answers two questions per transition, see [`RelayModel::must_relay`] and
//! [`RelayModel::apply`]. It describes how the client behaves today, flaws included, so that
//! fixing one shows up as a change here.

use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Duration,
};

use connlib_model::IpStack;

use crate::relay_transition::Transition;

#[derive(Debug)]
pub(crate) struct RelayModel {
    pub(crate) relay: ModelHost,
    pub(crate) client: ModelHost,
    /// A host on the internet that has nothing to do with the client.
    pub(crate) foreign: ModelHost,
    /// Where the client relays data to.
    pub(crate) peer: ModelHost,
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
    /// Whether relaying must work once a transition has settled: whenever the client and the
    /// relay share an address family.
    pub(crate) fn must_relay(&self) -> bool {
        (self.client.stack.supports_ipv4() && self.relay.stack.supports_ipv4())
            || (self.client.stack.supports_ipv6() && self.relay.stack.supports_ipv6())
    }

    /// Applies a transition, returning whether it was allowed to interrupt relaying.
    pub(crate) fn apply(&mut self, transition: &Transition, lost_datagram: bool) -> bool {
        match transition {
            Transition::Roam { stack } => {
                self.client.stack = *stack;

                true
            }
            Transition::RebootRelay | Transition::Partition { .. } => true,
            // `Allocation::refresh` does not retransmit, so a single lost datagram invalidates the
            // allocation.
            Transition::Refresh => lost_datagram,
            Transition::Advance { .. } | Transition::Inject { .. } => false,
        }
    }
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

use super::{
    reference::{private_key, PrivateKey},
    sim_net::{any_ip_stack, any_port, host, Host},
};
use crate::ClientState;
use connlib_shared::{
    messages::{ClientId, DnsServer, Interface},
    proptest::{client_id, domain_name},
};
use prop::collection;
use proptest::prelude::*;
use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
};

/// Simulation state for a particular client.
#[derive(Debug, Clone)]
pub(crate) struct SimClient {
    pub(crate) id: ClientId,
}

/// Reference state for a particular client.
#[derive(Debug, Clone)]
pub struct RefClient {
    pub(crate) key: PrivateKey,
    pub(crate) known_hosts: HashMap<String, Vec<IpAddr>>,
    pub(crate) tunnel_ip4: Ipv4Addr,
    pub(crate) tunnel_ip6: Ipv6Addr,
}

impl RefClient {
    /// Initialize the [`ClientState`].
    ///
    /// This simulates receiving the `init` message from the portal.
    pub(crate) fn init(self, upstream_dns: Vec<DnsServer>) -> ClientState {
        let mut client_state = ClientState::new(self.key, self.known_hosts);
        let _ = client_state.update_interface_config(Interface {
            ipv4: self.tunnel_ip4,
            ipv6: self.tunnel_ip6,
            upstream_dns,
        });

        client_state
    }

    pub(crate) fn is_tunnel_ip(&self, ip: IpAddr) -> bool {
        match ip {
            IpAddr::V4(ip4) => self.tunnel_ip4 == ip4,
            IpAddr::V6(ip6) => self.tunnel_ip6 == ip6,
        }
    }

    pub(crate) fn tunnel_ip_for(&self, dst: IpAddr) -> IpAddr {
        match dst {
            IpAddr::V4(_) => self.tunnel_ip4.into(),
            IpAddr::V6(_) => self.tunnel_ip6.into(),
        }
    }
}

pub(crate) fn ref_client_host(
    tunnel_ip4s: &mut impl Iterator<Item = Ipv4Addr>,
    tunnel_ip6s: &mut impl Iterator<Item = Ipv6Addr>,
) -> impl Strategy<Value = Host<RefClient, SimClient>> {
    host(
        any_ip_stack(),
        any_port(),
        ref_client(tunnel_ip4s, tunnel_ip6s),
        sim_client(),
    )
}

fn ref_client(
    tunnel_ip4s: &mut impl Iterator<Item = Ipv4Addr>,
    tunnel_ip6s: &mut impl Iterator<Item = Ipv6Addr>,
) -> impl Strategy<Value = RefClient> {
    let tunnel_ip4 = tunnel_ip4s.next().unwrap();
    let tunnel_ip6 = tunnel_ip6s.next().unwrap();

    (private_key(), known_hosts()).prop_map(move |(key, known_hosts)| RefClient {
        key,
        known_hosts,
        tunnel_ip4,
        tunnel_ip6,
    })
}

fn sim_client() -> impl Strategy<Value = SimClient> {
    client_id().prop_map(|id| SimClient { id })
}

fn known_hosts() -> impl Strategy<Value = HashMap<String, Vec<IpAddr>>> {
    collection::hash_map(
        domain_name(2..4).prop_map(|d| d.parse().unwrap()),
        collection::vec(any::<IpAddr>(), 1..6),
        0..15,
    )
}

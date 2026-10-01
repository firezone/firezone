//! An [`IpNetworkTable`] with a hash map in front of it for host routes.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{collections::HashMap, net::IpAddr};

use fast_random_state::FastRandomState;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;

/// Maps IP networks to values, with constant-time lookups for host networks (`/32` and `/128`).
///
/// A host network is always the longest possible match for its address,
/// so lookups only fall back to longest-prefix matching if no host network matches.
pub struct NetworkTable<T> {
    hosts: HashMap<IpAddr, T, FastRandomState>,
    networks: IpNetworkTable<T>,
}

impl<T> Default for NetworkTable<T> {
    fn default() -> Self {
        Self {
            hosts: HashMap::default(),
            networks: IpNetworkTable::new(),
        }
    }
}

impl<T> NetworkTable<T> {
    pub fn new() -> Self {
        Self::default()
    }

    /// Inserts `value` for `network`, returning the previous value.
    pub fn insert(&mut self, network: impl Into<IpNetwork>, value: T) -> Option<T> {
        let network = network.into();

        match host(network) {
            Some(ip) => self.hosts.insert(ip, value),
            None => self.networks.insert(network, value),
        }
    }

    pub fn exact_match_mut(&mut self, network: impl Into<IpNetwork>) -> Option<&mut T> {
        let network = network.into();

        match host(network) {
            Some(ip) => self.hosts.get_mut(&ip),
            None => self.networks.exact_match_mut(network),
        }
    }

    pub fn longest_match(&self, ip: IpAddr) -> Option<(IpNetwork, &T)> {
        if let Some(value) = self.hosts.get(&ip) {
            return Some((IpNetwork::from(ip), value));
        }

        self.networks.longest_match(ip)
    }

    /// Returns all networks that contain `ip`, starting with the host network.
    pub fn matches(&self, ip: IpAddr) -> impl Iterator<Item = (IpNetwork, &T)> {
        self.hosts
            .get_key_value(&ip)
            .map(|(ip, value)| (IpNetwork::from(*ip), value))
            .into_iter()
            .chain(self.networks.matches(ip))
    }

    /// Iterates all entries in unspecified order.
    #[expect(clippy::disallowed_methods, reason = "The order is unspecified.")]
    pub fn iter(&self) -> impl Iterator<Item = (IpNetwork, &T)> {
        self.hosts
            .iter()
            .map(|(ip, value)| (IpNetwork::from(*ip), value))
            .chain(self.networks.iter())
    }

    /// Iterates all entries in unspecified order.
    #[expect(clippy::disallowed_methods, reason = "The order is unspecified.")]
    pub fn iter_mut(&mut self) -> impl Iterator<Item = (IpNetwork, &mut T)> {
        self.hosts
            .iter_mut()
            .map(|(ip, value)| (IpNetwork::from(*ip), value))
            .chain(self.networks.iter_mut())
    }

    pub fn retain(&mut self, mut f: impl FnMut(IpNetwork, &mut T) -> bool) {
        self.hosts
            .retain(|ip, value| f(IpNetwork::from(*ip), value));
        self.networks.retain(f);
    }

    pub fn is_empty(&self) -> bool {
        self.hosts.is_empty() && self.networks.is_empty()
    }
}

fn host(network: IpNetwork) -> Option<IpAddr> {
    let full_length = match network {
        IpNetwork::V4(_) => ip_network::Ipv4Network::LENGTH,
        IpNetwork::V6(_) => ip_network::Ipv6Network::LENGTH,
    };

    (network.netmask() == full_length).then(|| network.network_address())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_wins_over_covering_network() {
        let mut table = NetworkTable::new();
        table.insert(net("10.0.0.0/8"), "network");
        table.insert(net("10.0.0.1/32"), "host");

        assert_eq!(
            table.longest_match(ip("10.0.0.1")),
            Some((net("10.0.0.1/32"), &"host"))
        );
        assert_eq!(
            table.matches(ip("10.0.0.1")).collect::<Vec<_>>(),
            vec![
                (net("10.0.0.1/32"), &"host"),
                (net("10.0.0.0/8"), &"network")
            ]
        );
    }

    #[test]
    fn removing_host_falls_back_to_network() {
        let mut table = NetworkTable::new();
        table.insert(net("10.0.0.0/8"), "network");
        table.insert(net("10.0.0.1/32"), "host");

        table.retain(|_, value| *value != "host");

        assert_eq!(
            table.longest_match(ip("10.0.0.1")),
            Some((net("10.0.0.0/8"), &"network"))
        );
    }

    fn net(s: &str) -> IpNetwork {
        s.parse().unwrap()
    }

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }
}

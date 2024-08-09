use crate::REALM;
use connlib_shared::messages::{Relay, RelayId};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use itertools::Itertools;
use snownet::RelaySocket;
use std::{cmp::Ordering, collections::BTreeSet, net::SocketAddr, time::Instant};

pub fn turn(relays: &[Relay]) -> BTreeSet<(RelayId, RelaySocket, String, String, String)> {
    relays
        .iter()
        .filter_map(|r| {
            if let Relay::Turn(r) = r {
                Some((
                    r.id,
                    match r.addr {
                        SocketAddr::V4(v4) => RelaySocket::V4(v4),
                        SocketAddr::V6(v6) => RelaySocket::V6(v6),
                    },
                    r.username.clone(),
                    r.password.clone(),
                    REALM.to_string(),
                ))
            } else {
                None
            }
        })
        .chunk_by(|(id, _, _, _, _)| *id)
        .into_iter()
        .filter_map(|(_, grouped)| {
            grouped.reduce(
                |(_, current_socket, _, _, _), (id, socket, username, password, realm)| {
                    let new_socket = match (current_socket, socket) {
                        (RelaySocket::V4(v4), RelaySocket::V6(v6)) => RelaySocket::Dual { v4, v6 },
                        (RelaySocket::V6(v6), RelaySocket::V4(v4)) => RelaySocket::Dual { v4, v6 },
                        (_, dual @ RelaySocket::Dual { .. })
                        | (dual @ RelaySocket::Dual { .. }, _) => {
                            tracing::warn!(%id, "Duplicate addresses for relay");

                            dual
                        }
                        (v4 @ RelaySocket::V4(_), _) => {
                            tracing::warn!(%id, "Duplicate IPv4 address for relay");

                            v4
                        }
                        (v6 @ RelaySocket::V6(_), _) => {
                            tracing::warn!(%id, "Duplicate IPv6 address for relay");

                            v6
                        }
                    };

                    (id, new_socket, username, password, realm)
                },
            )
        })
        .collect()
}

pub fn earliest(left: Option<Instant>, right: Option<Instant>) -> Option<Instant> {
    match (left, right) {
        (None, None) => None,
        (Some(left), Some(right)) => Some(std::cmp::min(left, right)),
        (Some(left), None) => Some(left),
        (None, Some(right)) => Some(right),
    }
}

pub(crate) fn network_contains_network(ip_a: IpNetwork, ip_b: IpNetwork) -> bool {
    ip_a.contains(ip_b.network_address()) && ip_a.netmask() <= ip_b.netmask()
}

#[allow(dead_code)]
pub(crate) fn ipv4(ip: IpNetwork) -> Option<Ipv4Network> {
    match ip {
        IpNetwork::V4(v4) => Some(v4),
        IpNetwork::V6(_) => None,
    }
}

#[allow(dead_code)]
pub(crate) fn ipv6(ip: IpNetwork) -> Option<Ipv6Network> {
    match ip {
        IpNetwork::V4(_) => None,
        IpNetwork::V6(v6) => Some(v6),
    }
}

/// Helper container to aggregate candidates and emit them in sorted order, starting with the highest-priority one (host candidates).
///
/// Whilst no fatal in theory, emitting candidates in the wrong order can cause temporary connectivity problems.
/// `str0m` needs to "replace" candidates when it receives better ones which can cancel in-flight STUN requests.
/// By sorting the candidates by priority, we try the best ones first, being symphatic to the ICE algorithm.
#[derive(Default)]
pub(crate) struct Candidates(Vec<snownet::Candidate>);

impl Candidates {
    pub(crate) fn push(&mut self, candidate: snownet::Candidate) {
        self.0.push(candidate)
    }

    pub(crate) fn serialize(mut self) -> BTreeSet<String> {
        self.0.sort_by(priority_desc);

        self.0.into_iter().map(|c| c.to_sdp_string()).collect()
    }
}

fn priority_desc(c1: &snownet::Candidate, c2: &snownet::Candidate) -> Ordering {
    c1.prio().cmp(&c2.prio()).reverse()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, SocketAddrV4};

    #[test]
    fn sorts_candidates_by_priority() {
        let mut candidates = vec![
            snownet::Candidate::host(
                SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1)),
                "udp",
            )
            .unwrap(),
            snownet::Candidate::server_reflexive(
                SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 2)),
                SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1)),
                "udp",
            )
            .unwrap(),
        ];

        candidates.sort_by(priority_desc);

        assert_eq!(candidates[0].kind().to_string(), "host");
        assert_eq!(candidates[1].kind().to_string(), "srflx");
    }
}

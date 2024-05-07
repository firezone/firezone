use crate::REALM;
use connlib_shared::messages::{Relay, RelayId};
use ip_network::IpNetwork;
use itertools::Itertools;
use snownet::RelaySocket;
use std::{collections::HashSet, net::SocketAddr, time::Instant};

pub fn stun(relays: &[Relay], predicate: impl Fn(&SocketAddr) -> bool) -> HashSet<SocketAddr> {
    relays
        .iter()
        .filter_map(|r| {
            if let Relay::Stun(r) = r {
                Some(r.addr)
            } else {
                None
            }
        })
        .filter(predicate)
        .collect()
}

pub fn turn(relays: &[Relay]) -> HashSet<(RelayId, RelaySocket, String, String, String)> {
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
        .group_by(|(id, _, _, _, _)| *id)
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

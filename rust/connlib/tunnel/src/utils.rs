use crate::{REALM, messages::Relay};
use connlib_model::RelayId;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use itertools::Itertools as _;
use snownet::RelaySocket;
use std::{collections::BTreeSet, net::SocketAddr};

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

pub(crate) fn network_contains_network(ip_a: IpNetwork, ip_b: IpNetwork) -> bool {
    ip_a.contains(ip_b.network_address()) && ip_a.netmask() <= ip_b.netmask()
}

#[expect(dead_code)]
pub(crate) fn ipv4(ip: IpNetwork) -> Option<Ipv4Network> {
    match ip {
        IpNetwork::V4(v4) => Some(v4),
        IpNetwork::V6(_) => None,
    }
}

#[expect(dead_code)]
pub(crate) fn ipv6(ip: IpNetwork) -> Option<Ipv6Network> {
    match ip {
        IpNetwork::V4(_) => None,
        IpNetwork::V6(v6) => Some(v6),
    }
}

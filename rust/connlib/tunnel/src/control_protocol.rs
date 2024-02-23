use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use std::{collections::HashSet, net::SocketAddr, sync::Arc};

use connlib_shared::messages::{Relay, RequestConnection, ReuseConnection};

use crate::{peer::Peer, REALM};

mod client;
pub mod gateway;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    NewConnection(RequestConnection),
    ReuseConnection(ReuseConnection),
}

fn insert_peers<TId: Copy, TTransform>(
    peers_by_ip: &mut IpNetworkTable<Arc<Peer<TId, TTransform>>>,
    ips: &Vec<IpNetwork>,
    peer: Arc<Peer<TId, TTransform>>,
) {
    for ip in ips {
        peers_by_ip.insert(*ip, peer.clone());
    }
}

fn stun(relays: &[Relay], predicate: impl Fn(&SocketAddr) -> bool) -> HashSet<SocketAddr> {
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

fn turn(
    relays: &[Relay],
    predicate: impl Fn(&SocketAddr) -> bool,
) -> HashSet<(SocketAddr, String, String, String)> {
    relays
        .iter()
        .filter_map(|r| {
            if let Relay::Turn(r) = r {
                Some((
                    r.addr,
                    r.username.clone(),
                    r.password.clone(),
                    REALM.to_string(),
                ))
            } else {
                None
            }
        })
        .filter(|(socket, _, _, _)| predicate(socket))
        .collect()
}

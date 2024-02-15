use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use std::{collections::HashSet, fmt, hash::Hash, net::SocketAddr, sync::Arc};

use connlib_shared::{
    messages::{Relay, RequestConnection, ReuseConnection},
    Callbacks,
};

use crate::{peer::Peer, Tunnel, REALM};

mod client;
pub mod gateway;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    NewConnection(RequestConnection),
    ReuseConnection(ReuseConnection),
}

impl<CB, TRoleState, TRole, TId, TTransform> Tunnel<CB, TRoleState, TRole, TId, TTransform>
where
    CB: Callbacks + 'static,
    TId: Eq + Hash + Copy + fmt::Display,
{
    pub fn add_ice_candidate(&mut self, conn_id: TId, ice_candidate: String) {
        self.connections_state
            .node
            .add_remote_candidate(conn_id, ice_candidate);
    }
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

fn stun(relays: &[Relay]) -> HashSet<SocketAddr> {
    relays
        .iter()
        .filter_map(|r| {
            if let Relay::Stun(r) = r {
                Some(r.uri)
            } else {
                None
            }
        })
        .collect()
}

fn turn(relays: &[Relay]) -> HashSet<(SocketAddr, String, String, String)> {
    relays
        .iter()
        .filter_map(|r| {
            if let Relay::Turn(r) = r {
                Some((
                    r.uri,
                    r.username.clone(),
                    r.password.clone(),
                    REALM.to_string(),
                ))
            } else {
                None
            }
        })
        .collect()
}

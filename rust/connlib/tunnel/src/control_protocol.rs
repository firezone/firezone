use std::{collections::HashSet, fmt, hash::Hash, net::SocketAddr};

use connlib_shared::{
    messages::{Relay, RequestConnection, ReuseConnection},
    Callbacks,
};

use crate::{Tunnel, REALM};

mod client;
pub mod gateway;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    NewConnection(RequestConnection),
    ReuseConnection(ReuseConnection),
}

impl<CB, TRoleState, TRole, TId> Tunnel<CB, TRoleState, TRole, TId>
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

use crate::REALM;
use connlib_shared::messages::Relay;
use std::{collections::HashSet, net::SocketAddr};

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

pub fn turn(
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

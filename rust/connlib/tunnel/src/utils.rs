use crate::REALM;
use connlib_shared::messages::Relay;
use std::{collections::HashSet, net::SocketAddr, time::Instant};

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

pub fn earliest(left: Option<Instant>, right: Option<Instant>) -> Option<Instant> {
    match (left, right) {
        (None, None) => None,
        (Some(left), Some(right)) => Some(std::cmp::min(left, right)),
        (Some(left), None) => Some(left),
        (None, Some(right)) => Some(right),
    }
}

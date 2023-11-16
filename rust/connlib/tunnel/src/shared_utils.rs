use crate::connection::{Connecting, Connection, WantsRemoteCredentials};
use connlib_shared::messages::Relay;
use firezone_relay::client::{Allocation, Binding, Transmit};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::task::{Context, Poll};
use str0m::ice::IceError;
use str0m::net::Protocol;
use str0m::Candidate;
use stun_codec::rfc5389::attributes::Username;

/// Updates all initial and pending connections with (potentially new) candidates from all bindings and allocations.
///
/// Each [`Connection`] checks internally, whether it is "allowed" to use a candidate from a particular STUN/TURN server.
///
/// # Note regarding efficiency
///
/// This function involves two nested loops. However, we expect the number of STUN & TURN servers to be small, i.e. < 5.
/// Similarly, the number of initial and pending connections is also expected to be small or perhaps even 0.
///
/// Thus, usage of the nested loops is deemed acceptable over a more efficient algorithm.
/// Technically, we could split this function into multiple and only call a subset of its functionality on each call-site.
/// That would actually involve more code which is likely more difficult to maintain.
pub(crate) fn update_candidates_of_connections<'a, TId: 'a>(
    bindings: impl Iterator<Item = (&'a SocketAddr, &'a Binding)>,
    allocations: impl Iterator<Item = (&'a SocketAddr, &'a Allocation)>,
    initial_connections: &mut HashMap<TId, Connection<WantsRemoteCredentials>>,
    pending_connections: &mut HashMap<TId, Connection<Connecting>>,
) -> impl Iterator<Item = (TId, Candidate)>
where
    TId: Copy,
{
    let mut new_candidates = Vec::new();

    let binding_candidates = bindings.flat_map(|(server, binding)| {
        new_candidate(
            *server,
            binding.mapped_address(),
            Candidate::server_reflexive,
        )
    });
    let allocation_candidates = allocations.flat_map(|(server, allocation)| {
        let server_reflexive = new_candidate(
            *server,
            allocation.mapped_address(),
            Candidate::server_reflexive,
        );
        let ip4_relayed = new_candidate(*server, allocation.ip4_socket(), Candidate::relayed);
        let ip6_relayed = new_candidate(*server, allocation.ip6_socket(), Candidate::relayed);

        server_reflexive
            .into_iter()
            .chain(ip4_relayed)
            .chain(ip6_relayed)
    });

    for (server, candidate) in binding_candidates.chain(allocation_candidates) {
        for (conn, connection) in initial_connections.iter_mut() {
            if connection.add_local_candidate(server, candidate.clone()) {
                new_candidates.push((*conn, candidate.clone()));
            }
        }

        for (conn, connection) in pending_connections.iter_mut() {
            if connection.add_local_candidate(server, candidate.clone()) {
                new_candidates.push((*conn, candidate.clone()));
            }
        }
    }

    new_candidates.into_iter()
}

/// Constructs a new [`Candidate`] from an address and a given source.
///
/// If the address is not present or not valid, `None` is returned.
fn new_candidate<S>(
    source: SocketAddr,
    maybe_address: Option<S>,
    ctor: impl Fn(SocketAddr, Protocol) -> Result<Candidate, IceError>,
) -> Option<(SocketAddr, Candidate)>
where
    S: Into<SocketAddr>,
{
    let addr = maybe_address?.into();

    match (ctor)(addr, Protocol::Udp) {
        Ok(c) => Some((source, c)),
        Err(e) => {
            tracing::debug!(%addr, "Address is not a valid candidate: {e}");
            None
        }
    }
}

// TODO: Get rid of this by implementing `Stream` for `Binding` and use `SelectAll`.
pub(crate) fn poll_bindings<'a>(
    bindings: impl Iterator<Item = &'a mut Binding>,
    cx: &mut Context,
) -> Poll<Transmit> {
    for binding in bindings {
        if let Poll::Ready(transmit) = binding.poll(cx) {
            return Poll::Ready(transmit);
        }
    }

    Poll::Pending
}

// TODO: Get rid of this by implementing `Stream` for `Allocation` and use `SelectAll`.
pub(crate) fn poll_allocations<'a>(
    allocations: impl Iterator<Item = &'a mut Allocation>,
    cx: &mut Context,
) -> Poll<Transmit> {
    for allocation in allocations {
        if let Poll::Ready(transmit) = allocation.poll(cx) {
            return Poll::Ready(transmit);
        }
    }

    Poll::Pending
}

// TODO: Get rid of this by creating custom collections that can be shared between client and gateway (or somehow else).
pub(crate) fn upsert_relays(
    bindings: &mut HashMap<SocketAddr, Binding>,
    allocations: &mut HashMap<SocketAddr, Allocation>,
    relays: Vec<Relay>,
) -> (Vec<SocketAddr>, Vec<SocketAddr>) {
    let (stun_servers, turn_servers) = parse_relays(relays);

    for stun_server in stun_servers.clone() {
        bindings.entry(stun_server).or_insert_with(|| {
            tracing::debug!(addr = %stun_server, "Adding STUN server");

            Binding::new(stun_server)
        });
    }

    for (turn_server, username, password) in turn_servers.clone() {
        allocations.entry(turn_server).or_insert_with(|| {
            tracing::debug!(addr = %turn_server, username = %username.name(), "Adding TURN server");

            Allocation::new(turn_server, username, password)
        });
    }

    (
        stun_servers,
        turn_servers.iter().map(|(s, _, _)| s).copied().collect(),
    )
}

// TODO: Get rid of this by directly parsing relays using `serde`.
fn parse_relays(relays: Vec<Relay>) -> (Vec<SocketAddr>, Vec<(SocketAddr, Username, String)>) {
    let stun_servers = relays.iter().filter_map(Relay::try_to_stun).collect();
    let turn_servers = relays.iter().filter_map(Relay::try_to_turn).collect();

    (stun_servers, turn_servers)
}

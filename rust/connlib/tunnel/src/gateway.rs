use crate::bounded_queue::BoundedQueue;
use crate::connection::{Connecting, Connection, DirectGatewayToClient};
use crate::device_channel::Device;
use crate::index::IndexLfsr;
use crate::rate_limiter::RateLimiter;
use crate::shared_utils::{
    poll_allocations, poll_bindings, update_candidates_of_connections, upsert_relays,
};
use crate::{connection, device_channel, DnsFallbackStrategy, Transmit, Tunnel, MAX_UDP_SIZE};
use boringtun::noise::Tunn;
use boringtun::x25519::{PublicKey, StaticSecret};
use chrono::{DateTime, Utc};
use connlib_shared::messages::{
    ClientId, Interface as InterfaceConfig, Relay, ResourceDescription, SecretKey,
};
use connlib_shared::Callbacks;
use either::Either;
use firezone_relay::client::{Allocation, Binding};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use secrecy::ExposeSecret;
use std::collections::hash_map::Entry;
use std::collections::HashMap;
use std::net::SocketAddr;
use std::task::{Context, Poll};
use std::time::Duration;
use str0m::ice::IceCreds;
use str0m::net::Protocol;
use str0m::Candidate;

impl<CB> Tunnel<CB, State>
where
    CB: Callbacks + 'static,
{
    pub fn set_interface(&self, config: &InterfaceConfig) -> connlib_shared::Result<()> {
        let device = Device::new(config, self.callbacks(), DnsFallbackStrategy::default())?;

        *self.device.lock() = Some(device);
        self.no_device_waker.wake();

        tracing::info!("Configured new device");

        Ok(())
    }
}

/// [`Tunnel`] state specific to gateways.
pub struct State {
    next_index: IndexLfsr,
    rate_limiter: RateLimiter,
    tunnel_private_key: StaticSecret,

    bindings: HashMap<SocketAddr, Binding>,
    allocations: HashMap<SocketAddr, Allocation>,

    // TODO: Choose a better name as this is also used to expire resources.
    update_timer_interval: tokio::time::Interval,

    pending_connections: HashMap<ClientId, Connection<Connecting>>,
    established_connections: HashMap<ClientId, Connection<DirectGatewayToClient>>,

    clients_by_ip: IpNetworkTable<ClientId>,

    /// A re-usable buffer for en/de-capsulating packets.
    buf: [u8; MAX_UDP_SIZE],
    /// Events we've buffered to be returned to the [`Tunnel`].
    pending_events: BoundedQueue<Either<Event, Transmit>>,
}

impl State {
    pub(crate) fn new(tunnel_private_key: StaticSecret) -> Self {
        Self {
            next_index: Default::default(),
            rate_limiter: RateLimiter::new((&tunnel_private_key).into()),
            tunnel_private_key,
            bindings: Default::default(),
            allocations: Default::default(),
            update_timer_interval: tokio::time::interval(Duration::from_secs(1)),
            pending_connections: Default::default(),
            established_connections: Default::default(),
            clients_by_ip: IpNetworkTable::new(),
            buf: [0u8; MAX_UDP_SIZE],
            pending_events: BoundedQueue::with_capacity(1000), // Really this should never fill up!
        }
    }

    pub(crate) fn allow_access(
        &mut self,
        client: ClientId,
        resource: ResourceDescription,
        expires_at: DateTime<Utc>,
    ) {
        // TODO: Should we also keep state already for pending connections?
        let Some(conn) = self.established_connections.get_mut(&client) else {
            return;
        };

        tracing::info!(%client, resource = %resource.id(), %expires_at, "Allowing access to resource");

        conn.allow_access(resource, expires_at);
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn make_new_connection(
        &mut self,
        local: SocketAddr,
        id: ClientId,
        relays: Vec<Relay>,
        remote_credentials: IceCreds,
        preshared_key: SecretKey,
        client_key: PublicKey,
        client_ips: Vec<IpNetwork>,
    ) -> IceCreds {
        tracing::trace!(client = %id, "Creating new connection");

        let (stun_servers, turn_servers) =
            upsert_relays(&mut self.bindings, &mut self.allocations, relays);

        let connection = Connection::new_gateway_to_client(
            preshared_key,
            client_key,
            remote_credentials,
            local,
            stun_servers,
            turn_servers,
        );
        let local_credentials = connection.ice_credentials();
        self.pending_connections.insert(id, connection);

        // TODO: Only update candidates of this connection.
        self.pending_events.extend(
            update_candidates_of_connections(
                self.bindings.iter(),
                self.allocations.iter(),
                &mut HashMap::new(),
                &mut self.pending_connections,
            )
            .map(|(conn_id, candidate)| {
                Either::Left(Event::SignalIceCandidate { conn_id, candidate })
            }),
        );

        // TODO: Do this as part of the connection, maybe emit an event?
        self.pending_events
            .push_back(Either::Left(Event::SignalIceCandidate {
                conn_id: id,
                candidate: Candidate::host(local, Protocol::Udp).unwrap(),
            }))
            .unwrap();

        for ip in client_ips {
            self.clients_by_ip.insert(ip, id);
        }

        local_credentials
    }

    pub(crate) fn add_remote_candidate(&mut self, client: ClientId, candidate: Candidate) {
        let Some(agent) = self.pending_connections.get_mut(&client) else {
            return;
        };

        agent.add_remote_candidate(candidate);
    }

    /// Handles an incoming datagram from the given sender.
    ///
    /// TODO
    #[tracing::instrument(level = "trace", skip(self, packet), fields(num_bytes = %packet.len()))]
    pub(crate) fn handle_socket_input<'b>(
        &'b mut self,
        sender: SocketAddr,
        packet: &'b [u8],
    ) -> Option<device_channel::Packet<'b>> {
        if let Some(binding) = self.bindings.get_mut(&sender) {
            if binding.handle_input(sender, packet) {
                self.pending_events.extend(
                    update_candidates_of_connections(
                        self.bindings.iter(),
                        self.allocations.iter(),
                        &mut HashMap::new(),
                        &mut self.pending_connections,
                    )
                    .map(|(conn_id, candidate)| {
                        Either::Left(Event::SignalIceCandidate { conn_id, candidate })
                    }),
                );
                return None;
            }
        }

        if let Some(allocation) = self.allocations.get_mut(&sender) {
            if allocation.handle_input(sender, packet) {
                self.pending_events.extend(
                    update_candidates_of_connections(
                        self.bindings.iter(),
                        self.allocations.iter(),
                        &mut HashMap::new(),
                        &mut self.pending_connections,
                    )
                    .map(|(conn_id, candidate)| {
                        Either::Left(Event::SignalIceCandidate { conn_id, candidate })
                    }),
                );
                return None;
            }
        }

        for connection in self.pending_connections.values_mut() {
            if connection.handle_input(sender, packet) {
                return None;
            }
        }

        for connection in self.established_connections.values_mut() {
            if connection.accepts(sender, packet) {
                match connection.decapsulate(sender, packet, &mut self.buf) {
                    Ok(maybe_packet) => return maybe_packet,
                    Err(e) => {
                        todo!("{e}")
                    }
                }
            }
        }

        None
    }

    /// Handles an incoming datagram from the device.
    ///
    /// TODO
    #[tracing::instrument(level = "trace", skip(self, packet), fields(num_bytes = %packet.len(), dst))]
    pub(crate) fn handle_device_input<'a, 'b>(
        &'a mut self,
        packet: &'b mut [u8],
    ) -> Option<Either<device_channel::Packet<'b>, (SocketAddr, &'a [u8])>> {
        let dst = Tunn::dst_address(packet)?;
        tracing::Span::current().record("dst", tracing::field::display(&dst));

        let (_, client) = self.clients_by_ip.longest_match(dst)?;

        let peer = self.established_connections.get_mut(client)?; // TODO: Better error logging on inconsistent state?

        match peer.encapsulate(packet, &mut self.buf).transpose()? {
            Ok((dst, bytes)) => Some(Either::Right((dst, bytes))),
            Err(e) => {
                tracing::warn!("Failed to encapsulate packet: {e}");
                None
            }
        }
    }

    pub(crate) fn poll_next_event(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Either<Event, Transmit>> {
        if let Poll::Ready(event) = self.pending_events.poll(cx) {
            return Poll::Ready(event);
        }

        if let Poll::Ready(transmit) = poll_bindings(self.bindings.values_mut(), cx) {
            return Poll::Ready(Either::Right(transmit.into()));
        }

        if let Poll::Ready(transmit) = poll_allocations(self.allocations.values_mut(), cx) {
            return Poll::Ready(Either::Right(transmit.into()));
        }

        'outer: for client in self.pending_connections.keys().copied().collect::<Vec<_>>() {
            let Entry::Occupied(mut entry) = self.pending_connections.entry(client) else {
                unreachable!("ID comes from list")
            };

            let connection = entry.get_mut();

            loop {
                match connection.poll(cx) {
                    Poll::Ready(connection::ConnectingEvent::Connection { src, dst }) => {
                        let connection = entry.remove().into_established_gateway_to_client(
                            src,
                            dst,
                            self.new_tunnel_fn(),
                        );

                        self.established_connections.insert(client, connection);

                        continue 'outer;
                    }
                    Poll::Ready(connection::ConnectingEvent::WantChannelToPeer { .. }) => {
                        tracing::warn!("Ignoring request to create channel");

                        continue;
                    }
                    Poll::Ready(connection::ConnectingEvent::Transmit(transmit)) => {
                        return Poll::Ready(Either::Right(transmit));
                    }
                    Poll::Pending => continue 'outer,
                }
            }
        }

        if self.update_timer_interval.poll_tick(cx).is_ready() {
            for connection in self.established_connections.values_mut() {
                connection.update_timers();
                connection.expire_resources();
            }
        }

        for connection in self.established_connections.values_mut() {
            while let Some(transmit) = dbg!(connection.poll_transmit()) {
                let _ = self.pending_events.push_back(Either::Right(transmit));
            }
        }

        Poll::Pending
    }

    fn new_tunnel_fn(&mut self) -> impl FnOnce(SecretKey, PublicKey) -> Tunn + '_ {
        |secret, public| {
            Tunn::new(
                self.tunnel_private_key.clone(),
                public,
                Some(secret.expose_secret().0),
                None,
                self.next_index.next(),
                Some(self.rate_limiter.clone_to()),
            )
        }
    }
}

pub enum Event {
    SignalIceCandidate {
        conn_id: ClientId,
        candidate: Candidate,
    },
}

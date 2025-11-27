use std::{
    collections::{BTreeMap, BTreeSet, HashMap, VecDeque},
    net::SocketAddr,
    time::{Duration, Instant},
};

use crate::codec;
use anyhow::{Context as _, Result};
use ip_packet::IpPacket;
use l3_tcp::{
    InMemoryDevice, Interface, IpEndpoint, PollResult, SocketHandle, SocketSet, create_interface,
    create_tcp_socket,
};

/// A sans-IO implementation of DNS-over-TCP server.
///
/// Listens on a specified number of socket addresses, parses incoming DNS queries and allows writing back responses.
pub struct Server {
    device: InMemoryDevice,
    interface: Interface,

    sockets: SocketSet<'static>,
    listen_endpoints: BTreeMap<SocketHandle, SocketAddr>,

    /// Tracks the [`SocketHandle`] on which we need to send a reply for a given query by the local socket address, remote socket address and query ID.
    pending_sockets_by_local_remote_and_query_id:
        HashMap<(SocketAddr, SocketAddr, u16), SocketHandle>,

    received_queries: VecDeque<Query>,

    created_at: Instant,
    last_now: Instant,
}

pub struct Query {
    pub message: dns_types::Query,
    /// The local address of the socket that received the query.
    pub local: SocketAddr,
    /// The remote address of the client that sent the query.
    pub remote: SocketAddr,
}

impl Server {
    pub fn new(now: Instant) -> Self {
        let mut device = InMemoryDevice::default();
        let interface = create_interface(&mut device);

        Self {
            device,
            interface,
            sockets: SocketSet::new(Vec::default()),
            listen_endpoints: Default::default(),
            pending_sockets_by_local_remote_and_query_id: Default::default(),
            received_queries: Default::default(),
            created_at: now,
            last_now: now,
        }
    }

    /// Listen on the specified addresses.
    ///
    /// This resets all sockets we were previously listening on.
    /// This function is generic over a `NUM_CONCURRENT_CLIENTS` constant.
    /// The constant configures, how many concurrent clients you would like to be able to serve per listen address.
    pub fn set_listen_addresses<const NUM_CONCURRENT_CLIENTS: usize>(
        &mut self,
        addresses: BTreeSet<SocketAddr>,
    ) {
        let current_listen_endpoints = self
            .listen_endpoints
            .values()
            .copied()
            .collect::<BTreeSet<_>>();

        if current_listen_endpoints == addresses {
            tracing::debug!(
                ?current_listen_endpoints,
                "Already listening on this exact set of addresses"
            );

            return;
        }

        assert!(NUM_CONCURRENT_CLIENTS > 0);

        let mut sockets =
            SocketSet::new(Vec::with_capacity(addresses.len() * NUM_CONCURRENT_CLIENTS));
        let mut listen_endpoints = BTreeMap::new();

        for listen_endpoint in addresses {
            for _ in 0..NUM_CONCURRENT_CLIENTS {
                let mut socket = create_tcp_socket();
                socket
                    .listen(listen_endpoint)
                    .expect("A fresh socket should always be able to listen");

                let handle = sockets.add(socket);
                listen_endpoints.insert(handle, listen_endpoint);
            }

            tracing::debug!(%listen_endpoint, concurrency = %NUM_CONCURRENT_CLIENTS, "Created listening TCP socket");
        }

        self.sockets = sockets;
        self.listen_endpoints = listen_endpoints;
        self.received_queries.clear();
        self.pending_sockets_by_local_remote_and_query_id.clear();
    }

    /// Checks whether this server can handle the given packet.
    ///
    /// Only TCP packets targeted at one of sockets configured with [`Server::set_listen_addresses`] are accepted.
    pub fn accepts(&self, packet: &IpPacket) -> bool {
        let Some(tcp) = packet.as_tcp() else {
            #[cfg(debug_assertions)]
            tracing::trace!(?packet, "Not a TCP packet");

            return false;
        };

        let dst = SocketAddr::new(packet.destination(), tcp.destination_port());
        let is_listening = self.listen_endpoints.values().any(|s| s == &dst);

        #[cfg(debug_assertions)]
        if !is_listening && tracing::enabled!(tracing::Level::TRACE) {
            let listen_endpoints = BTreeSet::from_iter(self.listen_endpoints.values().copied());

            tracing::trace!(%dst, ?listen_endpoints, "No listening socket for destination");
        }

        is_listening
    }

    /// Handle the [`IpPacket`].
    ///
    /// This function only inserts the packet into a buffer.
    /// To actually process the packets in the buffer, [`Server::handle_timeout`] must be called.
    pub fn handle_inbound(&mut self, packet: IpPacket) {
        debug_assert!(self.accepts(&packet));

        self.device.receive(packet);
    }

    /// Send a query response from the given source to the provided destination socket.
    ///
    /// This fails if the socket is not writeable or if we don't have a pending query for this client.
    /// On any error, the TCP connection is automatically reset.
    pub fn send_message(
        &mut self,
        src: SocketAddr,
        dst: SocketAddr,
        response: dns_types::Response,
    ) -> Result<()> {
        let handle = self
            .pending_sockets_by_local_remote_and_query_id
            .remove(&(src, dst, response.id()))
            .context("No pending query found for message")?;

        let socket = self.sockets.get_mut::<l3_tcp::Socket>(handle);

        codec::try_send(socket, &response.into_bytes(u16::MAX))
            .inspect_err(|_| socket.abort()) // Abort socket on error.
            .context("Failed to write DNS response")?;

        Ok(())
    }

    /// Inform the server that time advanced.
    ///
    /// Typical for a sans-IO design, `handle_timeout` will work through all local buffers and process them as much as possible.
    pub fn handle_timeout(&mut self, now: Instant) {
        self.last_now = now;

        let result = self.interface.poll(
            l3_tcp::now(self.created_at, now),
            &mut self.device,
            &mut self.sockets,
        );

        if result == PollResult::None {
            return;
        }

        for (handle, l3_tcp::AnySocket::Tcp(socket)) in self.sockets.iter_mut() {
            let Some(local) = self.listen_endpoints.get(&handle).copied() else {
                tracing::warn!(%handle, "No listen endpoint for socket");
                continue;
            };

            let _guard = tracing::trace_span!("socket", %handle).entered();

            while let Some(result) = try_recv_query(socket, local).transpose() {
                match result {
                    Ok((message, remote)) => {
                        let qid = message.id();

                        tracing::trace!(%local, %remote, %qid, "Received DNS query");

                        self.pending_sockets_by_local_remote_and_query_id
                            .insert((local, remote, qid), handle);

                        self.received_queries.push_back(Query {
                            message,
                            local,
                            remote,
                        });
                    }
                    Err(e) => {
                        tracing::debug!("Error on receiving DNS query: {e:#}");
                        socket.abort();
                        break;
                    }
                }
            }
        }
    }

    pub fn poll_timeout(&mut self) -> Option<Instant> {
        let now = l3_tcp::now(self.created_at, self.last_now);

        let poll_in = self.interface.poll_delay(now, &self.sockets)?;

        Some(self.last_now + Duration::from(poll_in))
    }

    /// Returns [`IpPacket`]s that should be sent.
    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.device.next_send()
    }

    /// Returns queries received from a DNS client.
    pub fn poll_queries(&mut self) -> Option<Query> {
        self.received_queries.pop_front()
    }
}

fn try_recv_query(
    socket: &mut l3_tcp::Socket,
    listen: SocketAddr,
) -> Result<Option<(dns_types::Query, SocketAddr)>> {
    // smoltcp's sockets can only ever handle a single remote, i.e. there is no permanent listening socket.
    // to be able to handle a new connection, reset the socket back to `listen` once the connection is closed / closing.
    {
        use l3_tcp::State::*;

        if matches!(socket.state(), Closed | TimeWait | CloseWait) {
            tracing::debug!(state = %socket.state(), "Resetting socket to listen state");

            socket.abort();
            socket
                .listen(listen)
                .context("Failed to move socket to LISTEN state")?;
        }
    }

    // We configure `smoltcp` with "any-ip", meaning packets to technically any IP will be routed here to us.
    if let Some(local) = socket.local_endpoint() {
        anyhow::ensure!(
            local == IpEndpoint::from(listen),
            "Bad destination socket: {local}"
        )
    }

    // Ensure we can recv, send and have space to send.
    if !socket.can_recv() || !socket.can_send() || socket.send_queue() > 0 {
        tracing::trace!(
            state = %socket.state(),
            send_queue = %socket.send_queue(),
            "Not yet ready to receive next message"
        );

        return Ok(None);
    }

    let Some(query) = codec::try_recv(socket)? else {
        return Ok(None);
    };

    let remote = socket
        .remote_endpoint()
        .context("Unknown remote endpoint despite having just received a message")?;

    Ok(Some((
        query,
        SocketAddr::new(remote.addr.into(), remote.port),
    )))
}

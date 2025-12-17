mod doh;
mod gso_queue;
mod nameserver_set;
mod tcp_dns;
mod udp_dns;

use crate::{TunnelError, device_channel::Device, dns, otel, sockets::Sockets};
use anyhow::{Context as _, ErrorExt, Result};
use chrono::{DateTime, Utc};
use dns_types::DoHUrl;
use futures::FutureExt as _;
use futures_bounded::{FuturesMap, FuturesTupleSet};
use gat_lending_iterator::LendingIterator;
use gso_queue::GsoQueue;
use http_client::HttpClient;
use ip_packet::{Ecn, IpPacket, MAX_FZ_PAYLOAD};
use nameserver_set::NameserverSet;
use socket_factory::{DatagramIn, SocketFactory, TcpSocket, UdpSocket};
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    io,
    net::{IpAddr, SocketAddr},
    pin::Pin,
    sync::Arc,
    task::{Context, Poll, ready},
    time::{Duration, Instant},
};
use tracing::Level;
use tun::Tun;

/// How many IP packets we will at most read from the MPSC-channel connected to our TUN device thread.
///
/// Reading IP packets from the channel in batches allows us to process (i.e. encrypt) them as a batch.
/// UDP datagrams of the same size and destination can then be sent in a single syscall using GSO.
///
/// On mobile platforms, we are memory-constrained and thus cannot afford to process big batches of packets.
/// Thus, we limit the batch-size there to 25.
const MAX_INBOUND_PACKET_BATCH: usize = {
    if cfg!(any(target_os = "ios", target_os = "android")) {
        25
    } else {
        100
    }
};

/// Bundles together all side-effects that connlib needs to have access to.
pub struct Io {
    /// The UDP sockets used to send & receive packets from the network.
    sockets: Sockets,
    gso_queue: GsoQueue,

    nameservers: NameserverSet,
    reval_nameserver_interval: tokio::time::Interval,

    udp_dns_server: BTreeMap<SocketAddr, l4_udp_dns_server::Server>,
    tcp_dns_server: BTreeMap<SocketAddr, l4_tcp_dns_server::Server>,

    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,

    dns_queries: FuturesTupleSet<Result<dns_types::Response>, DnsQueryMetaData>,

    udp_dns_client: l4_udp_dns_client::UdpDnsClient,
    doh_clients: BTreeMap<DoHUrl, HttpClient>,
    doh_clients_bootstrap: FuturesMap<DoHUrl, Result<HttpClient>>,

    timeout: Option<Pin<Box<tokio::time::Sleep>>>,

    tun: Device,
    outbound_packet_buffer: VecDeque<IpPacket>,
    packet_counter: opentelemetry::metrics::Counter<u64>,
    dropped_packets: opentelemetry::metrics::Counter<u64>,
}

#[derive(Debug, Clone)]
struct DnsQueryMetaData {
    query: dns_types::Query,
    server: dns::Upstream,
    local: SocketAddr,
    remote: SocketAddr,
    transport: dns::Transport,
}

pub(crate) struct Buffers {
    ip: Vec<IpPacket>,
}

impl Default for Buffers {
    fn default() -> Self {
        Self {
            ip: Vec::with_capacity(MAX_INBOUND_PACKET_BATCH),
        }
    }
}

/// Represents all IO sources that may be ready during a single event-loop tick.
///
/// This structure allows us to batch-process multiple ready sources rather than
/// handling them one at a time, improving fairness and preventing starvation.
pub struct Input<D, I> {
    pub now: Instant,
    pub now_utc: DateTime<Utc>,
    pub timeout: bool,
    pub device: Option<D>,
    pub network: Option<I>,
    pub tcp_dns_queries: Vec<l4_tcp_dns_server::Query>,
    pub udp_dns_queries: Vec<l4_udp_dns_server::Query>,
    pub dns_response: Option<dns::RecursiveResponse>,
    pub error: TunnelError,
}

impl<D, I> Input<D, I> {
    fn error(e: impl Into<anyhow::Error>) -> Self {
        Self {
            now: Instant::now(),
            now_utc: Utc::now(),
            timeout: false,
            device: None,
            network: None,
            tcp_dns_queries: Vec::new(),
            udp_dns_queries: Vec::new(),
            dns_response: None,
            error: TunnelError::single(e),
        }
    }
}

fn poll_to_option<T>(poll: Poll<T>) -> Option<T> {
    match poll {
        Poll::Ready(r) => Some(r),
        Poll::Pending => None,
    }
}

fn poll_result_to_option<T, E>(poll: Poll<Result<T, E>>, error: &mut TunnelError) -> Option<T>
where
    anyhow::Error: From<E>,
{
    match poll {
        Poll::Ready(Ok(r)) => Some(r),
        Poll::Ready(Err(e)) => {
            error.push(e);

            None
        }
        Poll::Pending => None,
    }
}

const DNS_QUERY_TIMEOUT: Duration = Duration::from_secs(5);
const RE_EVALUATE_NAMESERVER_INTERVAL: Duration = Duration::from_secs(60);

impl Io {
    /// Creates a new I/O abstraction
    ///
    /// Must be called within a Tokio runtime context so we can bind the sockets.
    pub fn new(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        nameservers: BTreeSet<IpAddr>,
    ) -> Self {
        let mut sockets = Sockets::default();
        sockets.rebind(udp_socket_factory.clone()); // Bind sockets on startup.

        Self {
            outbound_packet_buffer: VecDeque::default(),
            timeout: None,
            sockets,
            nameservers: NameserverSet::new(
                nameservers,
                tcp_socket_factory.clone(),
                udp_socket_factory.clone(),
            ),
            udp_dns_client: l4_udp_dns_client::UdpDnsClient::new(
                udp_socket_factory.clone(),
                Vec::default(),
            ),
            reval_nameserver_interval: tokio::time::interval(RE_EVALUATE_NAMESERVER_INTERVAL),
            tcp_socket_factory,
            udp_socket_factory,
            dns_queries: FuturesTupleSet::new(
                || futures_bounded::Delay::tokio(DNS_QUERY_TIMEOUT),
                1000,
            ),
            doh_clients: Default::default(),
            doh_clients_bootstrap: FuturesMap::new(
                || futures_bounded::Delay::tokio(DNS_QUERY_TIMEOUT),
                10,
            ),
            gso_queue: GsoQueue::new(),
            tun: Device::new(),
            udp_dns_server: Default::default(),
            tcp_dns_server: Default::default(),
            packet_counter: opentelemetry::global::meter("connlib")
                .u64_counter("system.network.packets")
                .with_description("The number of packets processed.")
                .build(),
            dropped_packets: otel::metrics::network_packet_dropped(),
        }
    }

    pub fn rebind_dns(&mut self, sockets: Vec<SocketAddr>) -> Result<(), TunnelError> {
        tracing::debug!(?sockets, "Rebinding DNS servers");

        self.udp_dns_server.clear();
        self.tcp_dns_server.clear();

        let mut error = TunnelError::default();

        for socket in sockets {
            let mut udp = l4_udp_dns_server::Server::default();
            let mut tcp = l4_tcp_dns_server::Server::default();

            match udp.rebind(socket) {
                Ok(()) => {
                    self.udp_dns_server.insert(socket, udp);
                }
                Err(e) => {
                    error.push(e);
                }
            };
            match tcp.rebind(socket) {
                Ok(()) => {
                    self.tcp_dns_server.insert(socket, tcp);
                }
                Err(e) => {
                    error.push(e);
                }
            };
        }

        if !error.is_empty() {
            self.udp_dns_server.clear();
            self.tcp_dns_server.clear();

            return Err(error);
        }

        Ok(())
    }

    pub fn update_system_resolvers(&mut self, resolvers: Vec<IpAddr>) {
        tracing::debug!(servers = ?resolvers, "Re-configuring UDP DNS client with new upstreams");

        self.udp_dns_client =
            l4_udp_dns_client::UdpDnsClient::new(self.udp_socket_factory.clone(), resolvers)
    }

    pub fn poll_has_sockets(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        self.sockets.poll_has_sockets(cx)
    }

    pub fn fastest_nameserver(&self) -> Option<IpAddr> {
        self.nameservers.fastest()
    }

    pub fn poll<'b>(
        &mut self,
        cx: &mut Context<'_>,
        buffers: &'b mut Buffers,
    ) -> Poll<
        Input<
            impl Iterator<Item = IpPacket> + use<'b>,
            impl for<'a> LendingIterator<Item<'a> = DatagramIn<'a>> + use<>,
        >,
    > {
        if let Err(e) = ready!(self.flush(cx)) {
            return Poll::Ready(Input::error(e));
        }

        let mut error = TunnelError::default();

        if self.reval_nameserver_interval.poll_tick(cx).is_ready() {
            self.nameservers.evaluate();
        }

        // We purposely don't want to block the event loop here because we can do plenty of other work while this is running.
        let _ = self.nameservers.poll(cx);

        while let Poll::Ready((url, result)) = self.doh_clients_bootstrap.poll_unpin(cx) {
            match result {
                Ok(Ok(client)) => {
                    self.doh_clients.insert(url.clone(), client);
                }
                Ok(Err(e)) => tracing::debug!(%url, "Failed to bootstrap DoH client: {e:#}"),
                Err(e) => tracing::debug!(%url, "Failed to bootstrap DoH client: {e:#}"),
            }
        }

        let network = self.sockets.poll_recv_from(cx).map(|network| {
            anyhow::Ok(
                network
                    .context("UDP socket failed")?
                    .filter(is_max_wg_packet_size),
            )
        });

        let device = self
            .tun
            .poll_read_many(cx, &mut buffers.ip, MAX_INBOUND_PACKET_BATCH)
            .map(|num_packets| {
                let num_ipv4 = buffers.ip[..num_packets]
                    .iter()
                    .filter(|p| p.ipv4_header().is_some())
                    .count();
                let num_ipv6 = num_packets - num_ipv4;

                self.packet_counter.add(
                    num_ipv4 as u64,
                    &[
                        otel::attr::network_type_ipv4(),
                        otel::attr::network_io_direction_receive(),
                    ],
                );
                self.packet_counter.add(
                    num_ipv6 as u64,
                    &[
                        otel::attr::network_type_ipv6(),
                        otel::attr::network_io_direction_receive(),
                    ],
                );

                buffers.ip.drain(..num_packets)
            });

        let udp_dns_queries = self
            .udp_dns_server
            .values_mut()
            .flat_map(|s| match s.poll(cx) {
                Poll::Ready(Ok(q)) => Some(q),
                Poll::Ready(Err(e)) => {
                    error.push(e);

                    None
                }
                Poll::Pending => None,
            })
            .collect::<Vec<_>>();

        let tcp_dns_queries = self
            .tcp_dns_server
            .values_mut()
            .flat_map(|s| match s.poll(cx) {
                Poll::Ready(Ok(q)) => Some(q),
                Poll::Ready(Err(e)) => {
                    error.push(e);

                    None
                }
                Poll::Pending => None,
            })
            .collect::<Vec<_>>();

        let dns_response = self
            .dns_queries
            .poll_unpin(cx)
            .map(|(result, meta)| match result {
                Ok(result) => dns::RecursiveResponse {
                    server: meta.server,
                    query: meta.query,
                    message: result,
                    transport: meta.transport,
                    local: meta.local,
                    remote: meta.remote,
                },
                Err(e @ futures_bounded::Timeout { .. }) => dns::RecursiveResponse {
                    server: meta.server,
                    query: meta.query,
                    message: Err(anyhow::Error::new(io::Error::new(
                        io::ErrorKind::TimedOut,
                        e,
                    ))),
                    transport: meta.transport,
                    local: meta.local,
                    remote: meta.remote,
                },
            });

        // We need to discard DoH clients if their queries fail because the connection got closed.
        // They will get re-bootstrapped on the next requested DoH query.
        if let Poll::Ready(response) = &dns_response
            && let dns::Upstream::DoH { server } = &response.server
            && let Err(e) = &response.message
            && e.any_is::<http_client::Closed>()
        {
            tracing::debug!(%server, "Connection of DoH client failed");

            self.doh_clients.remove(server);
        }

        let timeout = self
            .timeout
            .as_mut()
            .map(|timeout| timeout.poll_unpin(cx).is_ready())
            .unwrap_or(false);

        if timeout {
            self.timeout = None;
        }

        if !timeout
            && device.is_pending()
            && network.is_pending()
            && tcp_dns_queries.is_empty()
            && udp_dns_queries.is_empty()
            && dns_response.is_pending()
            && error.is_empty()
        {
            return Poll::Pending;
        }

        Poll::Ready(Input {
            now: Instant::now(),
            now_utc: Utc::now(),
            timeout,
            device: poll_to_option(device),
            network: poll_result_to_option(network, &mut error),
            tcp_dns_queries,
            udp_dns_queries,
            dns_response: poll_to_option(dns_response),
            error,
        })
    }

    pub fn flush(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        let mut datagrams = self.gso_queue.datagrams();
        let mut any_pending = false;

        loop {
            if self.sockets.poll_send_ready(cx)?.is_pending() {
                any_pending = true;
                break;
            }

            let Some(datagram) = datagrams.next() else {
                break;
            };

            self.sockets.send(datagram)?;
        }

        loop {
            // First, check if we can send more packets.
            if self.tun.poll_send_ready(cx)?.is_pending() {
                any_pending = true;
                break;
            }

            // Second, check if we have any buffer packets.
            let Some(packet) = self.outbound_packet_buffer.pop_front() else {
                break; // No more packets? All done.
            };

            // Third, send the packet.
            self.tun
                .send(packet)
                .context("Failed to send IP packet to TUN device")?;
        }

        if any_pending {
            return Poll::Pending;
        }

        Poll::Ready(Ok(()))
    }

    pub fn set_tun(&mut self, tun: Box<dyn Tun>) {
        self.tun.set_tun(tun);
    }

    pub fn send_tun(&mut self, packet: IpPacket) {
        self.packet_counter.add(
            1,
            &[
                otel::attr::network_type_for_packet(&packet),
                otel::attr::network_io_direction_transmit(),
            ],
        );

        self.outbound_packet_buffer.push_back(packet);
    }

    pub fn reset(&mut self) {
        self.tcp_socket_factory.reset();
        self.udp_socket_factory.reset();
        self.sockets.rebind(self.udp_socket_factory.clone());
        self.gso_queue.clear();
        self.dns_queries =
            FuturesTupleSet::new(|| futures_bounded::Delay::tokio(DNS_QUERY_TIMEOUT), 1000);
        self.nameservers.evaluate();

        for (server, _) in std::mem::take(&mut self.doh_clients) {
            self.bootstrap_doh_client(server);
        }
    }

    pub fn reset_timeout(&mut self, timeout: Instant, reason: &'static str) {
        let wakeup_in = tracing::event_enabled!(Level::TRACE)
            .then(|| timeout.duration_since(Instant::now()))
            .map(tracing::field::debug);
        let timeout = tokio::time::Instant::from_std(timeout);

        match self.timeout.as_mut() {
            Some(existing_timeout) if existing_timeout.deadline() != timeout => {
                tracing::trace!(wakeup_in, %reason);

                existing_timeout.as_mut().reset(timeout)
            }
            Some(_) => {}
            None => {
                self.timeout = {
                    tracing::trace!(?wakeup_in, %reason);

                    Some(Box::pin(tokio::time::sleep_until(timeout)))
                }
            }
        }
    }

    pub fn send_network(
        &mut self,
        src: Option<SocketAddr>,
        dst: SocketAddr,
        payload: &[u8],
        ecn: Ecn,
    ) {
        self.gso_queue.enqueue(src, dst, payload, ecn);

        self.packet_counter.add(
            1,
            &[
                otel::attr::network_protocol_name(payload),
                otel::attr::network_transport_udp(),
                otel::attr::network_io_direction_transmit(),
            ],
        );
    }

    pub fn send_dns_query(&mut self, query: dns::RecursiveQuery) {
        let meta = DnsQueryMetaData {
            query: query.message.clone(),
            server: query.server.clone(),
            transport: query.transport,
            local: query.local,
            remote: query.remote,
        };

        match (query.transport, query.server) {
            (dns::Transport::Udp, dns::Upstream::Do53 { server }) => {
                self.queue_dns_query(
                    udp_dns::send(self.udp_socket_factory.clone(), server, query.message),
                    meta,
                );
            }
            (dns::Transport::Tcp, dns::Upstream::Do53 { server }) => {
                self.queue_dns_query(
                    tcp_dns::send(self.tcp_socket_factory.clone(), server, query.message),
                    meta,
                );
            }
            (_, dns::Upstream::DoH { server }) => {
                let Some(http_client) = self.doh_clients.get(&server).cloned() else {
                    self.bootstrap_doh_client(server);

                    // Queue a dummy "query" that instantly fails to ensure we don't let the application run into a timeout.
                    // This will trigger a SERVFAIL response.
                    self.queue_dns_query(async { anyhow::bail!("Bootstrapping DoH client") }, meta);

                    return;
                };

                self.queue_dns_query(doh::send(http_client, server, query.message), meta);
            }
        }
    }

    pub(crate) fn bootstrap_doh_client(&mut self, server: DoHUrl) {
        if self.doh_clients.contains_key(&server) {
            return;
        }

        if self.doh_clients_bootstrap.contains(server.clone()) {
            return; // Already bootstrapping.
        }

        let socket_factory = self.tcp_socket_factory.clone();
        let addresses = self.udp_dns_client.resolve(server.host());

        let _ = self
            .doh_clients_bootstrap
            .try_push(server.clone(), async move {
                tracing::debug!(%server, "Bootstrapping DoH client");

                let addresses = addresses.await?;
                let http_client =
                    HttpClient::new(server.host().to_string(), addresses.clone(), socket_factory)
                        .await?;

                tracing::debug!(%server, "Bootstrapped DoH client");

                Ok(http_client)
            });
    }

    pub(crate) fn send_udp_dns_response(
        &mut self,
        to: SocketAddr,
        from: SocketAddr,
        message: dns_types::Response,
    ) -> io::Result<()> {
        self.udp_dns_server
            .get_mut(&from)
            .ok_or(io::Error::other("No DNS server"))?
            .send_response(to, message)
    }

    pub(crate) fn send_tcp_dns_response(
        &mut self,
        to: SocketAddr,
        from: SocketAddr,
        message: dns_types::Response,
    ) -> io::Result<()> {
        self.tcp_dns_server
            .get_mut(&from)
            .ok_or(io::Error::other("No DNS server"))?
            .send_response(to, message)
    }

    pub(crate) fn inc_dropped_packet(&self, attrs: &[opentelemetry::KeyValue]) {
        self.dropped_packets.add(1, attrs);
    }

    fn queue_dns_query(
        &mut self,
        future: impl Future<Output = Result<dns_types::Response>> + Send + 'static,
        meta: DnsQueryMetaData,
    ) {
        if self.dns_queries.try_push(future, meta.clone()).is_err() {
            tracing::debug!(?meta, "Failed to queue DNS query")
        }
    }
}

fn is_max_wg_packet_size(d: &DatagramIn) -> bool {
    let len = d.packet.len();
    if len > MAX_FZ_PAYLOAD {
        return false;
    }

    true
}

#[cfg(test)]
mod tests {
    use futures::task::noop_waker_ref;
    use std::{future::poll_fn, net::Ipv4Addr, ptr::addr_of_mut};

    use super::*;

    #[tokio::test]
    async fn timer_is_reset_after_it_fires() {
        let mut io = Io::for_test();

        let deadline = Instant::now() + Duration::from_secs(1);
        io.reset_timeout(deadline, "");

        let input = io.next().await;

        assert!(input.timeout);
        assert!(input.now >= deadline, "timer expire after deadline");
        drop(input);

        let poll = io.poll_test();

        assert!(poll.is_pending());
        assert!(io.timeout.is_none());
    }

    #[tokio::test]
    async fn emits_now_in_case_timeout_is_in_the_past() {
        let now = Instant::now();
        let mut io = Io::for_test();

        io.reset_timeout(now - Duration::from_secs(10), "");

        let input = io.next().await;
        let timeout = input.now;

        assert!(timeout >= now, "timeout = {timeout:?}, now = {now:?}");
    }

    #[tokio::test]
    async fn bootstrap_doh() {
        let _guard = logging::test("debug");

        let mut io = Io::for_test();
        io.update_system_resolvers(vec![IpAddr::from([1, 1, 1, 1])]);

        {
            io.send_dns_query(example_com_recursive_query());

            let input = io.next().await;

            assert_eq!(
                input.dns_response.unwrap().message.unwrap_err().to_string(),
                "Bootstrapping DoH client"
            );
        }

        // Hack: Advance for a bit but timeout after 2s. We don't emit an event when the client is bootstrapped so this will always be `Pending`.
        let _ = tokio::time::timeout(Duration::from_secs(2), io.next()).await;

        {
            io.send_dns_query(example_com_recursive_query());

            let input = io.next().await;

            assert_eq!(
                input.dns_response.unwrap().message.unwrap().response_code(),
                dns_types::ResponseCode::NOERROR
            );
        }
    }

    #[tokio::test]
    async fn rebind_dns_clears_all_servers_on_failure() {
        let _guard = logging::test("debug");

        let mut io = Io::for_test();

        let result = io.rebind_dns(vec![
            SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 40000), // This one will almost definitely work.
            SocketAddr::new(IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1)), 40000), // This one will fail.
        ]);

        assert_eq!(
            result
                .unwrap_err()
                .drain()
                .map(|e| e.to_string())
                .collect::<Vec<_>>(),
            vec![
                "Failed to bind UDP socket on 1.1.1.1:40000",
                "Failed to bind TCP listener on 1.1.1.1:40000"
            ]
        );
        assert!(io.udp_dns_server.is_empty());
        assert!(io.tcp_dns_server.is_empty());
    }

    fn example_com_recursive_query() -> dns::RecursiveQuery {
        dns::RecursiveQuery {
            server: dns::Upstream::DoH {
                server: DoHUrl::cloudflare(),
            },
            local: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 11111),
            remote: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 22222),
            message: dns_types::Query::new(
                "example.com".parse().unwrap(),
                dns_types::RecordType::A,
            ),
            transport: dns::Transport::Udp,
        }
    }

    static mut DUMMY_BUF: Buffers = Buffers { ip: Vec::new() };

    /// Helper functions to make the test more concise.
    impl Io {
        fn for_test() -> Io {
            let mut io = Io::new(
                Arc::new(socket_factory::tcp),
                Arc::new(socket_factory::udp),
                BTreeSet::new(),
            );
            io.set_tun(Box::new(DummyTun));

            io
        }

        async fn next(
            &mut self,
        ) -> Input<
            impl Iterator<Item = IpPacket> + use<>,
            impl for<'a> LendingIterator<Item<'a> = DatagramIn<'a>>,
        > {
            poll_fn(|cx| {
                self.poll(
                    cx,
                    // SAFETY: This is a test and we never receive packets here.
                    unsafe { &mut *addr_of_mut!(DUMMY_BUF) },
                )
            })
            .await
        }

        fn poll_test(
            &mut self,
        ) -> Poll<
            Input<
                impl Iterator<Item = IpPacket> + use<>,
                impl for<'a> LendingIterator<Item<'a> = DatagramIn<'a>> + use<>,
            >,
        > {
            self.poll(
                &mut Context::from_waker(noop_waker_ref()),
                // SAFETY: This is a test and we never receive packets here.
                unsafe { &mut *addr_of_mut!(DUMMY_BUF) },
            )
        }
    }

    struct DummyTun;

    impl Tun for DummyTun {
        fn poll_send_ready(&mut self, _: &mut Context) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }

        fn send(&mut self, _: IpPacket) -> io::Result<()> {
            Ok(())
        }

        fn poll_recv_many(
            &mut self,
            _: &mut Context,
            _: &mut Vec<IpPacket>,
            _: usize,
        ) -> Poll<usize> {
            Poll::Pending
        }

        fn name(&self) -> &str {
            "dummy"
        }
    }
}

mod crypto;
mod device;
mod doh;
mod nameserver_set;
mod tcp_dns;
mod udp_dns;
mod udp_gso_train;

pub(crate) use crypto::MAX_DECRYPT_BACKLOG_MEMORY;
pub use crypto::{DecryptBatch, EncryptBatch, Received};
pub use device::{Device, TunChannelClosed};
pub(crate) use udp_gso_train::UdpGsoTrain;

use crate::{
    TunnelError, dns,
    sockets::{ReceivedDatagrams, Sockets},
};
use anyhow::{ErrorExt, Result};
use bootstrap_dns_client::BootstrapDnsClient;
use bufferpool::{Buffer, VecBuf};
use crypto::{CryptoWorkers, Decrypting};
use dns_types::DoHUrl;
use fast_random_state::FastRandomState;
use futures::{
    FutureExt as _, TryFutureExt as _,
    channel::oneshot,
    future::{BoxFuture, Shared},
};
use futures_bounded::{FuturesMap, FuturesTupleSet, PushError};
use http_client::{HttpClient, TlsConfig};
use ip_packet::IpPacket;
use nameserver_set::NameserverSet;
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::{
    collections::{BTreeSet, HashMap},
    io,
    net::{IpAddr, SocketAddr},
    sync::Arc,
    task::{Context, Poll},
    time::{Duration, Instant},
};
use tun::Tun;

/// Bundles together all side-effects that connlib needs to have access to.
pub struct Io {
    /// The UDP sockets used to send & receive packets from the network.
    sockets: Sockets,
    crypto: CryptoWorkers,
    decrypting: Decrypting,

    nameservers: NameserverSet,
    reval_nameserver_interval: tokio::time::Interval,

    udp_dns_server: HashMap<SocketAddr, l4_udp_dns_server::Server, FastRandomState>,
    tcp_dns_server: HashMap<SocketAddr, l4_tcp_dns_server::Server, FastRandomState>,

    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,

    dns_queries: FuturesTupleSet<Result<dns_types::Response>, DnsQueryMetaData>,

    bootstrap_dns_client: BootstrapDnsClient,
    doh_clients: HashMap<DoHUrl, DohClient, FastRandomState>,
    doh_clients_bootstrap: FuturesMap<DoHUrl, Result<HttpClient>>,
    doh_tls_config: TlsConfig,

    tun: Device,
}

#[derive(Debug, Clone)]
struct DnsQueryMetaData {
    query: dns_types::Query,
    server: dns::Upstream,
    local: SocketAddr,
    remote: SocketAddr,
    transport: dns::Transport,
    started_at: Instant,
    retried: bool,
}

enum DohClient {
    /// Resolves once the bootstrap driven by [`Io`] has connected, or fails once it gave up.
    Connecting(Shared<oneshot::Receiver<HttpClient>>),
    Connected(HttpClient),
}

/// Represents all IO sources that may be ready during a single event-loop tick.
///
/// This structure allows us to batch-process multiple ready sources rather than
/// handling them one at a time, improving fairness and preventing starvation.
pub struct Input {
    pub device: Option<tun::PacketBatch>,
    pub network: Option<ReceivedDatagrams>,
    /// Packets decrypted from the jobs of an [`Io::start_decrypt_batch`].
    pub decrypted: Option<Buffer<VecBuf<Received<snownet::DecryptedIpPacket>>>>,
    pub tcp_dns_queries: Vec<l4_tcp_dns_server::Query>,
    pub udp_dns_queries: Vec<l4_udp_dns_server::Query>,
    pub dns_responses: Vec<dns::RecursiveResponse>,
    pub error: TunnelError,
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

/// The state of a single [`Io::poll`] call.
struct PollState<'a, 'cx> {
    io: &'a mut Io,
    cx: &'a mut Context<'cx>,
    udp_has_room: bool,
    tun_has_room: bool,
    input: Input,
}

impl<'a, 'cx> PollState<'a, 'cx> {
    fn new(io: &'a mut Io, cx: &'a mut Context<'cx>) -> Self {
        Self {
            io,
            cx,
            udp_has_room: false,
            tun_has_room: false,
            input: Input {
                device: None,
                network: None,
                decrypted: None,
                tcp_dns_queries: Vec::new(),
                udp_dns_queries: Vec::new(),
                dns_responses: Vec::new(),
                error: TunnelError::default(),
            },
        }
    }

    fn flush_udp(&mut self) {
        let poll = self.io.sockets.poll_flush(self.cx);

        self.udp_has_room = poll_result_to_option(poll, &mut self.input.error).is_some();
    }

    fn flush_tun(&mut self) {
        let poll = self.io.tun.poll_flush(self.cx);

        self.tun_has_room = poll_result_to_option(poll, &mut self.input.error).is_some();
    }

    fn poll_nameservers(&mut self) {
        if self
            .io
            .reval_nameserver_interval
            .poll_tick(self.cx)
            .is_ready()
        {
            self.io.nameservers.evaluate();
        }

        // We purposely don't want to block the event loop here because we can do plenty of other work while this is running.
        let _ = self.io.nameservers.poll(self.cx);
    }

    fn poll_doh_bootstrap(&mut self) {
        while let Poll::Ready((url, result)) = self.io.doh_clients_bootstrap.poll_unpin(self.cx) {
            match result.map_err(anyhow::Error::new).flatten() {
                Ok(client) => {
                    self.io
                        .doh_clients
                        .insert(url, DohClient::Connected(client));
                }
                Err(e) => {
                    tracing::debug!(%url, "Failed to bootstrap DoH client: {e:#}");

                    self.io.doh_clients.remove(&url);
                }
            }
        }
    }

    fn poll_decrypted(&mut self) {
        if !self.tun_has_room {
            return;
        }

        self.input.decrypted = poll_to_option(self.io.decrypting.poll_next(self.cx));
    }

    fn poll_network(&mut self) {
        if !self.io.decrypting.has_room() {
            return;
        }

        self.input.network = poll_to_option(self.io.sockets.poll_recv_from(self.cx));
    }

    fn poll_socket_errors(&mut self) {
        while let Poll::Ready(e) = self.io.sockets.poll_error(self.cx) {
            self.input.error.push(e);
        }
    }

    fn poll_device(&mut self) {
        if !self.udp_has_room {
            return;
        }

        let poll = self.io.tun.poll_read(self.cx);

        self.input.device = poll_result_to_option(poll, &mut self.input.error);
    }

    fn poll_dns_queries(&mut self) {
        for server in self.io.udp_dns_server.values_mut() {
            if let Some(query) = poll_result_to_option(server.poll(self.cx), &mut self.input.error)
            {
                self.input.udp_dns_queries.push(query);
            }
        }

        for server in self.io.tcp_dns_server.values_mut() {
            if let Some(query) = poll_result_to_option(server.poll(self.cx), &mut self.input.error)
            {
                self.input.tcp_dns_queries.push(query);
            }
        }
    }

    fn poll_dns_responses(&mut self) {
        while let Poll::Ready((result, mut meta)) = self.io.dns_queries.poll_unpin(self.cx) {
            let message = match result {
                Ok(message) => message,
                Err(e @ futures_bounded::Timeout { .. }) => Err(anyhow::Error::new(
                    io::Error::new(io::ErrorKind::TimedOut, e),
                )),
            };

            if let dns::Upstream::DoH { server } = &meta.server
                && let Err(e) = &message
                && e.any_is::<http_client::Closed>()
                && !meta.retried
            {
                tracing::debug!(%server, "DoH connection closed, retrying query on a new connection");

                let server = server.clone();
                let client = self.io.doh_client(server.clone());

                meta.retried = true;
                self.io
                    .queue_dns_query(doh::send(client, server, meta.query.clone()), meta);

                continue;
            }

            self.input.dns_responses.push(dns::RecursiveResponse {
                server: meta.server,
                query: meta.query,
                message,
                transport: meta.transport,
                local: meta.local,
                remote: meta.remote,
                started_at: meta.started_at,
                recursion: dns::Recursion::Local,
            });
        }
    }

    fn into_input(self) -> Poll<Input> {
        let input = self.input;

        if input.device.is_none()
            && input.network.is_none()
            && input.decrypted.is_none()
            && input.tcp_dns_queries.is_empty()
            && input.udp_dns_queries.is_empty()
            && input.dns_responses.is_empty()
            && input.error.is_empty()
        {
            return Poll::Pending;
        }

        Poll::Ready(input)
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
        let packet_counter = otel_instruments::network_packets();
        let mut sockets = Sockets::new(packet_counter.clone());
        sockets.rebind(udp_socket_factory.clone()); // Bind sockets on startup.

        Self {
            sockets,
            nameservers: NameserverSet::new(
                nameservers,
                tcp_socket_factory.clone(),
                udp_socket_factory.clone(),
            ),
            bootstrap_dns_client: BootstrapDnsClient::new(
                udp_socket_factory.clone(),
                tcp_socket_factory.clone(),
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
            doh_tls_config: TlsConfig::webpki_roots(),
            crypto: CryptoWorkers::new(packet_counter),
            decrypting: Decrypting::default(),
            tun: Device::new(),
            udp_dns_server: Default::default(),
            tcp_dns_server: Default::default(),
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
        tracing::debug!(servers = ?resolvers, "Re-configuring bootstrap DNS client with new upstreams");

        self.bootstrap_dns_client = BootstrapDnsClient::new(
            self.udp_socket_factory.clone(),
            self.tcp_socket_factory.clone(),
            resolvers,
        )
    }

    pub fn fastest_nameserver(&self) -> Option<IpAddr> {
        self.nameservers.fastest()
    }

    /// Polls all IO sources that are ready.
    ///
    /// The TUN device is only read while nothing waits for room in the UDP sockets and each has
    /// room for an [`Io::start_encrypt_batch`], and decrypted packets are only accepted while the TUN
    /// device has room.
    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Input> {
        let mut state = PollState::new(self, cx);

        state.flush_udp();
        state.flush_tun();
        state.poll_nameservers();
        state.poll_doh_bootstrap();
        state.poll_decrypted();
        state.poll_network();
        state.poll_socket_errors();
        state.poll_device();
        state.poll_dns_queries();
        state.poll_dns_responses();

        state.into_input()
    }

    pub fn flush(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        let mut any_pending = false;

        if self.sockets.poll_flush(cx)?.is_pending() {
            any_pending = true
        }

        if self.tun.poll_flush(cx)?.is_pending() {
            any_pending = true;
        }

        if any_pending {
            return Poll::Pending;
        }

        Poll::Ready(Ok(()))
    }

    pub fn set_tun(&mut self, tun: Box<dyn Tun>) {
        self.tun.set_tun(tun);
    }

    pub fn queue_tun(&mut self, packet: IpPacket) {
        self.tun.queue(packet);
    }

    /// Marks the end of the current batch of packets queued via [`Io::queue_tun`].
    pub fn flush_tun_batch(&mut self) {
        self.tun.flush_batch();
    }

    pub fn reset(&mut self) {
        self.tcp_socket_factory.reset();
        self.udp_socket_factory.reset();
        self.sockets.rebind(self.udp_socket_factory.clone());
        self.dns_queries =
            FuturesTupleSet::new(|| futures_bounded::Delay::tokio(DNS_QUERY_TIMEOUT), 1000);
        self.doh_clients_bootstrap =
            FuturesMap::new(|| futures_bounded::Delay::tokio(DNS_QUERY_TIMEOUT), 10);
        self.nameservers.evaluate();

        for (server, _) in std::mem::take(&mut self.doh_clients) {
            self.bootstrap_doh_client(server);
        }
    }

    /// Starts a batch of encapsulated packets to encrypt off the main thread.
    ///
    /// Its datagrams go to the UDP sockets when it is dropped. Start one only for the packets
    /// [`Io::poll`] read from the TUN device, which it does only while each UDP socket has room.
    pub fn start_encrypt_batch(&mut self) -> EncryptBatch<'_> {
        self.crypto.start_encrypt_batch(&mut self.sockets)
    }

    /// Starts a batch of received data messages to decrypt off the main thread, yielding them via
    /// [`Input::decrypted`].
    pub fn start_decrypt_batch(&mut self) -> DecryptBatch<'_> {
        self.crypto.start_decrypt_batch(&mut self.decrypting)
    }

    pub fn send_network(&mut self, transmit: snownet::Transmit) {
        self.sockets.send_ready(transmit);
    }

    pub fn send_dns_query(&mut self, query: dns::RecursiveQuery, now: Instant) {
        let meta = DnsQueryMetaData {
            query: query.message.clone(),
            server: query.server.clone(),
            transport: query.transport,
            local: query.local,
            remote: query.remote,
            started_at: now,
            retried: false,
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
                let client = self.doh_client(server.clone());

                self.queue_dns_query(doh::send(client, server, query.message), meta);
            }
        }
    }

    /// Ensures a DoH client for `server` exists or is being bootstrapped.
    pub(crate) fn bootstrap_doh_client(&mut self, server: DoHUrl) {
        self.doh_client_entry(server);
    }

    /// Resolves to the DoH client for `server` once it is connected.
    fn doh_client(&mut self, server: DoHUrl) -> BoxFuture<'static, Result<HttpClient>> {
        match self.doh_client_entry(server) {
            Some(DohClient::Connected(client)) => {
                futures::future::ready(Ok(client.clone())).boxed()
            }
            Some(DohClient::Connecting(client)) => client
                .clone()
                .map_err(|oneshot::Canceled| anyhow::anyhow!("Failed to bootstrap DoH client"))
                .boxed(),
            None => futures::future::ready(Err(anyhow::anyhow!(
                "Too many DoH clients are bootstrapping"
            )))
            .boxed(),
        }
    }

    /// Returns the entry for `server`, replacing a closed client with a fresh bootstrap.
    ///
    /// `None` if the bootstrap could not be started.
    fn doh_client_entry(&mut self, server: DoHUrl) -> Option<&DohClient> {
        if let Some(DohClient::Connected(client)) = self.doh_clients.get(&server)
            && client.is_closed()
        {
            tracing::debug!(%server, "DoH connection is closed");

            self.doh_clients.remove(&server);
        }

        if !self.doh_clients.contains_key(&server) {
            let (ready, client) = oneshot::channel();
            let addresses = self.bootstrap_dns_client.resolve(server.host());
            let socket_factory = self.tcp_socket_factory.clone();
            let tls_config = self.doh_tls_config.clone();

            let bootstrap = {
                let server = server.clone();

                async move {
                    tracing::debug!(%server, "Bootstrapping DoH client");

                    let addresses = addresses.await?;
                    let http_client = HttpClient::new(
                        server.host().into_owned(),
                        server.port(),
                        addresses,
                        tls_config,
                        socket_factory,
                    )
                    .await?;

                    tracing::debug!(%server, "Bootstrapped DoH client");

                    let _ = ready.send(http_client.clone());

                    Ok(http_client)
                }
            };

            match self
                .doh_clients_bootstrap
                .try_push(server.clone(), bootstrap)
            {
                Ok(()) | Err(PushError::Replaced(_)) => {}
                Err(PushError::BeyondCapacity(_)) => return None,
            }

            self.doh_clients
                .insert(server.clone(), DohClient::Connecting(client.shared()));
        }

        self.doh_clients.get(&server)
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

#[cfg(test)]
mod tests {
    use std::{future::poll_fn, net::Ipv4Addr};

    use doh_test_server::DohTestServer;

    use super::*;

    #[tokio::test]
    async fn bootstrap_doh() {
        let _guard = logging::test("debug");

        let answer = Ipv4Addr::new(192, 0, 2, 1);
        let server = DohTestServer::spawn(answer).await.unwrap();
        let mut io = Io::for_test();
        io.doh_tls_config = TlsConfig::new(server.root_cert_store());

        io.send_dns_query(example_com_recursive_query(server.url()), Instant::now());

        let response = io.next_dns_response().await.message.unwrap();

        assert_eq!(response.response_code(), dns_types::ResponseCode::NOERROR);
        assert_eq!(
            response
                .records()
                .filter_map(dns_types::records::extract_ip)
                .collect::<Vec<_>>(),
            vec![IpAddr::V4(answer)]
        );
    }

    #[tokio::test]
    async fn failed_bootstrap_is_evicted() {
        let _guard = logging::test("debug");

        let mut io = Io::for_test();

        io.send_dns_query(
            example_com_recursive_query(DoHUrl::cloudflare()),
            Instant::now(),
        );
        let response = io.next_dns_response().await;

        assert!(response.message.is_err());
        assert!(io.doh_clients.is_empty());

        io.send_dns_query(
            example_com_recursive_query(DoHUrl::cloudflare()),
            Instant::now(),
        );

        assert!(matches!(
            io.doh_clients.get(&DoHUrl::cloudflare()),
            Some(DohClient::Connecting(_))
        ));
    }

    #[tokio::test]
    async fn rebind_dns_clears_all_servers_on_failure() {
        let _guard = logging::test("debug");

        let mut io = Io::for_test();

        let result = io.rebind_dns(vec![
            SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0), // This one will almost definitely work.
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

    fn example_com_recursive_query(server: DoHUrl) -> dns::RecursiveQuery {
        dns::RecursiveQuery {
            server: dns::Upstream::DoH { server },
            local: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 11111),
            remote: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 22222),
            message: dns_types::Query::new(
                "example.com".parse().unwrap(),
                dns_types::RecordType::A,
            ),
            transport: dns::Transport::Udp,
        }
    }

    /// Helper functions to make the test more concise.
    impl Io {
        fn for_test() -> Io {
            let mut io = Io::new(
                Arc::new(socket_factory::tcp),
                Arc::new(socket_factory::udp),
                BTreeSet::new(),
            );
            io.set_tun(Box::new(DummyTun::new()));

            io
        }

        async fn next_dns_response(&mut self) -> dns::RecursiveResponse {
            loop {
                let mut input = poll_fn(|cx| self.poll(cx)).await;

                for e in input.error.drain() {
                    tracing::debug!("Ignoring error unrelated to DNS: {e:#}");
                }

                if let Some(response) = input.dns_responses.pop() {
                    return response;
                }
            }
        }
    }

    struct DummyTun {
        tx: tun::OutboundTx,
        rx: tun::InboundRx,
        _keep_alive: (tun::OutboundRx, tun::InboundTx),
    }

    impl DummyTun {
        fn new() -> Self {
            let (tx, outbound_rx) = tun::outbound_channel();
            let (inbound_tx, rx) = tun::inbound_channel();

            Self {
                tx,
                rx,
                _keep_alive: (outbound_rx, inbound_tx),
            }
        }
    }

    impl Tun for DummyTun {
        fn sender(&mut self) -> &mut tun::OutboundTx {
            &mut self.tx
        }

        fn receiver(&mut self) -> &mut tun::InboundRx {
            &mut self.rx
        }

        fn name(&self) -> &str {
            "dummy"
        }
    }
}

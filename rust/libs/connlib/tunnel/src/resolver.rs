mod doh;
mod nameserver_set;
mod tcp_dns;
mod udp_dns;

use crate::dns;
use anyhow::{ErrorExt as _, Result};
use bootstrap_dns_client::BootstrapDnsClient;
use dns_types::DoHUrl;
use fast_random_state::FastRandomState;
use futures::{
    FutureExt as _, TryFutureExt as _,
    channel::oneshot,
    future::{BoxFuture, Shared},
};
use futures_bounded::{FuturesMap, FuturesTupleSet, PushError};
use http_client::{HttpClient, TlsConfig};
use nameserver_set::NameserverSet;
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::{
    collections::{BTreeSet, HashMap},
    future::poll_fn,
    io,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::Arc,
    task::{Context, Poll},
    time::{Duration, Instant},
};
use tokio::sync::mpsc;

const DNS_QUERY_TIMEOUT: Duration = Duration::from_secs(5);
const RE_EVALUATE_NAMESERVER_INTERVAL: Duration = Duration::from_secs(60);

const QUERY_QUEUE_SIZE: usize = 256;
const RESPONSE_QUEUE_SIZE: usize = 256;
const CONTROL_QUEUE_SIZE: usize = 16;

/// The server of the response to a query for the system's nameservers when none is available.
const NO_NAMESERVER: dns::Upstream = dns::Upstream::Do53 {
    server: SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), dns::DNS_PORT),
};

/// A recursive DNS query for the resolver task.
#[derive(Debug)]
pub struct ResolverQuery {
    /// The upstream to forward the query to, `None` for the fastest of the system's nameservers.
    pub server: Option<dns::Upstream>,
    /// The local address we received the query on.
    pub local: SocketAddr,
    /// The client that sent us the query.
    pub remote: SocketAddr,
    pub message: dns_types::Query,
    pub transport: dns::Transport,
    pub started_at: Instant,
}

impl ResolverQuery {
    pub(crate) fn new_gateway(
        query: tunnel_proto::AuthorizedDnsQuery,
        started_at: Instant,
    ) -> Self {
        let (local, remote, message, transport) = query.into_parts();

        Self {
            server: None,
            local,
            remote,
            message,
            transport,
            started_at,
        }
    }

    pub(crate) fn new(query: dns::RecursiveQuery, started_at: Instant) -> Self {
        Self {
            server: Some(query.server),
            local: query.local,
            remote: query.remote,
            message: query.message,
            transport: query.transport,
            started_at,
        }
    }
}

/// A change in configuration for the resolver task.
#[derive(Debug)]
pub enum ResolverControl {
    /// The system's resolvers changed, which bootstrap the DoH clients.
    SystemResolvers(Vec<IpAddr>),
    /// The configured upstreams changed. DoH clients connect ahead of the first query.
    Upstreams(Vec<dns::Upstream>),
    /// The network changed. In-flight queries are dropped and DoH clients reconnect.
    Reset,
}

/// The ends of the resolver task's channels that the event loop holds.
pub(crate) struct EventLoopEnds {
    queries_tx: mpsc::Sender<ResolverQuery>,
    responses_rx: mpsc::Receiver<dns::RecursiveResponse>,
    control_tx: mpsc::Sender<ResolverControl>,
}

/// The ends of the resolver task's channels that the task holds.
pub struct ResolverTaskEnds {
    queries_rx: mpsc::Receiver<ResolverQuery>,
    responses_tx: mpsc::Sender<dns::RecursiveResponse>,
    control_rx: mpsc::Receiver<ResolverControl>,
}

pub(crate) fn channels() -> (EventLoopEnds, ResolverTaskEnds) {
    let (queries_tx, queries_rx) = mpsc::channel(QUERY_QUEUE_SIZE);
    let (responses_tx, responses_rx) = mpsc::channel(RESPONSE_QUEUE_SIZE);
    let (control_tx, control_rx) = mpsc::channel(CONTROL_QUEUE_SIZE);

    let event_loop = EventLoopEnds {
        queries_tx,
        responses_rx,
        control_tx,
    };
    let task = ResolverTaskEnds {
        queries_rx,
        responses_tx,
        control_rx,
    };

    (event_loop, task)
}

/// Spawns the resolver task and returns the event loop's ends of its channels.
///
/// Must be called within a Tokio runtime context.
pub(crate) fn spawn(
    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    nameservers: BTreeSet<IpAddr>,
) -> EventLoopEnds {
    let (event_loop, task) = channels();

    tokio::spawn(Resolver::new(task, tcp_socket_factory, udp_socket_factory, nameservers).run());

    event_loop
}

impl EventLoopEnds {
    pub fn send_query(&self, query: ResolverQuery) {
        if let Err(e) = self.queries_tx.try_send(query) {
            tracing::debug!(query = ?e.into_inner(), "Failed to queue DNS query");
        }
    }

    pub fn send_control(&self, control: ResolverControl) {
        if let Err(e) = self.control_tx.try_send(control) {
            tracing::warn!(control = ?e.into_inner(), "Failed to send control message to resolver");
        }
    }

    pub fn poll_responses(
        &mut self,
        cx: &mut Context<'_>,
        responses: &mut Vec<dns::RecursiveResponse>,
    ) {
        let _ = self
            .responses_rx
            .poll_recv_many(cx, responses, RESPONSE_QUEUE_SIZE);
    }
}

impl ResolverTaskEnds {
    /// Takes the next query the event loop sent, if any.
    pub fn try_recv_query(&mut self) -> Option<ResolverQuery> {
        self.queries_rx.try_recv().ok()
    }

    /// Takes the next control message the event loop sent, if any.
    pub fn try_recv_control(&mut self) -> Option<ResolverControl> {
        self.control_rx.try_recv().ok()
    }

    /// Hands `response` to the event loop, or returns it if the channel is full.
    pub fn respond(
        &self,
        response: dns::RecursiveResponse,
    ) -> Result<(), Box<dns::RecursiveResponse>> {
        self.responses_tx
            .try_send(response)
            .map_err(|e| Box::new(e.into_inner()))
    }
}

struct Resolver {
    channels: ResolverTaskEnds,

    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,

    nameservers: NameserverSet,
    reval_nameserver_interval: tokio::time::Interval,

    queries: FuturesTupleSet<Result<dns_types::Response>, QueryMetaData>,

    bootstrap_dns_client: BootstrapDnsClient,
    doh_clients: HashMap<DoHUrl, DohClient, FastRandomState>,
    doh_clients_bootstrap: FuturesMap<DoHUrl, Result<HttpClient>>,
    doh_tls_config: TlsConfig,
}

#[derive(Debug, Clone)]
struct QueryMetaData {
    query: dns_types::Query,
    server: dns::Upstream,
    local: SocketAddr,
    remote: SocketAddr,
    transport: dns::Transport,
    started_at: Instant,
    retried: bool,
}

enum DohClient {
    /// Resolves once the bootstrap driven by [`Resolver`] has connected, or fails once it gave up.
    Connecting(Shared<oneshot::Receiver<HttpClient>>),
    Connected(HttpClient),
}

impl Resolver {
    fn new(
        channels: ResolverTaskEnds,
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        nameservers: BTreeSet<IpAddr>,
    ) -> Self {
        Self {
            channels,
            nameservers: NameserverSet::new(
                nameservers,
                tcp_socket_factory.clone(),
                udp_socket_factory.clone(),
            ),
            reval_nameserver_interval: tokio::time::interval(RE_EVALUATE_NAMESERVER_INTERVAL),
            bootstrap_dns_client: BootstrapDnsClient::new(
                udp_socket_factory.clone(),
                tcp_socket_factory.clone(),
                Vec::default(),
            ),
            tcp_socket_factory,
            udp_socket_factory,
            queries: new_query_set(),
            doh_clients: Default::default(),
            doh_clients_bootstrap: new_bootstrap_set(),
            doh_tls_config: TlsConfig::webpki_roots(),
        }
    }

    async fn run(mut self) {
        while let Some(response) = poll_fn(|cx| self.poll_next_response(cx)).await {
            if self.channels.responses_tx.send(response).await.is_err() {
                return;
            }
        }
    }

    /// Resolves to `None` once the event loop is gone.
    fn poll_next_response(&mut self, cx: &mut Context<'_>) -> Poll<Option<dns::RecursiveResponse>> {
        while let Poll::Ready(control) = self.channels.control_rx.poll_recv(cx) {
            let Some(control) = control else {
                return Poll::Ready(None);
            };

            self.handle_control(control);
        }

        while let Poll::Ready(query) = self.channels.queries_rx.poll_recv(cx) {
            let Some(query) = query else {
                return Poll::Ready(None);
            };

            self.send_query(query);
        }

        if self.reval_nameserver_interval.poll_tick(cx).is_ready() {
            self.nameservers.evaluate();
        }

        // We purposely don't want to wait for this because we can resolve queries while this is running.
        let _ = self.nameservers.poll(cx);

        self.poll_doh_bootstrap(cx);

        while let Poll::Ready((result, mut meta)) = self.queries.poll_unpin(cx) {
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
                let client = self.doh_client(server.clone());

                meta.retried = true;
                self.queue(doh::send(client, server, meta.query.clone()), meta);

                continue;
            }

            return Poll::Ready(Some(dns::RecursiveResponse {
                server: meta.server,
                query: meta.query,
                message,
                transport: meta.transport,
                local: meta.local,
                remote: meta.remote,
                started_at: meta.started_at,
                recursion: dns::Recursion::Local,
            }));
        }

        Poll::Pending
    }

    fn handle_control(&mut self, control: ResolverControl) {
        match control {
            ResolverControl::SystemResolvers(resolvers) => {
                tracing::debug!(servers = ?resolvers, "Re-configuring bootstrap DNS client with new upstreams");

                self.bootstrap_dns_client = BootstrapDnsClient::new(
                    self.udp_socket_factory.clone(),
                    self.tcp_socket_factory.clone(),
                    resolvers,
                );
            }
            ResolverControl::Upstreams(upstreams) => {
                for upstream in upstreams {
                    let dns::Upstream::DoH { server } = upstream else {
                        continue;
                    };

                    self.doh_client_entry(server);
                }
            }
            ResolverControl::Reset => {
                self.queries = new_query_set();
                self.doh_clients_bootstrap = new_bootstrap_set();
                self.nameservers.evaluate();

                for (server, _) in std::mem::take(&mut self.doh_clients) {
                    self.doh_client_entry(server);
                }
            }
        }
    }

    fn send_query(&mut self, query: ResolverQuery) {
        let server = query.server.or_else(|| {
            let nameserver = self.nameservers.fastest()?;

            Some(dns::Upstream::Do53 {
                server: SocketAddr::new(nameserver, dns::DNS_PORT),
            })
        });
        let meta = QueryMetaData {
            query: query.message.clone(),
            server: server.clone().unwrap_or(NO_NAMESERVER),
            local: query.local,
            remote: query.remote,
            transport: query.transport,
            started_at: query.started_at,
            retried: false,
        };

        match (query.transport, server) {
            (_, None) => {
                tracing::warn!(query = ?query.message, "No nameserver available to handle DNS query");

                self.queue(
                    futures::future::ready(Err(anyhow::anyhow!("No nameserver available"))),
                    meta,
                );
            }
            (dns::Transport::Udp, Some(dns::Upstream::Do53 { server })) => {
                self.queue(
                    udp_dns::send(self.udp_socket_factory.clone(), server, query.message),
                    meta,
                );
            }
            (dns::Transport::Tcp, Some(dns::Upstream::Do53 { server })) => {
                self.queue(
                    tcp_dns::send(self.tcp_socket_factory.clone(), server, query.message),
                    meta,
                );
            }
            (_, Some(dns::Upstream::DoH { server })) => {
                let client = self.doh_client(server.clone());

                self.queue(doh::send(client, server, query.message), meta);
            }
        }
    }

    fn poll_doh_bootstrap(&mut self, cx: &mut Context<'_>) {
        while let Poll::Ready((url, result)) = self.doh_clients_bootstrap.poll_unpin(cx) {
            match result.map_err(anyhow::Error::new).flatten() {
                Ok(client) => {
                    self.doh_clients.insert(url, DohClient::Connected(client));
                }
                Err(e) => {
                    tracing::debug!(%url, "Failed to bootstrap DoH client: {e:#}");

                    self.doh_clients.remove(&url);
                }
            }
        }
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

    fn queue(
        &mut self,
        future: impl Future<Output = Result<dns_types::Response>> + Send + 'static,
        meta: QueryMetaData,
    ) {
        if self.queries.try_push(future, meta.clone()).is_err() {
            tracing::debug!(?meta, "Failed to queue DNS query")
        }
    }
}

fn new_query_set() -> FuturesTupleSet<Result<dns_types::Response>, QueryMetaData> {
    FuturesTupleSet::new(|| futures_bounded::Delay::tokio(DNS_QUERY_TIMEOUT), 1000)
}

fn new_bootstrap_set() -> FuturesMap<DoHUrl, Result<HttpClient>> {
    FuturesMap::new(|| futures_bounded::Delay::tokio(DNS_QUERY_TIMEOUT), 10)
}

#[cfg(test)]
mod tests;

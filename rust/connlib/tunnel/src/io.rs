use crate::{device_channel::Device, dns::DnsQuery, sockets::Sockets};
use connlib_shared::messages::DnsServer;
use futures::Future;
use futures_bounded::FuturesTupleSet;
use futures_util::FutureExt as _;
use hickory_proto::iocompat::AsyncIoTokioAsStd;
use hickory_proto::TokioTime;
use hickory_resolver::{
    config::{NameServerConfig, Protocol, ResolverConfig, ResolverOpts},
    name_server::{GenericConnector, RuntimeProvider},
    AsyncResolver, TokioHandle,
};
use ip_packet::{IpPacket, MutableIpPacket};
use socket_factory::{DatagramIn, DatagramOut, SocketFactory, TcpSocket, UdpSocket};
use std::{
    collections::HashMap,
    io,
    net::{IpAddr, SocketAddr},
    pin::Pin,
    sync::Arc,
    task::{ready, Context, Poll},
    time::{Duration, Instant},
};

const DNS_QUERIES_QUEUE_SIZE: usize = 100;

/// Bundles together all side-effects that connlib needs to have access to.
pub struct Io {
    /// The TUN device offered to the user.
    ///
    /// This is the `tun-firezone` network interface that users see when they e.g. type `ip addr` on Linux.
    device: Device,
    /// The UDP sockets used to send & receive packets from the network.
    sockets: Sockets,

    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,

    timeout: Option<Pin<Box<tokio::time::Sleep>>>,

    upstream_dns_servers: HashMap<IpAddr, AsyncResolver<GenericConnector<TokioRuntimeProvider>>>,
    forwarded_dns_queries: FuturesTupleSet<
        Result<hickory_resolver::lookup::Lookup, hickory_resolver::error::ResolveError>,
        DnsQuery<'static>,
    >,
}

pub enum Input<'a, I> {
    Timeout(Instant),
    Device(MutableIpPacket<'a>),
    Network(I),
    DnsResponse(
        DnsQuery<'static>,
        Result<
            Result<hickory_resolver::lookup::Lookup, hickory_resolver::error::ResolveError>,
            futures_bounded::Timeout,
        >,
    ),
}

impl Io {
    /// Creates a new I/O abstraction
    ///
    /// Must be called within a Tokio runtime context so we can bind the sockets.
    pub fn new(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    ) -> io::Result<Self> {
        let mut sockets = Sockets::default();
        sockets.rebind(udp_socket_factory.as_ref())?; // Bind sockets on startup. Must happen within a tokio runtime context.

        Ok(Self {
            device: Device::new(),
            timeout: None,
            sockets,
            tcp_socket_factory,
            udp_socket_factory,
            upstream_dns_servers: HashMap::default(),
            forwarded_dns_queries: FuturesTupleSet::new(
                Duration::from_secs(60),
                DNS_QUERIES_QUEUE_SIZE,
            ),
        })
    }

    pub fn poll<'b>(
        &mut self,
        cx: &mut Context<'_>,
        ip4_buffer: &'b mut [u8],
        ip6_bffer: &'b mut [u8],
        device_buffer: &'b mut [u8],
    ) -> Poll<io::Result<Input<'b, impl Iterator<Item = DatagramIn<'b>>>>> {
        if let Poll::Ready((response, query)) = self.forwarded_dns_queries.poll_unpin(cx) {
            return Poll::Ready(Ok(Input::DnsResponse(query, response)));
        }

        if let Some(timeout) = self.timeout.as_mut() {
            if timeout.poll_unpin(cx).is_ready() {
                return Poll::Ready(Ok(Input::Timeout(timeout.deadline().into())));
            }
        }

        if let Poll::Ready(network) = self.sockets.poll_recv_from(ip4_buffer, ip6_bffer, cx)? {
            return Poll::Ready(Ok(Input::Network(network)));
        }

        ready!(self.sockets.poll_flush(cx))?;

        if let Poll::Ready(packet) = self.device.poll_read(device_buffer, cx)? {
            return Poll::Ready(Ok(Input::Device(packet)));
        }

        Poll::Pending
    }

    pub fn device_mut(&mut self) -> &mut Device {
        &mut self.device
    }

    pub fn rebind_sockets(&mut self) -> io::Result<()> {
        self.sockets.rebind(self.udp_socket_factory.as_ref())?;

        Ok(())
    }

    pub fn set_upstream_dns_servers(
        &mut self,
        dns_servers: impl IntoIterator<Item = (IpAddr, DnsServer)>,
    ) {
        tracing::info!("Setting new DNS resolvers");

        self.forwarded_dns_queries =
            FuturesTupleSet::new(Duration::from_secs(60), DNS_QUERIES_QUEUE_SIZE);
        self.upstream_dns_servers = create_resolvers(
            dns_servers,
            TokioRuntimeProvider::new(
                self.tcp_socket_factory.clone(),
                self.udp_socket_factory.clone(),
            ),
        );
    }

    pub fn perform_dns_query(&mut self, query: DnsQuery<'static>) -> Result<(), DnsQueryError> {
        let upstream = query.query.destination();
        let resolver = self
            .upstream_dns_servers
            .get(&upstream)
            .cloned()
            .expect("Only DNS queries to known upstream servers should be forwarded to `Io`");

        if self
            .forwarded_dns_queries
            .try_push(
                {
                    let name = query.name.clone().to_string();
                    let record_type = query.record_type;

                    async move { resolver.lookup(&name, record_type).await }
                },
                query,
            )
            .is_err()
        {
            return Err(DnsQueryError::TooManyQueries);
        }

        Ok(())
    }

    pub fn reset_timeout(&mut self, timeout: Instant) {
        let timeout = tokio::time::Instant::from_std(timeout);

        match self.timeout.as_mut() {
            Some(existing_timeout) if existing_timeout.deadline() != timeout => {
                existing_timeout.as_mut().reset(timeout)
            }
            Some(_) => {}
            None => self.timeout = Some(Box::pin(tokio::time::sleep_until(timeout))),
        }
    }

    pub fn send_network(&mut self, transmit: snownet::Transmit) -> io::Result<()> {
        self.sockets.send(DatagramOut {
            src: transmit.src,
            dst: transmit.dst,
            packet: transmit.payload,
        })?;

        Ok(())
    }

    pub fn send_device(&self, packet: IpPacket<'_>) -> io::Result<()> {
        self.device.write(packet)?;

        Ok(())
    }
}

#[derive(Debug, thiserror::Error)]
pub enum DnsQueryError {
    #[error("Too many ongoing DNS queries")]
    TooManyQueries,
}

/// Identical to [`TokioRuntimeProvider`](hickory_resolver::name_server::TokioRuntimeProvider) but using our own [`SocketFactory`].
#[derive(Clone)]
struct TokioRuntimeProvider {
    handle: TokioHandle,
    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
}

impl TokioRuntimeProvider {
    fn new(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    ) -> TokioRuntimeProvider {
        Self {
            handle: Default::default(),
            tcp_socket_factory,
            udp_socket_factory,
        }
    }
}

impl RuntimeProvider for TokioRuntimeProvider {
    type Handle = TokioHandle;
    type Timer = TokioTime;
    type Udp = UdpSocket;
    type Tcp = AsyncIoTokioAsStd<tokio::net::TcpStream>;

    fn create_handle(&self) -> Self::Handle {
        self.handle.clone()
    }

    fn connect_tcp(
        &self,
        server_addr: SocketAddr,
    ) -> Pin<Box<dyn Send + Future<Output = io::Result<Self::Tcp>>>> {
        let socket = (self.tcp_socket_factory)(&server_addr);
        Box::pin(async move {
            let socket = socket?;
            let stream = socket.connect(server_addr).await?;

            Ok(AsyncIoTokioAsStd(stream))
        })
    }

    fn bind_udp(
        &self,
        local_addr: SocketAddr,
        _server_addr: SocketAddr,
    ) -> Pin<Box<dyn Send + Future<Output = io::Result<Self::Udp>>>> {
        let socket = (self.udp_socket_factory)(&local_addr);

        Box::pin(async move { socket })
    }
}

fn create_resolvers(
    dns_servers: impl IntoIterator<Item = (IpAddr, DnsServer)>,
    runtime_provider: TokioRuntimeProvider,
) -> HashMap<IpAddr, AsyncResolver<GenericConnector<TokioRuntimeProvider>>> {
    dns_servers
        .into_iter()
        .map(|(sentinel, srv)| {
            let mut resolver_config = ResolverConfig::new();
            resolver_config.add_name_server(NameServerConfig::new(srv.address(), Protocol::Udp));
            resolver_config.add_name_server(NameServerConfig::new(srv.address(), Protocol::Tcp));

            let mut resolver_opts = ResolverOpts::default();
            resolver_opts.edns0 = true;
            resolver_opts.recursion_desired = false;

            (
                sentinel,
                AsyncResolver::new_with_conn(
                    resolver_config,
                    resolver_opts,
                    GenericConnector::new(runtime_provider.clone()),
                ),
            )
        })
        .collect()
}

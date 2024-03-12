use crate::{
    device_channel::Device,
    dns::{self, DnsQuery},
    ip_packet::{IpPacket, MutableIpPacket},
    sockets::{Received, Sockets},
};
use connlib_shared::messages::DnsServer;
use futures_bounded::FuturesTupleSet;
use futures_util::FutureExt as _;
use hickory_resolver::{
    config::{NameServerConfig, Protocol, ResolverConfig},
    TokioAsyncResolver,
};
use snownet::Transmit;
use std::{
    collections::HashMap,
    io,
    net::IpAddr,
    pin::Pin,
    task::{ready, Context, Poll},
    time::{Duration, Instant},
};

const DNS_QUERIES_QUEUE_SIZE: usize = 100;

pub struct Io {
    device: Device,
    timeout: Option<Pin<Box<tokio::time::Sleep>>>,
    sockets: Sockets,

    upstream_dns_servers: HashMap<IpAddr, TokioAsyncResolver>,
    forwarded_dns_queries: FuturesTupleSet<
        Result<hickory_resolver::lookup::Lookup, hickory_resolver::error::ResolveError>,
        DnsQuery<'static>,
    >,
}

pub enum Input<'a, I> {
    Timeout(Instant),
    Device(MutableIpPacket<'a>),
    Network(I),
}

impl Io {
    pub fn new() -> io::Result<Self> {
        Ok(Self {
            device: Device::new(),
            timeout: None,
            sockets: Sockets::new()?,
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
        buffer: &'b mut [u8],
    ) -> Poll<io::Result<Input<'b, impl Iterator<Item = Received<'b>>>>> {
        loop {
            // FIXME: Building the DNS response in here isn't very clean because this should only be the IO component and not do business-logic.
            // But it also seems weird to pass the DNS result out if we've got the device right here.
            match self.forwarded_dns_queries.poll_unpin(cx) {
                Poll::Ready((Ok(response), query)) => {
                    match dns::build_response_from_resolve_result(query.query, response) {
                        Ok(Some(packet)) => {
                            self.device.write(packet)?;
                        }
                        Ok(None) => continue,
                        Err(e) => {
                            tracing::warn!("Failed to build DNS response from lookup result: {e}");
                            continue;
                        }
                    }
                }
                Poll::Ready((Err(resolve_timeout), query)) => {
                    tracing::warn!(name = %query.name, server = %query.query.destination(), "DNS query timed out: {resolve_timeout}");
                    continue;
                }
                Poll::Pending => {}
            }

            let (buf1, buf2) = buffer.split_at_mut(buffer.len() / 2); // If rustc borrow-checker would be better, we wouldn't need this.

            if let Some(timeout) = self.timeout.as_mut() {
                if timeout.poll_unpin(cx).is_ready() {
                    return Poll::Ready(Ok(Input::Timeout(timeout.deadline().into())));
                }
            }

            if let Poll::Ready(network) = self.sockets.poll_recv_from(buf1, cx)? {
                return Poll::Ready(Ok(Input::Network(network)));
            }

            ready!(self.sockets.poll_send_ready(cx))?; // Packets read from the device need to be written to a socket, let's make sure the socket can take more packets.

            if let Poll::Ready(packet) = self.device.poll_read(buf2, cx)? {
                return Poll::Ready(Ok(Input::Device(packet)));
            }

            return Poll::Pending;
        }
    }

    pub fn device_mut(&mut self) -> &mut Device {
        &mut self.device
    }

    pub fn sockets_ref(&self) -> &Sockets {
        &self.sockets
    }

    pub fn set_upstream_dns_servers(
        &mut self,
        dns_servers: impl IntoIterator<Item = (IpAddr, DnsServer)>,
    ) {
        self.upstream_dns_servers = create_resolvers(dns_servers);
    }

    pub fn perform_dns_query(&mut self, query: DnsQuery<'static>) {
        let upstream = query.query.destination();
        let Some(resolver) = self.upstream_dns_servers.get(&upstream).cloned() else {
            tracing::warn!(%upstream, "Dropping DNS query because of unknown upstream DNS server");
            return;
        };

        let query = query.into_owned();

        if self
            .forwarded_dns_queries
            .try_push(
                {
                    let name = query.name.clone();
                    let record_type = query.record_type;

                    async move { resolver.lookup(&name, record_type).await }
                },
                query,
            )
            .is_err()
        {
            tracing::warn!("Too many DNS queries, dropping existing one");
        }
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

    pub fn send_network(&self, transmit: Transmit) -> io::Result<()> {
        self.sockets.try_send(&transmit)?;

        Ok(())
    }

    pub fn send_device(&self, packet: IpPacket<'_>) -> io::Result<()> {
        self.device.write(packet)?;

        Ok(())
    }
}

fn create_resolvers(
    dns_servers: impl IntoIterator<Item = (IpAddr, DnsServer)>,
) -> HashMap<IpAddr, TokioAsyncResolver> {
    dns_servers
        .into_iter()
        .map(|(sentinel, srv)| {
            let mut resolver_config = ResolverConfig::new();
            resolver_config.add_name_server(NameServerConfig::new(srv.address(), Protocol::Udp));
            (
                sentinel,
                TokioAsyncResolver::tokio(resolver_config, Default::default()),
            )
        })
        .collect()
}

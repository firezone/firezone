use std::{
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    time::{Duration, Instant},
};

use anyhow::Result;
use ip_packet::IpPacket;

pub(crate) struct TcpDnsClient {
    inner: Option<dns_over_tcp::Client>,
    source_interface: Option<(Ipv4Addr, Ipv6Addr)>,
}

impl TcpDnsClient {
    pub(crate) fn new(now: Instant) -> Self {
        Self {
            inner: Some(Self::new_inner(now)),
            source_interface: None,
        }
    }

    pub(crate) fn reset(&mut self) {
        self.inner = None;
    }

    pub(crate) fn reset_and_clear_source_interface(&mut self) {
        self.inner = None;
        self.source_interface = None;
    }

    pub(crate) fn set_source_interface(&mut self, ipv4: Ipv4Addr, ipv6: Ipv6Addr, now: Instant) {
        self.source_interface = Some((ipv4, ipv6));
        self.ensure_inner(now).set_source_interface(ipv4, ipv6);
    }

    pub(crate) fn send_query(
        &mut self,
        server: SocketAddr,
        query: dns_types::Query,
        now: Instant,
    ) -> Result<SocketAddr> {
        let local = self.ensure_inner(now).send_query(server, query)?;

        Ok(local)
    }

    pub(crate) fn accepts(&self, packet: &IpPacket) -> bool {
        self.inner
            .as_ref()
            .is_some_and(|client| client.accepts(packet))
    }

    pub(crate) fn handle_inbound(&mut self, packet: IpPacket) {
        self.inner
            .as_mut()
            .expect("TCP DNS client should be active when it accepts a packet")
            .handle_inbound(packet);
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        if let Some(client) = self.inner.as_mut() {
            client.handle_timeout(now);
        }
    }

    pub(crate) fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.inner
            .as_mut()
            .and_then(dns_over_tcp::Client::poll_outbound)
    }

    pub(crate) fn poll_timeout(&mut self) -> Option<Instant> {
        self.inner
            .as_mut()
            .and_then(dns_over_tcp::Client::poll_timeout)
    }

    pub(crate) fn poll_query_result(&mut self) -> Option<dns_over_tcp::QueryResult> {
        self.inner
            .as_mut()
            .and_then(dns_over_tcp::Client::poll_query_result)
    }

    fn ensure_inner(&mut self, now: Instant) -> &mut dns_over_tcp::Client {
        if self.inner.is_none() {
            let mut client = Self::new_inner(now);

            if let Some((ipv4, ipv6)) = self.source_interface {
                client.set_source_interface(ipv4, ipv6);
            }

            self.inner = Some(client);
        }

        self.inner
            .as_mut()
            .expect("TCP DNS client should be active after initialization")
    }

    fn new_inner(now: Instant) -> dns_over_tcp::Client {
        dns_over_tcp::Client::new(now, Duration::from_secs(15), [0u8; 32])
    }
}

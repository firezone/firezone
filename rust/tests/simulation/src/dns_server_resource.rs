use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    iter,
    net::SocketAddr,
    time::Instant,
};

use dns_types::ResponseCode;
use dns_types::prelude::*;
use ip_packet::{IpPacket, MAX_UDP_PAYLOAD, UdpSlice};

use super::dns_records::DnsRecords;

/// The UDP and TCP DNS servers listening on a set of sockets.
#[derive(Default)]
pub(crate) struct DnsServers {
    udp: BTreeMap<SocketAddr, UdpDnsServerResource>,
    tcp: BTreeMap<SocketAddr, TcpDnsServerResource>,
}

impl DnsServers {
    pub(crate) fn deploy(&mut self, socket: SocketAddr) {
        self.udp.insert(socket, UdpDnsServerResource::default());
        self.tcp.insert(socket, TcpDnsServerResource::new(socket));
    }

    pub(crate) fn clear(&mut self) {
        self.udp.clear();
        self.tcp.clear();
    }

    /// Returns the UDP server that `packet` is a query to.
    pub(crate) fn udp_server_for(
        &mut self,
        packet: &IpPacket,
    ) -> Option<&mut UdpDnsServerResource> {
        let udp = packet.as_udp()?;
        if !is_dns_query(&udp) {
            return None;
        }

        self.udp.get_mut(&SocketAddr::new(
            packet.destination(),
            udp.destination_port(),
        ))
    }

    /// Returns the TCP server that `packet` is addressed to.
    pub(crate) fn tcp_server_for(
        &mut self,
        packet: &IpPacket,
    ) -> Option<&mut TcpDnsServerResource> {
        let tcp = packet.as_tcp()?;

        self.tcp.get_mut(&SocketAddr::new(
            packet.destination(),
            tcp.destination_port(),
        ))
    }

    /// Answers the queries received so far.
    pub(crate) fn poll_answers(&mut self, records: &DnsRecords, now: Instant) -> Vec<IpPacket> {
        let udp = self.udp.values_mut().flat_map(|server| {
            server.handle_timeout(records);

            iter::from_fn(|| server.poll_outbound())
        });
        let tcp = self.tcp.values_mut().flat_map(|server| {
            server.handle_timeout(records, now);

            iter::from_fn(|| server.poll_outbound())
        });

        udp.chain(tcp).collect()
    }
}

/// Tells a DNS query from a probe.
///
/// Synthetic UDP probes contain only their eight-byte probe ID. DNS queries have a longer
/// wire header, so probes still exercise normal packet routing when they happen to target a
/// DNS server port.
pub(crate) fn is_dns_query(udp: &UdpSlice) -> bool {
    udp.payload().len() != size_of::<u64>()
}

pub struct TcpDnsServerResource {
    socket: SocketAddr,
    server: Option<dns_over_tcp::Server>,
}

#[derive(Debug, Default)]
pub struct UdpDnsServerResource {
    inbound_packets: VecDeque<IpPacket>,
    outbound_packets: VecDeque<IpPacket>,
}

impl TcpDnsServerResource {
    pub fn new(socket: SocketAddr) -> Self {
        Self {
            socket,
            server: None,
        }
    }

    pub fn handle_input(&mut self, packet: IpPacket, now: Instant) {
        let server = self.server.get_or_insert_with(|| {
            let mut server = dns_over_tcp::Server::new(now);
            // Each simulated client maintains at most one connection to a DNS
            // server, and the generated topology contains exactly two clients.
            server.set_listen_addresses::<2>(BTreeSet::from([self.socket]));
            server
        });

        server.handle_inbound(packet);
    }

    pub fn handle_timeout(&mut self, global_dns_records: &DnsRecords, now: Instant) {
        let Some(server) = self.server.as_mut() else {
            return;
        };

        server.handle_timeout(now);
        while let Some(query) = server.poll_queries() {
            let response = handle_dns_query(&query.message, global_dns_records);

            server
                .send_message(query.local, query.remote, response)
                .unwrap();
        }
    }

    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.server
            .as_mut()
            .and_then(dns_over_tcp::Server::poll_outbound)
    }
}

impl UdpDnsServerResource {
    pub fn handle_input(&mut self, packet: IpPacket) {
        self.inbound_packets.push_back(packet);
    }

    pub fn handle_timeout(&mut self, global_dns_records: &DnsRecords) {
        while let Some(packet) = self.inbound_packets.pop_front() {
            let udp = packet.as_udp().unwrap();
            let query = dns_types::Query::parse(udp.payload()).unwrap();

            let response = handle_dns_query(&query, global_dns_records);
            let response_bytes = response.into_bytes(MAX_UDP_PAYLOAD);

            self.outbound_packets.push_back(
                ip_packet::make::udp_packet(
                    packet.destination(),
                    packet.source(),
                    udp.destination_port(),
                    udp.source_port(),
                    &response_bytes,
                )
                .expect("src and dst are retrieved from the same packet"),
            )
        }
    }

    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.outbound_packets.pop_front()
    }
}

fn handle_dns_query(
    query: &dns_types::Query,
    global_dns_records: &DnsRecords,
) -> dns_types::Response {
    const TTL: u32 = 1; // We deliberately chose a short TTL so we don't have to model the DNS cache in these tests.

    let domain = query.domain().to_vec();

    let records = global_dns_records
        .domain_records_iter(&domain)
        .filter(|r| r.rtype() == query.qtype())
        .map(|rdata| (domain.clone(), TTL, rdata));

    dns_types::ResponseBuilder::for_query(query, ResponseCode::NOERROR)
        .with_records(records)
        .build()
}

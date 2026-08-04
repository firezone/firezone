use std::{
    collections::{BTreeSet, VecDeque},
    net::SocketAddr,
    time::Instant,
};

use dns_types::ResponseCode;
use dns_types::prelude::*;
use ip_packet::{IpPacket, MAX_UDP_PAYLOAD};

use super::dns_records::DnsRecords;
use super::endpoint::Endpoint;

pub struct TcpDnsServerResource {
    socket: SocketAddr,
    server: Endpoint<dns_over_tcp::Server>,
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
            server: Endpoint::Inactive,
        }
    }

    pub fn handle_input(&mut self, packet: IpPacket, now: Instant) {
        if self.server.is_retired() {
            let is_syn = packet.as_tcp().is_some_and(|tcp| tcp.syn() && !tcp.ack());
            if !is_syn {
                tracing::debug!(?packet, "Ignoring packet for retired TCP DNS server");
                return;
            }

            self.server = Endpoint::Inactive;
        }

        if self.server.active().is_none() {
            let mut server = dns_over_tcp::Server::new(now);
            // Each simulated client maintains at most one connection to a DNS
            // server, and the generated topology contains exactly two clients.
            server.set_listen_addresses::<2>(BTreeSet::from([self.socket]));
            self.server.activate(server);
        }

        self.server
            .active_mut()
            .expect("TCP DNS server should be active after initialization")
            .handle_inbound(packet);
    }

    pub fn handle_timeout(&mut self, global_dns_records: &DnsRecords, now: Instant) {
        let Some(server) = self.server.active_mut() else {
            return;
        };

        server.handle_timeout(now);
        while let Some(query) = server.poll_queries() {
            let response = handle_dns_query(&query.message, global_dns_records, now);

            server
                .send_message(query.local, query.remote, response)
                .unwrap();
        }
    }

    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.server
            .active_mut()
            .and_then(dns_over_tcp::Server::poll_outbound)
    }

    pub(crate) fn retire(&mut self) {
        self.server.retire();
    }
}

impl UdpDnsServerResource {
    pub(crate) fn clear(&mut self) {
        self.inbound_packets.clear();
        self.outbound_packets.clear();
    }

    pub fn handle_input(&mut self, packet: IpPacket) {
        self.inbound_packets.push_back(packet);
    }

    pub fn handle_timeout(&mut self, global_dns_records: &DnsRecords, now: Instant) {
        while let Some(packet) = self.inbound_packets.pop_front() {
            let udp = packet.as_udp().unwrap();
            let query = dns_types::Query::parse(udp.payload()).unwrap();

            let response = handle_dns_query(&query, global_dns_records, now);
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
    at: Instant,
) -> dns_types::Response {
    const TTL: u32 = 1; // We deliberately chose a short TTL so we don't have to model the DNS cache in these tests.

    let domain = query.domain().to_vec();

    let records = global_dns_records
        .domain_records_iter(&domain, at)
        .filter(|r| r.rtype() == query.qtype())
        .map(|rdata| (domain.clone(), TTL, rdata));

    dns_types::ResponseBuilder::for_query(query, ResponseCode::NOERROR)
        .with_records(records)
        .build()
}

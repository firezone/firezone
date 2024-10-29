use std::{
    collections::{BTreeSet, VecDeque},
    net::SocketAddr,
    time::Instant,
};

use domain::base::{
    iana::{Class, Rcode},
    Message, MessageBuilder, Record, RecordData, ToName, Ttl,
};
use ip_packet::IpPacket;

use crate::client::truncate_dns_response;

use super::dns_records::DnsRecords;

pub struct TcpDnsServerResource {
    server: dns_over_tcp::Server,
}

#[derive(Debug, Default)]
pub struct UdpDnsServerResource {
    inbound_packets: VecDeque<IpPacket>,
    outbound_packets: VecDeque<IpPacket>,
}

impl TcpDnsServerResource {
    pub fn new(socket: SocketAddr, now: Instant) -> Self {
        let mut server = dns_over_tcp::Server::new(now);
        server.set_listen_addresses::<5>(BTreeSet::from([socket]));

        Self { server }
    }

    pub fn handle_input(&mut self, packet: IpPacket) {
        self.server.handle_inbound(packet);
    }

    pub fn handle_timeout(&mut self, global_dns_records: &DnsRecords, now: Instant) {
        self.server.handle_timeout(now);
        while let Some(query) = self.server.poll_queries() {
            let response = handle_dns_query(query.message.for_slice(), global_dns_records);

            self.server.send_message(query.socket, response).unwrap();
        }
    }

    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.server.poll_outbound()
    }
}

impl UdpDnsServerResource {
    pub fn handle_input(&mut self, packet: IpPacket) {
        self.inbound_packets.push_back(packet);
    }

    pub fn handle_timeout(&mut self, global_dns_records: &DnsRecords, _: Instant) {
        while let Some(packet) = self.inbound_packets.pop_front() {
            let udp = packet.as_udp().unwrap();
            let query = Message::from_octets(udp.payload().to_vec()).unwrap();

            let response = handle_dns_query(query.for_slice(), global_dns_records);

            self.outbound_packets.push_back(
                ip_packet::make::udp_packet(
                    packet.destination(),
                    packet.source(),
                    udp.destination_port(),
                    udp.source_port(),
                    truncate_dns_response(&response),
                )
                .expect("src and dst are retrieved from the same packet"),
            )
        }
    }

    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.outbound_packets.pop_front()
    }
}

fn handle_dns_query(query: &Message<[u8]>, global_dns_records: &DnsRecords) -> Message<Vec<u8>> {
    let response = MessageBuilder::new_vec();
    let mut answers = response.start_answer(query, Rcode::NOERROR).unwrap();

    for query in query.question() {
        let query = query.unwrap();
        let name = query.qname().to_name::<Vec<u8>>();

        let records = global_dns_records
            .domain_records_iter(&name)
            .filter(|r| r.rtype() == query.qtype())
            .map(|rdata| Record::new(name.clone(), Class::IN, Ttl::from_days(1), rdata));

        for record in records {
            answers.push(record).unwrap();
        }
    }

    answers.into_message()
}

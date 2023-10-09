use std::{net::IpAddr, sync::Arc};

use crate::{
    ip_packet::{to_dns, IpPacket, MutableIpPacket, Version},
    ControlSignal, Tunnel,
};
use connlib_shared::{messages::ResourceDescription, Callbacks, DNS_SENTINEL};
use domain::base::{
    iana::{Class, Rcode, Rtype},
    Dname, Message, MessageBuilder, ParsedDname, ToDname,
};
use pnet_packet::{udp::MutableUdpPacket, MutablePacket, Packet as UdpPacket, PacketSize};

const DNS_TTL: u32 = 300;
const UDP_HEADER_SIZE: usize = 8;
const REVERSE_DNS_ADDRESS_END: &str = "arpa";
const REVERSE_DNS_ADDRESS_V4: &str = "in-addr";
const REVERSE_DNS_ADDRESS_V6: &str = "ip6";

#[derive(Debug, Clone)]
pub(crate) enum SendPacket {
    Ipv4(Vec<u8>),
    Ipv6(Vec<u8>),
}

// We don't need to support multiple questions/qname in a single query because
// nobody does it and since this run with each packet we want to squeeze as much optimization
// as we can therefore we won't do it.
//
// See: https://stackoverflow.com/a/55093896
impl<C, CB, TIceState> Tunnel<C, CB, TIceState>
where
    C: ControlSignal + Send + Sync + 'static,
    CB: Callbacks + 'static,
{
    fn build_response(
        self: &Arc<Self>,
        original_buf: &[u8],
        mut dns_answer: Vec<u8>,
    ) -> Option<Vec<u8>> {
        let response_len = dns_answer.len();
        let original_pkt = IpPacket::new(original_buf)?;
        let original_dgm = original_pkt.as_udp()?;
        let hdr_len = original_pkt.packet_size() - original_dgm.payload().len();
        let mut res_buf = Vec::with_capacity(hdr_len + response_len);

        res_buf.extend_from_slice(&original_buf[..hdr_len]);
        res_buf.append(&mut dns_answer);

        let mut pkt = MutableIpPacket::new(&mut res_buf)?;
        let dgm_len = UDP_HEADER_SIZE + response_len;
        pkt.set_len(hdr_len + response_len, dgm_len);
        pkt.swap_src_dst();

        let mut dgm = MutableUdpPacket::new(pkt.payload_mut())?;
        dgm.set_length(dgm_len as u16);
        dgm.set_source(original_dgm.get_destination());
        dgm.set_destination(original_dgm.get_source());

        let mut pkt = MutableIpPacket::new(&mut res_buf)?;
        let udp_checksum = pkt.to_immutable().udp_checksum(&pkt.as_immutable_udp()?);
        pkt.as_udp()?.set_checksum(udp_checksum);
        pkt.set_ipv4_checksum();
        Some(res_buf)
    }

    fn build_dns_with_answer<N>(
        self: &Arc<Self>,
        message: &Message<[u8]>,
        qname: &N,
        qtype: Rtype,
        resource: &ResourceDescription,
    ) -> Option<Vec<u8>>
    where
        N: ToDname + ?Sized,
    {
        let msg_buf = Vec::with_capacity(message.as_slice().len() * 2);
        let msg_builder = MessageBuilder::from_target(msg_buf).expect(
            "Developer error: we should be always be able to create a MessageBuilder from a Vec",
        );
        let mut answer_builder = msg_builder.start_answer(message, Rcode::NoError).ok()?;
        match qtype {
            Rtype::A => answer_builder
                .push((
                    qname,
                    Class::In,
                    DNS_TTL,
                    domain::rdata::A::from(resource.ipv4()?),
                ))
                .ok()?,
            Rtype::Aaaa => answer_builder
                .push((
                    qname,
                    Class::In,
                    DNS_TTL,
                    domain::rdata::Aaaa::from(resource.ipv6()?),
                ))
                .ok()?,
            Rtype::Ptr => answer_builder
                .push((
                    qname,
                    Class::In,
                    DNS_TTL,
                    domain::rdata::Ptr::<ParsedDname<_>>::new(
                        resource.dns_name()?.parse::<Dname<Vec<u8>>>().ok()?.into(),
                    ),
                ))
                .ok()?,
            _ => return None,
        }
        Some(answer_builder.finish())
    }

    pub(crate) fn check_for_dns(self: &Arc<Self>, buf: &[u8]) -> Option<SendPacket> {
        let packet = IpPacket::new(buf)?;
        let version = packet.version();
        if packet.destination() != IpAddr::from(DNS_SENTINEL) {
            return None;
        }
        let datagram = packet.as_udp()?;
        let message = to_dns(&datagram)?;
        if message.header().qr() {
            return None;
        }
        let question = message.first_question()?;
        let resource = match question.qtype() {
            Rtype::A | Rtype::Aaaa => self
                .resources
                .read()
                .get_by_name(&ToDname::to_cow(question.qname()).to_string())
                .cloned(),
            Rtype::Ptr => {
                let dns_parts = ToDname::to_cow(question.qname()).to_string();
                let mut dns_parts = dns_parts.split('.').rev();
                if !dns_parts
                    .next()
                    .is_some_and(|d| d == REVERSE_DNS_ADDRESS_END)
                {
                    return None;
                }
                let ip: IpAddr = match dns_parts.next() {
                    Some(REVERSE_DNS_ADDRESS_V4) => {
                        let mut ip = [0u8; 4];
                        for i in ip.iter_mut() {
                            *i = dns_parts.next()?.parse().ok()?;
                        }
                        ip.into()
                    }
                    Some(REVERSE_DNS_ADDRESS_V6) => {
                        let mut ip = [0u8; 16];
                        for i in ip.iter_mut() {
                            *i = u8::from_str_radix(
                                &format!("{}{}", dns_parts.next()?, dns_parts.next()?),
                                16,
                            )
                            .ok()?;
                        }
                        ip.into()
                    }
                    _ => return None,
                };

                if dns_parts.next().is_some() {
                    return None;
                }

                self.resources.read().get_by_ip(ip).cloned()
            }
            _ => return None,
        };
        let response =
            self.build_dns_with_answer(message, question.qname(), question.qtype(), &resource?)?;
        let response = self.build_response(buf, response);
        response.map(|pkt| match version {
            Version::Ipv4 => SendPacket::Ipv4(pkt),
            Version::Ipv6 => SendPacket::Ipv6(pkt),
        })
    }
}

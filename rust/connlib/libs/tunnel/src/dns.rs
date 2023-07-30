use std::{net::IpAddr, sync::Arc};

use crate::{
    ip_packet::{to_dns, IpPacket, MutableIpPacket},
    ControlSignal, Tunnel,
};
use domain::base::{
    iana::{Class, Rcode, Rtype},
    Message, MessageBuilder, ToDname,
};
use libs_common::{messages::ResourceDescription, Callbacks, DNS_SENTINEL};
use pnet_packet::{udp::MutableUdpPacket, MutablePacket, Packet as UdpPacket, PacketSize};

const DNS_TTL: u32 = 300;
const UDP_HEADER_SIZE: usize = 8;

// We don't need to support multiple questions/qname in a single query because
// nobody does it and since this run with each packet we want to squeeze as much optimization
// as we can therefore we won't do it.
//
// See: https://stackoverflow.com/a/55093896
impl<C, CB> Tunnel<C, CB>
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
        pkt.set_checksum();
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
            _ => todo!(),
        }
        Some(answer_builder.finish())
    }

    pub(crate) fn check_for_dns(self: &Arc<Self>, buf: &[u8]) -> Option<Vec<u8>> {
        let packet = IpPacket::new(buf)?;
        if packet.destination() != IpAddr::from(DNS_SENTINEL) {
            return None;
        }
        let datagram = packet.as_udp()?;
        let message = to_dns(&datagram)?;
        let question = message.first_question()?;
        if matches!(question.qtype(), Rtype::A | Rtype::Aaaa) && !message.header().qr() {
            if let Some(resource) = self
                .resources
                .read()
                .get_by_name(&ToDname::to_cow(question.qname()).to_string())
            {
                let response = self.build_dns_with_answer(
                    message,
                    question.qname(),
                    question.qtype(),
                    resource,
                )?;
                return self.build_response(buf, response);
            }
        }
        None
    }
}

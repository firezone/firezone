use crate::ip_packet::{to_dns, IpPacket, MutableIpPacket, Version};
use crate::resource_table::ResourceTable;
use crate::DnsQuery;
use connlib_shared::error::ConnlibError;
use connlib_shared::{messages::ResourceDescription, DNS_SENTINEL};
use domain::base::{
    iana::{Class, Rcode, Rtype},
    Dname, Message, MessageBuilder, ParsedDname, Question, ToDname,
};
use hickory_resolver::lookup::Lookup;
use hickory_resolver::proto::op::Message as TrustDnsMessage;
use hickory_resolver::proto::rr::RecordType;
use itertools::Itertools;
use pnet_packet::{udp::MutableUdpPacket, MutablePacket, Packet as UdpPacket, PacketSize};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

const DNS_TTL: u32 = 300;
const UDP_HEADER_SIZE: usize = 8;
const REVERSE_DNS_ADDRESS_END: &str = "arpa";
const REVERSE_DNS_ADDRESS_V4: &str = "in-addr";
const REVERSE_DNS_ADDRESS_V6: &str = "ip6";

#[derive(Debug, Clone)]
pub(crate) enum Packet {
    Ipv4(Vec<u8>),
    Ipv6(Vec<u8>),
}

#[derive(Debug)]
pub(crate) enum ResolveStrategy<T, U> {
    LocalResponse(T),
    ForwardQuery(U),
}

struct DnsQueryParams {
    name: String,
    record_type: RecordType,
}

impl DnsQueryParams {
    fn into_query(self, query: IpPacket) -> DnsQuery {
        DnsQuery {
            name: self.name,
            record_type: self.record_type,
            query,
        }
    }
}

impl<T> ResolveStrategy<T, DnsQueryParams> {
    fn new(name: String, record_type: Rtype) -> ResolveStrategy<T, DnsQueryParams> {
        ResolveStrategy::ForwardQuery(DnsQueryParams {
            name,
            record_type: u16::from(record_type).into(),
        })
    }
}

// We don't need to support multiple questions/qname in a single query because
// nobody does it and since this run with each packet we want to squeeze as much optimization
// as we can therefore we won't do it.
//
// See: https://stackoverflow.com/a/55093896
pub(crate) fn parse<'a>(
    resources: &ResourceTable<ResourceDescription>,
    packet: IpPacket<'a>,
) -> Option<ResolveStrategy<Packet, DnsQuery<'a>>> {
    if packet.destination() != IpAddr::from(DNS_SENTINEL) {
        return None;
    }
    let datagram = packet.as_udp()?;
    let message = to_dns(&datagram)?;
    if message.header().qr() {
        return None;
    }
    let question = message.first_question()?;
    let resource = match resource_from_question(resources, &question)? {
        ResolveStrategy::LocalResponse(resource) => resource,
        ResolveStrategy::ForwardQuery(params) => {
            return Some(ResolveStrategy::ForwardQuery(params.into_query(packet)))
        }
    };
    let response = build_dns_with_answer(message, question.qname(), question.qtype(), &resource)?;
    Some(ResolveStrategy::LocalResponse(build_response(
        packet, response,
    )?))
}

pub(crate) fn build_response(
    original_pkt: IpPacket<'_>,
    mut dns_answer: Vec<u8>,
) -> Option<Packet> {
    let version = original_pkt.version();
    let response_len = dns_answer.len();
    let original_dgm = original_pkt.as_udp()?;
    let hdr_len = original_pkt.packet_size() - original_dgm.payload().len();
    let mut res_buf = Vec::with_capacity(hdr_len + response_len);

    res_buf.extend_from_slice(&original_pkt.packet()[..hdr_len]);
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
    let packet = match version {
        Version::Ipv4 => Packet::Ipv4(res_buf),
        Version::Ipv6 => Packet::Ipv6(res_buf),
    };

    Some(packet)
}

pub(crate) fn build_response_from_resolve_result(
    original_pkt: IpPacket<'_>,
    response: hickory_resolver::error::ResolveResult<Lookup>,
) -> Result<Option<Packet>, ConnlibError> {
    let Some(mut message) = as_dns_message(&original_pkt) else {
        debug_assert!(false, "The original message should be a DNS query for us to ever call write_dns_lookup_response");
        return Ok(None);
    };

    let response = match response.map_err(|err| err.kind().clone()) {
        Ok(response) => message.add_answers(response.records().to_vec()),
        Err(hickory_resolver::error::ResolveErrorKind::NoRecordsFound {
            soa,
            response_code,
            ..
        }) => {
            if let Some(soa) = soa {
                message.add_name_server(soa.clone().into_record_of_rdata());
            }

            message.set_response_code(response_code)
        }
        Err(e) => {
            return Err(e.into());
        }
    };

    let packet = build_response(original_pkt, response.to_vec()?);

    Ok(packet)
}

fn build_dns_with_answer<N>(
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

fn resource_from_question<N: ToDname>(
    resources: &ResourceTable<ResourceDescription>,
    question: &Question<N>,
) -> Option<ResolveStrategy<ResourceDescription, DnsQueryParams>> {
    let name = ToDname::to_cow(question.qname()).to_string();
    let qtype = question.qtype();

    let resource = match qtype {
        Rtype::A | Rtype::Aaaa => resources.get_by_name(&name),
        Rtype::Ptr => {
            let ip = reverse_dns_addr(&name)?;
            resources.get_by_ip(ip)
        }
        _ => return None,
    };

    resource
        .cloned()
        .map(ResolveStrategy::LocalResponse)
        .unwrap_or(ResolveStrategy::new(name, qtype))
        .into()
}

pub(crate) fn as_dns_message(pkt: &IpPacket) -> Option<TrustDnsMessage> {
    let datagram = pkt.as_udp()?;
    TrustDnsMessage::from_vec(datagram.payload()).ok()
}

fn reverse_dns_addr(name: &str) -> Option<IpAddr> {
    let mut dns_parts = name.split('.').rev();
    if dns_parts.next()? != REVERSE_DNS_ADDRESS_END {
        return None;
    }

    let ip: IpAddr = match dns_parts.next()? {
        REVERSE_DNS_ADDRESS_V4 => reverse_dns_addr_v4(&mut dns_parts)?.into(),
        REVERSE_DNS_ADDRESS_V6 => reverse_dns_addr_v6(&mut dns_parts)?.into(),
        _ => return None,
    };

    if dns_parts.next().is_some() {
        return None;
    }

    Some(ip)
}

fn reverse_dns_addr_v4<'a>(dns_parts: &mut impl Iterator<Item = &'a str>) -> Option<Ipv4Addr> {
    dns_parts.join(".").parse().ok()
}

fn reverse_dns_addr_v6<'a>(dns_parts: &mut impl Iterator<Item = &'a str>) -> Option<Ipv6Addr> {
    dns_parts
        .chunks(4)
        .into_iter()
        .map(|mut s| s.join(""))
        .join(":")
        .parse()
        .ok()
}

#[cfg(test)]
mod test {
    use super::reverse_dns_addr;
    use std::net::Ipv4Addr;

    #[test]
    fn reverse_dns_addr_works_v4() {
        assert_eq!(
            reverse_dns_addr("1.2.3.4.in-addr.arpa"),
            Some(Ipv4Addr::new(4, 3, 2, 1).into())
        );
    }

    #[test]
    fn reverse_dns_v4_addr_extra_number() {
        assert_eq!(reverse_dns_addr("0.1.2.3.4.in-addr.arpa"), None);
    }

    #[test]
    fn reverse_dns_addr_wrong_ending() {
        assert_eq!(reverse_dns_addr("1.2.3.4.in-addr.carpa"), None);
    }

    #[test]
    fn reverse_dns_v4_addr_with_ip6_ending() {
        assert_eq!(reverse_dns_addr("1.2.3.4.ip6.arpa"), None);
    }

    #[test]
    fn reverse_dns_addr_v6() {
        assert_eq!(
            reverse_dns_addr(
                "b.a.9.8.7.6.5.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa"
            ),
            Some("2001:db8::567:89ab".parse().unwrap())
        );
    }

    #[test]
    fn reverse_dns_addr_v6_extra_number() {
        assert_eq!(
            reverse_dns_addr(
                "0.b.a.9.8.7.6.5.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa"
            ),
            None
        );
    }

    #[test]
    fn reverse_dns_addr_v6_ipv4_ending() {
        assert_eq!(
            reverse_dns_addr(
                "b.a.9.8.7.6.5.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.in-addr.arpa"
            ),
            None
        );
    }
}

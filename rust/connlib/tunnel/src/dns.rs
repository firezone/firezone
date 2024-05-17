use crate::client::DnsResource;
use connlib_shared::messages::{client::ResourceDescriptionDns, DnsServer};
use connlib_shared::Name;
use domain::base::RelativeName;
use domain::base::{
    iana::{Class, Rcode, Rtype},
    Message, MessageBuilder, Question, ToName,
};
use hickory_resolver::lookup::Lookup;
use hickory_resolver::proto::error::{ProtoError, ProtoErrorKind};
use hickory_resolver::proto::op::{Message as TrustDnsMessage, MessageType};
use hickory_resolver::proto::rr::RecordType;
use ip_packet::udp::UdpPacket;
use ip_packet::Packet as _;
use ip_packet::{udp::MutableUdpPacket, IpPacket, MutableIpPacket, MutablePacket, PacketSize};
use itertools::Itertools;
use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

const DNS_TTL: u32 = 1;
const UDP_HEADER_SIZE: usize = 8;
const REVERSE_DNS_ADDRESS_END: &str = "arpa";
const REVERSE_DNS_ADDRESS_V4: &str = "in-addr";
const REVERSE_DNS_ADDRESS_V6: &str = "ip6";
const DNS_PORT: u16 = 53;

/// Tells the Client how to reply to a single DNS query
#[derive(Debug)]
pub(crate) enum ResolveStrategy<T, U, V> {
    /// The query is for a Resource, we have an IP mapped already, and we can respond instantly
    LocalResponse(T),
    /// The query is for a non-Resource, forward it to an upstream or system resolver
    ForwardQuery(U),
    /// The query is for a Resource, but we can't map an IP until we connect to it, so defer the response while we connect in the background
    DeferredResponse(V),
}

#[derive(Debug)]
pub struct DnsQuery<'a> {
    pub name: String,
    pub record_type: RecordType,
    // We could be much more efficient with this field,
    // we only need the header to create the response.
    pub query: ip_packet::IpPacket<'a>,
}

impl<'a> DnsQuery<'a> {
    pub(crate) fn into_owned(self) -> DnsQuery<'static> {
        let Self {
            name,
            record_type,
            query,
        } = self;
        let buf = query.packet().to_vec();
        let query = ip_packet::IpPacket::owned(buf)
            .expect("We are constructing the ip packet from an ip packet");

        DnsQuery {
            name,
            record_type,
            query,
        }
    }
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

impl<T, V> ResolveStrategy<T, DnsQueryParams, V> {
    fn forward(name: String, record_type: Rtype) -> ResolveStrategy<T, DnsQueryParams, V> {
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
/// Parses an incoming packet as a DNS query and decides how to respond to it
///
/// Returns:
/// - `None` if the packet is not a valid DNS query destined for one of our sentinel resolvers
/// - Otherwise, a strategy for responding to the query
pub(crate) fn parse<'a>(
    dns_resources: &HashMap<String, ResourceDescriptionDns>,
    dns_resources_internal_ips: &HashMap<DnsResource, HashSet<IpAddr>>,
    dns_mapping: &bimap::BiMap<IpAddr, DnsServer>,
    packet: IpPacket<'a>,
) -> Option<ResolveStrategy<IpPacket<'static>, DnsQuery<'a>, (DnsResource, Rtype)>> {
    dns_mapping.get_by_left(&packet.destination())?;
    let datagram = packet.as_udp()?;
    let message = as_dns(&datagram)?;
    if message.header().qr() {
        return None;
    }

    let question = message.first_question()?;
    // In general we prefer to always have a response NxDomain to deal with with domains we don't expect
    // For systems with splitdns, in theory, we should only see Ptr queries we don't handle(e.g. apple's dns-sd)
    let resource =
        match resource_from_question(dns_resources, dns_resources_internal_ips, &question) {
            Some(ResolveStrategy::LocalResponse(resource)) => Some(resource),
            Some(ResolveStrategy::ForwardQuery(params)) => {
                return Some(ResolveStrategy::ForwardQuery(params.into_query(packet)));
            }
            Some(ResolveStrategy::DeferredResponse(resource)) => {
                return Some(ResolveStrategy::DeferredResponse((
                    resource,
                    question.qtype(),
                )))
            }
            None => None,
        };
    let response = build_dns_with_answer(message, question.qname(), &resource)?;
    Some(ResolveStrategy::LocalResponse(build_response(
        packet, response,
    )?))
}

pub(crate) fn create_local_answer<'a>(
    ips: &HashSet<IpAddr>,
    packet: IpPacket<'a>,
) -> Option<IpPacket<'a>> {
    let datagram = packet.as_udp().unwrap();
    let message = as_dns(&datagram).unwrap();
    let question = message.first_question().unwrap();
    let qtype = question.qtype();

    #[allow(clippy::wildcard_enum_match_arm)]
    let resource = match qtype {
        Rtype::A => RecordData::A(
            ips.iter()
                .copied()
                .filter_map(get_v4)
                .map(domain::rdata::A::new)
                .collect(),
        ),
        Rtype::AAAA => RecordData::Aaaa(
            ips.iter()
                .copied()
                .filter_map(get_v6)
                .map(domain::rdata::Aaaa::new)
                .collect(),
        ),
        _ => unreachable!(),
    };

    let response = build_dns_with_answer(message, question.qname(), &Some(resource))?;

    build_response(packet, response)
}

pub(crate) fn build_response_from_resolve_result(
    original_pkt: IpPacket<'_>,
    response: hickory_resolver::error::ResolveResult<Lookup>,
) -> Result<Option<IpPacket>, hickory_resolver::error::ResolveError> {
    let Some(mut message) = as_dns_message(&original_pkt) else {
        debug_assert!(false, "The original message should be a DNS query for us to ever call write_dns_lookup_response");
        return Ok(None);
    };

    message.set_message_type(MessageType::Response);

    let response = match response.map_err(|err| err.kind().clone()) {
        Ok(response) => message.add_answers(response.records().to_vec()),
        Err(hickory_resolver::error::ResolveErrorKind::Proto(ProtoError { kind, .. }))
            if matches!(*kind, ProtoErrorKind::NoRecordsFound { .. }) =>
        {
            let ProtoErrorKind::NoRecordsFound {
                soa, response_code, ..
            } = *kind
            else {
                panic!("Impossible - We matched on `ProtoErrorKind::NoRecordsFound` but then could not destructure that same variant");
            };
            if let Some(soa) = soa {
                message.add_name_server(soa.into_record_of_rdata());
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

/// Constructs an IP packet responding to an IP packet containing a DNS query
fn build_response(
    original_pkt: IpPacket<'_>,
    mut dns_answer: Vec<u8>,
) -> Option<IpPacket<'static>> {
    let response_len = dns_answer.len();
    let original_dgm = original_pkt.as_udp()?;
    let hdr_len = original_pkt.packet_size() - original_dgm.payload().len();
    let mut res_buf = Vec::with_capacity(hdr_len + response_len);

    res_buf.extend_from_slice(&original_pkt.packet()[..hdr_len]);
    res_buf.append(&mut dns_answer);

    let mut pkt = MutableIpPacket::new(&mut res_buf)?;
    let dgm_len = UDP_HEADER_SIZE + response_len;
    match &mut pkt {
        MutableIpPacket::Ipv4(p) => p.set_total_length((hdr_len + response_len) as u16),
        MutableIpPacket::Ipv6(p) => p.set_payload_length(dgm_len as u16),
    }
    pkt.swap_src_dst();

    let mut dgm = MutableUdpPacket::new(pkt.payload_mut())?;
    dgm.set_length(dgm_len as u16);
    dgm.set_source(original_dgm.get_destination());
    dgm.set_destination(original_dgm.get_source());

    let mut pkt = MutableIpPacket::new(&mut res_buf)?;
    let udp_checksum = pkt.to_immutable().udp_checksum(&pkt.as_immutable_udp()?);
    pkt.as_udp()?.set_checksum(udp_checksum);
    pkt.set_ipv4_checksum();

    Some(IpPacket::owned(res_buf).unwrap())
}

fn build_dns_with_answer<N>(
    message: &Message<[u8]>,
    qname: &N,
    resource: &Option<RecordData<Name>>,
) -> Option<Vec<u8>>
where
    N: ToName + ?Sized,
{
    let msg_buf = Vec::with_capacity(message.as_slice().len() * 2);
    let msg_builder = MessageBuilder::from_target(msg_buf).expect(
        "Developer error: we should be always be able to create a MessageBuilder from a Vec",
    );

    let Some(resource) = resource else {
        return Some(
            msg_builder
                .start_answer(message, Rcode::NXDOMAIN)
                .ok()?
                .finish(),
        );
    };

    let mut answer_builder = msg_builder.start_answer(message, Rcode::NOERROR).ok()?;
    answer_builder.header_mut().set_ra(true);

    // W/O object-safety there's no other way to access the inner type
    // we could as well implement the ComposeRecordData trait for RecordData
    // but the code would look like this but for each method instead
    match resource {
        RecordData::A(r) => r
            .iter()
            .try_for_each(|r| answer_builder.push((qname, Class::IN, DNS_TTL, r))),
        RecordData::Aaaa(r) => r
            .iter()
            .try_for_each(|r| answer_builder.push((qname, Class::IN, DNS_TTL, r))),
        RecordData::Ptr(r) => answer_builder.push((qname, Class::IN, DNS_TTL, r)),
    }
    .ok()?;

    Some(answer_builder.finish())
}

pub fn as_dns<'a>(pkt: &'a UdpPacket<'a>) -> Option<&'a Message<[u8]>> {
    (pkt.get_destination() == DNS_PORT)
        .then(|| Message::from_slice(pkt.payload()).ok())
        .flatten()
}

// No object safety =_=
#[derive(Clone)]
enum RecordData<T> {
    A(Vec<domain::rdata::A>),
    Aaaa(Vec<domain::rdata::Aaaa>),
    Ptr(domain::rdata::Ptr<T>),
}

pub fn is_subdomain(name: &Name, resource: &str) -> bool {
    let question_mark = RelativeName::<Vec<_>>::from_octets(b"\x01?".as_ref().into()).unwrap();
    let Ok(resource) = Name::vec_from_str(resource) else {
        return false;
    };

    if resource.starts_with(&question_mark) {
        return resource
            .parent()
            .is_some_and(|r| r == name || name.parent().is_some_and(|n| r == n));
    }

    if resource.starts_with(&RelativeName::wildcard_vec()) {
        let Some(resource) = resource.parent() else {
            return false;
        };
        return name.iter_suffixes().any(|n| n == resource);
    }

    name == &resource
}

fn get_description(
    name: &Name,
    dns_resources: &HashMap<String, ResourceDescriptionDns>,
) -> Option<ResourceDescriptionDns> {
    if let Some(resource) = dns_resources.get(&name.to_string()) {
        return Some(resource.clone());
    }

    if let Some(resource) = dns_resources.get(
        &RelativeName::<Vec<_>>::from_octets(b"\x01?".as_ref().into())
            .ok()?
            .chain(name)
            .ok()?
            .to_string(),
    ) {
        return Some(resource.clone());
    }

    if let Some(parent) = name.parent() {
        if let Some(resource) = dns_resources.get(
            &RelativeName::<Vec<_>>::from_octets(b"\x01?".as_ref().into())
                .ok()?
                .chain(parent)
                .ok()?
                .to_string(),
        ) {
            return Some(resource.clone());
        }
    }

    name.iter_suffixes().find_map(|n| {
        dns_resources
            .get(&RelativeName::wildcard_vec().chain(n).ok()?.to_string())
            .cloned()
    })
}

/// Decide how to reply to an incoming DNS query
///
/// The Client will use this decision to make its response.
///
/// If the query is not for a Firezone Resource, the Client should forward it to an
/// upstream (or system default) resolver.
/// If we are connected to the Resource, the Client should reply immediately with the IP address(es) of the Resource.
/// If we are not connected yet, the Client should defer the response and begin connecting.
fn resource_from_question<N: ToName>(
    dns_resources: &HashMap<String, ResourceDescriptionDns>,
    dns_resources_internal_ips: &HashMap<DnsResource, HashSet<IpAddr>>,
    question: &Question<N>,
) -> Option<ResolveStrategy<RecordData<Name>, DnsQueryParams, DnsResource>> {
    let name = ToName::to_vec(question.qname());
    let qtype = question.qtype();

    #[allow(clippy::wildcard_enum_match_arm)]
    match qtype {
        Rtype::A => {
            let Some(description) = get_description(&name, dns_resources) else {
                return Some(ResolveStrategy::forward(name.to_string(), qtype));
            };

            let description = DnsResource::from_description(&description, name);
            let Some(ips) = dns_resources_internal_ips.get(&description) else {
                return Some(ResolveStrategy::DeferredResponse(description));
            };
            Some(ResolveStrategy::LocalResponse(RecordData::A(
                ips.iter()
                    .cloned()
                    .filter_map(get_v4)
                    .map(domain::rdata::A::new)
                    .collect(),
            )))
        }
        Rtype::AAAA => {
            let Some(description) = get_description(&name, dns_resources) else {
                return Some(ResolveStrategy::forward(name.to_string(), qtype));
            };
            let description = DnsResource::from_description(&description, name);
            let Some(ips) = dns_resources_internal_ips.get(&description) else {
                return Some(ResolveStrategy::DeferredResponse(description));
            };

            Some(ResolveStrategy::LocalResponse(RecordData::Aaaa(
                ips.iter()
                    .cloned()
                    .filter_map(get_v6)
                    .map(domain::rdata::Aaaa::new)
                    .collect(),
            )))
        }
        Rtype::PTR => {
            let Some(ip) = reverse_dns_addr(&name.to_string()) else {
                return Some(ResolveStrategy::forward(name.to_string(), qtype));
            };
            let Some(resource) = dns_resources_internal_ips
                .iter()
                .find_map(|(r, ips)| ips.contains(&ip).then_some(r))
            else {
                return Some(ResolveStrategy::forward(name.to_string(), qtype));
            };
            Some(ResolveStrategy::LocalResponse(RecordData::Ptr(
                domain::rdata::Ptr::new(resource.address.clone()),
            )))
        }
        _ => {
            if get_description(&name, dns_resources).is_some() {
                return None;
            };

            Some(ResolveStrategy::forward(name.to_string(), qtype))
        }
    }
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

fn get_v4(ip: IpAddr) -> Option<Ipv4Addr> {
    match ip {
        IpAddr::V4(v4) => Some(v4),
        IpAddr::V6(_) => None,
    }
}

fn get_v6(ip: IpAddr) -> Option<Ipv6Addr> {
    match ip {
        IpAddr::V4(_) => None,
        IpAddr::V6(v6) => Some(v6),
    }
}

#[cfg(test)]
mod test {
    use connlib_shared::{messages::client::ResourceDescriptionDns, Name};

    use crate::dns::is_subdomain;

    use super::{get_description, reverse_dns_addr};
    use std::{collections::HashMap, net::Ipv4Addr};

    fn foo() -> ResourceDescriptionDns {
        serde_json::from_str(
            r#"{
                "id": "c4bb3d79-afa7-4660-8918-06c38fda3a4a",
                "address": "*.foo.com",
                "name": "foo.com wildcard",
                "address_description": "foo",
                "gateway_groups": [{"id": "bf56f32d-7b2c-4f5d-a784-788977d014a4", "name": "test"}]
            }"#,
        )
        .unwrap()
    }

    fn bar() -> ResourceDescriptionDns {
        serde_json::from_str(
            r#"{
                "id": "c4bb3d79-afa7-4660-8918-06c38fda3a4b",
                "address": "*.bar.com",
                "name": "bar.com wildcard",
                "address_description": "bar",
                "gateway_groups": [{"id": "bf56f32d-7b2c-4f5d-a784-788977d014a4", "name": "test"}]
            }"#,
        )
        .unwrap()
    }

    fn baz() -> ResourceDescriptionDns {
        serde_json::from_str(
            r#"{
                "id": "c4bb3d79-afa7-4660-8918-06c38fda3a4c",
                "address": "baz.com",
                "name": "baz.com",
                "address_description": "baz",
                "gateway_groups": [{"id": "bf56f32d-7b2c-4f5d-a784-788977d014a4", "name": "test"}]
            }"#,
        )
        .unwrap()
    }

    fn dns_resource_fixture() -> HashMap<String, ResourceDescriptionDns> {
        let mut dns_resources_fixture = HashMap::new();

        dns_resources_fixture.insert("*.foo.com".to_string(), foo());

        dns_resources_fixture.insert("?.bar.com".to_string(), bar());

        dns_resources_fixture.insert("baz.com".to_string(), baz());

        dns_resources_fixture
    }

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

    #[test]
    fn wildcard_matching() {
        let dns_resources_fixture = dns_resource_fixture();

        assert_eq!(
            get_description(
                &Name::vec_from_str("a.foo.com").unwrap(),
                &dns_resources_fixture,
            )
            .unwrap(),
            foo(),
        );

        assert_eq!(
            get_description(
                &Name::vec_from_str("foo.com").unwrap(),
                &dns_resources_fixture,
            )
            .unwrap(),
            foo(),
        );

        assert_eq!(
            get_description(
                &Name::vec_from_str("a.b.foo.com").unwrap(),
                &dns_resources_fixture,
            )
            .unwrap(),
            foo(),
        );

        assert!(get_description(
            &Name::vec_from_str("oo.com").unwrap(),
            &dns_resources_fixture,
        )
        .is_none(),);
    }

    #[test]
    fn question_mark_matching() {
        let dns_resources_fixture = dns_resource_fixture();

        assert_eq!(
            get_description(
                &Name::vec_from_str("a.bar.com").unwrap(),
                &dns_resources_fixture,
            )
            .unwrap(),
            bar(),
        );

        assert_eq!(
            get_description(
                &Name::vec_from_str("bar.com").unwrap(),
                &dns_resources_fixture,
            )
            .unwrap(),
            bar(),
        );

        assert!(get_description(
            &Name::vec_from_str("a.b.bar.com").unwrap(),
            &dns_resources_fixture,
        )
        .is_none(),);
    }

    #[test]
    fn exact_matching() {
        let dns_resources_fixture = dns_resource_fixture();

        assert_eq!(
            get_description(
                &Name::vec_from_str("baz.com").unwrap(),
                &dns_resources_fixture,
            )
            .unwrap(),
            baz(),
        );

        assert!(get_description(
            &Name::vec_from_str("a.baz.com").unwrap(),
            &dns_resources_fixture,
        )
        .is_none());

        assert!(get_description(
            &Name::vec_from_str("a.b.baz.com").unwrap(),
            &dns_resources_fixture,
        )
        .is_none(),);
    }

    #[test]
    fn exact_subdomain_match() {
        assert!(is_subdomain(
            &Name::vec_from_str("foo.com").unwrap(),
            "foo.com"
        ));

        assert!(!is_subdomain(
            &Name::vec_from_str("a.foo.com").unwrap(),
            "foo.com"
        ));

        assert!(!is_subdomain(
            &Name::vec_from_str("a.b.foo.com").unwrap(),
            "foo.com"
        ));

        assert!(!is_subdomain(
            &Name::vec_from_str("foo.com").unwrap(),
            "a.foo.com"
        ));
    }

    #[test]
    fn wildcard_subdomain_match() {
        assert!(is_subdomain(
            &Name::vec_from_str("foo.com").unwrap(),
            "*.foo.com"
        ));

        assert!(is_subdomain(
            &Name::vec_from_str("a.foo.com").unwrap(),
            "*.foo.com"
        ));

        assert!(is_subdomain(
            &Name::vec_from_str("a.foo.com").unwrap(),
            "*.a.foo.com"
        ));

        assert!(is_subdomain(
            &Name::vec_from_str("b.a.foo.com").unwrap(),
            "*.a.foo.com"
        ));

        assert!(is_subdomain(
            &Name::vec_from_str("a.b.foo.com").unwrap(),
            "*.foo.com"
        ));

        assert!(!is_subdomain(
            &Name::vec_from_str("afoo.com").unwrap(),
            "*.foo.com"
        ));

        assert!(!is_subdomain(
            &Name::vec_from_str("b.afoo.com").unwrap(),
            "*.foo.com"
        ));

        assert!(!is_subdomain(
            &Name::vec_from_str("bar.com").unwrap(),
            "*.foo.com"
        ));

        assert!(!is_subdomain(
            &Name::vec_from_str("foo.com").unwrap(),
            "*.a.foo.com"
        ));
    }

    #[test]
    fn question_mark_subdomain_match() {
        assert!(is_subdomain(
            &Name::vec_from_str("foo.com").unwrap(),
            "?.foo.com"
        ));

        assert!(is_subdomain(
            &Name::vec_from_str("a.foo.com").unwrap(),
            "?.foo.com"
        ));

        assert!(!is_subdomain(
            &Name::vec_from_str("a.b.foo.com").unwrap(),
            "?.foo.com"
        ));

        assert!(!is_subdomain(
            &Name::vec_from_str("bar.com").unwrap(),
            "?.foo.com"
        ));

        assert!(!is_subdomain(
            &Name::vec_from_str("foo.com").unwrap(),
            "?.a.foo.com"
        ));

        assert!(!is_subdomain(
            &Name::vec_from_str("afoo.com").unwrap(),
            "?.foo.com"
        ));
    }
}

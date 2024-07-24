use crate::client::IpProvider;
use connlib_shared::messages::{DnsServer, ResourceId};
use connlib_shared::DomainName;
use hickory_proto::op::{Message, ResponseCode};
use hickory_proto::rr::domain::Label;
use hickory_proto::rr::rdata::{self, PTR};
use hickory_proto::rr::{RData, Record, RecordType};
use hickory_resolver::lookup::Lookup;
use hickory_resolver::proto::error::{ProtoError, ProtoErrorKind};
use hickory_resolver::proto::op::MessageType;
use ip_packet::udp::UdpPacket;
use ip_packet::Packet as _;
use ip_packet::{udp::MutableUdpPacket, IpPacket, MutableIpPacket, MutablePacket, PacketSize};
use itertools::Itertools;
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

const DNS_TTL: u32 = 1;
const UDP_HEADER_SIZE: usize = 8;
const REVERSE_DNS_ADDRESS_END: &str = "arpa";
const REVERSE_DNS_ADDRESS_V4: &str = "in-addr";
const REVERSE_DNS_ADDRESS_V6: &str = "ip6";
const DNS_PORT: u16 = 53;

pub struct StubResolver {
    fqdn_to_ips: HashMap<DomainName, Vec<IpAddr>>,
    ips_to_fqdn: HashMap<IpAddr, (DomainName, ResourceId)>,
    ip_provider: IpProvider,
    /// All DNS resources we know about, indexed by their domain (could be wildcard domain like `*.mycompany.com`).
    dns_resources: HashMap<String, ResourceId>,
    /// Fixed dns name that will be resolved to fixed ip addrs, similar to /etc/hosts
    known_hosts: KnownHosts,
}

#[derive(Debug)]
pub struct DnsQuery<'a> {
    pub name: DomainName,
    pub record_type: RecordType,
    // We could be much more efficient with this field,
    // we only need the header to create the response.
    pub query: ip_packet::IpPacket<'a>,
}

/// Tells the Client how to reply to a single DNS query
#[derive(Debug)]
pub(crate) enum ResolveStrategy<'a> {
    /// The query is for a Resource, we have an IP mapped already, and we can respond instantly
    LocalResponse(IpPacket<'static>),
    /// The query is for a non-Resource, forward it to an upstream or system resolver
    ForwardQuery(DnsQuery<'a>),
}

struct KnownHosts {
    fqdn_to_ips: HashMap<DomainName, Vec<IpAddr>>,
    ips_to_fqdn: HashMap<IpAddr, DomainName>,
}

impl KnownHosts {
    fn new(hosts: HashMap<String, Vec<IpAddr>>) -> KnownHosts {
        KnownHosts {
            fqdn_to_ips: fqdn_to_ips_for_known_hosts(&hosts),
            ips_to_fqdn: ips_to_fqdn_for_known_hosts(&hosts),
        }
    }

    fn get_records(&self, qtype: RecordType, domain: &DomainName) -> Option<Vec<RData>> {
        // `RecordType` is non-exhaustive so we cannot list them all.
        #[allow(clippy::wildcard_enum_match_arm)]
        match qtype {
            RecordType::A => {
                let ips = self.fqdn_to_ips.get::<DomainName>(domain)?;

                Some(to_a_records(ips.iter().copied()))
            }

            RecordType::AAAA => {
                let ips = self.fqdn_to_ips.get::<DomainName>(domain)?;

                Some(to_aaaa_records(ips.iter().copied()))
            }
            RecordType::PTR => {
                let ip = reverse_dns_addr(&domain.to_string())?;
                let fqdn = self.ips_to_fqdn.get(&ip)?;

                Some(vec![RData::PTR(PTR(fqdn.clone()))])
            }
            _ => None,
        }
    }
}

impl StubResolver {
    pub(crate) fn new(known_hosts: HashMap<String, Vec<IpAddr>>) -> StubResolver {
        StubResolver {
            fqdn_to_ips: Default::default(),
            ips_to_fqdn: Default::default(),
            ip_provider: IpProvider::for_resources(),
            dns_resources: Default::default(),
            known_hosts: KnownHosts::new(known_hosts),
        }
    }

    /// Attempts to resolve an IP to a given resource.
    ///
    /// Semantically, this is like a PTR query, i.e. we check whether we handed out this IP as part of answering a DNS query for one of our resources.
    /// This is in the hot-path of packet routing and must be fast!
    pub(crate) fn resolve_resource_by_ip(&self, ip: &IpAddr) -> Option<ResourceId> {
        let (_, resource_id) = self.ips_to_fqdn.get(ip)?;

        Some(*resource_id)
    }

    pub(crate) fn get_fqdn(&self, ip: &IpAddr) -> Option<(&DomainName, &Vec<IpAddr>)> {
        let (fqdn, _) = self.ips_to_fqdn.get(ip)?;
        Some((fqdn, self.fqdn_to_ips.get(fqdn).unwrap()))
    }

    pub(crate) fn add_resource(&mut self, id: ResourceId, address: String) {
        let existing = self.dns_resources.insert(address.clone(), id);

        if existing.is_none() {
            tracing::info!(%address, "Activating DNS resource");
        }
    }

    pub(crate) fn remove_resource(&mut self, id: ResourceId) {
        self.dns_resources.retain(|address, r| {
            if *r == id {
                tracing::info!(%address, "Deactivating DNS resource");
                return false;
            }

            true
        });
    }

    fn get_or_assign_a_records(&mut self, fqdn: DomainName, resource_id: ResourceId) -> Vec<RData> {
        to_a_records(self.get_or_assign_ips(fqdn, resource_id).into_iter())
    }

    fn get_or_assign_aaaa_records(
        &mut self,
        fqdn: DomainName,
        resource_id: ResourceId,
    ) -> Vec<RData> {
        to_aaaa_records(self.get_or_assign_ips(fqdn, resource_id).into_iter())
    }

    fn get_or_assign_ips(&mut self, fqdn: DomainName, resource_id: ResourceId) -> Vec<IpAddr> {
        let ips = self
            .fqdn_to_ips
            .entry(fqdn.clone())
            .or_insert_with(|| {
                // TODO: the side effeccts are executed even if this is not inserted
                // make it so that's not the case
                let mut ips = self.ip_provider.get_n_ipv4(4);
                ips.extend_from_slice(&self.ip_provider.get_n_ipv6(4));
                ips
            })
            .clone();
        for ip in &ips {
            self.ips_to_fqdn.insert(*ip, (fqdn.clone(), resource_id));
        }

        ips
    }

    fn match_resource(&self, domain_name: &DomainName) -> Option<ResourceId> {
        match_domain(domain_name, &self.dns_resources)
    }

    fn resource_address_name_by_reservse_dns(
        &self,
        reverse_dns_name: &DomainName,
    ) -> Option<DomainName> {
        let address = reverse_dns_addr(&reverse_dns_name.to_string())?;
        let (domain, _) = self.ips_to_fqdn.get(&address)?;

        Some(domain.clone())
    }

    // TODO: we can save a few allocations here still
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
    pub(crate) fn handle<'a>(
        &mut self,
        dns_mapping: &bimap::BiMap<IpAddr, DnsServer>,
        packet: IpPacket<'a>,
    ) -> Option<ResolveStrategy<'a>> {
        dns_mapping.get_by_left(&packet.destination())?;
        let datagram = packet.as_udp()?;
        let message = as_dns(&datagram)?;
        if message.message_type() == MessageType::Response {
            return None;
        }

        let question = message.queries().first()?;
        let domain = question.name();
        let qtype = question.query_type();

        tracing::trace!("Parsed packet as DNS query: '{qtype} {domain}'");

        if let Some(records) = self.known_hosts.get_records(qtype, domain) {
            let response = build_dns_with_answer(domain.clone(), records)?;
            return Some(ResolveStrategy::LocalResponse(build_response(
                packet, response,
            )));
        }

        let maybe_resource = self.match_resource(domain);

        let resource_records = match (qtype, maybe_resource) {
            (RecordType::A, Some(resource)) => {
                self.get_or_assign_a_records(domain.clone(), resource)
            }
            (RecordType::AAAA, Some(resource)) => {
                self.get_or_assign_aaaa_records(domain.clone(), resource)
            }
            (RecordType::PTR, _) => {
                let fqdn = self.resource_address_name_by_reservse_dns(domain)?;

                vec![RData::PTR(PTR(fqdn))]
            }
            _ => {
                return Some(ResolveStrategy::ForwardQuery(DnsQuery {
                    name: domain.clone(),
                    record_type: u16::from(qtype).into(),
                    query: packet,
                }))
            }
        };

        let response = build_dns_with_answer(domain.clone(), resource_records)?;

        Some(ResolveStrategy::LocalResponse(build_response(
            packet, response,
        )))
    }
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

impl Clone for DnsQuery<'static> {
    fn clone(&self) -> Self {
        Self {
            name: self.name.clone(),
            record_type: self.record_type,
            query: self.query.clone(),
        }
    }
}

fn to_a_records(ips: impl Iterator<Item = IpAddr>) -> Vec<RData> {
    ips.filter_map(get_v4)
        .map(rdata::A)
        .map(RData::A)
        .collect_vec()
}

fn to_aaaa_records(ips: impl Iterator<Item = IpAddr>) -> Vec<RData> {
    ips.filter_map(get_v6)
        .map(rdata::AAAA)
        .map(RData::AAAA)
        .collect_vec()
}

pub(crate) fn build_response_from_resolve_result(
    original_pkt: IpPacket<'_>,
    response: hickory_resolver::error::ResolveResult<Lookup>,
) -> Result<IpPacket, hickory_resolver::error::ResolveError> {
    let mut message = original_pkt.unwrap_as_dns();

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
fn build_response(original_pkt: IpPacket<'_>, mut dns_answer: Vec<u8>) -> IpPacket<'static> {
    let response_len = dns_answer.len();
    let original_dgm = original_pkt.unwrap_as_udp();
    let hdr_len = original_pkt.packet_size() - original_dgm.payload().len();
    let mut res_buf = Vec::with_capacity(hdr_len + response_len + 20);

    // TODO: this is some weirdness due to how MutableIpPacket is implemented
    // we need an extra 20 bytes padding.
    res_buf.extend_from_slice(&[0; 20]);
    res_buf.extend_from_slice(&original_pkt.packet()[..hdr_len]);
    res_buf.append(&mut dns_answer);

    let mut pkt = MutableIpPacket::new(&mut res_buf).unwrap();
    let dgm_len = UDP_HEADER_SIZE + response_len;
    match &mut pkt {
        MutableIpPacket::Ipv4(p) => p.set_total_length((hdr_len + response_len) as u16),
        MutableIpPacket::Ipv6(p) => p.set_payload_length(dgm_len as u16),
    }
    pkt.swap_src_dst();

    let mut dgm = MutableUdpPacket::new(pkt.payload_mut()).unwrap();
    dgm.set_length(dgm_len as u16);
    dgm.set_source(original_dgm.get_destination());
    dgm.set_destination(original_dgm.get_source());

    let mut pkt = MutableIpPacket::new(&mut res_buf).unwrap();
    let udp_checksum = pkt
        .to_immutable()
        .udp_checksum(&pkt.to_immutable().unwrap_as_udp());
    pkt.unwrap_as_udp().set_checksum(udp_checksum);
    pkt.set_ipv4_checksum();

    // TODO: more of this weirdness
    res_buf.drain(0..20);
    IpPacket::owned(res_buf).unwrap()
}

fn build_dns_with_answer(qname: DomainName, records: Vec<RData>) -> Option<Vec<u8>> {
    let mut message = Message::new();

    message.add_answers(
        records
            .into_iter()
            .map(|data| Record::from_rdata(qname.clone(), DNS_TTL, data)),
    );
    message.set_recursion_available(true);
    message.set_response_code(ResponseCode::NoError);

    message.to_vec().ok()
}

pub fn as_dns(pkt: &UdpPacket) -> Option<Message> {
    if pkt.get_destination() != DNS_PORT {
        return None;
    }

    let message = Message::from_vec(pkt.payload()).ok()?;

    Some(message)
}

pub fn is_subdomain(name: &DomainName, resource: &str) -> bool {
    let question_mark = Label::from_ascii("?").unwrap();
    let wildcard = Label::from_ascii("*").unwrap();

    let Ok(resource) = DomainName::from_ascii(resource) else {
        return false;
    };
    let resource_base = resource.base_name();

    if resource
        .iter()
        .next()
        .is_some_and(|l| l == question_mark.as_bytes())
    {
        return resource_base.zone_of(name);
    }

    if resource
        .iter()
        .next()
        .is_some_and(|l| l == wildcard.as_bytes())
    {
        return resource_base.zone_of(name);
    }

    name == &resource
}

fn match_domain<T>(name: &DomainName, resources: &HashMap<String, T>) -> Option<T>
where
    T: Copy,
{
    let question_mark = DomainName::from_ascii("?").unwrap();
    let wildcard = DomainName::from_ascii("*").unwrap();

    // First, check for full match.
    if let Some(resource) = resources.get(&name.to_string()) {
        return Some(*resource);
    }

    // Second, check for `?` matching this domain exactly.
    let qm_dot_domain = question_mark.clone().append_domain(name).ok()?.to_ascii();
    if let Some(resource) = resources.get(&qm_dot_domain) {
        return Some(*resource);
    }

    let mut base = name.base_name();

    // Third, check for `?` matching up to 1 parent.
    let qm_dot_parent = question_mark.append_domain(&base).ok()?.to_ascii();

    if let Some(resource) = resources.get(&qm_dot_parent) {
        return Some(*resource);
    }

    // Last, check for any wildcard domains, starting with the most specific one.
    while !base.is_root() {
        let wildcard_dot_suffix = wildcard.clone().append_domain(&base).ok()?.to_ascii();

        if let Some(resource) = resources.get(&wildcard_dot_suffix) {
            return Some(*resource);
        }

        base = base.base_name();
    }

    None
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

fn fqdn_to_ips_for_known_hosts(
    hosts: &HashMap<String, Vec<IpAddr>>,
) -> HashMap<DomainName, Vec<IpAddr>> {
    hosts
        .iter()
        .filter_map(|(d, a)| DomainName::from_utf8(d).ok().map(|d| (d, a.clone())))
        .collect()
}

fn ips_to_fqdn_for_known_hosts(
    hosts: &HashMap<String, Vec<IpAddr>>,
) -> HashMap<IpAddr, DomainName> {
    hosts
        .iter()
        .filter_map(|(d, a)| {
            DomainName::from_utf8(d)
                .ok()
                .map(|d| a.iter().map(move |a| (*a, d.clone())))
        })
        .flatten()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let res = resolver([("*.foo.com", rid(0)), ("*.com", rid(1))]);

        assert_eq!(res.match_resource(&domain("a.foo.com")), Some(rid(0)));
        assert_eq!(res.match_resource(&domain("foo.com")), Some(rid(0)));
        assert_eq!(res.match_resource(&domain("a.b.foo.com")), Some(rid(0)));
        assert_eq!(res.match_resource(&domain("oo.com")), Some(rid(1)));
        assert_eq!(res.match_resource(&domain("oo.xyz")), None);
    }

    #[test]
    fn question_mark_matching() {
        let res = resolver([("?.bar.com", rid(1))]);

        assert_eq!(res.match_resource(&domain("a.bar.com")), Some(rid(1)));
        assert_eq!(res.match_resource(&domain("bar.com")), Some(rid(1)));
        assert_eq!(res.match_resource(&domain("a.b.bar.com")), None);
    }

    #[test]
    fn exact_matching() {
        let res = resolver([("baz.com", rid(2))]);

        assert_eq!(res.match_resource(&domain("baz.com")), Some(rid(2)));
        assert_eq!(res.match_resource(&domain("a.baz.com")), None);
        assert_eq!(res.match_resource(&domain("a.b.baz.com")), None);
    }

    #[test]
    fn exact_subdomain_match() {
        assert!(is_subdomain(&domain("foo.com"), "foo.com"));
        assert!(!is_subdomain(&domain("a.foo.com"), "foo.com"));
        assert!(!is_subdomain(&domain("a.b.foo.com"), "foo.com"));
        assert!(!is_subdomain(&domain("foo.com"), "a.foo.com"));
    }

    #[test]
    fn wildcard_subdomain_match() {
        assert!(is_subdomain(&domain("foo.com"), "*.foo.com"));
        assert!(is_subdomain(&domain("a.foo.com"), "*.foo.com"));
        assert!(is_subdomain(&domain("a.foo.com"), "*.a.foo.com"));
        assert!(is_subdomain(&domain("b.a.foo.com"), "*.a.foo.com"));
        assert!(is_subdomain(&domain("a.b.foo.com"), "*.foo.com"));
        assert!(!is_subdomain(&domain("afoo.com"), "*.foo.com"));
        assert!(!is_subdomain(&domain("b.afoo.com"), "*.foo.com"));
        assert!(!is_subdomain(&domain("bar.com"), "*.foo.com"));
        assert!(!is_subdomain(&domain("foo.com"), "*.a.foo.com"));
    }

    #[test]
    fn question_mark_subdomain_match() {
        assert!(is_subdomain(&domain("foo.com"), "?.foo.com"));
        assert!(is_subdomain(&domain("a.foo.com"), "?.foo.com"));
        assert!(!is_subdomain(&domain("a.b.foo.com"), "?.foo.com"));
        assert!(!is_subdomain(&domain("bar.com"), "?.foo.com"));
        assert!(!is_subdomain(&domain("foo.com"), "?.a.foo.com"));
        assert!(!is_subdomain(&domain("afoo.com"), "?.foo.com"));
    }

    fn domain(name: &str) -> DomainName {
        DomainName::from_utf8(name).unwrap()
    }

    fn resolver<const N: usize>(records: [(&str, ResourceId); N]) -> StubResolver {
        let mut stub_resolver = StubResolver::new(HashMap::default());

        for (domain, id) in records {
            stub_resolver.add_resource(id, domain.to_owned())
        }

        stub_resolver
    }

    fn rid(id: u128) -> ResourceId {
        ResourceId::from_u128(id)
    }
}

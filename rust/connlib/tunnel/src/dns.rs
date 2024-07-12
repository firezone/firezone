use crate::client::IpProvider;
use connlib_shared::messages::client::ResourceDescriptionDns;
use connlib_shared::messages::{DnsServer, ResourceId};
use connlib_shared::DomainName;
use domain::base::RelativeName;
use domain::base::{
    iana::{Class, Rcode, Rtype},
    Message, MessageBuilder, ToName,
};
use domain::rdata::AllRecordData;
use hickory_resolver::lookup::Lookup;
use hickory_resolver::proto::error::{ProtoError, ProtoErrorKind};
use hickory_resolver::proto::op::MessageType;
use hickory_resolver::proto::rr::RecordType;
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

    fn get_records(
        &self,
        qtype: Rtype,
        domain: &DomainName,
    ) -> Option<Vec<AllRecordData<Vec<u8>, DomainName>>> {
        match qtype {
            Rtype::A => {
                let ips = self.fqdn_to_ips.get::<DomainName>(domain)?;

                Some(to_a_records(ips.iter().copied()))
            }

            Rtype::AAAA => {
                let ips = self.fqdn_to_ips.get::<DomainName>(domain)?;

                Some(to_aaaa_records(ips.iter().copied()))
            }
            Rtype::PTR => {
                let ip = reverse_dns_addr(&domain.to_string())?;
                let fqdn = self.ips_to_fqdn.get(&ip)?;

                Some(vec![AllRecordData::Ptr(domain::rdata::Ptr::new(
                    fqdn.clone(),
                ))])
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

    pub(crate) fn add_resource(&mut self, resource: &ResourceDescriptionDns) {
        let existing = self
            .dns_resources
            .insert(resource.address.clone(), resource.id);

        if existing.is_none() {
            tracing::info!(address = %resource.address, "Activating DNS resource");
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

    fn get_or_assign_a_records(
        &mut self,
        fqdn: DomainName,
        resource_id: ResourceId,
    ) -> Vec<AllRecordData<Vec<u8>, DomainName>> {
        to_a_records(self.get_or_assign_ips(fqdn, resource_id).into_iter())
    }

    fn get_or_assign_aaaa_records(
        &mut self,
        fqdn: DomainName,
        resource_id: ResourceId,
    ) -> Vec<AllRecordData<Vec<u8>, DomainName>> {
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
        if message.header().qr() {
            return None;
        }

        let question = message.first_question()?;
        let domain = question.qname().to_vec();
        let qtype = question.qtype();

        tracing::trace!("Parsed packet as DNS query: '{qtype} {domain}'");

        if let Some(records) = self.known_hosts.get_records(qtype, &domain) {
            let response = build_dns_with_answer(message, domain, records)?;
            return Some(ResolveStrategy::LocalResponse(build_response(
                packet, response,
            )));
        }

        let maybe_resource = self.match_resource(&domain);

        let resource_records = match (qtype, maybe_resource) {
            (Rtype::A, Some(resource)) => self.get_or_assign_a_records(domain.clone(), resource),
            (Rtype::AAAA, Some(resource)) => {
                self.get_or_assign_aaaa_records(domain.clone(), resource)
            }
            (Rtype::PTR, _) => {
                let fqdn = self.resource_address_name_by_reservse_dns(&domain)?;

                vec![AllRecordData::Ptr(domain::rdata::Ptr::new(fqdn))]
            }
            _ => {
                return Some(ResolveStrategy::ForwardQuery(DnsQuery {
                    name: domain,
                    record_type: u16::from(qtype).into(),
                    query: packet,
                }))
            }
        };

        let response = build_dns_with_answer(message, domain, resource_records)?;

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

fn to_a_records(ips: impl Iterator<Item = IpAddr>) -> Vec<AllRecordData<Vec<u8>, DomainName>> {
    ips.filter_map(get_v4)
        .map(domain::rdata::A::new)
        .map(AllRecordData::A)
        .collect_vec()
}

fn to_aaaa_records(ips: impl Iterator<Item = IpAddr>) -> Vec<AllRecordData<Vec<u8>, DomainName>> {
    ips.filter_map(get_v6)
        .map(domain::rdata::Aaaa::new)
        .map(AllRecordData::Aaaa)
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

fn build_dns_with_answer(
    message: &Message<[u8]>,
    qname: DomainName,
    records: Vec<AllRecordData<Vec<u8>, DomainName>>,
) -> Option<Vec<u8>> {
    let msg_buf = Vec::with_capacity(message.as_slice().len() * 2);
    let msg_builder = MessageBuilder::from_target(msg_buf).expect(
        "Developer error: we should be always be able to create a MessageBuilder from a Vec",
    );

    let mut answer_builder = msg_builder.start_answer(message, Rcode::NOERROR).ok()?;
    answer_builder.header_mut().set_ra(true);

    for record in records {
        answer_builder
            .push((&qname, Class::IN, DNS_TTL, record))
            .ok()?;
    }

    Some(answer_builder.finish())
}

pub fn as_dns<'a>(pkt: &'a UdpPacket<'a>) -> Option<&'a Message<[u8]>> {
    (pkt.get_destination() == DNS_PORT)
        .then(|| Message::from_slice(pkt.payload()).ok())
        .flatten()
}

pub fn is_subdomain(name: &DomainName, resource: &str) -> bool {
    let question_mark = RelativeName::<Vec<_>>::from_octets(b"\x01?".as_ref().into()).unwrap();
    let Ok(resource) = DomainName::vec_from_str(resource) else {
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

fn match_domain<T>(name: &DomainName, dns_resources: &HashMap<String, T>) -> Option<T>
where
    T: Copy,
{
    if let Some(resource) = dns_resources.get(&name.to_string()) {
        return Some(*resource);
    }

    if let Some(resource) = dns_resources.get(
        &RelativeName::<Vec<_>>::from_octets(b"\x01?".as_ref().into())
            .ok()?
            .chain(name)
            .ok()?
            .to_string(),
    ) {
        return Some(*resource);
    }

    if let Some(parent) = name.parent() {
        if let Some(resource) = dns_resources.get(
            &RelativeName::<Vec<_>>::from_octets(b"\x01?".as_ref().into())
                .ok()?
                .chain(parent)
                .ok()?
                .to_string(),
        ) {
            return Some(*resource);
        }
    }

    name.iter_suffixes().find_map(|n| {
        dns_resources
            .get(&RelativeName::wildcard_vec().chain(n).ok()?.to_string())
            .copied()
    })
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
        .filter_map(|(d, a)| DomainName::vec_from_str(d).ok().map(|d| (d, a.clone())))
        .collect()
}

fn ips_to_fqdn_for_known_hosts(
    hosts: &HashMap<String, Vec<IpAddr>>,
) -> HashMap<IpAddr, DomainName> {
    hosts
        .iter()
        .filter_map(|(d, a)| {
            DomainName::vec_from_str(d)
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
        let dns_resources_fixture = HashMap::from([("*.foo.com".to_string(), 0)]);

        assert_eq!(
            match_domain(&domain("a.foo.com"), &dns_resources_fixture),
            Some(0),
        );

        assert_eq!(
            match_domain(&domain("foo.com"), &dns_resources_fixture),
            Some(0),
        );

        assert_eq!(
            match_domain(&domain("a.b.foo.com"), &dns_resources_fixture),
            Some(0),
        );

        assert_eq!(
            match_domain(&domain("oo.com"), &dns_resources_fixture),
            None
        );
    }

    #[test]
    fn question_mark_matching() {
        let dns_resources_fixture = HashMap::from([("?.bar.com".to_string(), 1)]);

        assert_eq!(
            match_domain(&domain("a.bar.com"), &dns_resources_fixture),
            Some(1),
        );

        assert_eq!(
            match_domain(&domain("bar.com"), &dns_resources_fixture),
            Some(1),
        );

        assert_eq!(
            match_domain(&domain("a.b.bar.com"), &dns_resources_fixture),
            None
        );
    }

    #[test]
    fn exact_matching() {
        let dns_resources_fixture = HashMap::from([("baz.com".to_string(), 2)]);

        assert_eq!(
            match_domain(&domain("baz.com"), &dns_resources_fixture),
            Some(2),
        );

        assert_eq!(
            match_domain(&domain("a.baz.com"), &dns_resources_fixture),
            None
        );

        assert_eq!(
            match_domain(&domain("a.b.baz.com"), &dns_resources_fixture),
            None,
        );
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
        DomainName::vec_from_str(name).unwrap()
    }
}

use crate::client::IpProvider;
use connlib_shared::messages::{DnsServer, ResourceId};
use connlib_shared::DomainName;
use domain::base::RelativeName;
use domain::base::{
    iana::{Class, Rcode, Rtype},
    Message, MessageBuilder, ToName,
};
use domain::rdata::AllRecordData;
use ip_packet::IpPacket;
use ip_packet::Packet as _;
use itertools::Itertools;
use pattern::{Candidate, Pattern};
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

const DNS_TTL: u32 = 1;
const REVERSE_DNS_ADDRESS_END: &str = "arpa";
const REVERSE_DNS_ADDRESS_V4: &str = "in-addr";
const REVERSE_DNS_ADDRESS_V6: &str = "ip6";
const DNS_PORT: u16 = 53;

pub struct StubResolver {
    fqdn_to_ips: HashMap<DomainName, Vec<IpAddr>>,
    ips_to_fqdn: HashMap<IpAddr, (DomainName, ResourceId)>,
    ip_provider: IpProvider,
    /// All DNS resources we know about, indexed by the glob pattern they match against.
    dns_resources: HashMap<Pattern, ResourceId>,
    /// Fixed dns name that will be resolved to fixed ip addrs, similar to /etc/hosts
    known_hosts: KnownHosts,
}

/// Tells the Client how to reply to a single DNS query
#[derive(Debug)]
pub(crate) enum ResolveStrategy {
    /// The query is for a Resource, we have an IP mapped already, and we can respond instantly
    LocalResponse(IpPacket<'static>),
    /// The query is for a non-Resource, forward it to an upstream or system resolver.
    ForwardQuery {
        upstream: SocketAddr,
        original_src: SocketAddr,
        query_id: u16,
        payload: Vec<u8>,
    },
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

    pub(crate) fn add_resource(&mut self, id: ResourceId, pattern: String) -> bool {
        let parsed_pattern = match Pattern::new(&pattern) {
            Ok(p) => p,
            Err(e) => {
                tracing::warn!(%pattern, "Domain pattern is not valid: {e}");
                return false;
            }
        };

        let existing = self.dns_resources.insert(parsed_pattern, id);

        existing.is_none()
    }

    pub(crate) fn remove_resource(&mut self, id: ResourceId) {
        self.dns_resources.retain(|_, r| *r != id);
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

    /// Attempts to match the given domain against our list of possible patterns.
    ///
    /// This performs a linear search and is thus O(N) and **must not** be called in the hot-path of packet routing.
    fn match_resource(&self, domain_name: &DomainName) -> Option<ResourceId> {
        let name = Candidate::from_domain(domain_name);

        for (pattern, id) in &self.dns_resources {
            if pattern.matches(&name) {
                return Some(*id);
            }
        }

        None
    }

    fn resource_address_name_by_reservse_dns(
        &self,
        reverse_dns_name: &DomainName,
    ) -> Option<DomainName> {
        let address = reverse_dns_addr(&reverse_dns_name.to_string())?;
        let (domain, _) = self.ips_to_fqdn.get(&address)?;

        Some(domain.clone())
    }

    fn knows_resource(&self, resource: &ResourceId) -> bool {
        self.dns_resources.values().contains(resource)
    }

    /// Parses an incoming packet as a DNS query and decides how to respond to it
    ///
    /// Returns:
    /// - `None` if the packet is not a valid DNS query destined for one of our sentinel resolvers
    /// - Otherwise, a strategy for responding to the query
    pub(crate) fn handle(
        &mut self,
        dns_mapping: &bimap::BiMap<IpAddr, DnsServer>,
        packet: IpPacket,
    ) -> Option<ResolveStrategy> {
        let upstream = dns_mapping.get_by_left(&packet.destination())?.address();
        let datagram = packet.as_udp()?;

        // We only support DNS on port 53.
        if datagram.get_destination() != DNS_PORT {
            return None;
        }

        let message = Message::from_octets(datagram.payload()).ok()?;

        if message.header().qr() {
            return None;
        }

        // We don't need to support multiple questions/qname in a single query because
        // nobody does it and since this run with each packet we want to squeeze as much optimization
        // as we can therefore we won't do it.
        //
        // See: https://stackoverflow.com/a/55093896
        let question = message.first_question()?;
        let domain = question.qname().to_vec();
        let qtype = question.qtype();

        tracing::trace!("Parsed packet as DNS query: '{qtype} {domain}'");

        if let Some(records) = self.known_hosts.get_records(qtype, &domain) {
            let response = build_dns_with_answer(message, domain, records)?;
            let packet = ip_packet::make::udp_packet(
                packet.destination(),
                packet.source(),
                datagram.get_destination(),
                datagram.get_source(),
                response,
            )
            .expect("src and dst come from the same packet")
            .into_immutable();

            return Some(ResolveStrategy::LocalResponse(packet));
        }

        // `match_resource` is `O(N)` which we deem fine for DNS queries.
        let maybe_resource = self.match_resource(&domain);

        let resource_records = match (qtype, maybe_resource) {
            (_, Some(resource)) if !self.knows_resource(&resource) => {
                return Some(ResolveStrategy::ForwardQuery {
                    upstream,
                    query_id: message.header().id(),
                    payload: message.into_octets().to_vec(),
                    original_src: SocketAddr::new(packet.source(), datagram.get_source()),
                })
            }
            (Rtype::A, Some(resource)) => self.get_or_assign_a_records(domain.clone(), resource),
            (Rtype::AAAA, Some(resource)) => {
                self.get_or_assign_aaaa_records(domain.clone(), resource)
            }
            (Rtype::PTR, _) => {
                let fqdn = self.resource_address_name_by_reservse_dns(&domain)?;

                vec![AllRecordData::Ptr(domain::rdata::Ptr::new(fqdn))]
            }
            _ => {
                return Some(ResolveStrategy::ForwardQuery {
                    upstream,
                    query_id: message.header().id(),
                    payload: message.into_octets().to_vec(),
                    original_src: SocketAddr::new(packet.source(), datagram.get_source()),
                })
            }
        };

        let response = build_dns_with_answer(message, domain, resource_records)?;
        let packet = ip_packet::make::udp_packet(
            packet.destination(),
            packet.source(),
            datagram.get_destination(),
            datagram.get_source(),
            response,
        )
        .expect("src and dst come from the same packet")
        .into_immutable();

        Some(ResolveStrategy::LocalResponse(packet))
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

fn build_dns_with_answer(
    message: Message<&[u8]>,
    qname: DomainName,
    records: Vec<AllRecordData<Vec<u8>, DomainName>>,
) -> Option<Vec<u8>> {
    let mut answer_builder = MessageBuilder::new_vec()
        .start_answer(&message, Rcode::NOERROR)
        .ok()?;
    answer_builder.header_mut().set_ra(true);

    for record in records {
        answer_builder
            .push((&qname, Class::IN, DNS_TTL, record))
            .ok()?;
    }

    Some(answer_builder.finish())
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

mod pattern {
    use super::*;
    use std::{convert::Infallible, fmt, str::FromStr};

    #[derive(Debug, PartialEq, Eq, Hash)]
    pub struct Pattern(glob::Pattern);

    impl fmt::Display for Pattern {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            self.0.fmt(f)
        }
    }

    impl Pattern {
        pub fn new(p: &str) -> Result<Self, glob::PatternError> {
            Ok(Self(glob::Pattern::new(&p.replace('.', "/"))?))
        }

        /// Matches a [`Candidate`] against this [`Pattern`].
        ///
        /// Matching only requires a reference, thus allowing users to test a [`Candidate`] against multiple [`Patterns`].
        pub fn matches(&self, domain: &Candidate) -> bool {
            let domain = domain.0.as_str();

            if let Some(rem) = self.0.as_str().strip_prefix("*/") {
                if domain == rem {
                    return true;
                }
            }

            self.0.matches_with(
                domain,
                glob::MatchOptions {
                    case_sensitive: false,
                    require_literal_separator: true,
                    require_literal_leading_dot: false,
                },
            )
        }
    }

    /// A candidate for matching against a domain [`Pattern`].
    ///
    /// Creates a type-safe contract that replaces `.` with `/` in the domain which is requires for pattern matching.
    pub struct Candidate(String);

    impl Candidate {
        pub fn from_domain(domain: &DomainName) -> Self {
            Self(domain.to_string().replace('.', "/"))
        }
    }

    impl FromStr for Candidate {
        type Err = Infallible;

        fn from_str(s: &str) -> Result<Self, Self::Err> {
            Ok(Self(s.replace('.', "/")))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr as _;
    use test_case::test_case;

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

    #[test_case("**.example.com", "example.com"; "double star matches root domain")]
    #[test_case("app.**.example.com", "app.bar.foo.example.com"; "double star matches multiple levels within domain")]
    #[test_case("**.example.com", "foo.example.com"; "double star matches one level")]
    #[test_case("**.example.com", "foo.bar.example.com"; "double star matches two levels")]
    #[test_case("*.example.com", "foo.example.com"; "single star matches one level")]
    #[test_case("*.example.com", "example.com"; "single star matches root domain")]
    #[test_case("foo.*.example.com", "foo.bar.example.com"; "single star matches one domain within domain")]
    #[test_case("app.*.*.example.com", "app.foo.bar.example.com"; "single star can appear on multiple levels")]
    #[test_case("app.f??.example.com", "app.foo.example.com"; "question mark matches one letter")]
    #[test_case("app.example.com", "app.example.com"; "matches literal domain")]
    fn domain_pattern_matches(pattern: &str, domain: &str) {
        let pattern = Pattern::new(pattern).unwrap();
        let candidate = Candidate::from_str(domain).unwrap();

        let matches = pattern.matches(&candidate);

        assert!(matches);
    }

    #[test_case("app.*.example.com", "app.foo.bar.example.com"; "single star does not match two level")]
    #[test_case("app.*com", "app.foo.com"; "single star does not match dot")]
    // #[test_case("app.**com", "app.foo.com"; "double star does not match dot")]
    #[test_case("app?com", "app.com"; "question mark does not match dot")]
    fn domain_pattern_does_not_match(pattern: &str, domain: &str) {
        let pattern = Pattern::new(pattern).unwrap();
        let candidate = Candidate::from_str(domain).unwrap();

        let matches = pattern.matches(&candidate);

        assert!(!matches);
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

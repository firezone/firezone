use crate::client::{IpProvider, IDS_EXPIRE};
use connlib_shared::messages::{DnsServer, ResourceId};
use connlib_shared::DomainName;
use domain::base::{
    iana::{Class, Rcode, Rtype},
    Message, MessageBuilder, ToName,
};
use domain::rdata::AllRecordData;
use ip_packet::Packet as _;
use ip_packet::{IpPacket, MutableIpPacket};
use itertools::Itertools;
use pattern::{Candidate, Pattern};
use snownet::Transmit;
use std::borrow::Cow;
use std::collections::{BTreeMap, HashMap};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::ops::ControlFlow;
use std::time::Instant;

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

    /// DNS queries that had their destination IP mangled because they are forwarded through the tunnel.
    ///
    /// The [`Instant`] tracks when the DNS query expires.
    mangled_dns_queries: HashMap<u16, Instant>,

    /// DNS queries that were forwarded to an upstream server, indexed by the DNS query ID + the server we sent it to.
    ///
    /// The value is a tuple of:
    ///
    /// - The [`SocketAddr`] is the original source IP.
    /// - The [`Instant`] tracks when the DNS query expires.
    ///
    /// We store an explicit expiry to avoid a memory leak in case of a non-responding DNS server.
    ///
    /// DNS query IDs don't appear to be unique across servers they are being sent to on some operating systems (looking at you, Windows).
    /// Hence, we need to index by ID + socket of the DNS server.
    forwarded_dns_queries: HashMap<(u16, SocketAddr), (SocketAddr, Instant)>,
}

/// Tells the Client how to reply to a single DNS query
#[derive(Debug)]
pub(crate) enum ResolveStrategy {
    /// The query is for a Resource, we have an IP mapped already, and we can respond instantly
    LocalResponse(IpPacket<'static>),
    /// The query is for a non-Resource, forward it to an upstream or system resolver.
    ForwardQuery(Transmit<'static>),
}

struct KnownHosts {
    fqdn_to_ips: BTreeMap<DomainName, Vec<IpAddr>>,
    ips_to_fqdn: BTreeMap<IpAddr, DomainName>,
}

impl KnownHosts {
    fn new(hosts: BTreeMap<String, Vec<IpAddr>>) -> KnownHosts {
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
    pub(crate) fn new(known_hosts: BTreeMap<String, Vec<IpAddr>>) -> StubResolver {
        StubResolver {
            fqdn_to_ips: Default::default(),
            ips_to_fqdn: Default::default(),
            ip_provider: IpProvider::for_resources(),
            dns_resources: Default::default(),
            known_hosts: KnownHosts::new(known_hosts),
            forwarded_dns_queries: Default::default(),
            mangled_dns_queries: Default::default(),
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
    #[tracing::instrument(level = "trace", skip_all, fields(domain))]
    fn match_resource_linear(&self, domain_name: &DomainName) -> Option<ResourceId> {
        let name = Candidate::from_domain(domain_name);

        for (pattern, id) in &self.dns_resources {
            if pattern.matches(&name) {
                tracing::trace!(%id, %pattern, "Matched domain");

                return Some(*id);
            }

            tracing::trace!(%pattern, %id, "No match");
        }

        tracing::debug!("No resources matched");

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

    /// Tries to handle a packet arriving on the TUN interface.
    ///
    /// If the packet is a DNS query, we compute a [`ResolveStrategy`].
    /// Otherwise, we continue with processing the packet.
    pub(crate) fn try_handle_tun_inbound<'p>(
        &mut self,
        dns_mapping: &bimap::BiMap<IpAddr, DnsServer>,
        mut packet: MutableIpPacket<'p>,
        forward_query_through_tunnel: impl Fn(IpAddr) -> bool,
        now: Instant,
    ) -> ControlFlow<ResolveStrategy, MutableIpPacket<'p>> {
        let Some(upstream) = dns_mapping
            .get_by_left(&packet.destination())
            .map(|s| s.address())
        else {
            return ControlFlow::Continue(packet);
        };

        let Some(datagram) = packet.as_immutable_udp() else {
            return ControlFlow::Continue(packet);
        };

        // We only support DNS on port 53.
        if datagram.get_destination() != DNS_PORT {
            return ControlFlow::Continue(packet);
        }

        let Ok(message) = Message::from_octets(datagram.payload()) else {
            return ControlFlow::Continue(packet);
        };

        if message.header().qr() {
            return ControlFlow::Continue(packet);
        }

        // We don't need to support multiple questions/qname in a single query because
        // nobody does it and since this run with each packet we want to squeeze as much optimization
        // as we can therefore we won't do it.
        //
        // See: https://stackoverflow.com/a/55093896
        let Some(question) = message.first_question() else {
            return ControlFlow::Continue(packet);
        };
        let domain = question.qname().to_vec();
        let qtype = question.qtype();

        tracing::trace!("Parsed packet as DNS query: '{qtype} {domain}'");

        if let Some(records) = self.known_hosts.get_records(qtype, &domain) {
            let Some(response) = build_dns_with_answer(message, domain, records) else {
                return ControlFlow::Continue(packet);
            };
            let packet = ip_packet::make::udp_packet(
                packet.destination(),
                packet.source(),
                datagram.get_destination(),
                datagram.get_source(),
                response,
            )
            .expect("src and dst come from the same packet")
            .into_immutable();

            return ControlFlow::Break(ResolveStrategy::LocalResponse(packet));
        }

        // `match_resource_linear` is `O(N)` which we deem fine for DNS queries.
        let maybe_resource = self.match_resource_linear(&domain);

        let resource_records = match (qtype, maybe_resource) {
            (Rtype::A, Some(resource)) => self.get_or_assign_a_records(domain.clone(), resource),
            (Rtype::AAAA, Some(resource)) => {
                self.get_or_assign_aaaa_records(domain.clone(), resource)
            }
            (Rtype::PTR, _) => {
                let Some(fqdn) = self.resource_address_name_by_reservse_dns(&domain) else {
                    return ControlFlow::Continue(packet);
                };

                vec![AllRecordData::Ptr(domain::rdata::Ptr::new(fqdn))]
            }
            _ => {
                let query_id = message.header().id();

                if forward_query_through_tunnel(upstream.ip()) {
                    tracing::trace!(old_dst = %packet.destination(), new_dst = %upstream.ip(), "Mangling DNS query to be sent through tunnel");

                    self.mangled_dns_queries.insert(query_id, now + IDS_EXPIRE);
                    packet.set_dst(upstream.ip());
                    packet.update_checksum();

                    return ControlFlow::Continue(packet);
                }

                let server = upstream;
                let original_src = SocketAddr::new(packet.source(), datagram.get_source());

                self.forwarded_dns_queries
                    .insert((query_id, server), (original_src, now + IDS_EXPIRE));

                tracing::trace!(%server, %query_id, "Forwarding DNS query");

                return ControlFlow::Break(ResolveStrategy::ForwardQuery(Transmit {
                    src: None,
                    dst: server,
                    payload: Cow::Owned(message.into_octets().to_vec()),
                }));
            }
        };

        let Some(response) = build_dns_with_answer(message, domain, resource_records) else {
            return ControlFlow::Continue(packet);
        };
        let packet = ip_packet::make::udp_packet(
            packet.destination(),
            packet.source(),
            datagram.get_destination(),
            datagram.get_source(),
            response,
        )
        .expect("src and dst come from the same packet")
        .into_immutable();

        ControlFlow::Break(ResolveStrategy::LocalResponse(packet))
    }

    pub(crate) fn try_handle_network_inbound(
        &mut self,
        dns_mapping: &bimap::BiMap<IpAddr, DnsServer>,
        from: SocketAddr,
        packet: &[u8],
    ) -> ControlFlow<IpPacket<'static>, ()> {
        // The sentinel DNS server shall be the source. If we don't have a sentinel DNS for this socket, it cannot be a DNS response.
        let Some(saddr) = dns_mapping.get_by_right(&DnsServer::from(from)) else {
            return ControlFlow::Continue(());
        };
        let sport = DNS_PORT;

        let Ok(message) = Message::from_slice(packet) else {
            return ControlFlow::Continue(());
        };
        let query_id = message.header().id();

        let Some((destination, _)) = self.forwarded_dns_queries.remove(&(query_id, from)) else {
            return ControlFlow::Continue(());
        };

        tracing::trace!(server = %from, %query_id, "Received forwarded DNS response");

        let daddr = destination.ip();
        let dport = destination.port();

        let Some(ip_packet) =
            ip_packet::make::udp_packet(*saddr, daddr, sport, dport, packet.to_vec())
                .inspect_err(|_| tracing::warn!("Failed to find original dst for DNS response"))
                .ok()
        else {
            return ControlFlow::Continue(());
        };

        ControlFlow::Break(ip_packet.into_immutable())
    }

    pub(crate) fn try_handle_tunnel_inbound<'p>(
        &mut self,
        dns_mapping: &bimap::BiMap<IpAddr, DnsServer>,
        mut packet: MutableIpPacket<'p>,
        now: Instant,
    ) -> MutableIpPacket<'p> {
        let src_ip = packet.source();

        let Some(udp) = packet.as_udp() else {
            return packet;
        };

        let src_port = udp.get_source();

        let Some(sentinel) = dns_mapping.get_by_right(&DnsServer::from((src_ip, src_port))) else {
            return packet;
        };

        let Ok(message) = domain::base::Message::from_slice(udp.payload()) else {
            return packet;
        };

        let Some(query_sent_at) = self
            .mangled_dns_queries
            .remove(&message.header().id())
            .map(|expires_at| expires_at - IDS_EXPIRE)
        else {
            return packet;
        };

        let rtt = now.duration_since(query_sent_at);

        let domains = message
            .question()
            .filter_map(|q| Some(q.ok()?.into_qname()))
            .join(",");

        tracing::trace!(old_src = %src_ip, new_src = %sentinel, ?rtt, %domains, "Mangling DNS response from CIDR resource");

        packet.set_src(*sentinel);
        packet.update_checksum();

        packet
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        self.forwarded_dns_queries.retain(|_, (_, exp)| now < *exp);
        self.mangled_dns_queries.retain(|_, exp| now < *exp);
    }

    pub(crate) fn poll_timeout(&self) -> Option<Instant> {
        // The number of mangled DNS queries is expected to be fairly small because we only track them whilst connecting to a CIDR resource that is a DNS server.
        // Thus, sorting these values on-demand even within `poll_timeout` is expected to be performant enough.
        let next_dns_query_expiry = self.mangled_dns_queries.values().min().copied();

        // TODO: Also include forwarded DNS queries here.

        next_dns_query_expiry
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
    let pattern = match Pattern::new(resource) {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!(%resource, "Unable to parse pattern: {e}");
            return false;
        }
    };

    let candidate = Candidate::from_domain(name);

    pattern.matches(&candidate)
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
    hosts: &BTreeMap<String, Vec<IpAddr>>,
) -> BTreeMap<DomainName, Vec<IpAddr>> {
    hosts
        .iter()
        .filter_map(|(d, a)| DomainName::vec_from_str(d).ok().map(|d| (d, a.clone())))
        .collect()
}

fn ips_to_fqdn_for_known_hosts(
    hosts: &BTreeMap<String, Vec<IpAddr>>,
) -> BTreeMap<IpAddr, DomainName> {
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
    pub struct Pattern {
        inner: glob::Pattern,
        original: String,
    }

    impl fmt::Display for Pattern {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            self.original.fmt(f)
        }
    }

    impl Pattern {
        pub fn new(p: &str) -> Result<Self, glob::PatternError> {
            Ok(Self {
                inner: glob::Pattern::new(&p.replace('.', "/"))?,
                original: p.to_string(),
            })
        }

        /// Matches a [`Candidate`] against this [`Pattern`].
        ///
        /// Matching only requires a reference, thus allowing users to test a [`Candidate`] against multiple [`Pattern`]s.
        pub fn matches(&self, domain: &Candidate) -> bool {
            let domain = domain.0.as_str();

            if let Some(rem) = self.inner.as_str().strip_prefix("*/") {
                if domain == rem {
                    return true;
                }
            }

            self.inner.matches_with(
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

    #[test]
    fn pattern_displays_without_slash() {
        let pattern = Pattern::new("**.example.com").unwrap();

        assert_eq!(pattern.to_string(), "**.example.com")
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
    #[test_case("*?*.example.com", "app.example.com"; "mix of * and ?")]
    #[test_case("app.**.web.**.example.com", "app.web.example.com"; "multiple double star within domain")]

    fn domain_pattern_matches(pattern: &str, domain: &str) {
        let pattern = Pattern::new(pattern).unwrap();
        let candidate = Candidate::from_str(domain).unwrap();

        let matches = pattern.matches(&candidate);

        assert!(matches);
    }

    #[test_case("app.*.example.com", "app.foo.bar.example.com"; "single star does not match two level")]
    #[test_case("app.*com", "app.foo.com"; "single star does not match dot")]
    #[test_case("app?com", "app.com"; "question mark does not match dot")]
    fn domain_pattern_does_not_match(pattern: &str, domain: &str) {
        let pattern = Pattern::new(pattern).unwrap();
        let candidate = Candidate::from_str(domain).unwrap();

        let matches = pattern.matches(&candidate);

        assert!(!matches);
    }
}

#[cfg(feature = "divan")]
mod benches {
    use super::*;
    use rand::{distributions::DistString, seq::IteratorRandom, Rng};

    #[divan::bench(
        consts = [10, 100, 1_000, 10_000, 100_000]
    )]
    fn match_domain_linear<const NUM_RES: u128>(bencher: divan::Bencher) {
        bencher
            .with_inputs(|| {
                let mut resolver = StubResolver::new(BTreeMap::default());
                let mut rng = rand::thread_rng();

                for n in 0..NUM_RES {
                    resolver.add_resource(ResourceId::from_u128(n), make_domain(&mut rng));
                }

                let needle = resolver
                    .dns_resources
                    .keys()
                    .choose(&mut rng)
                    .unwrap()
                    .to_string();

                let needle = DomainName::vec_from_str(&needle).unwrap();

                (resolver, needle)
            })
            .bench_refs(|(resolver, needle)| resolver.match_resource_linear(needle).unwrap());
    }

    fn make_domain(rng: &mut impl Rng) -> String {
        (0..rng.gen_range(2..5))
            .map(|_| rand::distributions::Alphanumeric.sample_string(rng, 3))
            .join(".")
    }
}

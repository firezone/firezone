use crate::client::IpProvider;
use anyhow::{Context, Result};
use connlib_model::{DomainName, ResourceId};
use dns_over_tcp::SocketHandle;
use domain::rdata::AllRecordData;
use domain::{
    base::{
        iana::{Class, Rcode, Rtype},
        Message, MessageBuilder, ToName,
    },
    dep::octseq::OctetsInto,
};
use firezone_logging::{anyhow_dyn_err, std_dyn_err, telemetry_span};
use itertools::Itertools;
use pattern::{Candidate, Pattern};
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::LazyLock;
use std::{
    collections::{BTreeMap, HashMap},
    net::SocketAddr,
};

const DNS_TTL: u32 = 1;
const REVERSE_DNS_ADDRESS_END: &str = "arpa";
const REVERSE_DNS_ADDRESS_V4: &str = "in-addr";
const REVERSE_DNS_ADDRESS_V6: &str = "ip6";
pub(crate) const DNS_PORT: u16 = 53;

/// The DNS over HTTPS canary domain used by Firefox to check whether DoH can be enabled by default.
///
/// Responding to queries for this domain with NXDOMAIN will disable DoH.
/// See <https://support.mozilla.org/en-US/kb/canary-domain-use-application-dnsnet>.
/// For Chrome and other Chrome-based browsers, this is not required as
/// Chrome will automatically disable DoH if your server(s) don't support
/// it. See <https://www.chromium.org/developers/dns-over-https/#faq>.
static DOH_CANARY_DOMAIN: LazyLock<DomainName> = LazyLock::new(|| {
    DomainName::vec_from_str("use-application-dns.net")
        .expect("static domain name should always parse")
});

pub struct StubResolver {
    fqdn_to_ips: BTreeMap<(DomainName, ResourceId), Vec<IpAddr>>,
    ips_to_fqdn: HashMap<IpAddr, (DomainName, ResourceId)>,
    ip_provider: IpProvider,
    /// All DNS resources we know about, indexed by the glob pattern they match against.
    dns_resources: BTreeMap<Pattern, ResourceId>,
}

/// A query that needs to be forwarded to an upstream DNS server for resolution.
#[derive(Debug)]
pub(crate) struct RecursiveQuery {
    pub server: SocketAddr,
    pub message: Message<Vec<u8>>,
    pub transport: Transport,
}

/// A response to a [`RecursiveQuery`].
#[derive(Debug)]
pub(crate) struct RecursiveResponse {
    pub server: SocketAddr,
    pub query: Message<Vec<u8>>,
    pub message: io::Result<Message<Vec<u8>>>,
    pub transport: Transport,
}

impl RecursiveQuery {
    pub(crate) fn via_udp(source: SocketAddr, server: SocketAddr, message: Message<&[u8]>) -> Self {
        Self {
            server,
            message: message.octets_into(),
            transport: Transport::Udp { source },
        }
    }

    pub(crate) fn via_tcp(
        source: SocketHandle,
        server: SocketAddr,
        message: Message<Vec<u8>>,
    ) -> Self {
        Self {
            server,
            message,
            transport: Transport::Tcp { source },
        }
    }
}

#[derive(Debug)]
pub(crate) enum Transport {
    Udp {
        /// The original source we received the DNS query on.
        source: SocketAddr,
    },
    Tcp {
        source: SocketHandle,
    },
}

/// Tells the Client how to reply to a single DNS query
#[derive(Debug)]
pub(crate) enum ResolveStrategy {
    /// The query is for a Resource, we have an IP mapped already, and we can respond instantly
    LocalResponse(Message<Vec<u8>>),
    /// The query is for a non-Resource, forward it to an upstream or system resolver.
    Recurse,
}

impl StubResolver {
    pub(crate) fn new() -> StubResolver {
        StubResolver {
            fqdn_to_ips: Default::default(),
            ips_to_fqdn: Default::default(),
            ip_provider: IpProvider::for_resources(),
            dns_resources: Default::default(),
        }
    }

    /// Attempts to resolve an IP to a given resource.
    ///
    /// Semantically, this is like a PTR query, i.e. we check whether we handed out this IP as part of answering a DNS query for one of our resources.
    /// This is in the hot-path of packet routing and must be fast!
    pub(crate) fn resolve_resource_by_ip(&self, ip: &IpAddr) -> Option<&(DomainName, ResourceId)> {
        self.ips_to_fqdn.get(ip)
    }

    pub(crate) fn resolved_resources(
        &self,
    ) -> impl Iterator<Item = (&DomainName, &ResourceId, &Vec<IpAddr>)> + '_ {
        self.fqdn_to_ips
            .iter()
            .map(|((domain, resource), ips)| (domain, resource, ips))
    }

    pub(crate) fn add_resource(&mut self, id: ResourceId, pattern: String) -> bool {
        let parsed_pattern = match Pattern::new(&pattern) {
            Ok(p) => p,
            Err(e) => {
                tracing::warn!(error = std_dyn_err(&e), %pattern, "Domain pattern is not valid");
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
            .entry((fqdn.clone(), resource_id))
            .or_insert_with(|| {
                let mut ips = self.ip_provider.get_n_ipv4(4);
                ips.extend_from_slice(&self.ip_provider.get_n_ipv6(4));

                tracing::debug!(domain = %fqdn, ?ips, "Assigning proxy IPs");

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
    fn match_resource_linear(&self, domain: &DomainName) -> Option<ResourceId> {
        let _span = telemetry_span!("match_resource_linear").entered();

        let name = Candidate::from_domain(domain);

        for (pattern, id) in &self.dns_resources {
            if pattern.matches(&name) {
                tracing::trace!(%id, %pattern, %domain, "Matched resource");

                return Some(*id);
            }
        }

        if tracing::enabled!(tracing::Level::TRACE) {
            let patterns = self.dns_resources.keys().join(" | ");
            let patterns = format!("[{patterns}]");

            tracing::trace!(%domain, %patterns, "No resources matched");
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

    /// Processes the incoming DNS query.
    ///
    /// Any errors will result in an immediate `SERVFAIL` response.
    pub(crate) fn handle(&mut self, message: Message<&[u8]>) -> ResolveStrategy {
        match self.try_handle(message) {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(error = anyhow_dyn_err(&e), "Failed to handle DNS query");

                ResolveStrategy::LocalResponse(servfail(message))
            }
        }
    }

    fn try_handle(&mut self, message: Message<&[u8]>) -> Result<ResolveStrategy> {
        anyhow::ensure!(
            !message.header().qr(),
            "Can only handle DNS queries, not responses"
        );

        // We don't need to support multiple questions/qname in a single query because
        // nobody does it and since this run with each packet we want to squeeze as much optimization
        // as we can therefore we won't do it.
        //
        // See: https://stackoverflow.com/a/55093896
        let question = message
            .sole_question()
            .context("Expected a single 'question'")?;
        let domain = question.qname().to_vec();
        let qtype = question.qtype();

        tracing::trace!("Parsed packet as DNS query: '{qtype} {domain}'");

        if domain == *DOH_CANARY_DOMAIN {
            let payload = MessageBuilder::new_vec()
                .start_answer(&message, Rcode::NXDOMAIN)
                .context("Failed to create answer from DNS query")?
                .into_message();

            return Ok(ResolveStrategy::LocalResponse(payload));
        }

        // `match_resource` is `O(N)` which we deem fine for DNS queries.
        let maybe_resource = self.match_resource_linear(&domain);

        let resource_records = match (qtype, maybe_resource) {
            (Rtype::A, Some(resource)) => self.get_or_assign_a_records(domain.clone(), resource),
            (Rtype::AAAA, Some(resource)) => {
                self.get_or_assign_aaaa_records(domain.clone(), resource)
            }
            (Rtype::PTR, _) => {
                let Some(fqdn) = self.resource_address_name_by_reservse_dns(&domain) else {
                    return Ok(ResolveStrategy::Recurse);
                };

                vec![AllRecordData::Ptr(domain::rdata::Ptr::new(fqdn))]
            }
            (Rtype::HTTPS, Some(_)) => {
                // We must intercept queries for the HTTPS record type to force the client to issue an A / AAAA query instead.
                // Otherwise, the client won't use the IPs we issue for a particular domain and the traffic cannot be tunneled.

                let response = build_dns_with_answer(message, domain, Vec::default())?;
                return Ok(ResolveStrategy::LocalResponse(response));
            }
            _ => return Ok(ResolveStrategy::Recurse),
        };

        tracing::trace!(%qtype, %domain, records = ?resource_records, "Forming DNS response");

        let response = build_dns_with_answer(message, domain, resource_records)?;
        Ok(ResolveStrategy::LocalResponse(response))
    }
}

pub fn servfail(message: Message<&[u8]>) -> Message<Vec<u8>> {
    MessageBuilder::new_vec()
        .start_answer(&message, Rcode::SERVFAIL)
        .expect("should always be able to create a heap-allocated SERVFAIL message")
        .into_message()
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
) -> Result<Message<Vec<u8>>> {
    let mut answer_builder = MessageBuilder::new_vec()
        .start_answer(&message, Rcode::NOERROR)
        .context("Failed to create answer from query")?;
    answer_builder.header_mut().set_ra(true);

    for record in records {
        answer_builder
            .push((&qname, Class::IN, DNS_TTL, record))
            .context("Failed to push record")?;
    }

    Ok(answer_builder.into_message())
}

pub fn is_subdomain(name: &DomainName, resource: &str) -> bool {
    let pattern = match Pattern::new(resource) {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!(error = std_dyn_err(&e), %resource, "Unable to parse pattern");
            return false;
        }
    };

    let candidate = Candidate::from_domain(name);

    pattern.matches(&candidate)
}

pub(crate) fn reverse_dns_addr(name: &str) -> Option<IpAddr> {
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

mod pattern {
    use super::*;
    use std::{convert::Infallible, fmt, str::FromStr};

    #[derive(Eq)]
    pub struct Pattern {
        inner: glob::Pattern,
        original: String,
    }

    impl std::hash::Hash for Pattern {
        fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
            self.original.hash(state)
        }
    }

    impl fmt::Debug for Pattern {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.debug_tuple("Pattern").field(&self.original).finish()
        }
    }

    impl PartialEq for Pattern {
        fn eq(&self, other: &Self) -> bool {
            self.original == other.original
        }
    }

    impl fmt::Display for Pattern {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            self.original.fmt(f)
        }
    }

    impl PartialOrd for Pattern {
        fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
            Some(self.cmp(other))
        }
    }

    impl Ord for Pattern {
        fn cmp(&self, other: &Self) -> std::cmp::Ordering {
            // Iterate over characters in reverse order so that e.g. `*.example.com` and `subdomain.example.com` will compare the `example.com` suffix
            let mut self_rev = self.original.chars().rev();
            let mut other_rev = other.original.chars().rev();

            loop {
                let self_next = self_rev.next();
                let other_next = other_rev.next();

                match (self_next, other_next) {
                    (Some(self_char), Some(other_char)) if self_char == other_char => {
                        continue;
                    }
                    // `*` > `?`
                    (Some('*'), Some('?')) => break std::cmp::Ordering::Greater,
                    (Some('?'), Some('*')) => break std::cmp::Ordering::Less,

                    // Domains that only differ in wildcard come later
                    (Some('*') | Some('?'), None | Some('.')) => break std::cmp::Ordering::Greater,
                    (None | Some('.'), Some('*') | Some('?')) => break std::cmp::Ordering::Less,

                    // `*` | `?` > non-wildcard
                    (Some('*') | Some('?'), Some(_)) => break std::cmp::Ordering::Greater,
                    (Some(_), Some('*') | Some('?')) => break std::cmp::Ordering::Less,

                    // non-wildcard lexically
                    (Some(self_char), Some(other_char)) => {
                        break self_char.cmp(&other_char).reverse(); // Reverse because we compare from right to left.
                    }

                    // Shorter domains come first
                    (Some(_), None) => break std::cmp::Ordering::Greater,
                    (None, Some(_)) => break std::cmp::Ordering::Less,

                    (None, None) => break std::cmp::Ordering::Equal,
                }
            }
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

    #[cfg(test)]
    mod tests {
        use std::collections::BTreeSet;

        use super::*;

        #[test]
        fn pattern_ordering() {
            let patterns = BTreeSet::from([
                Pattern::new("**.example.com").unwrap(),
                Pattern::new("bar.example.com").unwrap(),
                Pattern::new("foo.example.com").unwrap(),
                Pattern::new("example.com").unwrap(),
                Pattern::new("*ample.com").unwrap(),
                Pattern::new("*.bar.example.com").unwrap(),
                Pattern::new("?.example.com").unwrap(),
                Pattern::new("*.com").unwrap(),
                Pattern::new("*.example.com").unwrap(),
            ]);

            assert_eq!(
                Vec::from_iter(patterns),
                vec![
                    Pattern::new("example.com").unwrap(), // Shorter domains first.
                    Pattern::new("bar.example.com").unwrap(), // Lexical-ordering by default.
                    Pattern::new("*.bar.example.com").unwrap(), // Lexically takes priority over specific match.
                    Pattern::new("foo.example.com").unwrap(),   // Most specific next.
                    Pattern::new("?.example.com").unwrap(),     // Single-wildcard second.
                    Pattern::new("*.example.com").unwrap(),     // Star-wildcard third.
                    Pattern::new("**.example.com").unwrap(),    // Double-star wildcard last.
                    Pattern::new("*ample.com").unwrap(), // Specific match takes priority over wildcard.
                    Pattern::new("*.com").unwrap(),      // Wildcards after all non-wildcards.
                ]
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use domain::base::Question;
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

    #[test]
    fn prioritises_non_wildcard_over_wildcard_domain() {
        let mut resolver = StubResolver::new();
        let wc = ResourceId::from_u128(0);
        let non_wc = ResourceId::from_u128(1);

        resolver.add_resource(wc, "**.example.com".to_owned());
        resolver.add_resource(non_wc, "foo.example.com".to_owned());

        let resource_id = resolver
            .match_resource_linear(&"foo.example.com".parse().unwrap())
            .unwrap();

        assert_eq!(resource_id, non_wc);
    }

    #[test]
    fn doh_canary_domain_parses_correctly() {
        assert_eq!(DOH_CANARY_DOMAIN.to_string(), "use-application-dns.net")
    }

    #[test]
    fn query_for_doh_canary_domain_records_nx_domain() {
        let mut resolver = StubResolver::new();

        let mut builder = MessageBuilder::new_vec().question();
        builder
            .push(Question::new_in(
                "use-application-dns.net".parse::<DomainName>().unwrap(),
                Rtype::A,
            ))
            .unwrap();
        let query = builder.into_message();

        let ResolveStrategy::LocalResponse(response) = resolver.handle(query.for_slice_ref())
        else {
            panic!("Unexpected result")
        };

        assert_eq!(response.header().rcode(), Rcode::NXDOMAIN);
        assert_eq!(response.answer().unwrap().count(), 0);
    }
}

#[cfg(feature = "divan")]
#[allow(clippy::unwrap_used)]
mod benches {
    use super::*;
    use rand::{distributions::DistString, seq::IteratorRandom, Rng};

    #[divan::bench(
        consts = [10, 100, 1_000, 10_000, 100_000]
    )]
    fn match_domain_linear<const NUM_RES: u128>(bencher: divan::Bencher) {
        bencher
            .with_inputs(|| {
                let mut resolver = StubResolver::new();
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

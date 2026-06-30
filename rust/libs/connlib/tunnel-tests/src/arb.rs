//! Structured (`arbitrary`-driven) input layer for the tunnel fuzzer.
//!
//! Where [`crate::fuzz::run_fuzz_case`] folds the whole libFuzzer input into a
//! ChaCha seed and runs the *proptest* strategies, this module reads the input
//! positionally through a single [`arbitrary::Unstructured`]: a contiguous span
//! of bytes drives each individual decision. That preserves *mutation locality*
//! — flipping or removing a byte changes one decision rather than rekeying the
//! entire scenario — so libFuzzer's coverage-guided mutations and minimization
//! become meaningful.
//!
//! The bet only pays off if **no** decision spins on a rejection-sampling loop,
//! because `Unstructured` returns zeros / `Err` once exhausted (the same failure
//! mode that motivated the ChaCha seed). Every uniqueness constraint is therefore
//! made correct-by-construction:
//!
//! * socket IPs come from per-run [`SubnetCursor`]s (never repeat),
//! * site / client / gateway / relay / resource ids from monotonic counters,
//! * private keys carry a counter in their first bytes.
//!
//! Tunnel / interface IPs stay inside [`StubPortal::new`] from its shared
//! iterator, preserving the static-device-pool invariant (only *socket* IPs move
//! to cursors).
//!
//! Residual payload-level preconditions (e.g. `new_address != old_address`) are
//! not satisfiable purely by construction, so the loop keeps a **bounded**
//! "draw, check, skip" validity gate via [`ReferenceState::is_valid_transition`].

use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::{Duration, Instant},
};

use arbitrary::Unstructured;
use chrono::{DateTime, Utc};
use connlib_model::{ClientId, GatewayId, IpStack, RelayId, ResourceId, Site, SiteId};
use dns_types::{DomainName, OwnedRecordData, RecordType};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use tunnel::client::{CidrResource, DnsResource, DynamicDevicePoolResource, InternetResource};
use tunnel::dns;
use tunnel::malicious_behaviour::MaliciousBehaviour;
use tunnel::messages::{Filter, PortRange, UpstreamDo53, UpstreamDoH, client::DevicePoolMember};

use crate::dns_records::DnsRecords;
use crate::flux_capacitor::FluxCapacitor;
use crate::icmp_error_hosts::IcmpErrorHosts;
use crate::ref_client::RefClient;
use crate::ref_gateway::RefGateway;
use crate::reference::{PrivateKey, ReferenceState};
use crate::sim_net::{Host, RoutingTable};
use crate::stub_portal::StubPortal;
use crate::sut::TunnelTest;
use crate::transition::{
    DPort, Destination, DnsQuery, DnsTransport, Identifier, SPort, Seq, Transition,
};

/// Upper bound on transitions applied per case (the proptest suite uses 5..=15).
const MAX_TRANSITIONS: usize = 20;

/// Hard cap on sampling attempts, so a case always terminates even if many
/// sampled transitions fail their pre-conditions in the current state.
const MAX_ATTEMPTS: usize = 400;

/// Hands out a fresh address per call from a fixed subnet.
///
/// Uniqueness is structural: the iterator never repeats, so no "network IPs must
/// be unique" filter is ever needed.
struct SubnetCursor<A> {
    iter: Box<dyn Iterator<Item = A>>,
}

impl SubnetCursor<Ipv4Addr> {
    fn over(net: Ipv4Network) -> Self {
        Self {
            iter: Box::new(net.hosts()),
        }
    }

    /// Assert (don't wrap) on exhaustion: wrapping would silently reintroduce
    /// the collisions the cursor exists to prevent. The ranges are sized so the
    /// bounded worst case (initial hosts + per-transition roams / relays) stays
    /// far below capacity.
    fn next(&mut self) -> Ipv4Addr {
        self.iter.next().expect("socket subnet (v4) exhausted")
    }
}

impl SubnetCursor<Ipv6Addr> {
    fn over(net: Ipv6Network) -> Self {
        Self {
            iter: Box::new(net.subnets_with_prefix(128).map(|n| n.network_address())),
        }
    }

    fn next(&mut self) -> Ipv6Addr {
        self.iter.next().expect("socket subnet (v6) exhausted")
    }
}

/// The shared generation context: an [`Unstructured`] plus every by-construction
/// allocator that replaces a proptest rejection loop.
struct Gen<'a, 'u> {
    u: &'a mut Unstructured<'u>,

    // Disjoint socket-IP allocators (host routing IPs, distinct from connlib's
    // reserved ranges and from each other).
    socket_ip4: SubnetCursor<Ipv4Addr>, // 203.0.113.0/24 (TEST-NET-3), today's host_ip4s
    socket_ip6: SubnetCursor<Ipv6Addr>, // 2001:db80:1010:1010::/64
    do53_ip4: SubnetCursor<Ipv4Addr>,   // 192.18.0.0/24 (benchmarking range, RFC2544)
    do53_ip6: SubnetCursor<Ipv6Addr>,   // 2001:db80:53:53::/64

    // Monotonic id counters (uniqueness by counter, not by set-dedup resampling).
    next_site: u64,
    next_client: u64,
    next_gateway: u64,
    next_relay: u64,
    next_resource: u64,

    // Monotonic key counter.
    next_key: u32,
}

impl<'a, 'u> Gen<'a, 'u> {
    fn new(u: &'a mut Unstructured<'u>) -> Self {
        Self {
            u,
            socket_ip4: SubnetCursor::<Ipv4Addr>::over("203.0.113.0/24".parse().unwrap()),
            socket_ip6: SubnetCursor::<Ipv6Addr>::over(
                Ipv6Network::new_truncate(
                    Ipv6Addr::new(0x2001, 0xDB80, 0x1010, 0x1010, 0, 0, 0, 0),
                    64,
                )
                .unwrap(),
            ),
            do53_ip4: SubnetCursor::<Ipv4Addr>::over("192.18.0.0/24".parse().unwrap()),
            do53_ip6: SubnetCursor::<Ipv6Addr>::over(
                Ipv6Network::new_truncate(
                    Ipv6Addr::new(0x2001, 0xDB80, 0x53, 0x53, 0, 0, 0, 0),
                    64,
                )
                .unwrap(),
            ),
            next_site: 0,
            next_client: 0,
            next_gateway: 0,
            next_relay: 0,
            next_resource: 0,
            next_key: 0,
        }
    }

    fn is_empty(&self) -> bool {
        self.u.is_empty()
    }

    // --- the locality-preserving byte primitives the generators use ---

    /// Bounded count; on exhaustion returns the minimum so invariant-bearing
    /// collections degrade to their smallest legal size, never empty / unbounded.
    fn count(&mut self, lo: usize, hi: usize) -> usize {
        self.u.int_in_range(lo..=hi).unwrap_or(lo)
    }

    /// Pick an index in `0..len`. Exhaustion (and `len == 0`) yields 0.
    fn choose_index(&mut self, len: usize) -> usize {
        if len == 0 {
            return 0;
        }
        self.u.int_in_range(0..=len - 1).unwrap_or(0)
    }

    /// Heads with the given percentage probability.
    fn flip(&mut self, heads_pct: u8) -> bool {
        self.u.int_in_range(0..=99u32).unwrap_or(0) < heads_pct as u32
    }

    fn bool(&mut self) -> bool {
        self.u.arbitrary().unwrap_or(false)
    }

    fn u16(&mut self) -> u16 {
        self.u.arbitrary().unwrap_or(0)
    }

    fn u64(&mut self) -> u64 {
        self.u.arbitrary().unwrap_or(0)
    }

    fn u32(&mut self) -> u32 {
        self.u.arbitrary().unwrap_or(0)
    }

    fn fresh_site_id(&mut self) -> SiteId {
        let n = self.next_site;
        self.next_site += 1;
        SiteId::from_u128(u128::from(n) << 64)
    }

    fn fresh_client_id(&mut self) -> ClientId {
        let n = self.next_client;
        self.next_client += 1;
        ClientId::from_u128(u128::from(n) << 64)
    }

    fn fresh_gateway_id(&mut self) -> GatewayId {
        let n = self.next_gateway;
        self.next_gateway += 1;
        GatewayId::from_u128(u128::from(n) << 64)
    }

    fn fresh_relay_id(&mut self) -> RelayId {
        let n = self.next_relay;
        self.next_relay += 1;
        RelayId::from_u128(u128::from(n) << 64)
    }

    fn fresh_resource_id(&mut self) -> ResourceId {
        let n = self.next_resource;
        self.next_resource += 1;
        ResourceId::from_u128(u128::from(n) << 64)
    }

    /// Monotonic, unique private key. The counter occupies the first 4 bytes
    /// (keys are clamped and feed a deterministic HKDF, so this is harmless for
    /// test keys); the remaining bytes carry handshake entropy.
    fn fresh_private_key(&mut self) -> PrivateKey {
        let n = self.next_key;
        self.next_key += 1;
        let mut bytes = [0u8; 32];
        bytes[0..4].copy_from_slice(&n.to_be_bytes());
        let _ = self.u.fill_buffer(&mut bytes[4..]);
        PrivateKey(bytes)
    }

    fn latency(&mut self, max: u64) -> Duration {
        Duration::from_millis(self.u.int_in_range(10..=max - 1).unwrap_or(10))
    }

    /// `[a-z]{lo..=hi}`.
    fn lower_ascii(&mut self, lo: usize, hi: usize) -> String {
        let n = self.count(lo, hi);
        (0..n)
            .map(|_| (b'a' + self.u.arbitrary::<u8>().unwrap_or(0) % 26) as char)
            .collect()
    }
}

/// Drive one structured fuzz case from `data`.
///
/// Identical bytes always produce the identical scenario: `data` is read
/// left-to-right through one [`Unstructured`], the clock is fixed
/// (`utc_start = timestamp(0, 0)`), and there is no hidden RNG.
pub fn run_fuzz_case_structured(data: &[u8]) {
    let _guard = crate::init_fuzz_subscriber();

    let now = Instant::now();
    let utc_start = DateTime::<Utc>::from_timestamp(0, 0).expect("0 is a valid UNIX timestamp");
    let flux_capacitor = FluxCapacitor::new(now, utc_start);

    let mut u = Unstructured::new(data);
    let mut g = Gen::new(&mut u);

    // Generation is infallible: out-of-bytes degrades each decision to its
    // minimum/default rather than erroring, so a truncated input still yields a
    // minimal-but-valid scenario (and the loop simply applies fewer transitions).
    let mut ref_state = arb_initial_state(&mut g, now);

    let mut sut = TunnelTest::init_test(&ref_state, flux_capacitor.clone());
    TunnelTest::check_invariants(&sut, &ref_state);

    let mut applied = 0;
    for _ in 0..MAX_ATTEMPTS {
        if applied >= MAX_TRANSITIONS || g.is_empty() {
            break;
        }

        let Some(transition) = arb_transition(&mut g, &ref_state, now) else {
            break; // no legal arm
        };

        // Bounded residual validity gate (payload-level preconditions). Skipping
        // is safe: MAX_ATTEMPTS caps total iterations, so this cannot hang.
        if !ReferenceState::is_valid_transition(&ref_state, &transition) {
            continue;
        }

        if transition.should_clear_packets() {
            ReferenceState::clear_packets(&mut ref_state);
            TunnelTest::clear_packets(&mut sut);
        }

        ref_state = ReferenceState::apply(ref_state, &transition, flux_capacitor.now());
        sut = TunnelTest::apply(sut, &ref_state, transition.clone());
        TunnelTest::check_invariants(&sut, &ref_state);

        applied += 1;
    }
}

// ---------------------------------------------------------------------------
// Initial state
// ---------------------------------------------------------------------------

fn arb_initial_state(g: &mut Gen, start: Instant) -> ReferenceState {
    // 1. Portal layout. Tunnel IPs are assigned INSIDE StubPortal::new from a
    //    single shared iterator (clients -> gateways-by-site -> static-pool
    //    offline members), so the static-device-pool invariant is preserved.
    let portal = arb_stub_portal(g);

    // 2. Materialize hosts. Socket IPs come from cursors (unique by
    //    construction), keys from the keyed counter.
    let clients = arb_clients(g, &portal);
    let gateways = arb_gateways(g, &portal, start);
    let relays = arb_relays(g);

    // 3. Staged DNS dependency chain, preserved in order.
    let dns_resource_records = arb_dns_resource_records(g, &portal, start);
    let icmp_error_hosts = arb_icmp_error_hosts(g, &dns_resource_records, start);
    let tcp_resources = arb_tcp_resources(g, &dns_resource_records, &icmp_error_hosts, start);

    let mut global_dns_records = arb_global_dns_records(g, start);
    global_dns_records.merge(dns_resource_records);

    let drop_direct_client_traffic = g.bool();

    // Rebuild the routing table. Uniqueness is structural, so this never rejects;
    // a debug_assert guards against accidental collisions.
    let mut network = RoutingTable::default();
    for (id, host) in &clients {
        let ok = network.add_host(*id, host);
        debug_assert!(ok, "client socket IPs must be unique by construction");
    }
    for (id, host) in &gateways {
        let ok = network.add_host(*id, host);
        debug_assert!(ok, "gateway socket IPs must be unique by construction");
    }
    for (id, host) in &relays {
        let ok = network.add_host(*id, host);
        debug_assert!(ok, "relay socket IPs must be unique by construction");
    }

    ReferenceState::from_parts(
        clients,
        gateways,
        relays,
        portal,
        global_dns_records,
        tcp_resources,
        icmp_error_hosts,
        network,
        drop_direct_client_traffic,
    )
}

fn arb_stub_portal(g: &mut Gen) -> StubPortal {
    // Sites: 2..=4, first one becomes the Internet site.
    let n_sites = g.count(2, 4);
    let mut sites: Vec<Site> = (0..n_sites)
        .map(|_| Site {
            id: g.fresh_site_id(),
            name: g.lower_ascii(4, 10),
        })
        .collect();
    let mut internet_site = sites.remove(0);
    internet_site.name = "Internet".to_owned();
    let regular_sites = sites;

    // Clients: exactly 2.
    let clients: BTreeSet<ClientId> = (0..2).map(|_| g.fresh_client_id()).collect();

    // CIDR resources: 1..=4 (1..5).
    let n_cidr = g.count(1, 4);
    let mut cidr_resources: BTreeSet<CidrResource> = BTreeSet::new();
    for _ in 0..n_cidr {
        let site = pick_site(g, &regular_sites);
        cidr_resources.insert(arb_cidr_resource(g, vec![site]));
    }

    // DNS resources: 1..=4, each non-wildcard / `*.` / `**.`.
    let n_dns = g.count(1, 4);
    let mut dns_resources: BTreeSet<DnsResource> = BTreeSet::new();
    for _ in 0..n_dns {
        let site = pick_site(g, &regular_sites);
        dns_resources.insert(arb_dns_resource(g, vec![site]));
    }

    // Dynamic device pool resources: 0..=2.
    let n_pool = g.count(0, 2);
    let mut device_pool_resources: BTreeSet<DynamicDevicePoolResource> = BTreeSet::new();
    for _ in 0..n_pool {
        device_pool_resources.insert(arb_dynamic_device_pool_resource(g));
    }

    // Static device pool plans: 0..=3.
    let n_static = g.count(0, 3);
    let mut static_device_pool_plans = Vec::new();
    for _ in 0..n_static {
        static_device_pool_plans.push(arb_static_device_pool_plan(g));
    }

    let internet_resource = arb_internet_resource(g, vec![internet_site.clone()]);

    // Gateways per site: 1..=3 for each (Internet + regular) site.
    let mut gateways_by_site: BTreeMap<SiteId, BTreeSet<GatewayId>> = BTreeMap::new();
    for site in std::iter::once(&internet_site).chain(regular_sites.iter()) {
        let n_gw = g.count(1, 3);
        let gws: BTreeSet<GatewayId> = (0..n_gw).map(|_| g.fresh_gateway_id()).collect();
        gateways_by_site.insert(site.id, gws);
    }

    let gateway_selector = g.u32();

    let upstream_do53 = arb_upstream_do53_servers(g);
    let upstream_doh = arb_upstream_doh_servers(g);

    // Extra (overlapping) resources, mirroring `extra_cidr_resources` /
    // `extra_dns_resources`: each existing resource has a 50% chance of
    // spawning an overlapping sibling.
    let extra_cidr = arb_extra_cidr_resources(g, &cidr_resources);
    let extra_dns = arb_extra_dns_resources(g, &dns_resources);

    // Search domain derived from the (pre-extra) DNS resources.
    let search_domain = arb_search_domain(g, &dns_resources);

    cidr_resources.extend(extra_cidr);
    dns_resources.extend(extra_dns);

    // Do53-coverage augmentation: if a CIDR resource covers an upstream Do53
    // server, in 80% of cases allow udp/53 + tcp/53 through it.
    let cidr_resources: BTreeSet<CidrResource> = cidr_resources
        .into_iter()
        .map(|mut r| {
            let covers_do53 = upstream_do53.iter().any(|s| r.address.contains(s.ip));
            if covers_do53 && g.flip(80) {
                r.filters.push(Filter::Udp(PortRange {
                    port_range_start: 53,
                    port_range_end: 53,
                }));
                r.filters.push(Filter::Tcp(PortRange {
                    port_range_start: 53,
                    port_range_end: 53,
                }));
            }
            r
        })
        .collect();

    StubPortal::new(
        clients,
        gateways_by_site,
        gateway_selector,
        cidr_resources,
        dns_resources,
        device_pool_resources,
        static_device_pool_plans,
        internet_resource,
        search_domain,
        upstream_do53,
        upstream_doh,
    )
}

fn pick_site(g: &mut Gen, sites: &[Site]) -> Site {
    if sites.is_empty() {
        // Should not happen (we always have >=1 regular site), but stay total.
        return Site {
            id: g.fresh_site_id(),
            name: g.lower_ascii(4, 10),
        };
    }
    let idx = g.choose_index(sites.len());
    sites[idx].clone()
}

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

fn arb_cidr_resource(g: &mut Gen, sites: Vec<Site>) -> CidrResource {
    CidrResource {
        id: g.fresh_resource_id(),
        address: arb_cidr_resource_address(g),
        name: g.lower_ascii(4, 10),
        address_description: arb_address_description(g),
        sites,
        filters: arb_filters(g),
    }
}

fn arb_dns_resource(g: &mut Gen, sites: Vec<Site>) -> DnsResource {
    let base = arb_domain_name_string(g, 2, 3);
    let address = match g.choose_index(3) {
        0 => base,                 // non-wildcard
        1 => format!("*.{base}"),  // single star
        _ => format!("**.{base}"), // double star
    };
    DnsResource {
        id: g.fresh_resource_id(),
        address,
        name: g.lower_ascii(4, 10),
        address_description: arb_address_description(g),
        sites,
        ip_stack: arb_ip_stack_kind(g),
        filters: arb_filters(g),
    }
}

fn arb_internet_resource(g: &mut Gen, sites: Vec<Site>) -> InternetResource {
    InternetResource {
        name: "Internet Resource".to_owned(),
        id: g.fresh_resource_id(),
        sites,
    }
}

fn arb_dynamic_device_pool_resource(g: &mut Gen) -> DynamicDevicePoolResource {
    let base = arb_domain_name_string(g, 2, 3);
    DynamicDevicePoolResource {
        id: g.fresh_resource_id(),
        name: g.lower_ascii(4, 10),
        address: format!("*.{base}"),
    }
}

fn arb_static_device_pool_plan(g: &mut Gen) -> tunnel::proptest::StaticDevicePoolPlan {
    let n_online_members = g.count(0, 2);
    let n_offline = g.count(0, 2);
    let offline_members: Vec<ClientId> = (0..n_offline).map(|_| g.fresh_client_id()).collect();
    tunnel::proptest::StaticDevicePoolPlan {
        id: g.fresh_resource_id(),
        name: g.lower_ascii(4, 10),
        filters: arb_filters(g),
        n_online_members,
        offline_members,
    }
}

/// Mirrors `extra_cidr_resources`: 50% per existing resource, either same
/// address or a more-specific subnet within it.
fn arb_extra_cidr_resources(g: &mut Gen, existing: &BTreeSet<CidrResource>) -> Vec<CidrResource> {
    let mut out = Vec::new();
    for resource in existing {
        if !g.flip(50) {
            continue;
        }
        let extra_bits = match resource.address {
            IpNetwork::V4(n) => (32 - n.netmask()) as usize,
            IpNetwork::V6(n) => (128 - n.netmask()) as usize,
        };
        let address = if extra_bits > 0 && g.flip(50) {
            arb_more_specific_subnet(g, resource.address, extra_bits)
        } else {
            resource.address
        };
        out.push(CidrResource {
            id: g.fresh_resource_id(),
            address,
            name: g.lower_ascii(4, 10),
            address_description: None,
            sites: resource.sites.clone(),
            filters: arb_filters(g),
        });
    }
    out
}

/// Mirrors `extra_dns_resources`: 50% per existing resource, a same-or-more
/// specific address pattern.
fn arb_extra_dns_resources(g: &mut Gen, existing: &BTreeSet<DnsResource>) -> Vec<DnsResource> {
    let mut out = Vec::new();
    for resource in existing {
        if !g.flip(50) {
            continue;
        }

        let address = &resource.address;
        let mut candidates: Vec<String> = vec![address.clone()];
        if let Some(base) = address.strip_prefix("**.") {
            candidates.push(format!("*.{base}"));
            candidates.push(format!("{}.{base}", g.lower_ascii(3, 6)));
        } else if let Some(base) = address.strip_prefix("*.") {
            candidates.push(format!("{}.{base}", g.lower_ascii(3, 6)));
        }

        let idx = g.choose_index(candidates.len());
        let new_address = candidates[idx].clone();

        out.push(DnsResource {
            id: g.fresh_resource_id(),
            address: new_address,
            name: g.lower_ascii(4, 10),
            address_description: None,
            sites: resource.sites.clone(),
            ip_stack: resource.ip_stack,
            filters: arb_filters(g),
        });
    }
    out
}

fn arb_search_domain(g: &mut Gen, dns_resources: &BTreeSet<DnsResource>) -> Option<DomainName> {
    let candidates: Vec<DomainName> = dns_resources
        .iter()
        .filter_map(|r| {
            let (_, search) = r.address.split_once('.')?;
            DomainName::vec_from_str(search).ok()
        })
        .collect();

    if candidates.is_empty() || !g.flip(50) {
        return None;
    }
    let idx = g.choose_index(candidates.len());
    Some(candidates[idx].clone())
}

// ---------------------------------------------------------------------------
// Hosts
// ---------------------------------------------------------------------------

fn arb_clients(g: &mut Gen, portal: &StubPortal) -> BTreeMap<ClientId, Host<RefClient>> {
    let mut clients = BTreeMap::new();
    for (id, tun4, tun6) in portal.client_tunnel_ips() {
        let host = arb_client_host(g, id, tun4, tun6);
        clients.insert(id, host);
    }
    clients
}

fn arb_client_host(g: &mut Gen, id: ClientId, tun4: Ipv4Addr, tun6: Ipv6Addr) -> Host<RefClient> {
    let key = g.fresh_private_key();
    let system_dns = arb_system_dns_servers(g);
    let internet_resource_active = g.bool();
    let ignore_resource_filters = g.bool();

    let inner = RefClient::new(
        id,
        key,
        tun4,
        tun6,
        system_dns,
        internet_resource_active,
        MaliciousBehaviour {
            ignore_resource_filters,
        },
    );

    // Socket IP *shape* is byte-driven; the addresses come from the cursors.
    let (ip4, ip6) = arb_socket_ip_stack(g);
    let port = arb_listening_port(g);
    let latency = g.latency(250);
    let mut host = Host::new(inner, latency, port);
    host.update_interface(ip4, ip6);
    host
}

fn arb_gateways(
    g: &mut Gen,
    portal: &StubPortal,
    start: Instant,
) -> BTreeMap<GatewayId, Host<RefGateway>> {
    let mut gateways = BTreeMap::new();
    for (id, tun4, tun6, site_id) in portal.gateway_tunnel_ips() {
        // Gateways are always dual-stack on a fixed listening port (matching
        // `ref_gateway_host`).
        let site_specific = arb_site_specific_dns_records(g, portal, site_id, start);
        let inner = RefGateway::from_parts(g.fresh_private_key(), tun4, tun6, site_specific);
        let latency = g.latency(200);
        let mut host = Host::new(inner, latency, 52625);
        host.update_interface(Some(g.socket_ip4.next()), Some(g.socket_ip6.next()));
        gateways.insert(id, host);
    }
    gateways
}

fn arb_relays(g: &mut Gen) -> BTreeMap<RelayId, Host<u64>> {
    let n = g.count(1, 2);
    let mut relays = BTreeMap::new();
    for _ in 0..n {
        let id = g.fresh_relay_id();
        let seed = g.u64();
        let latency = g.latency(50);
        let mut host = Host::new(seed, latency, 3478);
        host.update_interface(Some(g.socket_ip4.next()), Some(g.socket_ip6.next()));
        relays.insert(id, host);
    }
    relays
}

/// V4 / V6 / Dual socket shape, addresses from the cursors so they never collide.
fn arb_socket_ip_stack(g: &mut Gen) -> (Option<Ipv4Addr>, Option<Ipv6Addr>) {
    match g.choose_index(3) {
        0 => (Some(g.socket_ip4.next()), None),
        1 => (None, Some(g.socket_ip6.next())),
        _ => (Some(g.socket_ip4.next()), Some(g.socket_ip6.next())),
    }
}

fn arb_listening_port(g: &mut Gen) -> u16 {
    match g.choose_index(3) {
        0 => 52625,
        1 => 3478,
        _ => {
            // NonZeroU16
            g.u.int_in_range(1..=u16::MAX).unwrap_or(1)
        }
    }
}

// ---------------------------------------------------------------------------
// DNS records
// ---------------------------------------------------------------------------

fn arb_dns_resource_records(g: &mut Gen, portal: &StubPortal, at: Instant) -> DnsRecords {
    let mut map = DnsRecords::default();
    for resource in portal.dns_resources() {
        let address = resource.address;
        match address.split_once('.') {
            Some(("*" | "**", base)) => {
                map.merge(arb_subdomain_records(g, base.to_owned(), at));
            }
            _ => {
                let ips = arb_resolved_ips(g);
                let domain: DomainName = address.parse().unwrap();
                map.merge(DnsRecords::from([(domain, BTreeMap::from([(at, ips)]))]));
            }
        }
    }
    map
}

/// Site-specific DNS records for a gateway: records for the DNS resources in
/// `site`, plus (when non-empty) some site-specific TXT/SRV records.
fn arb_site_specific_dns_records(
    g: &mut Gen,
    portal: &StubPortal,
    site: SiteId,
    at: Instant,
) -> DnsRecords {
    let mut map = DnsRecords::default();
    for resource in portal.dns_resources() {
        if !resource.sites.iter().any(|s| s.id == site) {
            continue;
        }
        let address = resource.address;
        match address.split_once('.') {
            Some(("*" | "**", base)) => {
                map.merge(arb_subdomain_records(g, base.to_owned(), at));
            }
            _ => {
                let ips = arb_resolved_ips(g);
                let domain: DomainName = address.parse().unwrap();
                map.merge(DnsRecords::from([(domain, BTreeMap::from([(at, ips)]))]));
            }
        }
    }
    map
}

fn arb_subdomain_records(g: &mut Gen, base: String, at: Instant) -> DnsRecords {
    let n = g.count(1, 3);
    let mut map = DnsRecords::default();
    for _ in 0..n {
        let label = g.lower_ascii(3, 6);
        let domain: DomainName = format!("{label}.{base}").parse().unwrap();
        let ips = arb_resolved_ips(g);
        map.merge(DnsRecords::from([(domain, BTreeMap::from([(at, ips)]))]));
    }
    map
}

/// 1..=5 "real" IP records drawn from the small documentation ranges (kept small
/// on purpose so two domains can share an IP).
fn arb_resolved_ips(g: &mut Gen) -> BTreeSet<OwnedRecordData> {
    let n = g.count(1, 5);
    let mut set = BTreeSet::new();
    for _ in 0..n {
        let ip = arb_dns_resource_ip(g);
        set.insert(dns_types::records::ip(ip));
    }
    set
}

fn arb_dns_resource_ip(g: &mut Gen) -> IpAddr {
    if g.bool() {
        // TEST-NET-2 198.51.100.0/24 (256 addrs, small => overlap likely).
        let last = g.u.arbitrary::<u8>().unwrap_or(0);
        IpAddr::V4(Ipv4Addr::new(198, 51, 100, last))
    } else {
        // Subnet of 2001:db8::/32.
        let n = g.u.arbitrary::<u16>().unwrap_or(0);
        IpAddr::V6(Ipv6Addr::new(0x2001, 0xDB80, 0x2020, 0x2020, 0, 0, 0, n))
    }
}

/// Global DNS records: 0..=4 domains, each with 1..=5 records (IP or TXT).
fn arb_global_dns_records(g: &mut Gen, at: Instant) -> DnsRecords {
    let n = g.count(0, 4);
    let mut map = DnsRecords::default();
    for _ in 0..n {
        let domain: DomainName = arb_domain_name_string(g, 2, 3).parse().unwrap();
        let records = arb_dns_record_set(g);
        map.merge(DnsRecords::from([(
            domain,
            BTreeMap::from([(at, records)]),
        )]));
    }
    map
}

/// 1..=5 records, weighted 3:1 IP:TXT (matching `dns_record`).
fn arb_dns_record_set(g: &mut Gen) -> BTreeSet<OwnedRecordData> {
    let n = g.count(1, 5);
    let mut set = BTreeSet::new();
    for _ in 0..n {
        let record = if g.flip(75) {
            dns_types::records::ip(arb_non_reserved_ip(g))
        } else {
            // TXT: 6..=10 sections of 255 'a's. Build it directly.
            let sections = g.count(6, 10);
            let mut content = Vec::new();
            for _ in 0..sections {
                content.push(255u8);
                content.extend(std::iter::repeat_n(b'a', 255));
            }
            match dns_types::records::txt(content) {
                Ok(r) => r,
                Err(_) => dns_types::records::ip(arb_non_reserved_ip(g)),
            }
        };
        set.insert(record);
    }
    set
}

// ---------------------------------------------------------------------------
// ICMP error hosts (H1) + TCP resources
// ---------------------------------------------------------------------------

/// Pick *exactly* `floor(n/2)` of the (deduplicated) record IPs and assign each
/// an ICMP error, matching `subsequence(ips, num_ips/2)` over a shuffle.
///
/// Implemented as a partial Fisher-Yates: we draw `floor(n/2)` distinct indices
/// uniformly, which is the faithful by-construction analog (a uniform
/// `floor(n/2)`-subset), not an independent keep-bit.
fn arb_icmp_error_hosts(g: &mut Gen, records: &DnsRecords, now: Instant) -> IcmpErrorHosts {
    let mut ips: Vec<IpAddr> = records
        .ips_iter(now)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let num_ips = ips.len();
    let pick = num_ips / 2;

    let mut chosen = Vec::with_capacity(pick);
    for i in 0..pick {
        // Select from the remaining suffix `ips[i..]`, swap into position `i`.
        let remaining = num_ips - i;
        let j = i + g.choose_index(remaining);
        ips.swap(i, j);
        chosen.push(ips[i]);
    }

    let inner: BTreeMap<IpAddr, crate::icmp_error_hosts::IcmpError> = chosen
        .into_iter()
        .map(|ip| (ip, arb_icmp_error(g)))
        .collect();

    IcmpErrorHosts::from_inner(inner)
}

fn arb_icmp_error(g: &mut Gen) -> crate::icmp_error_hosts::IcmpError {
    use crate::icmp_error_hosts::IcmpError;
    match g.choose_index(5) {
        0 => IcmpError::Network,
        1 => IcmpError::Host,
        2 => IcmpError::Port,
        3 => IcmpError::PacketTooBig { mtu: g.u32() },
        _ => IcmpError::TimeExceeded { code: 0 },
    }
}

/// Sample TCP resource addresses from the DNS records (1..=all domains), one
/// `SocketAddr` per resolved IP, dropping domains that have an ICMP-error IP.
fn arb_tcp_resources(
    g: &mut Gen,
    records: &DnsRecords,
    icmp_error_hosts: &IcmpErrorHosts,
    at: Instant,
) -> BTreeMap<DomainName, BTreeSet<SocketAddr>> {
    let all_domains: Vec<DomainName> = records.domains_iter().collect();
    if all_domains.is_empty() {
        return BTreeMap::new();
    }

    let n = g.count(1, all_domains.len());
    let mut out: BTreeMap<DomainName, BTreeSet<SocketAddr>> = BTreeMap::new();
    for _ in 0..n {
        let idx = g.choose_index(all_domains.len());
        let domain = all_domains[idx].clone();
        let port = g.u.int_in_range(1..=u16::MAX).unwrap_or(1);

        // Drop the domain if any of its IPs would produce an ICMP error.
        if records
            .domain_ips_iter(&domain, at)
            .any(|ip| icmp_error_hosts.icmp_error_for_ip(ip).is_some())
        {
            continue;
        }

        let addresses: BTreeSet<SocketAddr> = records
            .domain_ips_iter(&domain, at)
            .map(|ip| SocketAddr::new(ip, port))
            .collect();
        if !addresses.is_empty() {
            out.insert(domain, addresses);
        }
    }
    out
}

// ---------------------------------------------------------------------------
// DNS servers / upstreams / filters / addresses
// ---------------------------------------------------------------------------

/// At least one v4 and one v6 do53 server, then a subset (matching
/// `system_dns_servers` = subsequence of `do53_servers`).
fn arb_do53_pool(g: &mut Gen) -> Vec<IpAddr> {
    let n4 = g.count(1, 3);
    let n6 = g.count(1, 3);
    let mut pool = Vec::new();
    for _ in 0..n4 {
        pool.push(IpAddr::V4(g.do53_ip4.next()));
    }
    for _ in 0..n6 {
        pool.push(IpAddr::V6(g.do53_ip6.next()));
    }
    pool
}

/// Per-element keep-bit subset (a subsequence) of a fresh do53 pool.
fn arb_system_dns_servers(g: &mut Gen) -> Vec<IpAddr> {
    let pool = arb_do53_pool(g);
    pool.into_iter().filter(|_| g.bool()).collect()
}

fn arb_upstream_do53_servers(g: &mut Gen) -> Vec<UpstreamDo53> {
    let pool = arb_do53_pool(g);
    pool.into_iter()
        .filter(|_| g.bool())
        .map(|ip| UpstreamDo53 { ip })
        .collect()
}

fn arb_upstream_doh_servers(g: &mut Gen) -> Vec<UpstreamDoH> {
    // 0..=1 DoH servers (btree_set(doh_server(), 0..2)).
    let n = g.count(0, 1);
    let mut out = Vec::new();
    for _ in 0..n {
        let url = match g.choose_index(4) {
            0 => dns_types::DoHUrl::quad9(),
            1 => dns_types::DoHUrl::cloudflare(),
            2 => dns_types::DoHUrl::google(),
            _ => dns_types::DoHUrl::opendns(),
        };
        out.push(UpstreamDoH { url });
    }
    out
}

fn arb_filters(g: &mut Gen) -> Vec<Filter> {
    let n = g.count(0, 2);
    (0..n).map(|_| arb_filter(g)).collect()
}

fn arb_filter(g: &mut Gen) -> Filter {
    match g.choose_index(3) {
        0 => Filter::Icmp,
        1 => Filter::Udp(arb_port_range(g)),
        _ => Filter::Tcp(arb_port_range(g)),
    }
}

fn arb_port_range(g: &mut Gen) -> PortRange {
    let start = g.u16();
    let end = g.u.int_in_range(start..=u16::MAX).unwrap_or(start);
    PortRange {
        port_range_start: start,
        port_range_end: end,
    }
}

fn arb_address_description(g: &mut Gen) -> Option<String> {
    if g.bool() {
        Some(g.lower_ascii(4, 10))
    } else {
        None
    }
}

fn arb_ip_stack_kind(g: &mut Gen) -> IpStack {
    match g.choose_index(3) {
        0 => IpStack::Dual,
        1 => IpStack::Ipv4Only,
        _ => IpStack::Ipv6Only,
    }
}

fn arb_domain_name_string(g: &mut Gen, lo: usize, hi: usize) -> String {
    let n = g.count(lo, hi);
    let labels: Vec<String> = (0..n).map(|_| g.lower_ascii(3, 6)).collect();
    labels.join(".")
}

/// A CIDR address outside all reserved + documentation ranges (so it never
/// overlaps the host / DNS / tunnel ranges). Wrap-around repair, no rejection.
fn arb_cidr_resource_address(g: &mut Gen) -> IpNetwork {
    let ip = arb_non_reserved_ip(g);
    // host_mask_bits = 8 in the proptest path: netmask in [max-8, max].
    let mask_offset = g.count(0, 7);
    match ip {
        IpAddr::V4(v4) => {
            let netmask = 32 - mask_offset as u8;
            IpNetwork::new_truncate(IpAddr::V4(v4), netmask).unwrap()
        }
        IpAddr::V6(v6) => {
            let netmask = 128 - mask_offset as u8;
            IpNetwork::new_truncate(IpAddr::V6(v6), netmask).unwrap()
        }
    }
}

fn arb_more_specific_subnet(g: &mut Gen, address: IpNetwork, extra_bits: usize) -> IpNetwork {
    // Pick a host within `address`, then a longer prefix.
    let add = g.count(1, extra_bits.max(1));
    match address {
        IpNetwork::V4(n) => {
            let base = u32::from(n.network_address());
            let host_bits = 32 - n.netmask();
            let off = if host_bits == 0 {
                0
            } else {
                g.u32() % (1u32 << host_bits.min(31))
            };
            let ip = Ipv4Addr::from(base.wrapping_add(off));
            let netmask = (n.netmask() as usize + add).min(32) as u8;
            IpNetwork::new_truncate(IpAddr::V4(ip), netmask).unwrap()
        }
        IpNetwork::V6(n) => {
            let base = u128::from(n.network_address());
            let ip = Ipv6Addr::from(base);
            let netmask = (n.netmask() as usize + add).min(128) as u8;
            IpNetwork::new_truncate(IpAddr::V6(ip), netmask).unwrap()
        }
    }
}

/// An IP outside connlib's reserved ranges, via wrap-around repair (no rejection).
fn arb_non_reserved_ip(g: &mut Gen) -> IpAddr {
    use tunnel::client::{DNS_SENTINELS_V4, DNS_SENTINELS_V6, IPV4_RESOURCES, IPV6_RESOURCES};
    use tunnel::{IPV4_TUNNEL, IPV6_TUNNEL};

    if g.bool() {
        let undesired = [
            Ipv4Network::new(Ipv4Addr::BROADCAST, 32).unwrap(),
            Ipv4Network::new(Ipv4Addr::UNSPECIFIED, 32).unwrap(),
            Ipv4Network::new(Ipv4Addr::new(224, 0, 0, 0), 4).unwrap(),
            DNS_SENTINELS_V4,
            IPV4_RESOURCES,
            IPV4_TUNNEL,
        ];
        let mut ip = Ipv4Addr::from(g.u32());
        while let Some(range) = undesired.iter().find(|r| r.contains(ip)) {
            ip = Ipv4Addr::from(u32::from(range.broadcast_address()).wrapping_add(1));
        }
        IpAddr::V4(ip)
    } else {
        let undesired = [
            Ipv6Network::new(Ipv6Addr::UNSPECIFIED, 32).unwrap(),
            DNS_SENTINELS_V6,
            IPV6_RESOURCES,
            IPV6_TUNNEL,
            Ipv6Network::new(Ipv6Addr::new(0xff00, 0, 0, 0, 0, 0, 0, 0), 8).unwrap(),
        ];
        let hi = (g.u64() as u128) << 64;
        let lo = g.u64() as u128;
        let mut ip = Ipv6Addr::from(hi | lo);
        while let Some(range) = undesired.iter().find(|r| r.contains(ip)) {
            ip = Ipv6Addr::from(u128::from(range.last_address()).wrapping_add(1));
        }
        IpAddr::V6(ip)
    }
}

// ---------------------------------------------------------------------------
// Transitions
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug)]
enum TransitionKind {
    // Always-legal.
    UpdateSystemDnsServers,
    UpdateUpstreamDo53Servers,
    UpdateUpstreamDoHServers,
    UpdateUpstreamSearchDomain,
    RoamClient,
    DeployNewRelays,
    PartitionRelaysFromPortal,
    RebootRelaysWhilePartitioned,
    Idle,
    // State-gated.
    AddResource,
    AddResourceForQueriedDomain,
    ChangeCidrResourceAddress,
    MoveResourceToNewSite,
    ChangeFiltersOfResource,
    RemoveResource,
    ReconnectPortal,
    RestartClient,
    SetInternetResourceState,
    DeauthorizeWhileGatewayIsPartitioned,
    UpdateDnsRecords,
    // Packet arms (weight 10 each).
    Ipv4CidrPacket,
    Ipv6CidrPacket,
    ResolvedV4Packet,
    ResolvedV6Packet,
    ConnectTcpV4,
    ConnectTcpV6,
    IcmpErrorV4Packet,
    IcmpErrorV6Packet,
    // Packet arms against non-resource / gateway / peer-client IPs.
    NonResourceV4Packet,
    NonResourceV6Packet,
    GatewayV4Packet,
    GatewayV6Packet,
    PoolRoutedPacket,
    // DNS-query arms (`SendDnsQueries`).
    SendDnsQueriesAllDomains,
    SendDnsQueriesWildcard,
    SendDnsQueriesDevicePoolLabel,
    SendDnsQueriesDevicePoolRandom,
    // Static device pool membership update.
    UpdateStaticDevicePool,
}

fn arb_transition(g: &mut Gen, state: &ReferenceState, now: Instant) -> Option<Transition> {
    // 1. Build the legal-arm list in fixed enum order with the same weights the
    //    proptest `transitions()` uses.
    let mut legal: Vec<(TransitionKind, u32)> = Vec::new();
    use TransitionKind as K;

    legal.push((K::UpdateSystemDnsServers, 1));
    legal.push((K::UpdateUpstreamDo53Servers, 1));
    legal.push((K::UpdateUpstreamDoHServers, 1));
    legal.push((K::UpdateUpstreamSearchDomain, 1));
    legal.push((K::RoamClient, 1));
    legal.push((K::DeployNewRelays, 1));
    legal.push((K::PartitionRelaysFromPortal, 1));
    legal.push((K::RebootRelaysWhilePartitioned, 1));
    legal.push((K::Idle, 1));

    if !state.all_resources_not_known_to_client().is_empty() {
        legal.push((K::AddResource, 5));
    }
    if !state
        .unknown_dns_resources_for_already_queried_domains()
        .is_empty()
    {
        legal.push((K::AddResourceForQueriedDomain, 5));
    }
    if !state.cidr_resources_on_client().is_empty() {
        legal.push((K::ChangeCidrResourceAddress, 1));
    }
    if !state.cidr_and_dns_resources_on_client().is_empty() && !state.regular_sites().is_empty() {
        legal.push((K::MoveResourceToNewSite, 1));
    }
    if !state.resources_with_filters_on_client().is_empty() {
        legal.push((K::ChangeFiltersOfResource, 1));
    }
    if !state.all_resource_ids().is_empty() {
        legal.push((K::RemoveResource, 1));
        legal.push((K::DeauthorizeWhileGatewayIsPartitioned, 1));
    }
    if !state.all_client_ids().is_empty() {
        legal.push((K::ReconnectPortal, 1));
        legal.push((K::RestartClient, 1));
        legal.push((K::SetInternetResourceState, 1));
    }
    if !state.dns_resource_domains().is_empty() {
        legal.push((K::UpdateDnsRecords, 5));
    }
    if !state.ipv4_cidr_resource_dsts().is_empty() {
        legal.push((K::Ipv4CidrPacket, 10));
    }
    if !state.ipv6_cidr_resource_dsts().is_empty() {
        legal.push((K::Ipv6CidrPacket, 10));
    }
    if !state.resolved_v4_domains().is_empty() {
        legal.push((K::ResolvedV4Packet, 10));
    }
    if !state.resolved_v6_domains().is_empty() {
        legal.push((K::ResolvedV6Packet, 10));
    }
    if !state.resolved_v4_domains_with_tcp_resources().is_empty() {
        legal.push((K::ConnectTcpV4, 10));
    }
    if !state.resolved_v6_domains_with_tcp_resources().is_empty() {
        legal.push((K::ConnectTcpV6, 10));
    }
    if !state.resolved_v4_domains_with_icmp_errors(now).is_empty() {
        legal.push((K::IcmpErrorV4Packet, 10));
    }
    if !state.resolved_v6_domains_with_icmp_errors(now).is_empty() {
        legal.push((K::IcmpErrorV6Packet, 10));
    }
    // DNS-query arms (gated on a reachable DNS server existing).
    if !state.all_domains(now).is_empty() && !state.reachable_dns_servers().is_empty() {
        legal.push((K::SendDnsQueriesAllDomains, 5));
    }
    if !state.wildcard_dns_resources().is_empty() && !state.reachable_dns_servers().is_empty() {
        legal.push((K::SendDnsQueriesWildcard, 2));
    }
    if !state.device_pool_query_targets().is_empty() && !state.portal.device_labels().is_empty() {
        legal.push((K::SendDnsQueriesDevicePoolLabel, 2));
    }
    if !state.device_pool_query_targets().is_empty() {
        legal.push((K::SendDnsQueriesDevicePoolRandom, 1));
    }
    if !state
        .resolved_ip4_for_non_resources(&state.global_dns_records, now)
        .is_empty()
    {
        legal.push((K::NonResourceV4Packet, 1));
    }
    if !state
        .resolved_ip6_for_non_resources(&state.global_dns_records, now)
        .is_empty()
    {
        legal.push((K::NonResourceV6Packet, 1));
    }
    if !state.connected_gateway_ipv4_ips().is_empty() {
        legal.push((K::GatewayV4Packet, 1));
    }
    if !state.connected_gateway_ipv6_ips().is_empty() {
        legal.push((K::GatewayV6Packet, 1));
    }
    if !state.pool_routed_other_client_tun_ips().is_empty() {
        legal.push((K::PoolRoutedPacket, 5));
    }
    if !state.static_device_pools_on_any_client().is_empty() {
        legal.push((K::UpdateStaticDevicePool, 2));
    }

    // 2. Weighted pick over the legal list.
    let kind = weighted_choose(g, &legal)?;

    // 3. Generate the chosen arm's payload from the following bytes.
    let transition = match kind {
        K::UpdateSystemDnsServers => Transition::UpdateSystemDnsServers {
            servers: arb_system_dns_servers(g),
        },
        K::UpdateUpstreamDo53Servers => {
            Transition::UpdateUpstreamDo53Servers(arb_upstream_do53_servers(g))
        }
        K::UpdateUpstreamDoHServers => {
            Transition::UpdateUpstreamDoHServers(arb_upstream_doh_servers(g))
        }
        K::UpdateUpstreamSearchDomain => {
            let domains = state.portal.dns_resources();
            let candidates: Vec<DomainName> = domains
                .iter()
                .filter_map(|r| {
                    let (_, s) = r.address.split_once('.')?;
                    DomainName::vec_from_str(s).ok()
                })
                .collect();
            let chosen = if candidates.is_empty() || !g.flip(50) {
                None
            } else {
                let idx = g.choose_index(candidates.len());
                Some(candidates[idx].clone())
            };
            Transition::UpdateUpstreamSearchDomain(chosen)
        }
        K::RoamClient => {
            let ids = state.all_client_ids();
            let client_id = ids[g.choose_index(ids.len())];
            let (ip4, ip6) = arb_socket_ip_stack(g);
            Transition::RoamClient {
                client_id,
                ip4,
                ip6,
            }
        }
        K::DeployNewRelays => Transition::DeployNewRelays(arb_relays(g)),
        K::PartitionRelaysFromPortal => Transition::PartitionRelaysFromPortal,
        K::RebootRelaysWhilePartitioned => {
            // Reboot the *existing* relays with fresh credentials (same ids).
            let ids: Vec<RelayId> = state.relays.keys().copied().collect();
            let mut relays = BTreeMap::new();
            for id in ids {
                let seed = g.u64();
                let latency = g.latency(50);
                let mut host = Host::new(seed, latency, 3478);
                host.update_interface(Some(g.socket_ip4.next()), Some(g.socket_ip6.next()));
                relays.insert(id, host);
            }
            Transition::RebootRelaysWhilePartitioned(relays)
        }
        K::Idle => Transition::Idle,
        K::AddResource => {
            let candidates = state.all_resources_not_known_to_client();
            let (_, resource) = candidates[g.choose_index(candidates.len())].clone();
            Transition::AddResource(resource)
        }
        K::AddResourceForQueriedDomain => {
            let candidates = state.unknown_dns_resources_for_already_queried_domains();
            let (_, resource) = candidates[g.choose_index(candidates.len())].clone();
            Transition::AddResource(resource)
        }
        K::ChangeCidrResourceAddress => {
            let candidates = state.cidr_resources_on_client();
            let (_, resource) = candidates[g.choose_index(candidates.len())].clone();
            let new_address = arb_cidr_resource_address(g);
            Transition::ChangeCidrResourceAddress {
                resource,
                new_address,
            }
        }
        K::MoveResourceToNewSite => {
            let resources = state.cidr_and_dns_resources_on_client();
            let sites = state.regular_sites();
            let (_, resource) = resources[g.choose_index(resources.len())].clone();
            let new_site = sites[g.choose_index(sites.len())].clone();
            Transition::MoveResourceToNewSite { resource, new_site }
        }
        K::ChangeFiltersOfResource => {
            let candidates = state.resources_with_filters_on_client();
            let (_, resource) = candidates[g.choose_index(candidates.len())].clone();
            let new_filters = arb_filters(g);
            Transition::ChangeFiltersOfResource {
                resource,
                new_filters,
            }
        }
        K::RemoveResource => {
            let ids = state.all_resource_ids();
            let id = ids[g.choose_index(ids.len())];
            Transition::RemoveResource(id)
        }
        K::DeauthorizeWhileGatewayIsPartitioned => {
            let ids = state.all_resource_ids();
            let id = ids[g.choose_index(ids.len())];
            Transition::DeauthorizeWhileGatewayIsPartitioned(id)
        }
        K::ReconnectPortal => {
            let ids = state.all_client_ids();
            let client_id = ids[g.choose_index(ids.len())];
            Transition::ReconnectPortal { client_id }
        }
        K::RestartClient => {
            let ids = state.all_client_ids();
            let client_id = ids[g.choose_index(ids.len())];
            let key = g.fresh_private_key();
            Transition::RestartClient { client_id, key }
        }
        K::SetInternetResourceState => {
            let ids = state.all_client_ids();
            let client_id = ids[g.choose_index(ids.len())];
            let active = g.bool();
            Transition::SetInternetResourceState { client_id, active }
        }
        K::UpdateDnsRecords => {
            let domains = state.dns_resource_domains();
            let domain = domains[g.choose_index(domains.len())].clone();
            let records = arb_dns_record_set(g);
            Transition::UpdateDnsRecords { domain, records }
        }
        K::Ipv4CidrPacket => {
            let values = state.ipv4_cidr_resource_dsts();
            let (client_id, network, filters) = values[g.choose_index(values.len())].clone();
            let tunnel_ip4 = state.clients.get(&client_id).unwrap().inner().tunnel_ip4;
            let dst = host_in_v4(g, network);
            arb_icmp_or_udp_for_filters(g, client_id, IpAddr::V4(tunnel_ip4), dst, &filters)
        }
        K::Ipv6CidrPacket => {
            let values = state.ipv6_cidr_resource_dsts();
            let (client_id, network, filters) = values[g.choose_index(values.len())].clone();
            let tunnel_ip6 = state.clients.get(&client_id).unwrap().inner().tunnel_ip6;
            let dst = host_in_v6(g, network);
            arb_icmp_or_udp_for_filters(g, client_id, IpAddr::V6(tunnel_ip6), dst, &filters)
        }
        K::ResolvedV4Packet => {
            let values = state.resolved_v4_domains();
            let (client_id, domain, filters) = values[g.choose_index(values.len())].clone();
            let tunnel_ip4 = state.clients.get(&client_id).unwrap().inner().tunnel_ip4;
            arb_icmp_or_udp_for_filters(
                g,
                client_id,
                IpAddr::V4(tunnel_ip4),
                DstSpec::Domain(domain),
                &filters,
            )
        }
        K::ResolvedV6Packet => {
            let values = state.resolved_v6_domains();
            let (client_id, domain, filters) = values[g.choose_index(values.len())].clone();
            let tunnel_ip6 = state.clients.get(&client_id).unwrap().inner().tunnel_ip6;
            arb_icmp_or_udp_for_filters(
                g,
                client_id,
                IpAddr::V6(tunnel_ip6),
                DstSpec::Domain(domain),
                &filters,
            )
        }
        K::IcmpErrorV4Packet => {
            let values = state.resolved_v4_domains_with_icmp_errors(now);
            let (client_id, domain, filters) = values[g.choose_index(values.len())].clone();
            let tunnel_ip4 = state.clients.get(&client_id).unwrap().inner().tunnel_ip4;
            arb_icmp_or_udp_for_filters(
                g,
                client_id,
                IpAddr::V4(tunnel_ip4),
                DstSpec::Domain(domain),
                &filters,
            )
        }
        K::IcmpErrorV6Packet => {
            let values = state.resolved_v6_domains_with_icmp_errors(now);
            let (client_id, domain, filters) = values[g.choose_index(values.len())].clone();
            let tunnel_ip6 = state.clients.get(&client_id).unwrap().inner().tunnel_ip6;
            arb_icmp_or_udp_for_filters(
                g,
                client_id,
                IpAddr::V6(tunnel_ip6),
                DstSpec::Domain(domain),
                &filters,
            )
        }
        K::ConnectTcpV4 => {
            let values = state.resolved_v4_domains_with_tcp_resources();
            let (client_id, domain, filters) = values[g.choose_index(values.len())].clone();
            let tunnel_ip4 = state.clients.get(&client_id).unwrap().inner().tunnel_ip4;
            arb_connect_tcp_for_filters(g, client_id, IpAddr::V4(tunnel_ip4), domain, &filters)
        }
        K::ConnectTcpV6 => {
            let values = state.resolved_v6_domains_with_tcp_resources();
            let (client_id, domain, filters) = values[g.choose_index(values.len())].clone();
            let tunnel_ip6 = state.clients.get(&client_id).unwrap().inner().tunnel_ip6;
            arb_connect_tcp_for_filters(g, client_id, IpAddr::V6(tunnel_ip6), domain, &filters)
        }
        // Non-resource IP packets: unconstrained ICMP or UDP (any port for v4/v6
        // non-resources, matching the proptest `prop_oneof![icmp, udp(any u16)]`).
        K::NonResourceV4Packet => {
            let values = state.resolved_ip4_for_non_resources(&state.global_dns_records, now);
            let (client_id, ip) = values[g.choose_index(values.len())];
            let tunnel_ip4 = state.clients.get(&client_id).unwrap().inner().tunnel_ip4;
            arb_icmp_or_any_udp(g, client_id, IpAddr::V4(tunnel_ip4), IpAddr::V4(ip))
        }
        K::NonResourceV6Packet => {
            let values = state.resolved_ip6_for_non_resources(&state.global_dns_records, now);
            let (client_id, ip) = values[g.choose_index(values.len())];
            let tunnel_ip6 = state.clients.get(&client_id).unwrap().inner().tunnel_ip6;
            arb_icmp_or_any_udp(g, client_id, IpAddr::V6(tunnel_ip6), IpAddr::V6(ip))
        }
        // Connected-gateway IPs: ICMP or UDP on a non-DNS port to a host within the
        // gateway's tunnel network (matching `prop_oneof![icmp, udp(non_dns_ports)]`).
        K::GatewayV4Packet => {
            let values = state.connected_gateway_ipv4_ips();
            let (client_id, network) = values[g.choose_index(values.len())];
            let tunnel_ip4 = state.clients.get(&client_id).unwrap().inner().tunnel_ip4;
            let DstSpec::Ip(dst) = host_in_v4(g, network) else {
                unreachable!()
            };
            arb_icmp_or_nondns_udp(g, client_id, IpAddr::V4(tunnel_ip4), dst)
        }
        K::GatewayV6Packet => {
            let values = state.connected_gateway_ipv6_ips();
            let (client_id, network) = values[g.choose_index(values.len())];
            let tunnel_ip6 = state.clients.get(&client_id).unwrap().inner().tunnel_ip6;
            let DstSpec::Ip(dst) = host_in_v6(g, network) else {
                unreachable!()
            };
            arb_icmp_or_nondns_udp(g, client_id, IpAddr::V6(tunnel_ip6), dst)
        }
        // Peer-client routed via a static device pool: ICMP/UDP respecting the pool filters.
        K::PoolRoutedPacket => {
            let values = state.pool_routed_other_client_tun_ips();
            let (src_id, dst_ip, filters) = values[g.choose_index(values.len())].clone();
            let inner = state.clients.get(&src_id).unwrap().inner();
            let src_ip = match dst_ip {
                IpAddr::V4(_) => IpAddr::V4(inner.tunnel_ip4),
                IpAddr::V6(_) => IpAddr::V6(inner.tunnel_ip6),
            };
            arb_icmp_or_udp_for_filters(g, src_id, src_ip, DstSpec::Ip(dst_ip), &filters)
        }
        K::SendDnsQueriesAllDomains => {
            let domains = state.all_domains(now);
            let dns_servers = state.reachable_dns_servers();
            let (client_id, domain, rtypes) = domains[g.choose_index(domains.len())].clone();
            let (dns_client_id, dns_server) =
                dns_servers[g.choose_index(dns_servers.len())].clone();
            // The proptest deliberately emits a NO-OP when the sampled domain's
            // client differs from the sampled DNS server's client.
            if client_id != dns_client_id {
                Transition::SendDnsQueries(Vec::new())
            } else {
                let queries = arb_dns_queries(g, vec![(domain, rtypes)], dns_server);
                Transition::SendDnsQueries(queries.into_iter().map(|q| (client_id, q)).collect())
            }
        }
        K::SendDnsQueriesWildcard => {
            let wildcards = state.wildcard_dns_resources();
            let dns_servers = state.reachable_dns_servers();
            let (client_id, resource) = wildcards[g.choose_index(wildcards.len())].clone();
            let (dns_client_id, dns_server) =
                dns_servers[g.choose_index(dns_servers.len())].clone();
            if client_id != dns_client_id {
                Transition::SendDnsQueries(Vec::new())
            } else {
                let base = resource.address.trim_start_matches("*.").to_owned();
                let label = g.lower_ascii(3, 6);
                let domain: DomainName = format!("{label}.{base}").parse().unwrap();
                let rtypes = if g.bool() {
                    vec![RecordType::A]
                } else {
                    vec![RecordType::AAAA]
                };
                let queries = arb_dns_queries(g, vec![(domain, rtypes)], dns_server);
                Transition::SendDnsQueries(queries.into_iter().map(|q| (client_id, q)).collect())
            }
        }
        K::SendDnsQueriesDevicePoolLabel => {
            let targets = state.device_pool_query_targets();
            let labels = state.portal.device_labels();
            let (client_id, resource, dns_server) = targets[g.choose_index(targets.len())].clone();
            let label = labels[g.choose_index(labels.len())].clone();
            let base = resource.address.trim_start_matches("*.").to_owned();
            let domain: DomainName = format!("{label}.{base}").parse().unwrap();
            let queries = arb_dns_queries(g, vec![(domain, vec![RecordType::A])], dns_server);
            Transition::SendDnsQueries(queries.into_iter().map(|q| (client_id, q)).collect())
        }
        K::SendDnsQueriesDevicePoolRandom => {
            let targets = state.device_pool_query_targets();
            let (client_id, resource, dns_server) = targets[g.choose_index(targets.len())].clone();
            let base = resource.address.trim_start_matches("*.").to_owned();
            // Random label exercises the not-found path (FailReason::NotFound).
            let label = g.lower_ascii(3, 6);
            let domain: DomainName = format!("{label}.{base}").parse().unwrap();
            let queries = arb_dns_queries(g, vec![(domain, vec![RecordType::A])], dns_server);
            Transition::SendDnsQueries(queries.into_iter().map(|q| (client_id, q)).collect())
        }
        K::UpdateStaticDevicePool => {
            let pools = state.static_device_pools_on_any_client();
            let pool = pools[g.choose_index(pools.len())].clone();
            Transition::UpdateStaticDevicePool {
                pool_id: pool.id,
                new_devices: arb_static_pool_members(g, state, &pool),
            }
        }
    };

    Some(transition)
}

/// Reproduces `Union::new_weighted`: partition `int_in_range` over the summed
/// weight. Identical bytes always pick the same arm.
fn weighted_choose(g: &mut Gen, opts: &[(TransitionKind, u32)]) -> Option<TransitionKind> {
    if opts.is_empty() {
        return None;
    }
    let total: u32 = opts.iter().map(|(_, w)| *w).sum();
    let mut pick = g.u.int_in_range(0..=total - 1).unwrap_or(0);
    for (k, w) in opts {
        if pick < *w {
            return Some(*k);
        }
        pick -= *w;
    }
    opts.last().map(|(k, _)| *k)
}

/// Destination spec used while building a packet payload.
enum DstSpec {
    Domain(DomainName),
    Ip(IpAddr),
}

fn host_in_v4(g: &mut Gen, network: Ipv4Network) -> DstSpec {
    let host_bits = 32 - network.netmask();
    let base = u32::from(network.network_address());
    let off = if host_bits == 0 {
        0
    } else if host_bits >= 32 {
        g.u32()
    } else {
        g.u32() % (1u32 << host_bits)
    };
    DstSpec::Ip(IpAddr::V4(Ipv4Addr::from(base.wrapping_add(off))))
}

fn host_in_v6(g: &mut Gen, network: Ipv6Network) -> DstSpec {
    let host_bits = 128 - network.netmask();
    let base = u128::from(network.network_address());
    let off = if host_bits == 0 {
        0
    } else {
        let hi = (g.u64() as u128) << 64;
        let lo = g.u64() as u128;
        let mask = if host_bits >= 128 {
            u128::MAX
        } else {
            (1u128 << host_bits) - 1
        };
        (hi | lo) & mask
    };
    DstSpec::Ip(IpAddr::V6(Ipv6Addr::from(base.wrapping_add(off))))
}

/// Build an ICMP-or-UDP packet that respects `filters` (80% matching, 20% any),
/// mirroring `icmp_or_udp_packet_for_filters`.
fn arb_icmp_or_udp_for_filters(
    g: &mut Gen,
    client_id: ClientId,
    src: IpAddr,
    dst: DstSpec,
    filters: &[Filter],
) -> Transition {
    // Filters relevant here: ICMP + UDP (excluding the udp/53 special-case).
    let usable: Vec<Filter> = filters
        .iter()
        .filter(|f| !matches!(f, Filter::Tcp(_)))
        .filter(|f| {
            !matches!(
                f,
                Filter::Udp(PortRange {
                    port_range_start: 53,
                    port_range_end: 53,
                })
            )
        })
        .copied()
        .collect();

    let use_matching = !usable.is_empty() && g.flip(80);

    if use_matching {
        let filter = usable[g.choose_index(usable.len())];
        match filter {
            Filter::Icmp => arb_icmp_packet(g, client_id, src, dst),
            Filter::Udp(PortRange {
                port_range_start,
                port_range_end,
            }) => {
                let dport =
                    g.u.int_in_range(port_range_start..=port_range_end)
                        .unwrap_or(port_range_start);
                arb_udp_packet(g, client_id, src, dst, dport)
            }
            Filter::Tcp(_) => unreachable!("TCP filters were excluded above"),
        }
    } else {
        // Unconstrained ICMP or UDP (non-DNS port).
        if g.bool() {
            arb_icmp_packet(g, client_id, src, dst)
        } else {
            let dport = arb_non_dns_port(g);
            arb_udp_packet(g, client_id, src, dst, dport)
        }
    }
}

fn arb_connect_tcp_for_filters(
    g: &mut Gen,
    client_id: ClientId,
    src: IpAddr,
    domain: DomainName,
    filters: &[Filter],
) -> Transition {
    let tcp_filters: Vec<PortRange> = filters
        .iter()
        .filter_map(|f| match f {
            Filter::Tcp(r) => Some(*r),
            Filter::Udp(_) | Filter::Icmp => None,
        })
        .collect();

    let dport = if !tcp_filters.is_empty() && g.flip(80) {
        let r = tcp_filters[g.choose_index(tcp_filters.len())];
        g.u.int_in_range(r.port_range_start..=r.port_range_end)
            .unwrap_or(r.port_range_start)
    } else {
        let mut p = arb_non_dns_port(g);
        if p == 0 {
            p = 1;
        }
        p
    };

    let sport = g.u.int_in_range(1..=u16::MAX).unwrap_or(1);
    Transition::ConnectTcp {
        client_id,
        src,
        dst: arb_destination(g, DstSpec::Domain(domain)),
        sport: SPort(sport),
        dport: DPort(dport),
    }
}

/// Unconstrained ICMP or UDP to an IP destination, UDP using *any* port
/// (matches the non-resource `prop_oneof![icmp, udp(any::<u16>())]`).
fn arb_icmp_or_any_udp(g: &mut Gen, client_id: ClientId, src: IpAddr, dst: IpAddr) -> Transition {
    if g.bool() {
        arb_icmp_packet(g, client_id, src, DstSpec::Ip(dst))
    } else {
        let dport = g.u16();
        arb_udp_packet(g, client_id, src, DstSpec::Ip(dst), dport)
    }
}

/// Unconstrained ICMP or UDP to an IP destination, UDP using a non-DNS port
/// (matches the connected-gateway `prop_oneof![icmp, udp(non_dns_ports())]`).
fn arb_icmp_or_nondns_udp(
    g: &mut Gen,
    client_id: ClientId,
    src: IpAddr,
    dst: IpAddr,
) -> Transition {
    if g.bool() {
        arb_icmp_packet(g, client_id, src, DstSpec::Ip(dst))
    } else {
        let dport = arb_non_dns_port(g);
        arb_udp_packet(g, client_id, src, DstSpec::Ip(dst), dport)
    }
}

/// Port of `dns_queries`: zip a set of `(server, transport, query_id)` tuples with
/// a set of `(domain, rtypes)` and drop the unmatched tail. For each pair, choose a
/// response rtype (PTR-rewriting the domain when PTR is chosen).
///
/// Uniqueness of the query tuples is by construction (collected into a `BTreeSet`,
/// matching the proptest `btree_set`, so duplicates simply collapse — "we don't
/// care if we drop some").
fn arb_dns_queries(
    g: &mut Gen,
    domains: Vec<(DomainName, Vec<RecordType>)>,
    dns_server: dns::Upstream,
) -> Vec<DnsQuery> {
    // 1..5 unique (server, transport, query_id) tuples. The server is fixed to the
    // chosen one, so uniqueness reduces to (transport, query_id).
    let n_queries = g.count(1, 4);
    let mut tuples: BTreeSet<(DnsTransport, u16)> = BTreeSet::new();
    for _ in 0..n_queries {
        tuples.insert((arb_dns_transport(g), arb_dns_query_id(g)));
    }

    // 1..5 unique domains drawn from the provided list (collapses duplicates).
    let n_domains = g.count(1, 4);
    let mut domain_set: BTreeSet<(DomainName, Vec<RecordType>)> = BTreeSet::new();
    if !domains.is_empty() {
        for _ in 0..n_domains {
            domain_set.insert(domains[g.choose_index(domains.len())].clone());
        }
    }

    // Zip, dropping the unmatched tail of whichever set is longer.
    tuples
        .into_iter()
        .zip(domain_set)
        .map(|((transport, query_id), (mut domain, existing_rtypes))| {
            let r_type = arb_maybe_available_response_rtype(g, &existing_rtypes);
            if matches!(r_type, RecordType::PTR) {
                let reverse_ip = arb_ptr_query_ip(g);
                domain = DomainName::reverse_from_addr(reverse_ip).unwrap();
            }
            DnsQuery {
                domain,
                r_type,
                query_id,
                dns_server: dns_server.clone(),
                transport,
            }
        })
        .collect()
}

fn arb_dns_transport(g: &mut Gen) -> DnsTransport {
    if g.bool() {
        DnsTransport::Udp {
            local_port: g.u16(),
        }
    } else {
        DnsTransport::Tcp
    }
}

fn arb_dns_query_id(g: &mut Gen) -> u16 {
    // `prop_oneof![any::<u16>(), Just(33333)]` — equal weight.
    if g.bool() { g.u16() } else { 33333 }
}

/// Port of `maybe_available_response_rtypes`: if the domain has an A/AAAA record,
/// pick from {PTR, MX, A, AAAA}; otherwise pick from the available rtypes.
fn arb_maybe_available_response_rtype(g: &mut Gen, available: &[RecordType]) -> RecordType {
    if available.contains(&RecordType::A) || available.contains(&RecordType::AAAA) {
        let choices = [
            RecordType::PTR,
            RecordType::MX,
            RecordType::A,
            RecordType::AAAA,
        ];
        choices[g.choose_index(choices.len())]
    } else if available.is_empty() {
        // No records to choose from; default to A (the proptest never reaches here
        // because `all_domains` filters out empty-rtype domains).
        RecordType::A
    } else {
        available[g.choose_index(available.len())]
    }
}

/// Port of `ptr_query_ip`: a host in the resource ranges, or any IP.
fn arb_ptr_query_ip(g: &mut Gen) -> IpAddr {
    use tunnel::client::{IPV4_RESOURCES, IPV6_RESOURCES};
    match g.choose_index(3) {
        0 => {
            let DstSpec::Ip(ip) = host_in_v4(g, IPV4_RESOURCES) else {
                unreachable!()
            };
            ip
        }
        1 => {
            let DstSpec::Ip(ip) = host_in_v6(g, IPV6_RESOURCES) else {
                unreachable!()
            };
            ip
        }
        _ => {
            if g.bool() {
                IpAddr::V4(Ipv4Addr::from(g.u32()))
            } else {
                let hi = (g.u64() as u128) << 64;
                let lo = g.u64() as u128;
                IpAddr::V6(Ipv6Addr::from(hi | lo))
            }
        }
    }
}

/// Port of the `UpdateStaticDevicePool` member generation: a subsequence of the
/// online clients (as `/32` + `/128` device members) plus all preserved offline
/// members already in the pool.
fn arb_static_pool_members(
    g: &mut Gen,
    state: &ReferenceState,
    pool: &tunnel::client::StaticDevicePoolResource,
) -> Vec<DevicePoolMember> {
    let online_clients: Vec<(ClientId, Ipv4Network, Ipv6Network)> = state
        .clients
        .iter()
        .map(|(id, c)| {
            let inner = c.inner();
            (
                *id,
                Ipv4Network::new(inner.tunnel_ip4, 32).unwrap(),
                Ipv6Network::new(inner.tunnel_ip6, 128).unwrap(),
            )
        })
        .collect();
    let online_ids: BTreeSet<ClientId> = online_clients.iter().map(|(id, _, _)| *id).collect();

    let preserved_offline: Vec<DevicePoolMember> = pool
        .devices
        .iter()
        .filter(|d| !online_ids.contains(&d.id))
        .cloned()
        .collect();

    // Per-element keep-bit subsequence of the online clients (0..=all).
    let mut devices: Vec<DevicePoolMember> = online_clients
        .into_iter()
        .filter(|_| g.bool())
        .map(|(id, ipv4, ipv6)| DevicePoolMember { id, ipv4, ipv6 })
        .collect();
    devices.extend(preserved_offline);
    devices
}

fn arb_icmp_packet(g: &mut Gen, client_id: ClientId, src: IpAddr, dst: DstSpec) -> Transition {
    let seq = g.u16();
    let identifier = g.u16();
    let resolved_ip = g.u32();
    let payload = g.u64();
    Transition::SendIcmpPacket {
        client_id,
        src,
        dst: into_destination(dst, resolved_ip),
        seq: Seq(seq),
        identifier: Identifier(identifier),
        payload,
    }
}

fn arb_udp_packet(
    g: &mut Gen,
    client_id: ClientId,
    src: IpAddr,
    dst: DstSpec,
    dport: u16,
) -> Transition {
    let sport = g.u16();
    let resolved_ip = g.u32();
    let payload = g.u64();
    Transition::SendUdpPacket {
        client_id,
        src,
        dst: into_destination(dst, resolved_ip),
        sport: SPort(sport),
        dport: DPort(dport),
        payload,
    }
}

fn arb_destination(g: &mut Gen, dst: DstSpec) -> Destination {
    let resolved_ip = g.u32();
    into_destination(dst, resolved_ip)
}

fn into_destination(dst: DstSpec, resolved_ip: u32) -> Destination {
    match dst {
        DstSpec::Domain(name) => Destination::DomainName { resolved_ip, name },
        DstSpec::Ip(addr) => Destination::IpAddr(addr),
    }
}

/// A port that is not 53 or 53535, as a total bijection over the allowed set.
///
/// There are `u16::MAX + 1 = 65536` ports and two holes (53, 53535), leaving
/// `65534` allowed values. We draw an index in `0..=65533` and shift it past
/// each hole. The second threshold is expressed in the *original* index space
/// (53535 - 1 = 53534, because the hole at 53 already shifted everything below
/// it down by one).
fn arb_non_dns_port(g: &mut Gen) -> u16 {
    let mut p: u32 = g.u.int_in_range(0..=65533u32).unwrap_or(0);
    if p >= 53 {
        p += 1;
    }
    if p >= 53535 {
        p += 1;
    }
    p as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The non-DNS-port mapping must be a bijection onto `[0, 65535] \ {53, 53535}`:
    /// total (never panics / rejects), never produces a hole, and hits every
    /// other value exactly once.
    #[test]
    fn non_dns_port_is_a_bijection() {
        let mut seen = std::collections::BTreeSet::new();
        for idx in 0..=65533u32 {
            // Reproduce the body of `arb_non_dns_port` for a known index.
            let mut p = idx;
            if p >= 53 {
                p += 1;
            }
            if p >= 53535 {
                p += 1;
            }
            let p = p as u16;
            assert_ne!(p, 53, "53 is a hole");
            assert_ne!(p, 53535, "53535 is a hole");
            assert!(seen.insert(p), "value {p} produced twice");
        }
        assert_eq!(seen.len(), 65534, "must cover every allowed value once");
        assert!(!seen.contains(&53));
        assert!(!seen.contains(&53535));
    }

    #[test]
    fn run_fuzz_case_structured_smoke() {
        run_fuzz_case_structured(&[]);
        run_fuzz_case_structured(&[0u8; 64]);
        run_fuzz_case_structured(&[0xAB; 256]);

        let ramp: Vec<u8> = (0u8..=255).cycle().take(8192).collect();
        run_fuzz_case_structured(&ramp);
    }
}

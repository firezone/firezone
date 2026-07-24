//! Structured (`arbitrary`-driven) input layer for the tunnel fuzzer.
//!
//! Instead of folding the whole libFuzzer input into an RNG seed (which makes
//! every byte affect every decision), this module reads the input
//! positionally through a single [`arbitrary::Unstructured`]: a contiguous span
//! of bytes drives each individual decision. That preserves *mutation locality*
//! — flipping or removing a byte changes one decision rather than rekeying the
//! entire scenario — so libFuzzer's coverage-guided mutations and minimization
//! become meaningful.
//!
//! The generator never spins on a rejection-sampling loop because
//! `Unstructured` returns `Err` once exhausted. Every uniqueness constraint is
//! therefore made correct-by-construction:
//!
//! * socket IPs come from per-run [`SubnetCursor`]s (never repeat),
//! * site / client / gateway / relay / resource ids from monotonic counters,
//! * private keys carry a counter in their first bytes.
//!
//! Tunnel / interface IPs stay inside [`StubPortal::new`] from its shared
//! iterator, preserving the static-device-pool invariant (only *socket* IPs move
//! to cursors).
//!
//! Transition preconditions are encoded in the state-aware generators, so every
//! generated transition can be applied without rejection or retry loops.

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
use ip_packet::Protocol;
use tunnel_proto::MaliciousBehaviour;
use tunnel_proto::dns;
use tunnel_proto::messages::{
    Filter, PortRange, UpstreamDo53, UpstreamDoH, client::DevicePoolMember,
};

use crate::dns_records::DnsRecords;
use crate::flux_capacitor::FluxCapacitor;
use crate::icmp_error_hosts::IcmpErrorHosts;
use crate::ref_client::RefClient;
use crate::ref_gateway::RefGateway;
use crate::reference::{PrivateKey, ReferenceState};
use crate::resource::{
    CidrResource, DnsResource, DynamicDevicePoolResource, InternetResource, Resource,
    StaticDevicePoolResource,
};
use crate::sim_net::{EdgeConfig, FilterMode, Host, Mapping, RoutingTable};
use crate::stub_portal::{StaticDevicePoolPlan, StubPortal};
use crate::sut::TunnelTest;
use crate::transition::{
    DPort, Destination, DnsQuery, DnsTransport, Identifier, SPort, Seq, Transition,
};

/// Upper bound on transitions applied per case.
const MAX_TRANSITIONS: usize = 20;

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
/// allocator used to satisfy uniqueness constraints without rejection loops.
struct Gen<'a, 'u> {
    u: &'a mut Unstructured<'u>,

    // Disjoint socket-IP allocators (host routing IPs, distinct from connlib's
    // reserved ranges and from each other).
    socket_ip4: SubnetCursor<Ipv4Addr>, // 203.0.113.0/24 (TEST-NET-3), today's host_ip4s
    socket_ip6: SubnetCursor<Ipv6Addr>, // 2001:db80:1010:1010::/64
    nat_ip4: SubnetCursor<Ipv4Addr>,    // 198.51.100.0/24 (TEST-NET-2), public NAT addresses
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

    // Monotonic payload counter (packet identity; see `fresh_payload`).
    next_payload: u64,

    // Packet keys used by the simulated clients' request / reply maps.
    icmp_packets: BTreeSet<(Seq, Identifier)>,
    udp_packets: BTreeSet<(SPort, DPort)>,
    tcp_connections: BTreeSet<(SPort, DPort)>,
}

impl<'a, 'u> Gen<'a, 'u> {
    fn new(u: &'a mut Unstructured<'u>) -> Self {
        Self {
            u,
            socket_ip4: SubnetCursor::<Ipv4Addr>::over(
                "203.0.113.0/24".parse::<Ipv4Network>().unwrap(),
            ),
            socket_ip6: SubnetCursor::<Ipv6Addr>::over(
                Ipv6Network::new_truncate(
                    Ipv6Addr::new(0x2001, 0xDB80, 0x1010, 0x1010, 0, 0, 0, 0),
                    64,
                )
                .unwrap(),
            ),
            nat_ip4: SubnetCursor::<Ipv4Addr>::over(
                "198.51.100.0/24".parse::<Ipv4Network>().unwrap(),
            ),
            do53_ip4: SubnetCursor::<Ipv4Addr>::over(
                "192.18.0.0/24".parse::<Ipv4Network>().unwrap(),
            ),
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
            next_payload: 0,
            icmp_packets: BTreeSet::new(),
            udp_packets: BTreeSet::new(),
            tcp_connections: BTreeSet::new(),
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

    /// Pick an index in `0..len`. Exhaustion yields the first element.
    fn choose_index(&mut self, len: usize) -> usize {
        assert!(len > 0, "cannot choose from an empty collection");
        self.u.int_in_range(0..=len - 1).unwrap_or(0)
    }

    /// Heads with the given percentage probability.
    fn flip(&mut self, heads_pct: u8) -> bool {
        if self.u.is_empty() {
            return false;
        }

        self.u
            .int_in_range(0..=99u32)
            .is_ok_and(|draw| draw < heads_pct as u32)
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

    /// A packet payload that is unique within a scenario. Like
    /// [`fresh_private_key`](Self::fresh_private_key) a monotonic counter takes
    /// the high bits and the rest carries entropy. It reads the same eight bytes
    /// as a bare `u64`. The reference model identifies every packet solely by
    /// this value to match a client's send against the gateway's receive; two
    /// packets sharing one would alias in that map.
    fn fresh_payload(&mut self) -> u64 {
        let n = self.next_payload;
        self.next_payload += 1;
        let entropy = self.u64();
        ((n & 0xFF_FFFF) << 40) | (entropy & 0xFF_FFFF_FFFF)
    }

    fn fresh_icmp_packet(&mut self) -> (Seq, Identifier) {
        let candidate = (self.u16(), self.u16());
        let packet = (0..=u16::MAX)
            .map(|offset| {
                (
                    Seq(candidate.0.wrapping_add(offset)),
                    Identifier(candidate.1),
                )
            })
            .find(|packet| !self.icmp_packets.contains(packet))
            .expect("a scenario cannot exhaust all ICMP packet identifiers");
        self.icmp_packets.insert(packet);

        packet
    }

    fn fresh_udp_packet(&mut self, dport: u16) -> (SPort, DPort) {
        let candidate = self.u16();
        let packet = (0..=u16::MAX)
            .map(|offset| (SPort(candidate.wrapping_add(offset)), DPort(dport)))
            .find(|packet| !self.udp_packets.contains(packet))
            .expect("a scenario cannot exhaust all UDP packet identifiers");
        self.udp_packets.insert(packet);

        packet
    }

    fn fresh_tcp_connection(&mut self, dport: u16) -> (SPort, DPort) {
        let candidate = self.u.int_in_range(1..=u16::MAX).unwrap_or(1);
        let connection = (0..u32::from(u16::MAX))
            .map(|offset| {
                let sport = ((u32::from(candidate) - 1 + offset) % u32::from(u16::MAX) + 1) as u16;
                (SPort(sport), DPort(dport))
            })
            .find(|connection| !self.tcp_connections.contains(connection))
            .expect("a scenario cannot exhaust all TCP connection identifiers");
        self.tcp_connections.insert(connection);

        connection
    }

    fn latency(&mut self, max: u64) -> Duration {
        Duration::from_millis(self.u.int_in_range(10..=max - 1).unwrap_or(10))
    }

    /// `[a-z]{lo..=hi}`.
    fn lower_ascii(&mut self, lo: usize, hi: usize) -> String {
        let n = self.count(lo, hi);
        (0..n)
            .map(|_| self.u.int_in_range(b'a'..=b'z').unwrap_or(b'a') as char)
            .collect::<String>()
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

    for applied in 0..MAX_TRANSITIONS {
        if g.is_empty() {
            break;
        }

        let Some(transition) = arb_transition(&mut g, &ref_state, now) else {
            break; // no legal arm
        };

        // One line per applied transition. Silent during mass fuzzing (no
        // subscriber is installed unless `RUST_LOG` is set); with `RUST_LOG`
        // this makes a reduced/crashing input self-describing on stderr.
        tracing::debug!("Applying transition {applied}: {transition:?}");

        if transition.should_clear_packets() {
            ReferenceState::clear_packets(&mut ref_state);
            TunnelTest::clear_packets(&mut sut);
        }

        ref_state = ReferenceState::apply(ref_state, &transition, flux_capacitor.now());
        sut = TunnelTest::apply(sut, &ref_state, transition.clone());
        TunnelTest::check_invariants(&sut, &ref_state);
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

    let global_dns_records =
        merge_dns_records(arb_global_dns_records(g, start), dns_resource_records);

    // Rebuild the routing table. Uniqueness is structural, so this never rejects;
    // debug assertions guard against accidental collisions.
    let network = clients
        .iter()
        .fold(RoutingTable::default(), |mut network, (id, host)| {
            let ok = network.add_host(*id, host);
            debug_assert!(ok, "client socket IPs must be unique by construction");
            network
        });
    let network = gateways.iter().fold(network, |mut network, (id, host)| {
        let ok = network.add_host(*id, host);
        debug_assert!(ok, "gateway socket IPs must be unique by construction");
        network
    });
    let network = relays.iter().fold(network, |mut network, (id, host)| {
        let ok = network.add_host(*id, host);
        debug_assert!(ok, "relay socket IPs must be unique by construction");
        network
    });

    ReferenceState::from_parts(
        clients,
        gateways,
        relays,
        portal,
        global_dns_records,
        tcp_resources,
        icmp_error_hosts,
        network,
    )
}

fn arb_stub_portal(g: &mut Gen) -> StubPortal {
    let internet_site = Site {
        id: g.fresh_site_id(),
        name: "Internet".to_owned(),
    };
    let regular_sites = (0..g.count(1, 3))
        .map(|_| Site {
            id: g.fresh_site_id(),
            name: g.lower_ascii(4, 10),
        })
        .collect::<Vec<_>>();

    // Clients: exactly 2.
    let clients = (0..2).map(|_| g.fresh_client_id()).collect::<BTreeSet<_>>();

    // CIDR resources: 1..=4 (1..5).
    let n_cidr = g.count(1, 4);
    let cidr_resources = (0..n_cidr)
        .map(|_| {
            let site = pick_site(g, &regular_sites);
            arb_cidr_resource(g, vec![site])
        })
        .collect::<BTreeSet<_>>();

    // DNS resources: 1..=4, each non-wildcard / `*.` / `**.`.
    let n_dns = g.count(1, 4);
    let dns_resources = (0..n_dns)
        .map(|_| {
            let site = pick_site(g, &regular_sites);
            arb_dns_resource(g, vec![site])
        })
        .collect::<BTreeSet<_>>();

    // Dynamic device pool resources: 0..=2.
    let n_pool = g.count(0, 2);
    let device_pool_resources = (0..n_pool)
        .map(|_| arb_dynamic_device_pool_resource(g))
        .collect::<BTreeSet<_>>();

    // Static device pool plans: 0..=3.
    let n_static = g.count(0, 3);
    let static_device_pool_plans = (0..n_static)
        .map(|_| arb_static_device_pool_plan(g))
        .collect::<Vec<_>>();

    let internet_resource = arb_internet_resource(g, vec![internet_site.clone()]);

    // Gateways per site: 1..=3 for each (Internet + regular) site.
    let gateways_by_site = std::iter::once(&internet_site)
        .chain(&regular_sites)
        .map(|site| {
            let n_gw = g.count(1, 3);
            let gateways = (0..n_gw)
                .map(|_| g.fresh_gateway_id())
                .collect::<BTreeSet<_>>();
            (site.id, gateways)
        })
        .collect::<BTreeMap<_, _>>();

    let gateway_selector = g.u32();

    let upstream_do53 = arb_upstream_do53_servers(g);
    let upstream_doh = arb_upstream_doh_servers(g);

    // Extra (overlapping) resources, mirroring `extra_cidr_resources` /
    // `extra_dns_resources`: each existing resource has a 50% chance of
    // spawning an overlapping sibling.
    let extra_cidr_resources = arb_extra_cidr_resources(g, &cidr_resources);
    let extra_dns_resources = arb_extra_dns_resources(g, &dns_resources);

    // Search domain derived from the (pre-extra) DNS resources.
    let search_domain = arb_search_domain(g, &dns_resources);

    // Do53-coverage augmentation: if a CIDR resource covers an upstream Do53
    // server, in 80% of cases allow udp/53 + tcp/53 through it.
    let cidr_resources = cidr_resources
        .into_iter()
        .chain(extra_cidr_resources)
        .map(|resource| {
            let filters = resource
                .filters
                .iter()
                .copied()
                .chain(
                    (upstream_do53
                        .iter()
                        .any(|server| resource.address.contains(server.ip))
                        && g.flip(80))
                    .then_some([
                        Filter::Udp(PortRange {
                            port_range_start: 53,
                            port_range_end: 53,
                        }),
                        Filter::Tcp(PortRange {
                            port_range_start: 53,
                            port_range_end: 53,
                        }),
                    ])
                    .into_iter()
                    .flatten(),
                )
                .collect::<Vec<_>>();
            CidrResource {
                filters,
                ..resource
            }
        })
        .collect::<BTreeSet<_>>();
    let dns_resources = dns_resources
        .into_iter()
        .chain(extra_dns_resources)
        .collect::<BTreeSet<_>>();

    StubPortal::new(
        clients,
        gateways_by_site,
        regular_sites,
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
    // Mirror `strategies::stub_portal`: sample the portal-wide ICE-less toggle.
    .with_iceless(g.bool())
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

fn arb_static_device_pool_plan(g: &mut Gen) -> StaticDevicePoolPlan {
    let n_online_members = g.count(0, 2);
    let n_offline = g.count(0, 2);
    let offline_members = (0..n_offline)
        .map(|_| g.fresh_client_id())
        .collect::<Vec<_>>();
    StaticDevicePoolPlan {
        id: g.fresh_resource_id(),
        name: g.lower_ascii(4, 10),
        filters: arb_filters(g),
        n_online_members,
        offline_members,
    }
}

/// For half of the existing resources, generate a sibling with the same address
/// or a more-specific subnet within it.
fn arb_extra_cidr_resources(g: &mut Gen, existing: &BTreeSet<CidrResource>) -> Vec<CidrResource> {
    existing
        .iter()
        .filter_map(|resource| {
            if !g.flip(50) {
                return None;
            }

            let extra_bits = match resource.address {
                IpNetwork::V4(network) => (32 - network.netmask()) as usize,
                IpNetwork::V6(network) => (128 - network.netmask()) as usize,
            };
            let address = if extra_bits > 0 && g.flip(50) {
                arb_more_specific_subnet(g, resource.address, extra_bits)
            } else {
                resource.address
            };
            Some(CidrResource {
                id: g.fresh_resource_id(),
                address,
                name: g.lower_ascii(4, 10),
                address_description: None,
                sites: resource.sites.clone(),
                filters: arb_filters(g),
            })
        })
        .collect::<Vec<_>>()
}

/// For half of the existing resources, generate a sibling with the same or a
/// more-specific address pattern.
fn arb_extra_dns_resources(g: &mut Gen, existing: &BTreeSet<DnsResource>) -> Vec<DnsResource> {
    existing
        .iter()
        .filter_map(|resource| {
            if !g.flip(50) {
                return None;
            }

            let address = &resource.address;
            let candidates = if let Some(base) = address.strip_prefix("**.") {
                vec![
                    address.clone(),
                    format!("*.{base}"),
                    format!("{}.{base}", g.lower_ascii(3, 6)),
                ]
            } else if let Some(base) = address.strip_prefix("*.") {
                vec![address.clone(), format!("{}.{base}", g.lower_ascii(3, 6))]
            } else {
                vec![address.clone()]
            };
            let address = candidates[g.choose_index(candidates.len())].clone();

            Some(DnsResource {
                id: g.fresh_resource_id(),
                address,
                name: g.lower_ascii(4, 10),
                address_description: None,
                sites: resource.sites.clone(),
                ip_stack: resource.ip_stack,
                filters: arb_filters(g),
            })
        })
        .collect::<Vec<_>>()
}

fn arb_search_domain(g: &mut Gen, dns_resources: &BTreeSet<DnsResource>) -> Option<DomainName> {
    let candidates = dns_resources
        .iter()
        .filter_map(|r| {
            let (_, search) = r.address.split_once('.')?;
            DomainName::vec_from_str(search).ok()
        })
        .collect::<Vec<_>>();

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
    portal
        .client_tunnel_ips()
        .into_iter()
        .map(|(id, tun4, tun6)| (id, arb_client_host(g, id, tun4, tun6)))
        .collect::<BTreeMap<_, _>>()
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
    let edge = arb_edge_config(g);
    with_interface(
        Host::new(inner, latency, port, edge, g.nat_ip4.next()),
        ip4,
        ip6,
    )
}

fn arb_gateways(
    g: &mut Gen,
    portal: &StubPortal,
    start: Instant,
) -> BTreeMap<GatewayId, Host<RefGateway>> {
    portal
        .gateway_tunnel_ips()
        .into_iter()
        .map(|(id, tun4, tun6, site_id)| {
            // Gateways are always dual-stack on a fixed listening port.
            let site_specific = arb_site_specific_dns_records(g, portal, site_id, start);
            let inner = RefGateway::from_parts(g.fresh_private_key(), tun4, tun6, site_specific);
            let latency = g.latency(200);
            let edge = arb_edge_config(g);
            let host = Host::new(inner, latency, 52625, edge, g.nat_ip4.next());
            let host = with_interface(host, Some(g.socket_ip4.next()), Some(g.socket_ip6.next()));
            (id, host)
        })
        .collect::<BTreeMap<_, _>>()
}

fn arb_relays(g: &mut Gen) -> BTreeMap<RelayId, Host<u64>> {
    let n = g.count(1, 2);
    (0..n)
        .map(|_| {
            let id = g.fresh_relay_id();
            let seed = g.u64();
            let latency = g.latency(50);
            let host = Host::new(seed, latency, 3478, EdgeConfig::Open, g.nat_ip4.next());
            let host = with_interface(host, Some(g.socket_ip4.next()), Some(g.socket_ip6.next()));
            (id, host)
        })
        .collect::<BTreeMap<_, _>>()
}

fn with_interface<T>(mut host: Host<T>, ip4: Option<Ipv4Addr>, ip6: Option<Ipv6Addr>) -> Host<T> {
    host.update_interface(ip4, ip6);
    host
}

/// Network edge configurations worth varying in the system-level harness.
fn arb_edge_config(g: &mut Gen) -> EdgeConfig {
    match g.choose_index(3) {
        0 => EdgeConfig::Open,
        1 => {
            let filter = match g.choose_index(3) {
                0 => FilterMode::Open,
                1 => FilterMode::AddressRestricted,
                _ => FilterMode::PortRestricted,
            };

            EdgeConfig::Nat(Mapping::EndpointIndependent, filter)
        }
        _ => EdgeConfig::Nat(Mapping::EndpointDependent, FilterMode::PortRestricted),
    }
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
    portal
        .dns_resources()
        .into_iter()
        .map(|resource| arb_records_for_dns_resource(g, resource.address, at))
        .fold(DnsRecords::default(), merge_dns_records)
}

/// Site-specific DNS records for a gateway: records for the DNS resources in
/// `site`, plus (when non-empty) some site-specific TXT/SRV records.
fn arb_site_specific_dns_records(
    g: &mut Gen,
    portal: &StubPortal,
    site: SiteId,
    at: Instant,
) -> DnsRecords {
    portal
        .dns_resources()
        .into_iter()
        .filter(|resource| resource.sites.iter().any(|candidate| candidate.id == site))
        .map(|resource| arb_records_for_dns_resource(g, resource.address, at))
        .fold(DnsRecords::default(), merge_dns_records)
}

fn arb_records_for_dns_resource(g: &mut Gen, address: String, at: Instant) -> DnsRecords {
    match address.split_once('.') {
        Some(("*" | "**", base)) => arb_subdomain_records(g, base.to_owned(), at),
        _ => DnsRecords::from([(
            address.parse::<DomainName>().unwrap(),
            BTreeMap::from([(at, arb_resolved_ips(g))]),
        )]),
    }
}

fn merge_dns_records(mut records: DnsRecords, next: DnsRecords) -> DnsRecords {
    records.merge(next);
    records
}

fn arb_subdomain_records(g: &mut Gen, base: String, at: Instant) -> DnsRecords {
    let n = g.count(1, 3);
    (0..n)
        .map(|_| {
            let label = g.lower_ascii(3, 6);
            let domain = format!("{label}.{base}").parse::<DomainName>().unwrap();
            (domain, BTreeMap::from([(at, arb_resolved_ips(g))]))
        })
        .collect::<DnsRecords>()
}

/// 1..=5 "real" IP records drawn from the small documentation ranges (kept small
/// on purpose so two domains can share an IP).
fn arb_resolved_ips(g: &mut Gen) -> BTreeSet<OwnedRecordData> {
    let n = g.count(1, 5);
    (0..n)
        .map(|_| dns_types::records::ip(arb_dns_resource_ip(g)))
        .collect::<BTreeSet<_>>()
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
    (0..n)
        .map(|_| {
            let domain = arb_domain_name_string(g, 2, 3)
                .parse::<DomainName>()
                .unwrap();
            (domain, BTreeMap::from([(at, arb_dns_record_set(g))]))
        })
        .collect::<DnsRecords>()
}

/// 1..=5 records, weighted 3:1 IP:TXT (matching `dns_record`).
///
/// IP records are confined to the same documentation ranges as DNS *resource*
/// records (`arb_dns_resource_ip`). This is load-bearing: a domain's resolved IP
/// must never fall inside a CIDR/Internet resource's address range, or the
/// reference (which routes a `Destination::DomainName` by domain) and the SUT
/// (which routes by the resolved IP) would pick different gateways. CIDR resource
/// addresses correspondingly exclude these ranges (see `arb_cidr_resource_address`).
fn arb_dns_record_set(g: &mut Gen) -> BTreeSet<OwnedRecordData> {
    let n = g.count(1, 5);
    (0..n)
        .map(|_| {
            if g.flip(75) {
                return dns_types::records::ip(arb_dns_resource_ip(g));
            }

            // TXT: 6..=10 sections of 255 'a's.
            let sections = g.count(6, 10);
            let content = (0..sections)
                .flat_map(|_| std::iter::once(255u8).chain(std::iter::repeat_n(b'a', 255)))
                .collect::<Vec<_>>();
            dns_types::records::txt(content)
                .unwrap_or_else(|_| dns_types::records::ip(arb_dns_resource_ip(g)))
        })
        .collect::<BTreeSet<_>>()
}

// ---------------------------------------------------------------------------
// ICMP error hosts (H1) + TCP resources
// ---------------------------------------------------------------------------

/// Pick exactly half of the deduplicated record IPs and assign each an ICMP
/// error. A partial Fisher-Yates shuffle selects a uniform subset.
fn arb_icmp_error_hosts(g: &mut Gen, records: &DnsRecords, now: Instant) -> IcmpErrorHosts {
    let mut ips = records
        .ips_iter(now)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    let num_ips = ips.len();
    let pick = num_ips / 2;

    let chosen = (0..pick)
        .map(|i| {
            let remaining = num_ips - i;
            let j = i + g.choose_index(remaining);
            ips.swap(i, j);
            ips[i]
        })
        .collect::<Vec<_>>();

    let entries = chosen
        .into_iter()
        .map(|ip| (ip, arb_icmp_error(g)))
        .collect::<BTreeMap<_, _>>();

    IcmpErrorHosts::from_entries(entries)
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
    let mut all_domains = records.domains_iter().collect::<Vec<_>>();
    if all_domains.is_empty() {
        return BTreeMap::new();
    }

    let n = g.count(1, all_domains.len());
    (0..n)
        .filter_map(|i| {
            let idx = i + g.choose_index(all_domains.len() - i);
            all_domains.swap(i, idx);
            let domain = all_domains[i].clone();
            let port = g.u.int_in_range(1..=u16::MAX).unwrap_or(1);

            let has_icmp_error = records
                .domain_ips_iter(&domain, at)
                .any(|ip| icmp_error_hosts.icmp_error_for_ip(ip).is_some());
            if has_icmp_error {
                return None;
            }

            let addresses = records
                .domain_ips_iter(&domain, at)
                .map(|ip| SocketAddr::new(ip, port))
                .collect::<BTreeSet<_>>();
            (!addresses.is_empty()).then_some((domain, addresses))
        })
        .collect::<BTreeMap<_, _>>()
}

// ---------------------------------------------------------------------------
// DNS servers / upstreams / filters / addresses
// ---------------------------------------------------------------------------

/// Generate at least one IPv4 and one IPv6 Do53 server.
fn arb_do53_pool(g: &mut Gen) -> Vec<IpAddr> {
    let n4 = g.count(1, 3);
    let n6 = g.count(1, 3);
    (0..n4 + n6)
        .map(|i| {
            if i < n4 {
                IpAddr::V4(g.do53_ip4.next())
            } else {
                IpAddr::V6(g.do53_ip6.next())
            }
        })
        .collect::<Vec<_>>()
}

/// Per-element keep-bit subset of a fresh do53 pool that keeps at least one
/// server per address family, so DNS queries stay possible regardless of the
/// client's socket stack. 10% of the time the subset is deliberately empty to
/// keep the no-DNS-servers edge reachable.
fn arb_do53_subset(g: &mut Gen) -> Vec<IpAddr> {
    let pool = arb_do53_pool(g);

    if g.flip(10) {
        return Vec::new();
    }

    let subset = pool
        .iter()
        .copied()
        .filter(|_| g.bool())
        .collect::<Vec<_>>();
    let has_ipv4 = subset.iter().any(IpAddr::is_ipv4);
    let has_ipv6 = subset.iter().any(IpAddr::is_ipv6);

    subset
        .into_iter()
        .chain(
            pool.iter()
                .find(|ip| ip.is_ipv4())
                .filter(|_| !has_ipv4)
                .copied(),
        )
        .chain(
            pool.iter()
                .find(|ip| ip.is_ipv6())
                .filter(|_| !has_ipv6)
                .copied(),
        )
        .collect::<Vec<_>>()
}

fn arb_system_dns_servers(g: &mut Gen) -> Vec<IpAddr> {
    arb_do53_subset(g)
}

fn arb_upstream_do53_servers(g: &mut Gen) -> Vec<UpstreamDo53> {
    arb_do53_subset(g)
        .into_iter()
        .map(|ip| UpstreamDo53 { ip })
        .collect::<Vec<_>>()
}

fn arb_compatible_upstream_do53_servers(g: &mut Gen, state: &ReferenceState) -> Vec<UpstreamDo53> {
    let clients_share_ipv4 = state.clients.values().all(|client| client.ip4.is_some());
    let clients_share_ipv6 = state.clients.values().all(|client| client.ip6.is_some());

    arb_upstream_do53_servers(g)
        .into_iter()
        .filter(|server| {
            (server.ip.is_ipv4() && clients_share_ipv4)
                || (server.ip.is_ipv6() && clients_share_ipv6)
        })
        .collect::<Vec<_>>()
}

fn arb_upstream_doh_servers(g: &mut Gen) -> Vec<UpstreamDoH> {
    // Generate at most one DoH server.
    let n = g.count(0, 1);
    (0..n)
        .map(|_| {
            let url = match g.choose_index(4) {
                0 => dns_types::DoHUrl::quad9(),
                1 => dns_types::DoHUrl::cloudflare(),
                2 => dns_types::DoHUrl::google(),
                _ => dns_types::DoHUrl::opendns(),
            };
            UpstreamDoH { url }
        })
        .collect::<Vec<_>>()
}

fn arb_filters(g: &mut Gen) -> Vec<Filter> {
    let n = g.count(0, 2);
    (0..n).map(|_| arb_filter(g)).collect::<Vec<_>>()
}

fn arb_different_filters(g: &mut Gen, current: &[Filter]) -> Vec<Filter> {
    let filters = arb_filters(g);

    if filters != current {
        return filters;
    }

    if filters.is_empty() {
        vec![Filter::Icmp]
    } else {
        Vec::new()
    }
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
    (0..n)
        .map(|_| g.lower_ascii(3, 6))
        .collect::<Vec<_>>()
        .join(".")
}

/// The IP ranges that DNS records (resource + global) resolve into, plus the host
/// socket ranges and the DNS sentinel ranges.
///
/// CIDR / Internet resource addresses must avoid these: a resource whose range
/// contains a DNS-resolvable IP (or a sentinel) makes the reference (which routes
/// a `Destination::DomainName` by domain) and the SUT (which routes by the
/// resolved IP) disagree on the gateway. Defining a resource inside the DNS
/// sentinel range is also explicitly unsupported by connlib.
fn cidr_reserved_v4() -> [Ipv4Network; 4] {
    use tunnel_proto::DNS_SENTINELS_V4;
    [
        "192.0.2.0/24".parse::<Ipv4Network>().unwrap(), // TEST-NET-1 (documentation)
        "198.51.100.0/24".parse::<Ipv4Network>().unwrap(), // TEST-NET-2 (DNS resource real IPs)
        "203.0.113.0/24".parse::<Ipv4Network>().unwrap(), // TEST-NET-3 (host socket IPs)
        DNS_SENTINELS_V4,                               // 100.100.111.0/24
    ]
}

fn cidr_reserved_v6() -> [Ipv6Network; 3] {
    use tunnel_proto::DNS_SENTINELS_V6;
    [
        // The host (`2001:db80:1010:1010::/64`) and DNS (`2001:db80:2020:2020::/64`)
        // documentation subnets both live under `2001:db80::/32`.
        Ipv6Network::new_truncate(Ipv6Addr::new(0x2001, 0xDB80, 0, 0, 0, 0, 0, 0), 32).unwrap(),
        Ipv6Network::new_truncate(Ipv6Addr::new(0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0), 32).unwrap(),
        DNS_SENTINELS_V6, // fd00:2021:1111:8000:100:100:111:0/120
    ]
}

fn overlapping_reserved_v4(net: Ipv4Network) -> Option<Ipv4Network> {
    cidr_reserved_v4().into_iter().find(|reserved| {
        reserved.contains(net.network_address()) || net.contains(reserved.network_address())
    })
}

fn overlapping_reserved_v6(net: Ipv6Network) -> Option<Ipv6Network> {
    cidr_reserved_v6().into_iter().find(|reserved| {
        reserved.contains(net.network_address()) || net.contains(reserved.network_address())
    })
}

/// A CIDR address outside all reserved + documentation + DNS + sentinel ranges
/// (so it never overlaps the host / DNS / tunnel / sentinel ranges).
///
/// Wrap-around repair, no rejection loop: at most `cidr_reserved_*().len()`
/// advances, since each advance moves the network strictly past one reserved
/// range and the ranges are disjoint.
fn arb_cidr_resource_address(g: &mut Gen) -> IpNetwork {
    let ip = arb_non_reserved_ip(g);
    // Keep generated networks small enough to materialize individual hosts.
    let mask_offset = g.count(0, 8);
    match ip {
        IpAddr::V4(v4) => {
            let netmask = 32 - mask_offset as u8;
            let net = std::iter::successors(
                Some(Ipv4Network::new_truncate(v4, netmask).unwrap()),
                |network| {
                    let reserved = overlapping_reserved_v4(*network)?;
                    let next = u32::from(reserved.broadcast_address()).wrapping_add(1);
                    Ipv4Network::new_truncate(Ipv4Addr::from(next), netmask).ok()
                },
            )
            .find(|network| overlapping_reserved_v4(*network).is_none())
            .expect("reserved IPv4 ranges are finite");
            IpNetwork::V4(net)
        }
        IpAddr::V6(v6) => {
            let netmask = 128 - mask_offset as u8;
            let net = std::iter::successors(
                Some(Ipv6Network::new_truncate(v6, netmask).unwrap()),
                |network| {
                    let reserved = overlapping_reserved_v6(*network)?;
                    let next = u128::from(reserved.last_address()).wrapping_add(1);
                    Ipv6Network::new_truncate(Ipv6Addr::from(next), netmask).ok()
                },
            )
            .find(|network| overlapping_reserved_v6(*network).is_none())
            .expect("reserved IPv6 ranges are finite");
            IpNetwork::V6(net)
        }
    }
}

fn arb_different_cidr_resource_address(g: &mut Gen, current: IpNetwork) -> IpNetwork {
    let address = arb_cidr_resource_address(g);

    if address != current {
        return address;
    }

    match current {
        IpNetwork::V4(_) => IpNetwork::V6(
            Ipv6Network::new(Ipv6Addr::new(0x2001, 0xDB81, 0, 0, 0, 0, 0, 1), 128).unwrap(),
        ),
        IpNetwork::V6(_) => {
            IpNetwork::V4(Ipv4Network::new(Ipv4Addr::new(192, 0, 3, 1), 32).unwrap())
        }
    }
}

fn arb_more_specific_subnet(g: &mut Gen, address: IpNetwork, extra_bits: usize) -> IpNetwork {
    // Pick a host within `address`, then a longer prefix.
    let add = g.count(1, extra_bits.max(1));
    match address {
        IpNetwork::V4(n) => {
            let ip = host_in_v4(g, n);
            let netmask = (n.netmask() as usize + add).min(32) as u8;
            IpNetwork::new_truncate(IpAddr::V4(ip), netmask).unwrap()
        }
        IpNetwork::V6(n) => {
            let ip = host_in_v6(g, n);
            let netmask = (n.netmask() as usize + add).min(128) as u8;
            IpNetwork::new_truncate(IpAddr::V6(ip), netmask).unwrap()
        }
    }
}

/// An IP outside connlib's reserved ranges, via wrap-around repair (no rejection).
fn arb_non_reserved_ip(g: &mut Gen) -> IpAddr {
    use tunnel_proto::{
        DNS_SENTINELS_V4, DNS_SENTINELS_V6, IPV4_RESOURCES, IPV4_TUNNEL, IPV6_RESOURCES,
        IPV6_TUNNEL,
    };

    if g.bool() {
        let undesired = [
            Ipv4Network::new(Ipv4Addr::BROADCAST, 32).unwrap(),
            Ipv4Network::new(Ipv4Addr::UNSPECIFIED, 32).unwrap(),
            Ipv4Network::new(Ipv4Addr::new(224, 0, 0, 0), 4).unwrap(),
            DNS_SENTINELS_V4,
            IPV4_RESOURCES,
            IPV4_TUNNEL,
        ];
        let ip = std::iter::successors(Some(Ipv4Addr::from(g.u32())), |ip| {
            let range = undesired.iter().find(|range| range.contains(*ip))?;
            Some(Ipv4Addr::from(
                u32::from(range.broadcast_address()).wrapping_add(1),
            ))
        })
        .find(|ip| undesired.iter().all(|range| !range.contains(*ip)))
        .expect("undesired IPv4 ranges are finite");
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
        let ip = std::iter::successors(Some(Ipv6Addr::from(hi | lo)), |ip| {
            let range = undesired.iter().find(|range| range.contains(*ip))?;
            Some(Ipv6Addr::from(
                u128::from(range.last_address()).wrapping_add(1),
            ))
        })
        .find(|ip| undesired.iter().all(|range| !range.contains(*ip)))
        .expect("undesired IPv6 ranges are finite");
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
    ChangeCidrResourceAddress,
    MoveResourceToNewSite,
    ChangeFiltersOfResource,
    ChangeResourceType,
    RemoveResource,
    ReconnectPortal,
    RestartClient,
    SetInternetResourceState,
    DeauthorizeWhileGatewayIsPartitioned,
    UpdateDnsRecords,
    SendPacket,
    SendDnsQuery,
    // Static device pool membership update.
    UpdateStaticDevicePool,
}

fn move_resource_candidates(state: &ReferenceState) -> Vec<(Resource, Site)> {
    let sites = state.regular_sites();

    state
        .cidr_and_dns_resources_on_any_client()
        .into_iter()
        .flat_map(|resource| {
            sites.clone().into_iter().filter_map(move |site| {
                (!resource.is_exclusively_at(&site)).then(|| (resource.clone(), site))
            })
        })
        .collect::<Vec<_>>()
}

fn arb_resource_with_different_type(
    g: &mut Gen,
    state: &ReferenceState,
    resource: &Resource,
) -> Resource {
    #[derive(Clone, Copy)]
    enum ResourceType {
        Cidr,
        Dns,
        StaticDevicePool,
    }

    let resource_type = match resource {
        Resource::Cidr(_) => [ResourceType::Dns, ResourceType::StaticDevicePool][g.choose_index(2)],
        Resource::Dns(_) => [ResourceType::Cidr, ResourceType::StaticDevicePool][g.choose_index(2)],
        Resource::StaticDevicePool(_) => [ResourceType::Cidr, ResourceType::Dns][g.choose_index(2)],
        Resource::Internet(_) | Resource::DynamicDevicePool(_) => {
            unreachable!("only user-editable resource types can replace one another")
        }
    };

    let sites = resource.sites().into_iter().cloned().collect::<Vec<_>>();
    let site = sites
        .first()
        .cloned()
        .unwrap_or_else(|| pick_site(g, &state.regular_sites()));
    let id = resource.id();
    let name = resource.name().to_owned();
    let filters = resource.filters().to_vec();

    match resource_type {
        ResourceType::Cidr => Resource::Cidr(CidrResource {
            id,
            address: arb_cidr_resource_address(g),
            name,
            address_description: arb_address_description(g),
            sites: vec![site],
            filters,
        }),
        ResourceType::Dns => {
            let base = arb_domain_name_string(g, 2, 3);
            let address = match g.choose_index(3) {
                0 => base,
                1 => format!("*.{base}"),
                _ => format!("**.{base}"),
            };

            Resource::Dns(DnsResource {
                id,
                address,
                name,
                address_description: arb_address_description(g),
                sites: vec![site],
                ip_stack: arb_ip_stack_kind(g),
                filters,
            })
        }
        ResourceType::StaticDevicePool => Resource::StaticDevicePool(StaticDevicePoolResource {
            id,
            name,
            devices: arb_online_static_pool_members(g, state),
            filters,
        }),
    }
}

fn arb_transition(g: &mut Gen, state: &ReferenceState, now: Instant) -> Option<Transition> {
    let addable_resources = state.resources_unknown_to_all_clients();
    let cidr_resources = state.cidr_resources_on_any_client();
    let move_resources = move_resource_candidates(state);
    let filter_resources = state.resources_with_filters_on_any_client();
    let replaceable_resources = state.replaceable_resources_on_any_client();
    let removable_resources = state.removable_resource_ids();
    let deauthorizable_resources = state.deauthorizable_resource_ids();
    let client_ids = state.all_client_ids();
    let dns_record_domains = state.dns_resource_domains();
    let packet_targets = packet_targets(state, now);
    let dns_query_targets = dns_query_targets(state, now);
    let static_device_pools = state.static_device_pools_on_any_client();

    // Build the legal action list. Data-plane actions stay more frequent because
    // they drive most of the tunnel state machine; libFuzzer chooses the concrete
    // destination, protocol and fields from subsequent bytes.
    use TransitionKind as K;

    let legal = [
        Some((K::UpdateSystemDnsServers, 1)),
        Some((K::UpdateUpstreamDo53Servers, 1)),
        Some((K::UpdateUpstreamDoHServers, 1)),
        Some((K::UpdateUpstreamSearchDomain, 1)),
        Some((K::RoamClient, 1)),
        Some((K::DeployNewRelays, 1)),
        Some((K::PartitionRelaysFromPortal, 1)),
        Some((K::RebootRelaysWhilePartitioned, 1)),
        Some((K::Idle, 1)),
        (!addable_resources.is_empty()).then_some((K::AddResource, 5)),
        (!cidr_resources.is_empty()).then_some((K::ChangeCidrResourceAddress, 1)),
        (!move_resources.is_empty()).then_some((K::MoveResourceToNewSite, 1)),
        (!filter_resources.is_empty()).then_some((K::ChangeFiltersOfResource, 1)),
        (!replaceable_resources.is_empty()).then_some((K::ChangeResourceType, 2)),
        (!removable_resources.is_empty()).then_some((K::RemoveResource, 1)),
        (!deauthorizable_resources.is_empty())
            .then_some((K::DeauthorizeWhileGatewayIsPartitioned, 1)),
        (!client_ids.is_empty()).then_some((K::ReconnectPortal, 1)),
        (!client_ids.is_empty()).then_some((K::RestartClient, 1)),
        (!client_ids.is_empty()).then_some((K::SetInternetResourceState, 1)),
        (!dns_record_domains.is_empty()).then_some((K::UpdateDnsRecords, 5)),
        (!packet_targets.is_empty()).then_some((K::SendPacket, 50)),
        (!dns_query_targets.is_empty()).then_some((K::SendDnsQuery, 10)),
        (!static_device_pools.is_empty()).then_some((K::UpdateStaticDevicePool, 2)),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>();

    // 2. Weighted pick over the legal list.
    let kind = weighted_choose(g, &legal)?;

    // 3. Generate the chosen arm's payload from the following bytes.
    let transition = match kind {
        K::UpdateSystemDnsServers => Transition::UpdateSystemDnsServers {
            servers: arb_system_dns_servers(g),
        },
        K::UpdateUpstreamDo53Servers => {
            Transition::UpdateUpstreamDo53Servers(arb_compatible_upstream_do53_servers(g, state))
        }
        K::UpdateUpstreamDoHServers => {
            Transition::UpdateUpstreamDoHServers(arb_upstream_doh_servers(g))
        }
        K::UpdateUpstreamSearchDomain => {
            let domains = state.portal.dns_resources();
            let candidates = domains
                .iter()
                .filter_map(|r| {
                    let (_, s) = r.address.split_once('.')?;
                    DomainName::vec_from_str(s).ok()
                })
                .collect::<Vec<_>>();
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
            // Mirror `transition::roam_client`: both windows in 0..3000ms.
            let dead_window = Duration::from_millis(g.count(0, 2999) as u64);
            let portal_window = Duration::from_millis(g.count(0, 2999) as u64);
            Transition::RoamClient {
                client_id,
                ip4,
                ip6,
                nat_ip4: g.nat_ip4.next(),
                dead_window,
                portal_window,
            }
        }
        K::DeployNewRelays => Transition::DeployNewRelays(arb_relays(g)),
        K::PartitionRelaysFromPortal => Transition::PartitionRelaysFromPortal,
        K::RebootRelaysWhilePartitioned => {
            // Reboot the *existing* relays with fresh credentials (same ids).
            let ids = state.relays.keys().copied().collect::<Vec<_>>();
            let relays = ids
                .into_iter()
                .map(|id| {
                    let seed = g.u64();
                    let latency = g.latency(50);
                    let host = Host::new(seed, latency, 3478, EdgeConfig::Open, g.nat_ip4.next());
                    let host =
                        with_interface(host, Some(g.socket_ip4.next()), Some(g.socket_ip6.next()));
                    (id, host)
                })
                .collect::<BTreeMap<_, _>>();
            Transition::RebootRelaysWhilePartitioned(relays)
        }
        K::Idle => Transition::Idle,
        K::AddResource => {
            let resource = addable_resources[g.choose_index(addable_resources.len())].clone();
            Transition::AddResource(resource)
        }
        K::ChangeCidrResourceAddress => {
            let resource = cidr_resources[g.choose_index(cidr_resources.len())].clone();
            let new_address = arb_different_cidr_resource_address(g, resource.address);
            Transition::ChangeCidrResourceAddress {
                resource,
                new_address,
            }
        }
        K::MoveResourceToNewSite => {
            let (resource, new_site) = move_resources[g.choose_index(move_resources.len())].clone();
            Transition::MoveResourceToNewSite { resource, new_site }
        }
        K::ChangeFiltersOfResource => {
            let resource = filter_resources[g.choose_index(filter_resources.len())].clone();
            let new_filters = arb_different_filters(g, resource.filters());
            Transition::ChangeFiltersOfResource {
                resource,
                new_filters,
            }
        }
        K::ChangeResourceType => {
            let old_resource =
                replaceable_resources[g.choose_index(replaceable_resources.len())].clone();
            let new_resource = arb_resource_with_different_type(g, state, &old_resource);
            Transition::ChangeResourceType {
                old_resource,
                new_resource,
            }
        }
        K::RemoveResource => {
            let id = removable_resources[g.choose_index(removable_resources.len())];
            Transition::RemoveResource(id)
        }
        K::DeauthorizeWhileGatewayIsPartitioned => {
            let id = deauthorizable_resources[g.choose_index(deauthorizable_resources.len())];
            Transition::DeauthorizeWhileGatewayIsPartitioned(id)
        }
        K::ReconnectPortal => {
            let client_id = client_ids[g.choose_index(client_ids.len())];
            Transition::ReconnectPortal { client_id }
        }
        K::RestartClient => {
            let client_id = client_ids[g.choose_index(client_ids.len())];
            let key = g.fresh_private_key();
            Transition::RestartClient { client_id, key }
        }
        K::SetInternetResourceState => {
            let client_id = client_ids[g.choose_index(client_ids.len())];
            let active = g.bool();
            Transition::SetInternetResourceState { client_id, active }
        }
        K::UpdateDnsRecords => {
            let domain = dns_record_domains[g.choose_index(dns_record_domains.len())].clone();
            let records = arb_dns_record_set(g);
            Transition::UpdateDnsRecords { domain, records }
        }
        K::SendPacket => {
            let target = packet_targets[g.choose_index(packet_targets.len())].clone();
            arb_packet(g, state, target)
        }
        K::SendDnsQuery => {
            let target = dns_query_targets[g.choose_index(dns_query_targets.len())].clone();
            arb_dns_query(g, target)
        }
        K::UpdateStaticDevicePool => {
            let pool = static_device_pools[g.choose_index(static_device_pools.len())].clone();
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
    let total = opts.iter().map(|(_, weight)| *weight).sum::<u32>();
    let pick = g.u.int_in_range(0..=total - 1).unwrap_or(0);

    opts.iter()
        .scan(0, |end, (kind, weight)| {
            *end += *weight;
            Some((*kind, *end))
        })
        .find_map(|(kind, end)| (pick < end).then_some(kind))
}

/// The semantic destination selected by the state-aware grammar.
///
/// This deliberately remains more structured than an arbitrary IP packet. The
/// SUT still has to classify the materialized destination, while the generator
/// and reference model retain enough intent to reason about the action without
/// reproducing all of the production classifier's inputs from raw bytes.
#[derive(Clone)]
enum PacketTarget {
    Cidr {
        client_id: ClientId,
        src: IpAddr,
        network: IpNetwork,
        filters: Vec<Filter>,
    },
    Dns {
        client_id: ClientId,
        src: IpAddr,
        domain: DomainName,
        filters: Vec<Filter>,
        tcp_service_ports: Vec<u16>,
    },
    NonResource {
        client_id: ClientId,
        src: IpAddr,
        dst: IpAddr,
    },
    ConnectedGateway {
        client_id: ClientId,
        src: IpAddr,
        network: IpNetwork,
    },
    Peer {
        client_id: ClientId,
        src: IpAddr,
        dst: IpAddr,
        filters: Vec<Filter>,
    },
}

#[derive(Clone)]
enum DstSpec {
    Domain(DomainName),
    Ip(IpAddr),
}

fn packet_targets(state: &ReferenceState, now: Instant) -> Vec<PacketTarget> {
    state
        .ipv4_cidr_resource_dsts()
        .into_iter()
        .map(|(client_id, network, filters)| PacketTarget::Cidr {
            client_id,
            src: IpAddr::V4(state.clients[&client_id].inner().tunnel_ip4),
            network: network.into(),
            filters,
        })
        .chain(
            state
                .ipv6_cidr_resource_dsts()
                .into_iter()
                .map(|(client_id, network, filters)| PacketTarget::Cidr {
                    client_id,
                    src: IpAddr::V6(state.clients[&client_id].inner().tunnel_ip6),
                    network: network.into(),
                    filters,
                }),
        )
        .chain(
            state
                .resolved_v4_domains()
                .into_iter()
                .map(|(client_id, domain, filters)| PacketTarget::Dns {
                    client_id,
                    src: IpAddr::V4(state.clients[&client_id].inner().tunnel_ip4),
                    tcp_service_ports: tcp_service_ports(state, &domain, true),
                    domain,
                    filters,
                }),
        )
        .chain(
            state
                .resolved_v6_domains()
                .into_iter()
                .map(|(client_id, domain, filters)| PacketTarget::Dns {
                    client_id,
                    src: IpAddr::V6(state.clients[&client_id].inner().tunnel_ip6),
                    tcp_service_ports: tcp_service_ports(state, &domain, false),
                    domain,
                    filters,
                }),
        )
        .chain(
            state
                .resolved_ip4_for_non_resources(&state.global_dns_records, now)
                .into_iter()
                .map(|(client_id, dst)| PacketTarget::NonResource {
                    client_id,
                    src: IpAddr::V4(state.clients[&client_id].inner().tunnel_ip4),
                    dst: IpAddr::V4(dst),
                }),
        )
        .chain(
            state
                .resolved_ip6_for_non_resources(&state.global_dns_records, now)
                .into_iter()
                .map(|(client_id, dst)| PacketTarget::NonResource {
                    client_id,
                    src: IpAddr::V6(state.clients[&client_id].inner().tunnel_ip6),
                    dst: IpAddr::V6(dst),
                }),
        )
        .chain(
            state
                .connected_gateway_ipv4_ips()
                .into_iter()
                .map(|(client_id, network)| PacketTarget::ConnectedGateway {
                    client_id,
                    src: IpAddr::V4(state.clients[&client_id].inner().tunnel_ip4),
                    network: network.into(),
                }),
        )
        .chain(
            state
                .connected_gateway_ipv6_ips()
                .into_iter()
                .map(|(client_id, network)| PacketTarget::ConnectedGateway {
                    client_id,
                    src: IpAddr::V6(state.clients[&client_id].inner().tunnel_ip6),
                    network: network.into(),
                }),
        )
        .chain(state.pool_routed_other_client_tun_ips().into_iter().map(
            |(client_id, dst, filters)| {
                let client = state.clients[&client_id].inner();
                let src = match dst {
                    IpAddr::V4(_) => IpAddr::V4(client.tunnel_ip4),
                    IpAddr::V6(_) => IpAddr::V6(client.tunnel_ip6),
                };
                PacketTarget::Peer {
                    client_id,
                    src,
                    dst,
                    filters,
                }
            },
        ))
        .collect::<Vec<_>>()
}

fn tcp_service_ports(state: &ReferenceState, domain: &DomainName, ipv4: bool) -> Vec<u16> {
    state
        .tcp_resources
        .get(domain)
        .into_iter()
        .flatten()
        .filter(|address| address.is_ipv4() == ipv4)
        .map(SocketAddr::port)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>()
}

fn arb_packet(g: &mut Gen, state: &ReferenceState, target: PacketTarget) -> Transition {
    match target {
        PacketTarget::Cidr {
            client_id,
            src,
            network,
            filters,
        } => {
            let dst = DstSpec::Ip(host_in_network(g, network));
            arb_filtered_packet(g, state, client_id, src, dst, &filters)
        }
        PacketTarget::Dns {
            client_id,
            src,
            domain,
            filters,
            tcp_service_ports,
        } => {
            let can_connect_tcp = filters.is_empty()
                || filters
                    .iter()
                    .any(|filter| matches!(filter, Filter::Tcp(_)));

            if can_connect_tcp && !tcp_service_ports.is_empty() && g.bool() {
                arb_tcp_connection(
                    g,
                    state,
                    client_id,
                    src,
                    domain,
                    &filters,
                    &tcp_service_ports,
                )
            } else {
                arb_filtered_packet(g, state, client_id, src, DstSpec::Domain(domain), &filters)
            }
        }
        PacketTarget::NonResource {
            client_id,
            src,
            dst,
        } => arb_unfiltered_packet(g, state, client_id, src, dst, true),
        PacketTarget::ConnectedGateway {
            client_id,
            src,
            network,
        } => {
            let dst = host_in_network(g, network);
            arb_unfiltered_packet(g, state, client_id, src, dst, false)
        }
        PacketTarget::Peer {
            client_id,
            src,
            dst,
            filters,
        } => arb_filtered_packet(g, state, client_id, src, DstSpec::Ip(dst), &filters),
    }
}

fn host_in_network(g: &mut Gen, network: IpNetwork) -> IpAddr {
    match network {
        IpNetwork::V4(network) => IpAddr::V4(host_in_v4(g, network)),
        IpNetwork::V6(network) => IpAddr::V6(host_in_v6(g, network)),
    }
}

fn host_in_v4(g: &mut Gen, network: Ipv4Network) -> Ipv4Addr {
    let host_bits = 32 - network.netmask();
    let base = u32::from(network.network_address());
    let off = if host_bits == 0 {
        0
    } else if host_bits >= 32 {
        g.u32()
    } else {
        g.u32() % (1u32 << host_bits)
    };
    Ipv4Addr::from(base.wrapping_add(off))
}

fn host_in_v6(g: &mut Gen, network: Ipv6Network) -> Ipv6Addr {
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
    Ipv6Addr::from(base.wrapping_add(off))
}

/// Generate a packet for a resource-like destination. Most draws use a filter
/// that admits the packet; the remainder deliberately exercise the drop path.
fn arb_filtered_packet(
    g: &mut Gen,
    state: &ReferenceState,
    client_id: ClientId,
    src: IpAddr,
    dst: DstSpec,
    filters: &[Filter],
) -> Transition {
    let usable = filters
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
        .collect::<Vec<_>>();

    let use_matching = !usable.is_empty() && g.flip(80);

    if use_matching {
        let filter = usable[g.choose_index(usable.len())];
        match filter {
            Filter::Icmp => arb_icmp_packet(g, state, client_id, src, dst),
            Filter::Udp(PortRange {
                port_range_start,
                port_range_end,
            }) => {
                let dport =
                    g.u.int_in_range(port_range_start..=port_range_end)
                        .unwrap_or(port_range_start);
                arb_udp_packet(g, state, client_id, src, dst, dport)
            }
            Filter::Tcp(_) => unreachable!("TCP filters were excluded above"),
        }
    } else {
        if g.bool() {
            arb_icmp_packet(g, state, client_id, src, dst)
        } else {
            let dport = arb_non_dns_port(g);
            arb_udp_packet(g, state, client_id, src, dst, dport)
        }
    }
}

fn arb_tcp_connection(
    g: &mut Gen,
    state: &ReferenceState,
    client_id: ClientId,
    src: IpAddr,
    domain: DomainName,
    filters: &[Filter],
    service_ports: &[u16],
) -> Transition {
    let tcp_filters = filters
        .iter()
        .filter_map(|f| match f {
            Filter::Tcp(r) => Some(*r),
            Filter::Udp(_) | Filter::Icmp => None,
        })
        .collect::<Vec<_>>();

    let matching_service_ports = service_ports
        .iter()
        .copied()
        .filter(|port| {
            filters.is_empty()
                || tcp_filters
                    .iter()
                    .any(|range| (range.port_range_start..=range.port_range_end).contains(port))
        })
        .collect::<Vec<_>>();

    let dport = if !matching_service_ports.is_empty() && g.flip(75) {
        matching_service_ports[g.choose_index(matching_service_ports.len())]
    } else if !tcp_filters.is_empty() {
        let r = tcp_filters[g.choose_index(tcp_filters.len())];
        g.u.int_in_range(r.port_range_start..=r.port_range_end)
            .unwrap_or(r.port_range_start)
    } else {
        arb_non_dns_port(g).max(1)
    };

    let (sport, dport) = g.fresh_tcp_connection(dport);
    let dst = arb_destination(g, DstSpec::Domain(domain));
    let expected_route = state.route_for_packet(client_id, &dst, Protocol::Tcp(dport.0));
    Transition::ConnectTcp {
        client_id,
        src,
        dst,
        expected_route,
        sport,
        dport,
    }
}

fn arb_unfiltered_packet(
    g: &mut Gen,
    state: &ReferenceState,
    client_id: ClientId,
    src: IpAddr,
    dst: IpAddr,
    allow_dns_ports: bool,
) -> Transition {
    if g.bool() {
        arb_icmp_packet(g, state, client_id, src, DstSpec::Ip(dst))
    } else {
        let dport = if allow_dns_ports {
            g.u16()
        } else {
            arb_non_dns_port(g)
        };
        arb_udp_packet(g, state, client_id, src, DstSpec::Ip(dst), dport)
    }
}

#[derive(Clone)]
struct DnsQueryTarget {
    client_id: ClientId,
    dns_server: dns::Upstream,
    name: DnsNameSpec,
}

#[derive(Clone)]
enum DnsNameSpec {
    Concrete {
        domain: DomainName,
        rtypes: Vec<RecordType>,
    },
    Wildcard {
        base: String,
    },
    KnownDevice {
        base: String,
        labels: Vec<String>,
    },
    UnknownDevice {
        base: String,
    },
}

fn dns_query_targets(state: &ReferenceState, now: Instant) -> Vec<DnsQueryTarget> {
    let servers = state.reachable_dns_servers();
    let labels = state.portal.device_labels();

    state
        .all_domains(now)
        .into_iter()
        .flat_map(|(client_id, domain, rtypes)| {
            servers
                .iter()
                .filter(move |(id, _)| *id == client_id)
                .map(move |(_, dns_server)| DnsQueryTarget {
                    client_id,
                    dns_server: dns_server.clone(),
                    name: DnsNameSpec::Concrete {
                        domain: domain.clone(),
                        rtypes: rtypes.clone(),
                    },
                })
        })
        .chain(
            state
                .wildcard_dns_resources()
                .into_iter()
                .flat_map(|(client_id, resource)| {
                    servers.iter().filter(move |(id, _)| *id == client_id).map(
                        move |(_, dns_server)| DnsQueryTarget {
                            client_id,
                            dns_server: dns_server.clone(),
                            name: DnsNameSpec::Wildcard {
                                base: resource.address.trim_start_matches("*.").to_owned(),
                            },
                        },
                    )
                }),
        )
        .chain(state.device_pool_query_targets().into_iter().flat_map(
            |(client_id, resource, dns_server)| {
                let base = resource.address.trim_start_matches("*.").to_owned();
                [
                    (!labels.is_empty()).then(|| DnsQueryTarget {
                        client_id,
                        dns_server: dns_server.clone(),
                        name: DnsNameSpec::KnownDevice {
                            base: base.clone(),
                            labels: labels.clone(),
                        },
                    }),
                    Some(DnsQueryTarget {
                        client_id,
                        dns_server,
                        name: DnsNameSpec::UnknownDevice { base },
                    }),
                ]
                .into_iter()
                .flatten()
            },
        ))
        .collect::<Vec<_>>()
}

fn arb_dns_query(g: &mut Gen, target: DnsQueryTarget) -> Transition {
    let (domain, rtypes) = match target.name {
        DnsNameSpec::Concrete { domain, rtypes } => (domain, rtypes),
        DnsNameSpec::Wildcard { base } => {
            let domain = format!("{}.{}", g.lower_ascii(3, 6), base)
                .parse::<DomainName>()
                .unwrap();
            let rtypes = if g.bool() {
                vec![RecordType::A]
            } else {
                vec![RecordType::AAAA]
            };
            (domain, rtypes)
        }
        DnsNameSpec::KnownDevice { base, labels } => {
            let label = &labels[g.choose_index(labels.len())];
            (
                format!("{label}.{base}").parse::<DomainName>().unwrap(),
                vec![RecordType::A],
            )
        }
        DnsNameSpec::UnknownDevice { base } => (
            format!("{}.{}", g.lower_ascii(3, 6), base)
                .parse::<DomainName>()
                .unwrap(),
            vec![RecordType::A],
        ),
    };

    let r_type = arb_maybe_available_response_rtype(g, &rtypes);
    let domain = matches!(r_type, RecordType::PTR)
        .then(|| DomainName::reverse_from_addr(arb_ptr_query_ip(g)).unwrap())
        .unwrap_or(domain);

    Transition::SendDnsQuery {
        client_id: target.client_id,
        query: DnsQuery {
            domain,
            r_type,
            query_id: arb_dns_query_id(g),
            dns_server: target.dns_server,
            transport: arb_dns_transport(g),
        },
    }
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
    if g.bool() { g.u16() } else { 33333 }
}

/// If the domain has an A/AAAA record, pick from {PTR, MX, A, AAAA};
/// otherwise pick from the available record types.
fn arb_maybe_available_response_rtype(g: &mut Gen, available: &[RecordType]) -> RecordType {
    if available.contains(&RecordType::A) || available.contains(&RecordType::AAAA) {
        // A/AAAA are weighted up: they are the only types that resolve DNS
        // resources to (proxy) IPs and thereby feed the packet / NAT paths,
        // while PTR and MX only exercise the negative answers.
        let choices = [
            RecordType::A,
            RecordType::A,
            RecordType::AAAA,
            RecordType::AAAA,
            RecordType::PTR,
            RecordType::MX,
        ];
        choices[g.choose_index(choices.len())]
    } else if available.is_empty() {
        // No records to choose from; default to A. `all_domains` normally filters
        // out empty-rtype domains, so this only keeps the helper total.
        RecordType::A
    } else {
        available[g.choose_index(available.len())]
    }
}

/// Generate a PTR target inside a resource range or anywhere in the IP space.
fn arb_ptr_query_ip(g: &mut Gen) -> IpAddr {
    use tunnel_proto::{IPV4_RESOURCES, IPV6_RESOURCES};
    match g.choose_index(3) {
        0 => IpAddr::V4(host_in_v4(g, IPV4_RESOURCES)),
        1 => IpAddr::V6(host_in_v6(g, IPV6_RESOURCES)),
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

/// Select any subset of online clients (as `/32` + `/128` device members) and
/// preserve every offline member already in the pool.
fn arb_static_pool_members(
    g: &mut Gen,
    state: &ReferenceState,
    pool: &StaticDevicePoolResource,
) -> Vec<DevicePoolMember> {
    arb_online_static_pool_members(g, state)
        .into_iter()
        .chain(offline_static_pool_members(state, pool))
        .collect()
}

fn arb_online_static_pool_members(g: &mut Gen, state: &ReferenceState) -> Vec<DevicePoolMember> {
    state
        .clients
        .iter()
        .filter(|_| g.bool())
        .map(|(id, client)| {
            let client = client.inner();
            DevicePoolMember {
                id: *id,
                ipv4: Ipv4Network::new(client.tunnel_ip4, 32).unwrap(),
                ipv6: Ipv6Network::new(client.tunnel_ip6, 128).unwrap(),
            }
        })
        .collect()
}

fn offline_static_pool_members(
    state: &ReferenceState,
    pool: &StaticDevicePoolResource,
) -> impl Iterator<Item = DevicePoolMember> {
    let online_ids = state.clients.keys().copied().collect::<BTreeSet<_>>();

    pool.devices
        .iter()
        .filter(move |d| !online_ids.contains(&d.id))
        .cloned()
}

fn arb_icmp_packet(
    g: &mut Gen,
    state: &ReferenceState,
    client_id: ClientId,
    src: IpAddr,
    dst: DstSpec,
) -> Transition {
    let (seq, identifier) = g.fresh_icmp_packet();
    let resolved_ip = g.u32();
    let payload = g.fresh_payload();
    let dst = into_destination(dst, resolved_ip);
    let expected_route = state.route_for_packet(client_id, &dst, Protocol::IcmpEcho(identifier.0));
    Transition::SendIcmpPacket {
        client_id,
        src,
        dst,
        expected_route,
        seq,
        identifier,
        payload,
    }
}

fn arb_udp_packet(
    g: &mut Gen,
    state: &ReferenceState,
    client_id: ClientId,
    src: IpAddr,
    dst: DstSpec,
    dport: u16,
) -> Transition {
    let (sport, dport) = g.fresh_udp_packet(dport);
    let resolved_ip = g.u32();
    let payload = g.fresh_payload();
    let dst = into_destination(dst, resolved_ip);
    let expected_route = state.route_for_packet(client_id, &dst, Protocol::Udp(dport.0));
    Transition::SendUdpPacket {
        client_id,
        src,
        dst,
        expected_route,
        sport,
        dport,
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
    let p = g.u.int_in_range(0..=65533u32).unwrap_or(0);
    let p = p + u32::from(p >= 53);
    let p = p + u32::from(p >= 53535);
    p as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exhausted_probability_draws_are_false() {
        let mut input = Unstructured::new(&[]);
        let mut g = Gen::new(&mut input);

        assert!(!g.flip(50));
    }

    /// The non-DNS-port mapping must be a bijection onto `[0, 65535] \ {53, 53535}`:
    /// total (never panics / rejects), never produces a hole, and hits every
    /// other value exactly once.
    #[test]
    fn non_dns_port_is_a_bijection() {
        let mut seen = std::collections::BTreeSet::new();
        for idx in 0..=65533u32 {
            // Reproduce the body of `arb_non_dns_port` for a known index.
            let p = idx + u32::from(idx >= 53);
            let p = p + u32::from(p >= 53535);
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

        let ramp = (0u8..=255).cycle().take(8192).collect::<Vec<_>>();
        run_fuzz_case_structured(&ramp);
    }
}

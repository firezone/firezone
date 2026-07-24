use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Instant,
};

use connlib_model::{ClientId, GatewayId, RelayId, Site, SiteId};
use dns_types::{DomainName, OwnedRecordData};
use ip_network::IpNetwork;
use tunnel_proto::MaliciousBehaviour;
use tunnel_proto::messages::{Filter, PortRange};

use super::context::Generator;
use super::values::{
    arb_address_description, arb_cidr_resource_address, arb_domain_name_string, arb_filters,
    arb_ip_stack_kind, arb_more_specific_subnet, arb_system_dns_servers, arb_upstream_do53_servers,
    arb_upstream_doh_servers,
};
use crate::dns_records::DnsRecords;
use crate::icmp_error_hosts::IcmpErrorHosts;
use crate::ref_client::RefClient;
use crate::ref_gateway::RefGateway;
use crate::reference::ReferenceState;
use crate::resource::{CidrResource, DnsResource, DynamicDevicePoolResource, InternetResource};
use crate::sim_net::{EdgeConfig, FilterMode, Host, Mapping, RoutingTable};
use crate::stub_portal::{StaticDevicePoolPlan, StubPortal};

pub(super) fn generate(g: &mut Generator, start: Instant) -> ReferenceState {
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

fn arb_stub_portal(g: &mut Generator) -> StubPortal {
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

pub(super) fn pick_site(g: &mut Generator, sites: &[Site]) -> Site {
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

fn arb_cidr_resource(g: &mut Generator, sites: Vec<Site>) -> CidrResource {
    CidrResource {
        id: g.fresh_resource_id(),
        address: arb_cidr_resource_address(g),
        name: g.lower_ascii(4, 10),
        address_description: arb_address_description(g),
        sites,
        filters: arb_filters(g),
    }
}

fn arb_dns_resource(g: &mut Generator, sites: Vec<Site>) -> DnsResource {
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

fn arb_internet_resource(g: &mut Generator, sites: Vec<Site>) -> InternetResource {
    InternetResource {
        name: "Internet Resource".to_owned(),
        id: g.fresh_resource_id(),
        sites,
    }
}

fn arb_dynamic_device_pool_resource(g: &mut Generator) -> DynamicDevicePoolResource {
    let base = arb_domain_name_string(g, 2, 3);
    DynamicDevicePoolResource {
        id: g.fresh_resource_id(),
        name: g.lower_ascii(4, 10),
        address: format!("*.{base}"),
    }
}

fn arb_static_device_pool_plan(g: &mut Generator) -> StaticDevicePoolPlan {
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
fn arb_extra_cidr_resources(
    g: &mut Generator,
    existing: &BTreeSet<CidrResource>,
) -> Vec<CidrResource> {
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
fn arb_extra_dns_resources(
    g: &mut Generator,
    existing: &BTreeSet<DnsResource>,
) -> Vec<DnsResource> {
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

fn arb_search_domain(
    g: &mut Generator,
    dns_resources: &BTreeSet<DnsResource>,
) -> Option<DomainName> {
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

fn arb_clients(g: &mut Generator, portal: &StubPortal) -> BTreeMap<ClientId, Host<RefClient>> {
    portal
        .client_tunnel_ips()
        .into_iter()
        .map(|(id, tun4, tun6)| (id, arb_client_host(g, id, tun4, tun6)))
        .collect::<BTreeMap<_, _>>()
}

fn arb_client_host(
    g: &mut Generator,
    id: ClientId,
    tun4: Ipv4Addr,
    tun6: Ipv6Addr,
) -> Host<RefClient> {
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
    with_interface(Host::new(inner, latency, port, edge, g.nat_ip4()), ip4, ip6)
}

fn arb_gateways(
    g: &mut Generator,
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
            let host = Host::new(inner, latency, 52625, edge, g.nat_ip4());
            let host = with_interface(host, Some(g.socket_ip4()), Some(g.socket_ip6()));
            (id, host)
        })
        .collect::<BTreeMap<_, _>>()
}

pub(super) fn arb_relays(g: &mut Generator) -> BTreeMap<RelayId, Host<u64>> {
    let n = g.count(1, 2);
    (0..n)
        .map(|_| {
            let id = g.fresh_relay_id();
            let seed = g.u64();
            let latency = g.latency(50);
            let host = Host::new(seed, latency, 3478, EdgeConfig::Open, g.nat_ip4());
            let host = with_interface(host, Some(g.socket_ip4()), Some(g.socket_ip6()));
            (id, host)
        })
        .collect::<BTreeMap<_, _>>()
}

pub(super) fn with_interface<T>(
    mut host: Host<T>,
    ip4: Option<Ipv4Addr>,
    ip6: Option<Ipv6Addr>,
) -> Host<T> {
    host.update_interface(ip4, ip6);
    host
}

/// Network edge configurations worth varying in the system-level harness.
fn arb_edge_config(g: &mut Generator) -> EdgeConfig {
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
pub(super) fn arb_socket_ip_stack(g: &mut Generator) -> (Option<Ipv4Addr>, Option<Ipv6Addr>) {
    match g.choose_index(3) {
        0 => (Some(g.socket_ip4()), None),
        1 => (None, Some(g.socket_ip6())),
        _ => (Some(g.socket_ip4()), Some(g.socket_ip6())),
    }
}

fn arb_listening_port(g: &mut Generator) -> u16 {
    match g.choose_index(3) {
        0 => 52625,
        1 => 3478,
        _ => {
            // NonZeroU16
            g.u16_in(1..=u16::MAX)
        }
    }
}

// ---------------------------------------------------------------------------
// DNS records
// ---------------------------------------------------------------------------

fn arb_dns_resource_records(g: &mut Generator, portal: &StubPortal, at: Instant) -> DnsRecords {
    portal
        .dns_resources()
        .into_iter()
        .map(|resource| arb_records_for_dns_resource(g, resource.address, at))
        .fold(DnsRecords::default(), merge_dns_records)
}

/// Site-specific DNS records for a gateway: records for the DNS resources in
/// `site`, plus (when non-empty) some site-specific TXT/SRV records.
fn arb_site_specific_dns_records(
    g: &mut Generator,
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

fn arb_records_for_dns_resource(g: &mut Generator, address: String, at: Instant) -> DnsRecords {
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

fn arb_subdomain_records(g: &mut Generator, base: String, at: Instant) -> DnsRecords {
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
fn arb_resolved_ips(g: &mut Generator) -> BTreeSet<OwnedRecordData> {
    let n = g.count(1, 5);
    (0..n)
        .map(|_| dns_types::records::ip(arb_dns_resource_ip(g)))
        .collect::<BTreeSet<_>>()
}

fn arb_dns_resource_ip(g: &mut Generator) -> IpAddr {
    if g.bool() {
        // TEST-NET-2 198.51.100.0/24 (256 addrs, small => overlap likely).
        let last = g.u8();
        IpAddr::V4(Ipv4Addr::new(198, 51, 100, last))
    } else {
        // Subnet of 2001:db8::/32.
        let n = g.u16();
        IpAddr::V6(Ipv6Addr::new(0x2001, 0xDB80, 0x2020, 0x2020, 0, 0, 0, n))
    }
}

/// Global DNS records: 0..=4 domains, each with 1..=5 records (IP or TXT).
fn arb_global_dns_records(g: &mut Generator, at: Instant) -> DnsRecords {
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
pub(super) fn arb_dns_record_set(g: &mut Generator) -> BTreeSet<OwnedRecordData> {
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
fn arb_icmp_error_hosts(g: &mut Generator, records: &DnsRecords, now: Instant) -> IcmpErrorHosts {
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

fn arb_icmp_error(g: &mut Generator) -> crate::icmp_error_hosts::IcmpError {
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
    g: &mut Generator,
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
            let port = g.u16_in(1..=u16::MAX);

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

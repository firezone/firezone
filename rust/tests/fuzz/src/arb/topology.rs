use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    time::Duration,
};

use connlib_model::{ClientId, GatewayId, RelayId, Site, SiteId};
use dns_types::{DomainName, OwnedRecordData};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use smallvec::SmallVec;
use tunnel_proto::MaliciousBehaviour;
use tunnel_proto::messages::{Filter, PortRange, UpstreamDo53};

use super::context::Generator;
use super::packets::{host_in_v4, host_in_v6};
use super::values::{
    arb_address_description, arb_cidr_resource_address, arb_dns_resource_address,
    arb_domain_matching_dns_resource, arb_filters, arb_ip_stack_kind, arb_more_specific_subnet,
    arb_system_dns_servers, arb_tree_name, arb_upstream_do53_servers, arb_upstream_doh_servers,
};
use crate::dns_records::DnsRecords;
use crate::os::SimulatedOs;
use crate::ref_client::RefClient;
use crate::ref_gateway::RefGateway;
use crate::reference::ReferenceState;
use crate::resource::{CidrResource, DevicePoolResource, DnsResource, InternetResource};
use crate::sim_net::{EdgeConfig, Expiry, FilterMode, Host, Mapping, RoutingTable};
use crate::site_network::{IcmpError, RouteType, Routes};
use crate::stub_portal::{PoolMembers, StubPortal};

pub(super) fn generate(
    g: &mut Generator,
    portal: &StubPortal,
    domain_tree: Vec<DomainName>,
) -> ReferenceState {
    let clients = arb_clients(g, portal);
    let dns_resource_records = arb_dns_resource_records(g, portal, &domain_tree);
    let host_routes = arb_host_routes(g, &dns_resource_records, portal.upstream_do53());
    let sites = arb_sites(g, portal, &host_routes);
    let tcp_services = arb_tcp_services(g, &dns_resource_records, &sites);
    let gateways = arb_gateways(g, portal, &domain_tree, &sites);
    let relays = arb_relays(g);

    let global_dns_records = merge_dns_records(
        arb_global_dns_records(g, &domain_tree),
        dns_resource_records,
    );

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
        global_dns_records,
        domain_tree,
        tcp_services,
        network,
    )
}

pub(super) fn pick_site<'a>(g: &mut Generator, sites: &'a [Site]) -> &'a Site {
    &sites[g.choose_index(sites.len())]
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
        .collect()
}

pub(super) fn with_interface<T>(
    mut host: Host<T>,
    ip4: Option<Ipv4Addr>,
    ip6: Option<Ipv6Addr>,
) -> Host<T> {
    host.update_interface(ip4, ip6);

    host
}

pub(super) fn arb_socket_ip_stack(g: &mut Generator) -> (Option<Ipv4Addr>, Option<Ipv6Addr>) {
    match g.choose_index(3) {
        0 => (Some(g.socket_ip4()), None),
        1 => (None, Some(g.socket_ip6())),
        _ => (Some(g.socket_ip4()), Some(g.socket_ip6())),
    }
}

pub(super) fn arb_dns_record_set(
    g: &mut Generator,
    subnet: Option<(Ipv4Network, Ipv6Network)>,
) -> BTreeSet<OwnedRecordData> {
    let n = g.count(1, 5);

    (0..n)
        .map(|_| {
            if g.flip(75) {
                return dns_types::records::ip(arb_dns_resource_ip(g, subnet));
            }

            let sections = g.count(6, 10);
            let content = (0..sections)
                .flat_map(|_| std::iter::once(255u8).chain(std::iter::repeat_n(b'a', 255)))
                .collect::<Vec<_>>();
            dns_types::records::txt(content)
                .unwrap_or_else(|_| dns_types::records::ip(arb_dns_resource_ip(g, subnet)))
        })
        .collect::<BTreeSet<_>>()
}

const SITE_NAMES: [&str; 3] = ["sydney", "us-west", "us-east"];

pub(super) fn arb_stub_portal(g: &mut Generator, domain_tree: &[DomainName]) -> StubPortal {
    let internet_site = Site {
        id: g.fresh_site_id(),
        name: "Internet".to_owned(),
    };
    let regular_sites = (0..g.count(1, 3))
        .map(|i| Site {
            id: g.fresh_site_id(),
            name: SITE_NAMES[i].to_owned(),
        })
        .collect::<SmallVec<[_; 3]>>();
    g.allocate_site_subnets(&regular_sites);

    let clients = (0..2)
        .map(|_| (g.fresh_client_id(), g.tunnel_ip4(), g.tunnel_ip6()))
        .collect::<SmallVec<[_; 2]>>();

    let upstream_do53 = arb_upstream_do53_servers(g);
    let upstream_doh = arb_upstream_doh_servers(g);

    let cidr_resources = arb_cidr_resources(g, &regular_sites, &upstream_do53);
    let dns_resources = arb_dns_resources(g, &regular_sites, domain_tree);
    let device_pool_resources = (0..g.count(0, 3))
        .map(|_| arb_device_pool_resource(g, &clients))
        .collect::<SmallVec<[_; 3]>>();

    let internet_resource = arb_internet_resource(g, &internet_site);

    let gateways_by_site = std::iter::once(&internet_site)
        .chain(&regular_sites)
        .map(|site| {
            let gateways = (0..g.count(1, 3))
                .map(|_| (g.fresh_gateway_id(), g.tunnel_ip4(), g.tunnel_ip6()))
                .collect::<SmallVec<[_; 3]>>();
            (site.id, gateways)
        })
        .collect::<BTreeMap<_, _>>();

    let search_domain = arb_search_domain(g, &dns_resources);

    StubPortal::new(
        clients,
        gateways_by_site,
        regular_sites,
        g.u32(),
        g.u32(),
        cidr_resources,
        dns_resources,
        device_pool_resources,
        internet_resource,
        search_domain,
        upstream_do53,
        upstream_doh,
    )
    .with_iceless(g.bool())
}

fn arb_cidr_resource(g: &mut Generator, site: &Site) -> CidrResource {
    let id = g.fresh_resource_id();
    let address = match g.site_subnet(site.id).filter(|_| g.flip(50)) {
        Some(subnet) => arb_local_cidr_address(g, subnet),
        None => arb_cidr_resource_address(g),
    };

    CidrResource {
        id,
        address,
        name: g.lower_ascii(4, 10),
        address_description: arb_address_description(g),
        sites: vec![site.clone()],
        filters: arb_filters(g),
    }
}

/// Picks a network around a site's subnet, which may also cover other sites' subnets.
fn arb_local_cidr_address(g: &mut Generator, (v4, v6): (Ipv4Network, Ipv6Network)) -> IpNetwork {
    if g.bool() {
        let ip = host_in_v4(g, v4);
        let netmask = g.count(24, 32) as u8;

        return IpNetwork::V4(Ipv4Network::new_truncate(ip, netmask).unwrap());
    }

    let ip = host_in_v6(g, v6);
    let netmask = g.count(46, 128) as u8;

    IpNetwork::V6(Ipv6Network::new_truncate(ip, netmask).unwrap())
}

fn arb_dns_resource(g: &mut Generator, site: &Site, domain_tree: &[DomainName]) -> DnsResource {
    DnsResource {
        id: g.fresh_resource_id(),
        address: arb_dns_resource_address(g, domain_tree),
        name: g.lower_ascii(4, 10),
        address_description: arb_address_description(g),
        sites: vec![site.clone()],
        ip_stack: arb_ip_stack_kind(g),
        filters: arb_filters(g),
    }
}

fn arb_internet_resource(g: &mut Generator, site: &Site) -> InternetResource {
    InternetResource {
        name: "Internet Resource".to_owned(),
        id: g.fresh_resource_id(),
        sites: vec![site.clone()],
    }
}

fn arb_device_pool_resource(
    g: &mut Generator,
    clients: &[(ClientId, Ipv4Addr, Ipv6Addr)],
) -> (DevicePoolResource, PoolMembers) {
    let resource = DevicePoolResource {
        id: g.fresh_resource_id(),
        name: g.lower_ascii(4, 10),
        filters: arb_filters(g),
    };
    let members = if g.bool() {
        PoolMembers::AllClients
    } else {
        PoolMembers::Listed(
            clients
                .iter()
                .filter(|_| g.bool())
                .map(|(id, _, _)| *id)
                .collect(),
        )
    };

    (resource, members)
}

fn arb_cidr_resources(
    g: &mut Generator,
    sites: &[Site],
    upstream_do53: &[tunnel_proto::messages::UpstreamDo53],
) -> SmallVec<[CidrResource; 8]> {
    (0..g.count(1, 4))
        .flat_map(|_| {
            let site = pick_site(g, sites);
            let resource = arb_cidr_resource(g, site);
            let sibling = g.flip(50).then(|| {
                let extra_bits = match resource.address {
                    IpNetwork::V4(network) => (32 - network.netmask()) as usize,
                    IpNetwork::V6(network) => (128 - network.netmask()) as usize,
                };
                let address = if extra_bits > 0 && g.flip(50) {
                    arb_more_specific_subnet(g, resource.address, extra_bits)
                } else {
                    resource.address
                };

                CidrResource {
                    id: g.fresh_resource_id(),
                    address,
                    name: g.lower_ascii(4, 10),
                    address_description: None,
                    sites: resource.sites.clone(),
                    filters: arb_filters(g),
                }
            });

            [Some(resource), sibling]
                .into_iter()
                .flatten()
                .map(|resource| {
                    let allow_do53 = upstream_do53
                        .iter()
                        .any(|server| resource.address.contains(server.ip))
                        && g.flip(80);
                    let filters = resource
                        .filters
                        .iter()
                        .cloned()
                        .chain(
                            allow_do53
                                .then_some([
                                    Filter::Udp(PortRange::single(53)),
                                    Filter::Tcp(PortRange::single(53)),
                                ])
                                .into_iter()
                                .flatten(),
                        )
                        .collect();

                    CidrResource {
                        filters,
                        ..resource
                    }
                })
                .collect::<SmallVec<[_; 2]>>()
        })
        .collect()
}

fn arb_dns_resources(
    g: &mut Generator,
    sites: &[Site],
    domain_tree: &[DomainName],
) -> SmallVec<[DnsResource; 8]> {
    (0..g.count(1, 6))
        .map(|_| {
            let site = pick_site(g, sites);
            arb_dns_resource(g, site, domain_tree)
        })
        .collect()
}

fn arb_search_domain(g: &mut Generator, dns_resources: &[DnsResource]) -> Option<DomainName> {
    if !g.flip(50) {
        return None;
    }

    let candidates = || {
        dns_resources.iter().filter_map(|resource| {
            let (_, search) = resource.address.split_once('.')?;
            DomainName::vec_from_str(search).ok()
        })
    };
    let count = candidates().count();
    let index = (count > 0).then(|| g.choose_index(count))?;

    candidates().nth(index)
}

fn arb_clients(g: &mut Generator, portal: &StubPortal) -> BTreeMap<ClientId, Host<RefClient>> {
    portal
        .client_tunnel_ips()
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
    let send_untracked_icmp_errors = g.bool();
    let os = arb_simulated_os(g);
    let ignore_no_authorization_events = g.bool();

    let inner = RefClient::new(
        id,
        key,
        tun4,
        tun6,
        system_dns,
        internet_resource_active,
        MaliciousBehaviour {
            ignore_resource_filters,
            send_untracked_icmp_errors,
            ignore_no_authorization_events,
        },
        os,
    );

    let (ip4, ip6) = arb_socket_ip_stack(g);
    let port = arb_listening_port(g);
    let latency = g.latency(250);
    let edge = arb_edge_config(g);
    with_interface(Host::new(inner, latency, port, edge, g.nat_ip4()), ip4, ip6)
}

fn arb_gateways(
    g: &mut Generator,
    portal: &StubPortal,
    domain_tree: &[DomainName],
    sites: &BTreeMap<SiteId, SiteView>,
) -> BTreeMap<GatewayId, Host<RefGateway>> {
    portal
        .gateway_tunnel_ips()
        .map(|(id, tun4, tun6, site_id)| {
            let site = sites[&site_id].clone();
            let site_specific = arb_site_specific_dns_records(g, portal, site_id, domain_tree);
            let inner = RefGateway::from_parts(
                g.fresh_private_key(),
                tun4,
                tun6,
                site.routes,
                site_specific,
                site.unresolvable_names,
            );
            let latency = g.latency(200);
            let edge = arb_edge_config(g);
            let host = Host::new(inner, latency, 52625, edge, g.nat_ip4());
            let host = with_interface(host, Some(g.socket_ip4()), Some(g.socket_ip6()));
            (id, host)
        })
        .collect::<BTreeMap<_, _>>()
}

fn arb_simulated_os(g: &mut Generator) -> SimulatedOs {
    match g.choose_index(5) {
        0 => SimulatedOs::Linux,
        1 => SimulatedOs::Android,
        2 => SimulatedOs::MacOs,
        3 => SimulatedOs::Ios,
        _ => SimulatedOs::Windows,
    }
}

fn arb_edge_config(g: &mut Generator) -> EdgeConfig {
    match g.choose_index(3) {
        0 => EdgeConfig::Open,
        1 => {
            let filter = match g.choose_index(3) {
                0 => FilterMode::Open,
                1 => FilterMode::AddressRestricted,
                _ => FilterMode::PortRestricted,
            };

            EdgeConfig::Nat(Mapping::EndpointIndependent, filter, arb_expiry(g))
        }
        _ => EdgeConfig::Nat(
            Mapping::EndpointDependent,
            FilterMode::PortRestricted,
            arb_expiry(g),
        ),
    }
}

/// Samples NAT idle timers found in the wild, from netfilter's 30s unreplied
/// default up to carrier-grade minutes.
///
/// Every timer sits above connlib's 25s keep-alive cadences (the path agent's
/// `PRIMARY_KEEPALIVE`, snownet's `BINDING_INTERVAL`): a correct implementation
/// refreshes every flow it depends on at least that often, including reply
/// traffic on the pair the peer chose, so any expiry-induced connectivity loss
/// is a real liveness bug and not an artifact of the model.
fn arb_expiry(g: &mut Generator) -> Expiry {
    let timeout = Duration::from_secs(match g.choose_index(4) {
        0 => 30,
        1 => 60,
        2 => 120,
        _ => 300,
    });

    Expiry {
        timeout,
        inbound_refreshes: g.bool(),
    }
}

fn arb_listening_port(g: &mut Generator) -> u16 {
    match g.choose_index(3) {
        0 => 52625,
        1 => 3478,
        _ => g.u16_in(1..=u16::MAX),
    }
}

/// Generates the names each DNS resource resolves, some of them local to the resource's site.
///
/// A name keeps the network it was first generated in, so all its addresses are in one.
fn arb_dns_resource_records(
    g: &mut Generator,
    portal: &StubPortal,
    domain_tree: &[DomainName],
) -> DnsRecords {
    let mut records = DnsRecords::default();
    let mut owners = BTreeMap::<DomainName, Option<SiteId>>::new();

    for resource in portal.dns_resources() {
        let local = resource
            .sites
            .first()
            .map(|site| site.id)
            .filter(|_| g.flip(50));

        for _ in 0..arb_name_count(g, &resource.address) {
            let name = arb_domain_matching_dns_resource(g, &resource.address, domain_tree);
            let owner = *owners.entry(name.clone()).or_insert(local);
            let subnet = owner.and_then(|site| g.site_subnet(site));

            records.merge(DnsRecords::from_iter([(name, arb_resolved_ips(g, subnet))]));
        }
    }

    g.set_local_names(
        owners
            .into_iter()
            .filter_map(|(name, owner)| Some((name, owner?)))
            .collect(),
    );

    records
}

fn arb_site_specific_dns_records(
    g: &mut Generator,
    portal: &StubPortal,
    site: SiteId,
    domain_tree: &[DomainName],
) -> DnsRecords {
    portal
        .dns_resources()
        .filter(|resource| resource.sites.iter().any(|candidate| candidate.id == site))
        .map(|resource| arb_records_for_dns_resource(g, &resource.address, domain_tree))
        .fold(DnsRecords::default(), merge_dns_records)
}

fn arb_records_for_dns_resource(
    g: &mut Generator,
    address: &str,
    domain_tree: &[DomainName],
) -> DnsRecords {
    (0..arb_name_count(g, address))
        .map(|_| {
            (
                arb_domain_matching_dns_resource(g, address, domain_tree),
                arb_resolved_ips(g, None),
            )
        })
        .collect()
}

fn arb_name_count(g: &mut Generator, address: &str) -> usize {
    if address.contains('*') || address.contains('?') {
        return g.count(1, 3);
    }

    1
}

fn merge_dns_records(mut records: DnsRecords, next: DnsRecords) -> DnsRecords {
    records.merge(next);
    records
}

fn arb_resolved_ips(
    g: &mut Generator,
    subnet: Option<(Ipv4Network, Ipv6Network)>,
) -> BTreeSet<OwnedRecordData> {
    let n = g.count(1, 5);

    (0..n)
        .map(|_| dns_types::records::ip(arb_dns_resource_ip(g, subnet)))
        .collect::<BTreeSet<_>>()
}

/// Picks a public address, or one in `subnet`.
fn arb_dns_resource_ip(g: &mut Generator, subnet: Option<(Ipv4Network, Ipv6Network)>) -> IpAddr {
    if g.bool() {
        let last = g.u8();

        return match subnet {
            None => IpAddr::V4(Ipv4Addr::new(198, 51, 100, last)),
            Some((v4, _)) => {
                let host = u32::from(last) % (1 << (32 - v4.netmask()));

                IpAddr::V4(Ipv4Addr::from(u32::from(v4.network_address()) + host))
            }
        };
    }

    let n = g.u16();

    match subnet {
        None => IpAddr::V6(Ipv6Addr::new(0x2001, 0xDB80, 0x2020, 0x2020, 0, 0, 0, n)),
        Some((_, v6)) => IpAddr::V6(Ipv6Addr::from(
            u128::from(v6.network_address()) + u128::from(n),
        )),
    }
}

/// Generates records for names from the tree; a name local to a site resolves within its subnet.
fn arb_global_dns_records(g: &mut Generator, domain_tree: &[DomainName]) -> DnsRecords {
    let n = g.count(0, 4);
    (0..n)
        .map(|_| {
            let domain = arb_tree_name(g, domain_tree);
            let subnet = g.local_subnet(&domain);
            let records = arb_dns_record_set(g, subnet);

            (domain, records)
        })
        .collect::<DnsRecords>()
}

/// Generates the routes every site shares: hosts that answer with an ICMP error.
fn arb_host_routes(
    g: &mut Generator,
    records: &DnsRecords,
    upstream_do53: &[UpstreamDo53],
) -> Vec<(IpNetwork, RouteType)> {
    let mut unreachable = records
        .ips_iter()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .filter_map(|ip| {
            if !g.bool() {
                return None;
            }

            Some((ip, arb_icmp_error(g)))
        })
        .collect::<BTreeMap<_, _>>();

    // An upstream DNS resolver may be unreachable from the Gateways' networks;
    // recursive queries tunnelled to it fail with an ICMP error instead of a response.
    for server in upstream_do53 {
        if g.flip(25) {
            unreachable.insert(server.ip, arb_icmp_error(g));
        }
    }

    unreachable
        .into_iter()
        .map(|(ip, error)| (IpNetwork::from(ip), RouteType::Unreachable(error)))
        .collect()
}

/// What the Gateways of a site share.
#[derive(Clone)]
struct SiteView {
    routes: Routes,
    unresolvable_names: BTreeSet<DomainName>,
}

/// Generates the view of each site with Gateways.
///
/// A site delivers to its own subnet and answers traffic to other sites' subnets the same
/// way, and its resolver may not resolve names local to other sites.
fn arb_sites(
    g: &mut Generator,
    portal: &StubPortal,
    host_routes: &[(IpNetwork, RouteType)],
) -> BTreeMap<SiteId, SiteView> {
    let sites = portal
        .gateway_tunnel_ips()
        .map(|(_, _, _, site)| site)
        .collect::<BTreeSet<_>>();
    let local_names = g.local_names().clone();

    sites
        .into_iter()
        .map(|site| {
            let unreachable = match g.choose_index(3) {
                0 => RouteType::Blackhole,
                1 => RouteType::Unreachable(IcmpError::Network),
                _ => RouteType::Unreachable(IcmpError::Host),
            };
            let default_routes = [
                IpNetwork::V4(Ipv4Network::new(Ipv4Addr::UNSPECIFIED, 0).unwrap()),
                IpNetwork::V6(Ipv6Network::new(Ipv6Addr::UNSPECIFIED, 0).unwrap()),
            ]
            .map(|network| (network, RouteType::Deliver));
            let subnet_routes = g.site_subnets().iter().flat_map(|(owner, (v4, v6))| {
                let route = if *owner == site {
                    RouteType::Deliver
                } else {
                    unreachable
                };

                [(IpNetwork::V4(*v4), route), (IpNetwork::V6(*v6), route)]
            });
            let routes = Routes::new(
                default_routes
                    .into_iter()
                    .chain(subnet_routes)
                    .chain(host_routes.iter().copied()),
            );

            let unresolvable_names = local_names
                .iter()
                .filter(|(_, owner)| **owner != site)
                .filter(|_| g.flip(50))
                .map(|(name, _)| name.clone())
                .collect();

            (
                site,
                SiteView {
                    routes,
                    unresolvable_names,
                },
            )
        })
        .collect()
}

fn arb_icmp_error(g: &mut Generator) -> IcmpError {
    match g.choose_index(5) {
        0 => IcmpError::Network,
        1 => IcmpError::Host,
        2 => IcmpError::Port,
        3 => IcmpError::PacketTooBig { mtu: g.u32() },
        _ => IcmpError::TimeExceeded { code: 0 },
    }
}

fn arb_tcp_services(
    g: &mut Generator,
    records: &DnsRecords,
    sites: &BTreeMap<SiteId, SiteView>,
) -> BTreeMap<DomainName, BTreeSet<u16>> {
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

            let is_unreachable = records
                .domain_ips_iter(&domain)
                .any(|ip| sites.values().any(|site| !site.routes.delivers(ip)));
            let has_ips = records.domain_ips_iter(&domain).next().is_some();
            if is_unreachable || !has_ips {
                return None;
            }

            Some((domain, BTreeSet::from([port])))
        })
        .collect::<BTreeMap<_, _>>()
}

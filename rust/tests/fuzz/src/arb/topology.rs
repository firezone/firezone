use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Duration,
};

use connlib_model::{ClientId, GatewayId, RelayId, Site, SiteId};
use dns_types::{DomainName, OwnedRecordData};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use smallvec::SmallVec;
use tunnel_proto::MaliciousBehaviour;
use tunnel_proto::messages::{Filter, PortRange, UpstreamDo53, client::DevicePoolMember};

use super::context::Generator;
use super::values::{
    arb_address_description, arb_cidr_resource_address, arb_domain_name_string, arb_filters,
    arb_ip_stack_kind, arb_more_specific_subnet, arb_system_dns_servers, arb_upstream_do53_servers,
    arb_upstream_doh_servers,
};
use crate::dns_records::DnsRecords;
use crate::icmp_error_hosts::{IcmpError, IcmpErrorHosts};
use crate::os::SimulatedOs;
use crate::ref_client::RefClient;
use crate::ref_gateway::RefGateway;
use crate::reference::ReferenceState;
use crate::resource::{
    CidrResource, DnsResource, DynamicDevicePoolResource, InternetResource,
    StaticDevicePoolResource,
};
use crate::sim_net::{EdgeConfig, Expiry, FilterMode, Host, Mapping, RoutingTable};
use crate::stub_portal::StubPortal;

pub(super) fn generate(g: &mut Generator) -> ReferenceState {
    let portal = arb_stub_portal(g);
    let clients = arb_clients(g, &portal);
    let gateways = arb_gateways(g, &portal);
    let relays = arb_relays(g);
    let dns_resource_records = arb_dns_resource_records(g, &portal);
    let icmp_error_hosts =
        arb_icmp_error_hosts(g, &clients, &dns_resource_records, portal.upstream_do53());
    let tcp_resources = arb_tcp_resources(g, &dns_resource_records, &icmp_error_hosts);

    let global_dns_records = merge_dns_records(arb_global_dns_records(g), dns_resource_records);

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

pub(super) fn arb_dns_record_set(g: &mut Generator) -> BTreeSet<OwnedRecordData> {
    let n = g.count(1, 5);

    (0..n)
        .map(|_| {
            if g.flip(75) {
                return dns_types::records::ip(arb_dns_resource_ip(g));
            }

            let sections = g.count(6, 10);
            let content = (0..sections)
                .flat_map(|_| std::iter::once(255u8).chain(std::iter::repeat_n(b'a', 255)))
                .collect::<Vec<_>>();
            dns_types::records::txt(content)
                .unwrap_or_else(|_| dns_types::records::ip(arb_dns_resource_ip(g)))
        })
        .collect::<BTreeSet<_>>()
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
        .collect::<SmallVec<[_; 3]>>();

    let clients = (0..2)
        .map(|_| (g.fresh_client_id(), g.tunnel_ip4(), g.tunnel_ip6()))
        .collect::<SmallVec<[_; 2]>>();

    let upstream_do53 = arb_upstream_do53_servers(g);
    let upstream_doh = arb_upstream_doh_servers(g);

    let cidr_resources = arb_cidr_resources(g, &regular_sites, &upstream_do53);
    let dns_resources = arb_dns_resources(g, &regular_sites);
    let device_pool_resources = (0..g.count(0, 2))
        .map(|_| arb_dynamic_device_pool_resource(g))
        .collect::<SmallVec<[_; 2]>>();

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

    let static_device_pool_resources = (0..g.count(0, 3))
        .map(|_| arb_static_device_pool_resource(g, &clients))
        .collect::<SmallVec<[_; 3]>>();
    let search_domain = arb_search_domain(g, &dns_resources);

    StubPortal::new(
        clients,
        gateways_by_site,
        regular_sites,
        g.u32(),
        cidr_resources,
        dns_resources,
        device_pool_resources,
        static_device_pool_resources,
        internet_resource,
        search_domain,
        upstream_do53,
        upstream_doh,
    )
    .with_iceless(g.bool())
}

fn arb_cidr_resource(g: &mut Generator, site: &Site) -> CidrResource {
    CidrResource {
        id: g.fresh_resource_id(),
        address: arb_cidr_resource_address(g),
        name: g.lower_ascii(4, 10),
        address_description: arb_address_description(g),
        sites: vec![site.clone()],
        filters: arb_filters(g),
    }
}

fn arb_dns_resource(g: &mut Generator, site: &Site) -> DnsResource {
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

fn arb_dynamic_device_pool_resource(g: &mut Generator) -> DynamicDevicePoolResource {
    let base = arb_domain_name_string(g, 2, 3);
    DynamicDevicePoolResource {
        id: g.fresh_resource_id(),
        name: g.lower_ascii(4, 10),
        address: format!("*.{base}"),
    }
}

fn arb_static_device_pool_resource(
    g: &mut Generator,
    clients: &[(ClientId, Ipv4Addr, Ipv6Addr)],
) -> StaticDevicePoolResource {
    let n_online_members = g.count(0, 2);
    let n_offline_members = g.count(0, 2);
    let online_members = clients
        .iter()
        .take(n_online_members)
        .map(|(id, ipv4, ipv6)| DevicePoolMember {
            id: *id,
            ipv4: Ipv4Network::new(*ipv4, 32).unwrap(),
            ipv6: Ipv6Network::new(*ipv6, 128).unwrap(),
        });
    let offline_members = (0..n_offline_members).map(|_| DevicePoolMember {
        id: g.fresh_client_id(),
        ipv4: Ipv4Network::new(g.tunnel_ip4(), 32).unwrap(),
        ipv6: Ipv6Network::new(g.tunnel_ip6(), 128).unwrap(),
    });
    let devices = online_members.chain(offline_members).collect();

    StaticDevicePoolResource {
        id: g.fresh_resource_id(),
        name: g.lower_ascii(4, 10),
        filters: arb_filters(g),
        devices,
    }
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

fn arb_dns_resources(g: &mut Generator, sites: &[Site]) -> SmallVec<[DnsResource; 8]> {
    (0..g.count(1, 4))
        .flat_map(|_| {
            let site = pick_site(g, sites);
            let resource = arb_dns_resource(g, site);
            let sibling = g.flip(50).then(|| {
                let address = if let Some(base) = resource.address.strip_prefix("**.") {
                    match g.choose_index(3) {
                        0 => resource.address.clone(),
                        1 => format!("*.{base}"),
                        _ => format!("{}.{base}", g.lower_ascii(3, 6)),
                    }
                } else if let Some(base) = resource.address.strip_prefix("*.") {
                    match g.choose_index(2) {
                        0 => resource.address.clone(),
                        _ => format!("{}.{base}", g.lower_ascii(3, 6)),
                    }
                } else {
                    resource.address.clone()
                };

                DnsResource {
                    id: g.fresh_resource_id(),
                    address,
                    name: g.lower_ascii(4, 10),
                    address_description: None,
                    sites: resource.sites.clone(),
                    ip_stack: resource.ip_stack,
                    filters: arb_filters(g),
                }
            });

            [Some(resource), sibling].into_iter().flatten()
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
        },
        os,
    );

    let (ip4, ip6) = arb_socket_ip_stack(g);
    let port = arb_listening_port(g);
    let latency = g.latency(250);
    let edge = arb_edge_config(g);
    with_interface(Host::new(inner, latency, port, edge, g.nat_ip4()), ip4, ip6)
}

fn arb_gateways(g: &mut Generator, portal: &StubPortal) -> BTreeMap<GatewayId, Host<RefGateway>> {
    portal
        .gateway_tunnel_ips()
        .map(|(id, tun4, tun6, site_id)| {
            let site_specific = arb_site_specific_dns_records(g, portal, site_id);
            let inner = RefGateway::from_parts(g.fresh_private_key(), tun4, tun6, site_specific);
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

fn arb_dns_resource_records(g: &mut Generator, portal: &StubPortal) -> DnsRecords {
    portal
        .dns_resources()
        .map(|resource| arb_records_for_dns_resource(g, &resource.address))
        .fold(DnsRecords::default(), merge_dns_records)
}

fn arb_site_specific_dns_records(
    g: &mut Generator,
    portal: &StubPortal,
    site: SiteId,
) -> DnsRecords {
    portal
        .dns_resources()
        .filter(|resource| resource.sites.iter().any(|candidate| candidate.id == site))
        .map(|resource| arb_records_for_dns_resource(g, &resource.address))
        .fold(DnsRecords::default(), merge_dns_records)
}

fn arb_records_for_dns_resource(g: &mut Generator, address: &str) -> DnsRecords {
    match address.split_once('.') {
        Some(("*", base)) => arb_subdomain_records(g, base.to_owned()),
        Some(("**", base)) => arb_subdomain_records(g, base.to_owned()),
        _ => DnsRecords::from([(address.parse::<DomainName>().unwrap(), arb_resolved_ips(g))]),
    }
}

fn merge_dns_records(mut records: DnsRecords, next: DnsRecords) -> DnsRecords {
    records.merge(next);
    records
}

fn arb_subdomain_records(g: &mut Generator, base: String) -> DnsRecords {
    let n = g.count(1, 3);
    (0..n)
        .map(|_| {
            let label = g.lower_ascii(3, 6);
            let domain = format!("{label}.{base}").parse::<DomainName>().unwrap();
            (domain, arb_resolved_ips(g))
        })
        .collect::<DnsRecords>()
}

fn arb_resolved_ips(g: &mut Generator) -> BTreeSet<OwnedRecordData> {
    let n = g.count(1, 5);

    (0..n)
        .map(|_| dns_types::records::ip(arb_dns_resource_ip(g)))
        .collect::<BTreeSet<_>>()
}

fn arb_dns_resource_ip(g: &mut Generator) -> IpAddr {
    if g.bool() {
        let last = g.u8();

        IpAddr::V4(Ipv4Addr::new(198, 51, 100, last))
    } else {
        let n = g.u16();

        IpAddr::V6(Ipv6Addr::new(0x2001, 0xDB80, 0x2020, 0x2020, 0, 0, 0, n))
    }
}
fn arb_global_dns_records(g: &mut Generator) -> DnsRecords {
    let n = g.count(0, 4);
    (0..n)
        .map(|_| {
            let domain = arb_domain_name_string(g, 2, 3)
                .parse::<DomainName>()
                .unwrap();
            (domain, arb_dns_record_set(g))
        })
        .collect::<DnsRecords>()
}

fn arb_icmp_error_hosts(
    g: &mut Generator,
    clients: &BTreeMap<ClientId, Host<RefClient>>,
    records: &DnsRecords,
    upstream_do53: &[UpstreamDo53],
) -> IcmpErrorHosts {
    let mut ips = records
        .ips_iter()
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

    let mut entries = chosen
        .into_iter()
        .map(|ip| (ip, arb_icmp_error(g)))
        .collect::<BTreeMap<_, _>>();

    // An upstream DNS resolver may be unreachable from the Gateways' networks;
    // recursive queries tunnelled to it fail with an ICMP error instead of a response.
    for server in upstream_do53 {
        if g.flip(25) {
            entries.insert(server.ip, arb_icmp_error(g));
        }
    }

    // Traffic to a Client terminates at its TUN IP; nothing is routed beyond it.
    // A port that nothing listens on is therefore the only error it can originate.
    //
    // Only a Client that ignores its own flow tracking gets to answer this way: an
    // honest build drops the error before it leaves, because no flow of its own and
    // no route to the peer covers it.
    for client in clients.values() {
        let client = client.inner();

        if !client.malicious_behaviour.send_untracked_icmp_errors {
            continue;
        }

        entries.insert(client.tunnel_ip4.into(), IcmpError::Port);
        entries.insert(client.tunnel_ip6.into(), IcmpError::Port);
    }

    IcmpErrorHosts::from_entries(entries)
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

fn arb_tcp_resources(
    g: &mut Generator,
    records: &DnsRecords,
    icmp_error_hosts: &IcmpErrorHosts,
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
                .domain_ips_iter(&domain)
                .any(|ip| icmp_error_hosts.icmp_error_for_ip(ip).is_some());
            if has_icmp_error {
                return None;
            }

            let addresses = records
                .domain_ips_iter(&domain)
                .map(|ip| SocketAddr::new(ip, port))
                .collect::<BTreeSet<_>>();
            (!addresses.is_empty()).then_some((domain, addresses))
        })
        .collect::<BTreeMap<_, _>>()
}

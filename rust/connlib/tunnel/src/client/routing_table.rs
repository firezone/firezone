use std::{
    collections::{BTreeMap, BTreeSet},
    net::IpAddr,
    ops::RangeInclusive,
};

use connlib_shared::messages::{client::ResourceDescription, ResourceId};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use ip_packet::{IpPacket, Protocol};
use itertools::Itertools;
use rangemap::RangeInclusiveMap;

#[derive(Default)]
pub(crate) struct ResourceRoutingTable {
    table: IpNetworkTable<FilterMap>,
}

#[derive(Default, Clone)]
pub struct FilterMap {
    tcp: RangeInclusiveMap<u16, ResourceId>,
    udp: RangeInclusiveMap<u16, ResourceId>,
    icmp: Option<ResourceId>,
    permit_all: Option<ResourceId>,
}

impl FilterMap {
    fn match_packet(&self, packet: &IpPacket) -> Option<ResourceId> {
        let maybe_resource = match packet.destination_protocol() {
            Ok(Protocol::Tcp(tcp)) => self.tcp.get(&tcp).cloned(),
            Ok(Protocol::Udp(udp)) => self.udp.get(&udp).cloned(),
            Ok(Protocol::Icmp(_)) => self.icmp,
            Err(_) => None,
        };

        maybe_resource.or(self.permit_all)
    }
}

fn non_replacing_insert(
    map: &mut RangeInclusiveMap<u16, ResourceId>,
    range: &RangeInclusive<u16>,
    id: ResourceId,
) {
    let gaps = map.gaps(range).collect_vec();
    for gap in gaps {
        map.insert(gap, id);
    }
}

impl ResourceRoutingTable {
    pub(crate) fn calculate_table(
        resources: &BTreeMap<ResourceId, ResourceDescription>,
        disabled_resources: &BTreeSet<ResourceId>,
    ) -> ResourceRoutingTable {
        let mut table: IpNetworkTable<FilterMap> = IpNetworkTable::new();
        for resource in resources.values().sorted_by_key(|r| r.id()) {
            if disabled_resources.contains(&resource.id()) {
                continue;
            }
            match resource {
                ResourceDescription::Cidr(cidr) => {
                    if table.exact_match_mut(cidr.address).is_none() {
                        table.insert(cidr.address, Default::default());
                    }

                    let filter_table = table.exact_match_mut(cidr.address).unwrap();
                    if cidr.filters.is_empty() {
                        filter_table.permit_all = Some(cidr.id);
                    }

                    for filter in &cidr.filters {
                        match filter {
                            connlib_shared::messages::Filter::Udp(udp) => {
                                non_replacing_insert(&mut filter_table.udp, &udp.range(), cidr.id);
                            }
                            connlib_shared::messages::Filter::Tcp(tcp) => {
                                non_replacing_insert(&mut filter_table.tcp, &tcp.range(), cidr.id);
                            }
                            connlib_shared::messages::Filter::Icmp => {
                                filter_table.icmp.get_or_insert(cidr.id);
                            }
                        }
                    }
                }
                ResourceDescription::Internet(internet) => {
                    let mut filter_table: FilterMap = FilterMap {
                        permit_all: Some(internet.id),
                        ..Default::default()
                    };

                    filter_table.permit_all = Some(internet.id);

                    table.insert(Ipv4Network::DEFAULT_ROUTE, filter_table.clone());
                    table.insert(Ipv6Network::DEFAULT_ROUTE, filter_table);
                }
                ResourceDescription::Dns(_) => {}
            }
        }

        ResourceRoutingTable { table }
    }

    pub(crate) fn resource_id_by_dest_and_port(
        &self,
        packet: &IpPacket,
        dst: IpAddr,
    ) -> Option<ResourceId> {
        let possible_routes = self.table.matches(dst);
        let mut maybe_route = None;
        // TODO: we need these routes to be ordered with more specific to less
        for (route, filter_map) in possible_routes {
            if let Some((old_route, _)) = maybe_route {
                if !is_route_more_specific(old_route, route) {
                    continue;
                }
            }

            if let Some(resource) = filter_map.match_packet(packet) {
                maybe_route = Some((route, resource));
            }
        }

        maybe_route.map(|r| r.1)
    }

    // TODO: might remove later
    pub(crate) fn any_route_for_ip(&self, ip: IpAddr) -> bool {
        self.table.longest_match(ip).is_some()
    }

    pub(crate) fn routes(&self) -> impl Iterator<Item = IpNetwork> + '_ {
        self.table.iter().map(|(ip, _)| ip)
    }
}

fn is_route_more_specific(old_route: IpNetwork, new_route: IpNetwork) -> bool {
    match (old_route, new_route) {
        (IpNetwork::V4(old_route), IpNetwork::V4(new_route)) => {
            old_route.netmask() < new_route.netmask()
        }
        (IpNetwork::V6(old_route), IpNetwork::V6(new_route)) => {
            old_route.netmask() < new_route.netmask()
        }
        _ => unreachable!("cant compare between different ip versions"),
    }
}

use std::{
    collections::{HashMap, HashSet},
    net::IpAddr,
    ops::RangeInclusive,
};

use connlib_shared::messages::{client::ResourceDescription, Filters, ResourceId};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use itertools::Itertools;
use rangemap::{RangeInclusiveMap, RangeMap};

pub(crate) struct ResourceRoutingTable {
    table: IpNetworkTable<ResourceMap>,
}

#[derive(Default)]
struct ResourceMap {
    udp: RangeInclusiveMap<u16, ResourceId>,
    tcp: RangeInclusiveMap<u16, ResourceId>,
    icmp: Option<ResourceId>,
}

fn resource_map_from_fitlers(filters: &Filters, id: ResourceId) -> ResourceMap {
    let mut resource_map = ResourceMap::default();
    if filters.is_empty() {
        resource_map.udp.insert(0..=u16::MAX, id);
        resource_map.tcp.insert(0..=u16::MAX, id);
        resource_map.icmp = Some(id);
    }

    for filter in filters {
        match filter {
            connlib_shared::messages::Filter::Udp(p) => resource_map
                .udp
                .insert(p.port_range_start..=p.port_range_end, id),
            connlib_shared::messages::Filter::Tcp(p) => resource_map
                .tcp
                .insert(p.port_range_start..=p.port_range_end, id),
            connlib_shared::messages::Filter::Icmp => {
                resource_map.icmp = Some(id);
            }
        }
    }

    resource_map
}

// Note if no intersection this function is wrong
fn range_intersection(a: &RangeInclusive<u16>, b: &RangeInclusive<u16>) -> RangeInclusive<u16> {
    *(a.start()).max(b.start())..=*(a.end()).min(b.end())
}

// TODO: This might take more parameters
fn udp_priority(a: &ResourceDescription, b: &ResourceDescription) -> ResourceId {
    todo!()
}

// TODO: This might take more parameters
fn tcp_priority(a: &ResourceDescription, b: &ResourceDescription) -> ResourceId {
    todo!()
}

// TODO: This might take more parameters
fn icmp_priority(a: &ResourceDescription, b: &ResourceDescription) -> ResourceId {
    todo!()
}

fn add_range(
    map: &mut RangeInclusiveMap<u16, ResourceId>,
    range: &RangeInclusive<u16>,
    resource: &ResourceDescription,
    resources: &HashMap<ResourceId, ResourceDescription>,
    priority: impl Fn(&ResourceDescription, &ResourceDescription) -> ResourceId,
) {
    let mut intersections = Vec::new();
    let overlaps = map.overlapping(range);
    // Done in 2 phases to satisfy the borrow checker
    for (overlap, id) in overlaps {
        let intersection = range_intersection(overlap, range);
        intersections.push((intersection, resource.id()));
    }

    for (intersection, id) in intersections {
        map.insert(
            intersection,
            priority(resource, resources.get(&id).expect("TODO: inconsistency")),
        );
    }

    let gaps = map.gaps(&range).collect_vec();

    // gaps_mut would let us do this without cloning
    for gap in gaps {
        map.insert(gap, resource.id());
    }
}

fn insert_resource(
    table: &mut IpNetworkTable<ResourceMap>,
    address: impl Into<IpNetwork> + Copy,
    resource: &ResourceDescription,
    resources: &HashMap<ResourceId, ResourceDescription>,
) {
    let Some(route) = table.exact_match_mut(address) else {
        table.insert(
            address,
            resource_map_from_fitlers(&resource.filters(), resource.id()),
        );
        return;
    };

    for f in resource.filters() {
        match f {
            connlib_shared::messages::Filter::Udp(p) => {
                let range = p.port_range_start..=p.port_range_end;
                add_range(&mut route.udp, &range, resource, resources, udp_priority);
            }
            connlib_shared::messages::Filter::Tcp(p) => {
                let range = p.port_range_start..=p.port_range_end;
                add_range(&mut route.udp, &range, resource, resources, tcp_priority);
            }
            connlib_shared::messages::Filter::Icmp => {
                let Some(id) = route.icmp else {
                    route.icmp = Some(resource.id());
                    return;
                };

                route.icmp = Some(icmp_priority(
                    resource,
                    resources.get(&id).expect("TODO: consistency"),
                ));
            }
        }
    }
}

fn addresses(
    resource: &ResourceDescription,
    fqdn_to_ips: &HashMap<String, HashSet<IpAddr>>,
) -> Option<Vec<IpNetwork>> {
    let address = match resource {
        ResourceDescription::Dns(r) => &r.address,
        ResourceDescription::Cidr(r) => return Some(vec![r.address]),
    };

    let addresses = fqdn_to_ips.get(address)?;
    Some(addresses.iter().copied().map_into().collect_vec())
}

impl ResourceRoutingTable {
    fn calculate_table<'a>(
        resources: HashMap<ResourceId, ResourceDescription>,
        fqdn_to_ips: HashMap<String, HashSet<IpAddr>>,
    ) -> ResourceRoutingTable {
        let mut table = IpNetworkTable::new();
        for resource in resources.values() {
            let Some(addresses) = addresses(resource, &fqdn_to_ips) else {
                continue;
            };

            for address in addresses {
                insert_resource(&mut table, address, resource, &resources);
            }
        }

        ResourceRoutingTable { table }
    }
}

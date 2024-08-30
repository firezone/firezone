use std::{collections::HashMap, net::IpAddr, ops::RangeInclusive};

use connlib_shared::messages::{client::ResourceDescription, ResourceId};
use ip_network::{Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use ip_packet::{IpPacket, Protocol};
use itertools::Itertools;
use rangemap::RangeInclusiveMap;

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
            Ok(Protocol::Icmp(_)) => self.icmp.clone(),
            Err(_) => None,
        };

        maybe_resource.or(self.permit_all.clone())
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
        resources: HashMap<ResourceId, ResourceDescription>,
    ) -> ResourceRoutingTable {
        let mut table: IpNetworkTable<FilterMap> = IpNetworkTable::new();
        for resource in resources.values().sorted_by_key(|r| r.id()) {
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

    pub(crate) fn resource_id_by_dest_and_port(&self, packet: &IpPacket) -> Option<ResourceId> {
        let possible_routes = self.table.matches(packet.destination());
        // TODO: we need these routes to be ordered with more specific to less
        for (_, route) in possible_routes {
            route.match_packet(packet)
        }
    }
}
